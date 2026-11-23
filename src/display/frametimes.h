// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#ifndef FRAMETIMES_H
#define FRAMETIMES_H

#include <cstdio>
#include <string>

class FrameTimes
{
public:
    enum Part
    {
        /* The scripts of the game, between two frames. */
        Game,
        Draw,
        Sleep,
        /* The swap, which waits for the screen. */
        Screen,
        PartCount
    };

    /* Gives the time since the last call to `part`. */
    void mark(Part part, double seconds)
    {
        if (running)
            frame[part] += seconds - last;
        last = seconds;
        running = true;
    }

    /* Ends a frame. `budget` is the time that the frame rate gives to
     * one frame. The result is a report of the frames before this one
     * when they fill `reportSeconds` or had another budget, and ""
     * otherwise. */
    std::string frameDone(double budget, bool drawn)
    {
        std::string report;
        if (frames > 0 && (budget != frameBudget || seconds() >= reportSeconds))
            report = takeReport();
        frameBudget = budget;

        double period = 0;
        for (int part = 0; part < PartCount; ++part)
            period += frame[part];
        bool late = period > lateFactor * budget;
        for (int part = 0; part < PartCount; ++part)
        {
            total[part] += frame[part];
            if (late)
                lateTotal[part] += frame[part];
            frame[part] = 0;
        }
        ++frames;
        if (!drawn)
            ++notDrawn;
        if (late)
            ++lateFrames;
        if (period > longest)
            longest = period;
        return report;
    }

    static constexpr double reportSeconds = 10;
    static constexpr double lateFactor = 1.5;

private:
    double seconds() const
    {
        double sum = 0;
        for (int part = 0; part < PartCount; ++part)
            sum += total[part];
        return sum;
    }

    std::string takeReport()
    {
        double span = seconds();
        double meanMs = 1000.0 / frames;
        char text[400];
        int length = std::snprintf(
            text, sizeof(text),
            "%d frames in %.1f s, %.1f of %.0f fps. "
            "Mean ms: game %.1f, draw %.1f, sleep %.1f, screen %.1f.",
            frames, span, span > 0 ? frames / span : 0, 1 / frameBudget,
            total[Game] * meanMs, total[Draw] * meanMs,
            total[Sleep] * meanMs, total[Screen] * meanMs);
        if (notDrawn > 0)
            length += std::snprintf(text + length, sizeof(text) - length,
                                    " %d not drawn.", notDrawn);
        if (lateFrames > 0)
            std::snprintf(text + length, sizeof(text) - length,
                          " Late: %d frames, longest %.1f ms. "
                          "Their sum in ms: game %.1f, draw %.1f, sleep %.1f, screen %.1f.",
                          lateFrames, longest * 1000,
                          lateTotal[Game] * 1000, lateTotal[Draw] * 1000,
                          lateTotal[Sleep] * 1000, lateTotal[Screen] * 1000);

        frames = notDrawn = lateFrames = 0;
        longest = 0;
        for (int part = 0; part < PartCount; ++part)
            total[part] = lateTotal[part] = 0;
        return text;
    }

    double last = 0;
    bool running = false;
    double frame[PartCount] = {};

    double frameBudget = 0;
    int frames = 0;
    int notDrawn = 0;
    int lateFrames = 0;
    double longest = 0;
    double total[PartCount] = {};
    double lateTotal[PartCount] = {};
};

#endif // FRAMETIMES_H
