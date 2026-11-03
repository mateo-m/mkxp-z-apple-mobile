#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Compile many sources with one compiler command, one job per CPU.
#
# Usage:
#   printf '%s %s\n' <source> <object> ... |
#       tools/compile-parallel.sh <compiler> [<flag> ...]
#
# Each input line is a source and its object, without spaces. Each
# line runs `<compiler> [<flag> ...] -c <source> -o <object>`. The
# script fails when one compile fails, after the others end.
set -eu

if [ "$#" -eq 0 ]; then
    echo "compile-parallel: no compiler command" >&2
    exit 2
fi

# -J is the BSD form: the input pair goes where % is, before the
# compiler command.
# shellcheck disable=SC2016 # the child shell expands $1 and $2
xargs -n 2 -P "$(sysctl -n hw.ncpu)" -J % sh -c '
    src="$1"
    obj="$2"
    shift 2
    echo "  -> ${src##*/}"
    exec "$@" -c "$src" -o "$obj"
' compile-parallel % "$@"
