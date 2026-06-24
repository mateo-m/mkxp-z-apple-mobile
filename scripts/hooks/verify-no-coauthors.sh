#!/bin/sh
# Fail when commit message text or a revision range contains co-author trailers.

set -e

mode=$1
target=$2

if [ -z "$mode" ]; then
    printf 'usage: verify-no-coauthors.sh message <file|->\n' >&2
    printf '       verify-no-coauthors.sh range <rev-range>\n' >&2
    printf '       verify-no-coauthors.sh pre-push\n' >&2
    exit 1
fi

has_coauthor_trailer() {
    printf '%s\n' "$1" | grep -Eiq '^[[:space:]]*co-authored-by:'
}

fail_on_coauthor() {
    sha=$1
    subject=$2
    printf 'co-author policy failed: commit %s\n%s\n' "$sha" "$subject" >&2
    exit 1
}

scan_range() {
    range=$1
    if ! git rev-parse --verify "$range^{commit}" >/dev/null 2>&1; then
        return 0
    fi
    for sha in $(git rev-list "$range"); do
        body=$(git log -1 --format='%B' "$sha")
        if has_coauthor_trailer "$body"; then
            fail_on_coauthor "$sha" "$body"
        fi
    done
}

case "$mode" in
    message)
        if [ -z "$target" ]; then
            printf 'verify-no-coauthors.sh message: missing file\n' >&2
            exit 1
        fi
        if [ "$target" = "-" ]; then
            MSG=$(cat)
        else
            MSG=$(cat "$target")
        fi
        if has_coauthor_trailer "$MSG"; then
            printf 'co-author policy failed: commit message contains Co-authored-by trailer\n' >&2
            exit 1
        fi
        ;;
    range)
        if [ -z "$target" ]; then
            printf 'verify-no-coauthors.sh range: missing rev-range\n' >&2
            exit 1
        fi
        scan_range "$target"
        ;;
    pre-push)
        ZERO=0000000000000000000000000000000000000000
        while read -r _ local_sha _ remote_sha; do
            [ -n "$local_sha" ] || continue
            [ "$local_sha" = "$ZERO" ] && continue
            if [ "$remote_sha" = "$ZERO" ]; then
                scan_range "$local_sha"
            else
                scan_range "${remote_sha}..${local_sha}"
            fi
        done
        ;;
    *)
        printf 'verify-no-coauthors.sh: unknown mode %s\n' "$mode" >&2
        exit 1
        ;;
esac
