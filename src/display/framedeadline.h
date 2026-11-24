// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#ifndef FRAMEDEADLINE_H
#define FRAMEDEADLINE_H

#include <cstdint>

/* Call at the start of each frame, on the thread that runs it. */
void startFrameDeadline(uint64_t frameNanoseconds);

#endif // FRAMEDEADLINE_H
