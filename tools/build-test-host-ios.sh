#!/bin/sh
# Build EngineTests.app, a minimal iOS host for the in-engine test
# suite under tests/engine.
#
# The app has no interface. It answers the engine's "which game?"
# question with a folder inside its own bundle, and the engine runs
# the suite there. Everything the suite reports goes to stdout, which
# tools/run-engine-tests.sh reads back.
#
# There is no Xcode project. An iOS app bundle is a directory with a
# Mach-O binary, an Info.plist and resources, so this script assembles
# one by hand. That keeps the whole build in shell, the same as the
# two engine recipes it calls.
#
# Usage:
#   tools/build-test-host-ios.sh [--sdk iphonesimulator]
#                                [--game <dir>] [--out <dir>]
#
# Prerequisite: tools/fetch-deps-ios.sh
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

SDK=iphonesimulator
ARCH=arm64
MIN_OS=26.0
GAME="$ENGINE/tests/engine"
OUT="$ENGINE/build"

while [ "$#" -gt 0 ]
do
    case "$1" in
        --sdk) SDK="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --min-os) MIN_OS="$2"; shift 2 ;;
        --game) GAME="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "build-test-host-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

if [ "$SDK" != "iphonesimulator" ]; then
    # A device build needs a provisioning profile and a signing
    # identity, which this repository has no way to supply.
    echo "build-test-host-ios: only --sdk iphonesimulator is supported" >&2
    exit 2
fi

DEPS="$ENGINE/deps"
TREE="$DEPS/build-$SDK-$ARCH"
ANGLE="$DEPS/ANGLE/$SDK"

if [ ! -d "$TREE/lib" ] || [ ! -d "$ANGLE/lib" ]; then
    echo "build-test-host-ios: dependency libraries missing." >&2
    echo "Run tools/fetch-deps-ios.sh first." >&2
    exit 1
fi

if [ ! -f "$GAME/mkxp.json" ]; then
    echo "build-test-host-ios: $GAME holds no mkxp.json" >&2
    exit 1
fi

BUILD="$OUT/$SDK-$ARCH"
APP="$BUILD/EngineTests.app"
OBJ="$BUILD/obj"
LIB="$BUILD/lib"

SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
# The engine, SDL and OpenAL are C++, so the link driver must be
# clang++. It pulls in libc++ and the C++ ABI runtime.
CXX="$(xcrun --sdk "$SDK" -f clang++)"
TARGET="${ARCH}-apple-ios${MIN_OS}-simulator"

INCLUDES="\
 --include $TREE/include \
 --include $TREE/include/AL \
 --include $TREE/include/SDL2 \
 --include $TREE/include/pixman-1 \
 --include $TREE/include/uchardet \
 --include $TREE/include/freetype2 \
 --include $ANGLE/include"

mkdir -p "$OBJ" "$LIB"

# --- Engine core ------------------------------------------------------
# shellcheck disable=SC2086
"$ENGINE/tools/build-core-ios.sh" \
    --sdk "$SDK" --arch "$ARCH" --min-os "$MIN_OS" \
    --obj "$OBJ/core" --out "$LIB" \
    $INCLUDES

# --- Ruby bindings ----------------------------------------------------
# All three go in. binding.h dispatches on the active Ruby version at
# run time and names every entry point, so leaving one out breaks the
# link even when the suite uses a single version.
build_binding() {
    # $1 = 18|19|31, $2 = header dir, $3 = static archive, $4 = ext archive
    # shellcheck disable=SC2086
    "$ENGINE/tools/build-binding-ios.sh" --ruby "$1" \
        --sdk "$SDK" --arch "$ARCH" --min-os "$MIN_OS" \
        --obj "$OBJ/binding$1" --out "$LIB" --scratch "$BUILD" \
        --ruby-include "$TREE/include/$2" \
        --static-lib "$TREE/lib/$3" --ext-lib "$TREE/lib/$4" \
        $INCLUDES
}
build_binding 31 ruby31 libruby.3.1-static.a libruby.3.1-ext.a
build_binding 19 ruby19 libruby19-static.a libruby19-ext.a
build_binding 18 ruby18 libruby18-static.a libruby18-ext.a

# --- Host shim --------------------------------------------------------
echo "[test-host] Compiling the host shim..."
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -fobjc-arc -O2 \
    -I"$ENGINE/src" \
    -c "$ENGINE/tests/host/host.m" -o "$OBJ/host.o"

# --- Link -------------------------------------------------------------
echo "[test-host] Linking..."
mkdir -p "$APP"
"$CXX" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -L"$TREE/lib" -L"$ANGLE/lib" \
    -o "$APP/EngineTests" \
    "$OBJ/host.o" \
    -Wl,-force_load,"$LIB/libmkxpz-core.a" \
    "$LIB/mkxp18-merged.o" \
    "$LIB/mkxp19-merged.o" \
    "$LIB/mkxp31-merged.o" \
    -lSDL2 -lSDL2main -lSDL2_image -lSDL2_sound -lSDL2_ttf \
    -lfreetype -lpixman-1 -lpng16 \
    -logg -lvorbis -lvorbisfile -ltheora -ltheoradec \
    -lphysfs -luchardet -lopenal \
    -lssl -lcrypto \
    -lz -lbz2 -liconv \
    -lANGLE_static -lEGL_static -lGLESv2_static \
    -framework Foundation -framework UIKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreVideo -framework CoreAudio \
    -framework AudioToolbox -framework AVFoundation -framework Metal \
    -framework QuartzCore -framework GameController -framework CoreMotion \
    -framework IOSurface \
    -weak_framework CoreBluetooth -weak_framework CoreHaptics \
    -weak_framework OpenGLES

# --- Bundle -----------------------------------------------------------
echo "[test-host] Assembling the bundle..."
cp "$ENGINE/tests/host/Info.plist" "$APP/Info.plist"

# Assets.bundle holds everything the engine reads from its host at run
# time. A launcher assembles the same tree from the same sources.
ASSETS="$APP/Assets.bundle"
rm -rf "$ASSETS"
mkdir -p "$ASSETS/Shaders" "$ASSETS/Fonts" "$ASSETS/Preload" "$ASSETS/Postload"
cp "$ENGINE"/shader/*.frag "$ENGINE"/shader/*.vert "$ENGINE"/shader/*.h "$ASSETS/Shaders/"
cp "$ENGINE"/assets/liberation.ttf "$ENGINE"/assets/wqymicrohei.ttf "$ASSETS/Fonts/"
cp "$ENGINE"/assets/gamecontrollerdb.txt "$ENGINE"/assets/icon.png \
    "$ENGINE"/assets/cacert.pem "$ASSETS/"
cp "$ENGINE"/scripts/preload/*.rb "$ASSETS/Preload/"
cp "$ENGINE"/scripts/postload/*.rb "$ASSETS/Postload/"

# The Ruby stdlib subsets. binding-mri.cpp pushes the per-version
# directory onto $LOAD_PATH, which is what makes `require` resolve.
rm -rf "$APP/Ruby"
cp -R "$TREE/ruby-stdlib" "$APP/Ruby"

# The suite itself, as the game the host opens.
rm -rf "$APP/Game"
mkdir -p "$APP/Game"
cp -R "$GAME"/. "$APP/Game/"

# An unsigned bundle installs on some simulator runtimes and not on
# others. An ad-hoc signature works everywhere and needs no identity.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 ||
    echo "build-test-host-ios: warning: ad-hoc codesign failed" >&2

echo "[test-host] Done: $APP"
