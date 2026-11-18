// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/*
** Pokémon Unbreakable Ties divides its camera step by
** Graphics.average_frame_rate. When a long pause counted as one frame,
** the step grew past 1 and the camera position grew until Plane#ox=
** raised a RangeError (Sentry EMPO-APP-3E).
*/

#include "harness.h"

#include "display/framerateaverage.h"

#include <cmath>

namespace {

const double frame = 1.0 / 60;

/* Shows 60 frames a second from `start` for `count` frames, and gives
 * back the time of the last one. */
double showFrames(FrameRateAverage &rate, double start, int count)
{
    double now = start;
    for (int i = 0; i < count; ++i)
    {
        now += frame;
        rate.frameShown(now);
    }
    return now;
}

bool near60(double fps) { return std::fabs(fps - 60) < 0.01; }

} // namespace

TEST(framerateaverage_reads_the_rate_of_steady_frames)
{
    FrameRateAverage rate;
    rate.restart(5);
    showFrames(rate, 5, 100);

    CHECK(near60(rate.average()));
}

TEST(framerateaverage_does_not_count_a_pause_as_a_frame)
{
    FrameRateAverage rate;
    rate.restart(0);
    double now = showFrames(rate, 0, 100);

    now += 30;
    rate.restart(now);
    showFrames(rate, now, 1);

    CHECK(near60(rate.average()));
}

TEST(framerateaverage_counts_a_slow_frame)
{
    FrameRateAverage rate;
    rate.restart(0);
    double now = showFrames(rate, 0, 40);

    rate.frameShown(now + 1);

    CHECK(rate.average() < 30);
}
