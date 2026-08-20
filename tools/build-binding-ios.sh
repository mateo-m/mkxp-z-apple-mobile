#!/bin/sh
# Build mkxp<NN>-merged.o, the Ruby binding half of the engine, for one
# Ruby version and one Apple SDK.
#
# The engine ships three Ruby versions in one binary. To do that it
# compiles binding/ and hmode7/ once per Ruby version, merges each
# compile with that version's libruby through `ld -r`, and demotes
# every Ruby-defined symbol to private-extern with
# -unexported_symbols_list. Hidden Ruby symbols cannot clash across
# versions, so each merged object exports exactly one global symbol,
# `_mkxp_get_script_binding_<NN>`, which returns its ScriptBinding
# vtable. See docs/multi-ruby.md.
#
# This script is the single source of truth for that recipe. Launcher
# makefiles call it and supply only SDK paths and the libruby
# archives, so the merged objects a launcher links are the product of
# this recipe at a public commit.
#
# Usage:
#   tools/build-binding-ios.sh --ruby 18|19|31 \
#       --sdk iphoneos|iphonesimulator \
#       --out <libdir> --obj <objdir> --scratch <dir> \
#       --static-lib <libruby-static.a> --ext-lib <libruby-ext.a> \
#       --ruby-include <dir> \
#       --include <dir> [--include <dir> ...] \
#       [--arch arm64] [--min-os 26.0]
#
# Outputs into <libdir>:
#   mkxp<NN>-merged.o
#
# It does NOT write <libdir>/.mkxp-binding-fingerprint. That stamp
# says every merged object matches the binding sources, and one run
# builds one version, so it cannot make that claim. The caller that
# builds the full set records it. A run that dies after two of three
# versions must leave the old stamp in place, so the consumer sees a
# mismatch and rebuilds.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

RUBY=""
SDK=""
ARCH=arm64
MIN_OS=26.0
OUT=""
OBJ=""
SCRATCH=""
STATIC_LIB=""
EXT_LIB=""
RUBY_INCLUDE=""
DEP_INCLUDES=""

while [ "$#" -gt 0 ]
do
    case "$1" in
        --ruby) RUBY="$2"; shift 2 ;;
        --sdk) SDK="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --min-os) MIN_OS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --obj) OBJ="$2"; shift 2 ;;
        --scratch) SCRATCH="$2"; shift 2 ;;
        --static-lib) STATIC_LIB="$2"; shift 2 ;;
        --ext-lib) EXT_LIB="$2"; shift 2 ;;
        --ruby-include) RUBY_INCLUDE="$2"; shift 2 ;;
        --include) DEP_INCLUDES="$DEP_INCLUDES -I$2"; shift 2 ;;
        *) echo "build-binding-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

for required in ruby sdk out obj static-lib ext-lib ruby-include
do
    name="$(echo "$required" | tr 'a-z-' 'A-Z_')"
    eval "value=\$$name"
    if [ -z "$value" ]; then
        echo "build-binding-ios: --$required is required" >&2
        exit 2
    fi
done

SCRATCH="${SCRATCH:-$OBJ}"

# Per-Ruby-version parameters. MKXPZ_RUBY_VERSION and its major and
# minor parts drive the RAPI macros in binding/binding-util.h, which
# gate the C-API differences between the three versions.
case "$RUBY" in
    31)
        RUBY_VERSION="3.1"
        RUBY_MAJOR=3
        RUBY_MINOR=1
        # Only the 3.1 source carries the syntax-transform parser
        # patches. Ruby 3.0 was dropped for exactly this reason.
        RUBY_EXTRA_DEFINES="-DMKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES"
        ;;
    19)
        RUBY_VERSION="1.9"
        RUBY_MAJOR=1
        RUBY_MINOR=9
        RUBY_EXTRA_DEFINES=""
        ;;
    18)
        RUBY_VERSION="1.8"
        RUBY_MAJOR=1
        RUBY_MINOR=8
        RUBY_EXTRA_DEFINES=""
        ;;
    *)
        echo "build-binding-ios: --ruby must be 18, 19 or 31, got $RUBY" >&2
        exit 2
        ;;
esac

case "$SDK" in
    iphoneos)
        TARGET_FLAG="-miphoneos-version-min=$MIN_OS -target ${ARCH}-apple-ios${MIN_OS}"
        LD_PLATFORM="ios"
        ;;
    iphonesimulator)
        TARGET_FLAG="-mios-simulator-version-min=$MIN_OS -target ${ARCH}-apple-ios${MIN_OS}-simulator"
        LD_PLATFORM="ios-simulator"
        ;;
    *)
        echo "build-binding-ios: unsupported --sdk $SDK" >&2
        exit 2
        ;;
esac

SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk "$SDK" --show-sdk-version)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
LD="$(xcrun --sdk "$SDK" -f ld)"

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
 -I$ENGINE/shader \
 -I$ENGINE/hmode7/src"

# Where the Ruby headers sit in the search order is load-bearing, and
# it differs by version.
#
# Ruby 1.8 installs bare headers such as util.h, config.h and
# version.h. The engine has its own src/util/util.h. If the 1.8 header
# dir came first, `#include "util.h"` in the binding would resolve to
# Ruby's copy, which is the wrong file. So 1.8 goes last, after every
# engine and dependency dir.
#
# Ruby 1.9 and 3.1 install under a ruby/ subdirectory and share no
# bare name with the engine, so they go first, where the binding is
# sure to find ruby.h before anything else.
INCLUDES_HEAD=""
INCLUDES_TAIL=""
if [ -n "$RUBY_INCLUDE" ]; then
    case "$RUBY" in
        18) INCLUDES_TAIL="-I$RUBY_INCLUDE" ;;
        *) INCLUDES_HEAD="-I$RUBY_INCLUDE" ;;
    esac
fi

INCLUDES="$INCLUDES_HEAD $ENGINE_INCLUDES $DEP_INCLUDES $INCLUDES_TAIL"

# Shared feature flags come from src/mkxpz-buildconfig.h, which is
# force-included below. Only per-consumer parameters stay as -D
# options. The escaped quotes are intentional. Expanded unquoted, the
# compiler receives -DMKXPZ_VERSION="1.0.0" and the macro is a C
# string.
# shellcheck disable=SC2089
DEFINES="\
 -include $ENGINE/src/mkxpz-buildconfig.h \
 -DMKXPZ_VERSION=\"1.0.0\" \
 -DMKXPZ_GIT_HASH=\"ios\" \
 -DMKXPZ_RUBY_VERSION=\"$RUBY_VERSION\" \
 -DMKXPZ_RUBY_VERSION_MAJOR=$RUBY_MAJOR \
 -DMKXPZ_RUBY_VERSION_MINOR=$RUBY_MINOR \
 $RUBY_EXTRA_DEFINES"

# Suppress the same warnings the Xcode project suppresses, so this
# compile is no noisier than the in-Xcode engine build.
WARNFLAGS="\
 -Wno-documentation -Wno-shorten-64-to-32 -Wno-deprecated-declarations \
 -Wno-uninitialized -Wno-conditional-uninitialized -Wno-undefined-var-template \
 -Wno-comma -Wno-switch -Wno-unused-const-variable \
 -Wno-deprecated-literal-operator -Wno-unused-function"

MERGED="$OUT/mkxp${RUBY}-merged.o"
ENTRY="_mkxp_get_script_binding_${RUBY}"
UNEXPORTS="$SCRATCH/ruby${RUBY}-unexports.txt"

mkdir -p "$OBJ" "$OUT" "$SCRATCH"

echo "[mkxp$RUBY] Compiling binding/*.cpp + hmode7/*.cpp against Ruby $RUBY_VERSION..."
for src in "$ENGINE"/binding/*.cpp "$ENGINE"/hmode7/src/*.cpp
do
    obj="$OBJ/$(basename "$src" .cpp).o"
    echo "  -> $(basename "$obj")"
    # Flag lists below are word lists, so they stay unquoted.
    # shellcheck disable=SC2086,SC2090
    "$CXX" -isysroot "$SYSROOT" $TARGET_FLAG -arch "$ARCH" \
        -std=c++14 -fdeclspec -fobjc-arc -O3 \
        $INCLUDES $DEFINES $WARNFLAGS \
        -c "$src" -o "$obj"
done

echo "[mkxp$RUBY] Compiling per-version wrapper..."
# shellcheck disable=SC2086,SC2090
"$CXX" -isysroot "$SYSROOT" $TARGET_FLAG -arch "$ARCH" \
    -std=c++14 -fdeclspec -O3 \
    "-DMULTIRUBY_SUFFIX=_$RUBY" \
    $INCLUDES \
    -c "$ENGINE/multiruby/wrapper.cpp" \
    -o "$OBJ/_multiruby_wrapper.o"

echo "[mkxp$RUBY] Generating unexport list..."
# Hide every symbol the two archives define, plus everything the
# binding objects define except the one entry point. C++ typeinfo and
# the __cxa_ personality symbols stay visible, because the runtime
# shares them across the whole binary.
"$ENGINE/tools/generate-ruby-unexports.sh" "$STATIC_LIB" "$EXT_LIB" > "$UNEXPORTS"
nm -gU "$OBJ"/*.o 2>/dev/null \
    | awk '/^[0-9a-f]+ [TDSR] /{print $3}' \
    | sort -u \
    | grep -v "^$ENTRY\$" \
    | grep -vE '^__Z(TI|TS|TV)|^___cxa_' \
    >> "$UNEXPORTS"

if [ "$RUBY" = "31" ]; then
    # Carve out symbols that must stay externally visible. src/main.cpp
    # is compiled by the consumer and sets the syntax-transform target
    # version variables that the libruby 3.1 parse.y patch defines.
    # Hidden inside the merged object they still work for the binding,
    # but main.cpp then fails to link. They exist only in 3.1, so no
    # other merged object can clash with them.
    grep -vE '^_mkxp_syntax_transform_target_ruby_version_(major|minor|teeny)$' \
        "$UNEXPORTS" > "$UNEXPORTS.kept"
    mv "$UNEXPORTS.kept" "$UNEXPORTS"
fi

echo "[mkxp$RUBY] Merging via ld -r..."
# The object glob holds no spaces.
# shellcheck disable=SC2086
"$LD" -r -arch "$ARCH" \
    -platform_version "$LD_PLATFORM" "$MIN_OS" "$SDK_VERSION" \
    -syslibroot "$SYSROOT" \
    -unexported_symbols_list "$UNEXPORTS" \
    "$STATIC_LIB" \
    "$EXT_LIB" \
    "$OBJ"/*.o \
    -o "$MERGED"

echo "[mkxp$RUBY] Verifying merged .o..."
# The whole point of the merge is that the object exports one strong
# text symbol, the entry point. It also carries a few dozen weak
# definitions from C++ templates and inline functions, which ld marks
# "weak external automatically hidden". Those are safe to repeat
# across the three merged objects, so the check ignores them and
# looks only at plain `external` text symbols.
GLOBALS="$(nm -gUm "$MERGED" \
    | grep -E '\(__TEXT,__text\) external ' \
    | awk '{print $NF}' | sort -u)"
COUNT="$(printf '%s\n' "$GLOBALS" | grep -c . || true)"
if [ "$COUNT" != "1" ] || [ "$GLOBALS" != "$ENTRY" ]; then
    echo "build-binding-ios: $MERGED must export one strong text symbol, $ENTRY." >&2
    echo "It exports $COUNT:" >&2
    printf '%s\n' "$GLOBALS" | head -20 >&2
    exit 1
fi
echo "  strong text symbols: 1 ($ENTRY)"

echo "[mkxp$RUBY] Done: $MERGED"
