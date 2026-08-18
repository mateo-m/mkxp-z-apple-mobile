#!/bin/sh
# Build libmkxpz-core.a - the engine-core static library (everything
# under src/: renderer, audio, event loop, filesystem, host bridge) -
# for one Apple SDK. The Ruby binding half (binding/ + hmode7/) is NOT
# included. It links against a specific libruby and is built separately
# by its consumer (e.g. the Empo launcher's mkxp*-merged.o targets).
#
# This script is the single source of truth for compiling the engine
# core: launcher makefiles and this repo's CI both call it, so a
# published artifact is byte-for-byte the product of this recipe at a
# public commit. Compile-only: it needs dependency *headers* (SDL2,
# pixman, OpenAL, physfs, ANGLE, ...) but no dependency libraries.
#
# Usage:
#   tools/build-core-ios.sh --sdk iphoneos|iphonesimulator \
#       --out <libdir> --obj <objdir> \
#       --include <dir> [--include <dir> ...] \
#       [--arch arm64] [--min-os 26.0]
#
# Outputs into <libdir>:
#   libmkxpz-core.a
#   .mkxp-core-fingerprint   (see tools/core-fingerprint.sh)
#
# Incremental: an object is rebuilt when its source, or any engine
# header, is newer than the object. EXTRA_CORE_CFLAGS is appended to
# every compile when set.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

SDK=""
ARCH=arm64
MIN_OS=26.0
OUT=""
OBJ=""
DEP_INCLUDES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --sdk) SDK="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --min-os) MIN_OS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --obj) OBJ="$2"; shift 2 ;;
        --include) DEP_INCLUDES="$DEP_INCLUDES -I$2"; shift 2 ;;
        *) echo "build-core-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

if [ -z "$SDK" ] || [ -z "$OUT" ] || [ -z "$OBJ" ]; then
    echo "build-core-ios: --sdk, --out and --obj are required" >&2
    exit 2
fi

case "$SDK" in
    iphoneos)
        TARGET_FLAG="-miphoneos-version-min=$MIN_OS -target ${ARCH}-apple-ios${MIN_OS}"
        ;;
    iphonesimulator)
        TARGET_FLAG="-mios-simulator-version-min=$MIN_OS -target ${ARCH}-apple-ios${MIN_OS}-simulator"
        ;;
    *)
        echo "build-core-ios: unsupported --sdk $SDK" >&2
        exit 2
        ;;
esac

SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
AR="$(xcrun --sdk "$SDK" -f ar)"
RANLIB="$(xcrun --sdk "$SDK" -f ranlib)"

# Compiler launcher: use ccache when available (CORE_NO_CCACHE=1
# opts out). Purely a speed layer. Output is identical.
LAUNCHER=""
if [ "${CORE_NO_CCACHE:-0}" != "1" ] && command -v ccache >/dev/null 2>&1; then
    LAUNCHER="ccache"
fi

# Engine include dirs mirror the flat header layout the sources expect.
ENGINE_INCLUDES="\
 -I$ENGINE \
 -I$ENGINE/src \
 -I$ENGINE/src/audio \
 -I$ENGINE/src/crypto \
 -I$ENGINE/src/display \
 -I$ENGINE/src/display/gl \
 -I$ENGINE/src/display/libnsgif \
 -I$ENGINE/src/etc \
 -I$ENGINE/src/filesystem \
 -I$ENGINE/src/input \
 -I$ENGINE/src/net \
 -I$ENGINE/src/system \
 -I$ENGINE/src/theoraplay \
 -I$ENGINE/src/util \
 -I$ENGINE/binding \
 -I$ENGINE/shader"

# Shared feature flags come from src/mkxpz-buildconfig.h (force-
# included below). Only per-consumer parameters stay as -D options.
# The escaped quotes are intentional: expanded unquoted, the compiler
# receives -DMKXPZ_VERSION="1.0.0" and the macro is a C string.
# shellcheck disable=SC2089
DEFINES="\
 -DMKXPZ_VERSION=\"1.0.0\" \
 -DMKXPZ_GIT_HASH=\"ios\" \
 -DMKXPZ_RUBY_VERSION=\"3.1\" \
 -DMKXPZ_RUBY_VERSION_MAJOR=3 \
 -DMKXPZ_RUBY_VERSION_MINOR=1 \
 -DMKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES"

BUILDCONFIG="-include $ENGINE/src/mkxpz-buildconfig.h"

# shellcheck disable=SC2090 # literal quotes in DEFINES are intended
COMMON_FLAGS="-isysroot $SYSROOT $TARGET_FLAG -arch $ARCH -O3 \
$ENGINE_INCLUDES $DEP_INCLUDES $BUILDCONFIG $DEFINES ${EXTRA_CORE_CFLAGS:-}"

mkdir -p "$OBJ" "$OUT"

list_sources() {
    cd "$ENGINE"
    find src -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.mm' \) -print |
        LC_ALL=C sort
}

COUNT="$(list_sources | wc -l | tr -d ' ')"
if [ "$COUNT" -lt 10 ]; then
    echo "build-core-ios: only $COUNT sources found under $ENGINE/src; refusing" >&2
    exit 1
fi

needs_rebuild() {
    # $1 = object path, $2 = source path (engine-relative)
    [ -f "$1" ] || return 0
    [ "$ENGINE/$2" -nt "$1" ] && return 0
    # Any engine header newer than the object invalidates it (headers
    # define shared struct layouts, a coarse check beats silent UB).
    [ -n "$(find "$ENGINE/src" -name '*.h' -newer "$1" -print | head -n 1)" ]
}

echo "[mkxpz-core] Compiling engine core for $SDK ($ARCH, min $MIN_OS)..."
COMPILED=0
for src in $(list_sources); do
    # Flatten the path into a unique object name (src/display/gl/
    # shader.cpp and a hypothetical src/shader.cpp must not collide).
    obj="$OBJ/$(echo "$src" | sed -e 's|^src/||' -e 's|/|__|g' \
        -e 's|\.cpp$|.o|' -e 's|\.mm$|.o|' -e 's|\.c$|.o|')"
    if ! needs_rebuild "$obj" "$src"; then
        continue
    fi
    echo "  -> $src"
    case "$src" in
        *.c)
            # shellcheck disable=SC2086,SC2090 # LAUNCHER/COMMON_FLAGS are word lists
            $LAUNCHER "$CC" $COMMON_FLAGS -c "$ENGINE/$src" -o "$obj"
            ;;
        *.mm)
            # shellcheck disable=SC2086,SC2090
            $LAUNCHER "$CXX" -std=c++14 -fdeclspec -fobjc-arc $COMMON_FLAGS \
                -c "$ENGINE/$src" -o "$obj"
            ;;
        *)
            # shellcheck disable=SC2086,SC2090
            $LAUNCHER "$CXX" -std=c++14 -fdeclspec $COMMON_FLAGS \
                -c "$ENGINE/$src" -o "$obj"
            ;;
    esac
    COMPILED=$((COMPILED + 1))
done

LIB="$OUT/libmkxpz-core.a"
if [ "$COMPILED" -gt 0 ] || [ ! -f "$LIB" ]; then
    echo "[mkxpz-core] Archiving $LIB ($COMPILED recompiled)..."
    rm -f "$LIB"
    # shellcheck disable=SC2046 # object list is newline-safe (no spaces)
    "$AR" rcs "$LIB" $(find "$OBJ" -name '*.o' | LC_ALL=C sort)
    "$RANLIB" "$LIB"
else
    echo "[mkxpz-core] Up to date ($LIB)"
fi

"$ENGINE/tools/core-fingerprint.sh" > "$OUT/.mkxp-core-fingerprint"
echo "[mkxpz-core] Done: $LIB"
