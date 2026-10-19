#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Prefer a modern Homebrew Ruby over macOS system Ruby so `bundle` can
# satisfy Gemfile.lock (bundler 4.x needs Ruby >= 3.2).

if [ -x /opt/homebrew/opt/ruby/bin/bundle ]; then
    PATH="/opt/homebrew/opt/ruby/bin:$PATH"
elif [ -x /usr/local/opt/ruby/bin/bundle ]; then
    PATH="/usr/local/opt/ruby/bin:$PATH"
fi

export PATH
