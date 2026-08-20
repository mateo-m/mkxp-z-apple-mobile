#!/bin/sh
# Pre-commit hook: format staged files, then lint / verify formatting.

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

. "$REPO_ROOT/scripts/hooks/ruby-env.sh"

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)

if [ -z "$STAGED" ]; then
    exit 0
fi

section() {
    printf '\n-> %s\n' "$1"
}

die() {
    printf '\npre-commit failed: %s\n' "$1" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

RUBY_PATHS="scripts/preload scripts/postload tests"
RUBY_STAGED=$(printf '%s\n' "$STAGED" | grep -E '^(scripts/(preload|postload)|tests)/' || true)
if [ -n "$RUBY_STAGED" ]; then
    section "rubocop --autocorrect-all (Ruby scripts)"
    require_tool bundle
    # RUBY_PATHS is a word list, so it stays unquoted.
    # shellcheck disable=SC2086
    bundle exec rubocop --autocorrect-all --format quiet $RUBY_PATHS
    # shellcheck disable=SC2086
    if ! git diff --quiet -- $RUBY_PATHS; then
        # shellcheck disable=SC2086
        git add $RUBY_PATHS
    fi

    section "rubocop (Ruby scripts)"
    # shellcheck disable=SC2086
    bundle exec rubocop $RUBY_PATHS ||
        die "rubocop failed"

    section "regression tests (Ruby scripts)"
    require_tool ruby
    for test in tools/test_*.rb; do
        ruby "$test" >/dev/null || die "$test failed"
    done
fi

CPP_STAGED=$(printf '%s\n' "$STAGED" | grep -E '^(src/|tests/cpp/)' || true)
if [ -n "$CPP_STAGED" ]; then
    section "host tests (C++)"
    require_tool c++
    "$REPO_ROOT/tools/run-cpp-tests.sh" ||
        die "the C++ host tests failed"
fi

MD_FILES=$(printf '%s\n' "$STAGED" | grep -E '\.md$' | grep -Ev '^(src/theoraplay/|hmode7/)' || true)
if [ -n "$MD_FILES" ]; then
    section "markdownlint (Markdown)"
    require_tool bun
    printf '%s\n' "$MD_FILES" | xargs bun x markdownlint -c .markdownlint.json ||
        die "markdownlint failed"
fi

printf '\npre-commit OK\n'
