#!/bin/sh
# Build + run the engine's host-runnable unit tests. Plain C++17, no
# OS or engine dependencies (the tested code is the OS-free state
# machine in src/island_state.h) - runs anywhere a C++ compiler
# exists: dev Macs, Linux CI, pre-commit hooks.
set -e

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="${TMPDIR:-/tmp}/mkxpz-island-state-test"

CXX=${CXX:-c++}
"$CXX" -std=c++17 -Wall -Wextra -Werror -g \
    "$REPO_ROOT/tests/island_state_test.cpp" \
    -o "$OUT"

"$OUT"
