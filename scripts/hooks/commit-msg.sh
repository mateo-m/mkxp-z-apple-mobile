#!/bin/sh
# commit-msg: single-line subject only, no co-author trailers.

set -e

MSG_FILE=$1

sh scripts/hooks/verify-no-coauthors.sh message "$MSG_FILE"

MSG=$(cat "$MSG_FILE")

NON_EMPTY_LINES=$(printf '%s\n' "$MSG" | sed '/./,$!d' | wc -l | tr -d ' ')
if [ "$NON_EMPTY_LINES" -gt 1 ]; then
    printf 'commit-msg failed: use a single-line subject only (no commit body)\n' >&2
    exit 1
fi

SUBJECT=$(printf '%s\n' "$MSG" | sed '/./,$!d' | head -1)
if [ -z "$(printf '%s' "$SUBJECT" | tr -d '[:space:]')" ]; then
    printf 'commit-msg failed: empty commit message\n' >&2
    exit 1
fi
