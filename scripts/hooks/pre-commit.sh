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

RUBY_STAGED=$(printf '%s\n' "$STAGED" | grep -E '^scripts/(preload|postload)/' || true)
if [ -n "$RUBY_STAGED" ]; then
    section "rubocop --autocorrect-all (Ruby compat scripts)"
    require_tool bundle
    bundle exec rubocop --autocorrect-all --format quiet scripts/preload scripts/postload
    if ! git diff --quiet -- scripts/preload scripts/postload; then
        git add scripts/preload scripts/postload
    fi

    section "rubocop (Ruby compat scripts)"
    bundle exec rubocop scripts/preload scripts/postload ||
        die "rubocop failed"
fi

MD_FILES=$(printf '%s\n' "$STAGED" | grep -E '\.md$' | grep -Ev '^(src/theoraplay/|hmode7/)' || true)
if [ -n "$MD_FILES" ]; then
    section "markdownlint (Markdown)"
    require_tool bun
    printf '%s\n' "$MD_FILES" | xargs bun x markdownlint -c .markdownlint.json ||
        die "markdownlint failed"
fi

printf '\npre-commit OK\n'
