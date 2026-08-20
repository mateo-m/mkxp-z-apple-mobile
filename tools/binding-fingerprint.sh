#!/bin/sh
# Print a single content fingerprint (sha256) of every source that
# compiles into the mkxp{18,19,31}-merged.o binding objects:
#
#   - binding/*.{cpp,h}
#   - hmode7/src/*.{cpp,h}
#   - src/**/*.h, the headers the binding includes. A layout change
#     here must rebuild the merged objects, or the separately
#     compiled engine half sees a different ABI.
#   - multiruby/wrapper.cpp
#
# Whoever builds all three merged objects writes this value to
# <libdir>/.mkxp-binding-fingerprint, and only after the last one
# succeeds. tools/build-binding-ios.sh must not write it: it builds
# one version per run, so a partial build would stamp a set that is
# not there. A consumer recomputes the value per build and fails when
# the merged objects are stale. Paths are hashed relative to the
# repository root, so the fingerprint is identical across machines.
# Prebuilt tarballs must verify on a fresh clone.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

list_sources() {
    cd "$ENGINE"
    {
        find binding hmode7/src -type f \( -name '*.cpp' -o -name '*.h' \) -print
        find src -type f -name '*.h' -print
    } | LC_ALL=C sort
}

# Guard against silently hashing an empty list. A broken path would
# otherwise yield the well-known sha256 of no input.
COUNT="$(list_sources | wc -l | tr -d ' ')"
if [ "$COUNT" -lt 10 ]; then
    echo "binding-fingerprint: only $COUNT sources found under $ENGINE; refusing" >&2
    exit 1
fi

# The wrapper is hashed on its own line, after the sorted list. Keep
# that order. It is what the recorded fingerprints were built with.
cd "$ENGINE"
{
    list_sources | xargs shasum -a 256
    shasum -a 256 multiruby/wrapper.cpp
} | shasum -a 256 | awk '{print $1}'
