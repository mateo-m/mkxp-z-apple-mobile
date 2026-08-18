#!/bin/sh
# Print a single content fingerprint (sha256) of every source that
# compiles into libmkxpz-core.a (the prebuilt engine-core static
# library): src/**/*.{c,cpp,mm,h}.
#
# tools/build-core-ios.sh writes this value next to the library as
# .mkxp-core-fingerprint after each build. Consumers (e.g. the Empo
# launcher's scripts/verify-native-deps.sh) recompute it per build and
# fail when the prebuilt core is stale relative to the checked-out
# engine sources. Paths are hashed relative to the engine root so the
# fingerprint is identical across machines (prebuilt tarballs must
# verify on fresh clones).
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

list_sources() {
    cd "$ENGINE"
    find src -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.mm' -o -name '*.h' \) -print |
        LC_ALL=C sort
}

# Guard against silently hashing an empty list (e.g. a broken path
# would otherwise yield the well-known empty-input sha256).
COUNT="$(list_sources | wc -l | tr -d ' ')"
if [ "$COUNT" -lt 10 ]; then
    echo "core-fingerprint: only $COUNT sources found under $ENGINE; refusing" >&2
    exit 1
fi

(cd "$ENGINE" && list_sources | xargs shasum -a 256) |
    shasum -a 256 | awk '{print $1}'
