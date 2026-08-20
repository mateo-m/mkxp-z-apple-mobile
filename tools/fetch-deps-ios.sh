#!/bin/sh
# Download the prebuilt iOS dependency libraries this engine links
# against, so the repository can build a test host on its own.
#
# Both tarballs are public release assets, and the download needs no
# account and no `gh` CLI. deps/.version pins the versions and the
# sha256 of each one. Nothing is extracted before the checksum
# matches.
#
# Usage:
#   tools/fetch-deps-ios.sh [--sdk iphonesimulator|iphoneos|all]
#
# Result:
#   deps/build-<sdk>-arm64/{lib,include,ruby-stdlib}
#   deps/ANGLE/<sdk>/{lib,include}
#
# The tarball also carries mkxp*-merged.o and libmkxpz-core.a built
# from an older engine commit. Both are removed here. This repository
# builds them from the checked-out sources with tools/build-core-ios.sh
# and tools/build-binding-ios.sh.
#
# The download is skipped when a stamp file matches the pinned
# version. Delete deps/ to force a fresh fetch.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ENGINE/deps"
VERSION_FILE="$DEPS/.version"

if [ ! -f "$VERSION_FILE" ]; then
    echo "fetch-deps-ios: $VERSION_FILE missing" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$VERSION_FILE"

WANT_SDK=all
while [ "$#" -gt 0 ]
do
    case "$1" in
        --sdk) WANT_SDK="$2"; shift 2 ;;
        *) echo "fetch-deps-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

case "$WANT_SDK" in
    all|iphoneos|iphonesimulator) ;;
    *) echo "fetch-deps-ios: --sdk must be iphoneos, iphonesimulator or all" >&2; exit 2 ;;
esac

download() {
    # $1 = release tag, $2 = asset name, $3 = expected sha256,
    # $4 = destination file
    url="https://github.com/$DEPS_REPO/releases/download/$1/$2"
    echo "fetch-deps-ios: downloading $1/$2"
    if ! curl -fsSL --retry 3 -o "$4" "$url"; then
        echo "fetch-deps-ios: download failed: $url" >&2
        exit 1
    fi
    actual="$(shasum -a 256 "$4" | awk '{print $1}')"
    if [ "$actual" != "$3" ]; then
        echo "fetch-deps-ios: sha256 mismatch for $2" >&2
        echo "  expected: $3" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mkxpz-deps.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

mkdir -p "$DEPS"

# --- Dependency libraries and headers ---------------------------------
NATIVE_STAMP="$DEPS/.fetched-native"
if [ "$(cat "$NATIVE_STAMP" 2>/dev/null || true)" = "$NATIVE_DEPS_VERSION" ] &&
    [ -d "$DEPS/build-iphonesimulator-arm64/lib" ] &&
    [ -d "$DEPS/build-iphoneos-arm64/lib" ]; then
    echo "fetch-deps-ios: dependency libraries already at $NATIVE_DEPS_VERSION"
else
    download "$NATIVE_DEPS_VERSION" native-ios-prebuilt.tar.gz \
        "$NATIVE_DEPS_SHA256" "$SCRATCH/native.tar.gz"
    rm -rf "$DEPS/build-iphoneos-arm64" "$DEPS/build-iphonesimulator-arm64"
    # Tarball paths start at build-<sdk>-arm64/.
    tar -xzf "$SCRATCH/native.tar.gz" -C "$DEPS"
    # Drop the engine halves. They were built somewhere else, from
    # sources that may not match this checkout.
    rm -f "$DEPS"/build-*/lib/libmkxpz-core.a \
        "$DEPS"/build-*/lib/.mkxp-core-fingerprint \
        "$DEPS"/build-*/lib/mkxp*-merged.o \
        "$DEPS"/build-*/lib/.mkxp-binding-fingerprint
    rm -rf "$DEPS"/build-*/core-obj "$DEPS"/build-*/binding18 \
        "$DEPS"/build-*/binding19 "$DEPS"/build-*/binding31
    echo "$NATIVE_DEPS_VERSION" > "$NATIVE_STAMP"
    echo "fetch-deps-ios: dependency libraries at $NATIVE_DEPS_VERSION"
fi

# --- ANGLE ------------------------------------------------------------
ANGLE_STAMP="$DEPS/.fetched-angle"
if [ "$(cat "$ANGLE_STAMP" 2>/dev/null || true)" = "$ANGLE_VERSION" ] &&
    [ -d "$DEPS/ANGLE/iphonesimulator/lib" ] &&
    [ -d "$DEPS/ANGLE/iphoneos/lib" ]; then
    echo "fetch-deps-ios: ANGLE already at $ANGLE_VERSION"
else
    download "$ANGLE_VERSION" angle-ios-prebuilt.tar.gz \
        "$ANGLE_SHA256" "$SCRATCH/angle.tar.gz"
    rm -rf "$DEPS/ANGLE"
    mkdir -p "$DEPS/ANGLE"
    # Tarball paths start at <sdk>/.
    tar -xzf "$SCRATCH/angle.tar.gz" -C "$DEPS/ANGLE"
    echo "$ANGLE_VERSION" > "$ANGLE_STAMP"
    echo "fetch-deps-ios: ANGLE at $ANGLE_VERSION"
fi

# --- Report -----------------------------------------------------------
for sdk in iphoneos iphonesimulator
do
    if [ "$WANT_SDK" != "all" ] && [ "$WANT_SDK" != "$sdk" ]; then
        continue
    fi
    tree="$DEPS/build-$sdk-arm64"
    for needed in lib/libSDL2.a lib/libphysfs.a lib/libopenal.a include/SDL2 ruby-stdlib
    do
        if [ ! -e "$tree/$needed" ]; then
            echo "fetch-deps-ios: $tree/$needed missing after extract" >&2
            exit 1
        fi
    done
    if [ ! -e "$DEPS/ANGLE/$sdk/lib/libEGL_static.a" ]; then
        echo "fetch-deps-ios: deps/ANGLE/$sdk/lib/libEGL_static.a missing" >&2
        exit 1
    fi
    echo "fetch-deps-ios: $sdk ready"
done
