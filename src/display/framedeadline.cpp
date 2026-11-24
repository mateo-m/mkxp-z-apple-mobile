// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#include "framedeadline.h"

#include "app_bridge.h"

/* This header declares the `Rect` of MacTypes.h, so no file that
 * includes etc.h can include it. */
#include <AudioToolbox/AudioWorkInterval.h>
#include <cstdio>
#include <mach/mach_time.h>
#include <os/object.h>
#include <os/workgroup.h>

namespace
{

/* The game thread sleeps for most of each frame. iOS reads that as
 * light work and keeps the thread on the efficiency cores at a low
 * clock speed: on an A15, the scripts of a map frame take 7 ms, and
 * 1.6 ms on a performance core. The user-interactive QoS class, a fixed
 * priority and the real-time policy do not change that. A work interval
 * does, but only when it runs from one frame to the next and so holds
 * the sleep. An interval that ends when the work ends shows iOS a
 * deadline that is easy to meet, and the thread stays where it is. */
class FrameDeadline
{
public:
    /* The thread that joined must leave before it ends, or iOS stops
     * the process. */
    ~FrameDeadline()
    {
        if (state == Open)
            (void)os_workgroup_interval_finish(interval, nullptr);
        if (state == Joined || state == Open)
            os_workgroup_leave(interval, &token);
        if (interval)
            os_release(interval);
    }

    void nextFrame(uint64_t frameNanoseconds)
    {
        if (state == Off)
            return;
        if (state == New && !join())
            return;
        /* An interval that did not finish stays open in iOS, and the
         * thread cannot leave while it is open. */
        if (state == Open && os_workgroup_interval_finish(interval, nullptr) != 0)
            return;

        uint64_t now = mach_absolute_time();
        uint64_t deadline = now + frameNanoseconds * timebase.denom / timebase.numer;
        state = os_workgroup_interval_start(interval, now, deadline, nullptr) == 0 ? Open : Joined;
    }

private:
    enum State
    {
        New,
        Off,
        Joined,
        Open
    };

    bool join()
    {
        mach_timebase_info(&timebase);
        interval = AudioWorkIntervalCreate("frame", OS_CLOCK_MACH_ABSOLUTE_TIME, nullptr);
        int error = interval ? os_workgroup_join(interval, &token) : -1;
        state = error == 0 ? Joined : Off;

        char message[64];
        std::snprintf(message, sizeof(message), "frame work interval: %s (%d)",
                      error == 0 ? "on" : "off", error);
        mkxp_debugLog("INFO", "frame-deadline", message);
        return error == 0;
    }

    State state = New;
    os_workgroup_interval_t interval = nullptr;
    os_workgroup_join_token_s token{};
    mach_timebase_info_data_t timebase{};
};

} // namespace

void startFrameDeadline(uint64_t frameNanoseconds)
{
    static thread_local FrameDeadline deadline;
    deadline.nextFrame(frameNanoseconds);
}
