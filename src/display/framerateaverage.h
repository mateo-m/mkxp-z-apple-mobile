// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#ifndef FRAMERATEAVERAGE_H
#define FRAMERATEAVERAGE_H

#include <algorithm>
#include <deque>
#include <numeric>
#include <vector>

class FrameRateAverage
{
public:
    void frameShown(double seconds)
    {
        if (hasLastFrame)
        {
            if (intervals.size() > 40)
                intervals.pop_front();
            intervals.push_back(seconds - lastFrame);
        }
        lastFrame = seconds;
        hasLastFrame = true;
    }

    /* `fallback` is the rate until two frames are shown. */
    double average(double fallback) const
    {
        double total = std::accumulate(intervals.begin(), intervals.end(), 0.0);
        if (total <= 0)
            return fallback;
        return intervals.size() / total;
    }

    /* One slow frame does not move the median, but a slowdown that
     * lasts does. */
    double medianRate(double fallback) const
    {
        if (intervals.empty())
            return fallback;
        std::vector<double> sorted(intervals.begin(), intervals.end());
        auto middle = sorted.begin() + sorted.size() / 2;
        std::nth_element(sorted.begin(), middle, sorted.end());
        if (*middle <= 0)
            return fallback;
        return 1 / *middle;
    }

private:
    std::deque<double> intervals;
    double lastFrame = 0;
    bool hasLastFrame = false;
};

#endif // FRAMERATEAVERAGE_H
