#!/bin/sh
# Create a signed, single-line commit from staged changes.
# Use this instead of `git commit` when Co-authored-by trailers would be injected.

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

MSG=
ALLOW_EMPTY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -m)
            MSG=$2
            shift 2
            ;;
        --allow-empty)
            ALLOW_EMPTY=1
            shift
            ;;
        *)
            printf 'usage: scripts/git/commit.sh [-m <message>] [--allow-empty]\n' >&2
            exit 1
            ;;
    esac
done

if [ -z "$MSG" ]; then
    printf 'scripts/git/commit.sh: -m is required\n' >&2
    exit 1
fi

if git diff --cached --quiet; then
    if [ "$ALLOW_EMPTY" -ne 1 ]; then
        printf 'scripts/git/commit.sh: no staged changes (pass --allow-empty to create an empty commit)\n' >&2
        exit 1
    fi
fi

TMP_MSG=$(mktemp)
trap 'rm -f "$TMP_MSG"' EXIT INT TERM
printf '%s\n' "$MSG" >"$TMP_MSG"
sh scripts/hooks/commit-msg.sh "$TMP_MSG"

# Always run the hook script directly so checks cannot be skipped via
# LEFTHOOK=0 or a missing lefthook install.
if ! git diff --cached --quiet; then
    sh scripts/hooks/pre-commit.sh
    TREE=$(git write-tree)
else
    TREE=$(git rev-parse 'HEAD^{tree}')
fi

if git rev-parse --verify HEAD >/dev/null 2>&1; then
    PARENT=$(git rev-parse HEAD)
    NEW=$(git commit-tree -S -m "$MSG" -p "$PARENT" "$TREE")
else
    NEW=$(git commit-tree -S -m "$MSG" "$TREE")
fi

BRANCH=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
if [ -n "$BRANCH" ]; then
    git update-ref "refs/heads/$BRANCH" "$NEW"
else
    git update-ref HEAD "$NEW"
fi

printf 'Created %s\n' "$NEW"
