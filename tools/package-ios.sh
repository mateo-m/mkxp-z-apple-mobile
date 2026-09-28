#!/bin/sh
# Package the engine for a host: mkxp-z-ios.tar.gz.
#
# Run it after tools/build-deps-ios.sh and `make mkxp-merged mkxp-core`
# in deps/, for both SDKs. The archive holds:
#
#   MANIFEST             tag, commit, ANGLE release, RGSS version mask
#   LINK                 the libraries and frameworks a host links
#   include/app_bridge.h the interface a host calls
#   assets/              shaders, fonts, controller mappings, CA roots,
#                        and the preload and postload scripts
#   <sdk>/lib/           the engine core, the three binding objects and
#                        every dependency library
#   <sdk>/ruby-stdlib/   the Ruby stdlib subsets for the three Rubies
#
# A host links with the flags in LINK, from <sdk>/, and with ANGLE from
# the release that MANIFEST names. The engine finds assets/ as Assets.bundle
# and ruby-stdlib/ as Ruby/ next to its own binary (filesystemImplIOS.mm).
#
# Usage:
#   tools/package-ios.sh [--tag <name>] [--out <file>]
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ENGINE/deps"
TAG="$(git -C "$ENGINE" describe --tags --always --dirty)"
OUT="$ENGINE/mkxp-z-ios.tar.gz"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "package-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

LIBS="libmkxpz-core.a mkxp18-merged.o mkxp19-merged.o mkxp31-merged.o
libSDL2.a libSDL2_image.a libSDL2_sound.a libSDL2_ttf.a libfreetype.a
libpixman-1.a libogg.a libvorbis.a libvorbisfile.a libtheora.a
libtheoradec.a libphysfs.a libuchardet.a libopenal.a libssl.a libcrypto.a"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mkxp-z-ios.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT INT TERM

for sdk in iphoneos iphonesimulator; do
    tree="$DEPS/build-$sdk-arm64"
    if [ "$sdk" = iphoneos ]; then platform=2; else platform=7; fi
    mkdir -p "$STAGE/$sdk/lib"
    for lib in $LIBS; do
        if [ ! -f "$tree/lib/$lib" ]; then
            echo "package-ios: $tree/lib/$lib missing. Build $sdk first, see README.md" >&2
            exit 1
        fi
        # LC_BUILD_VERSION platform 2 is iOS, 7 is the iOS simulator.
        wrong="$(otool -l "$tree/lib/$lib" | awk -v want="$platform" \
            '$1 == "platform" && $2 != want { n++ } END { print n + 0 }')"
        if [ "$wrong" -gt 0 ]; then
            echo "package-ios: $tree/lib/$lib holds $wrong objects for another platform than $sdk" >&2
            exit 1
        fi
        cp "$tree/lib/$lib" "$STAGE/$sdk/lib/"
    done
    cp -R "$tree/ruby-stdlib" "$STAGE/$sdk/ruby-stdlib"
done

# The Ruby 3.1 syntax-transform patches are what let the engine run
# RGSS3 games. Two places say whether they are in: the define the core
# compiles with, and the symbol the patched Ruby adds. nm -a, because
# the merged object hides every Ruby name.
if grep -q 'DMKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES' "$ENGINE/tools/build-core-ios.sh"; then
    COMPILED=yes
else
    COMPILED=no
fi
for sdk in iphoneos iphonesimulator; do
    if nm -a "$STAGE/$sdk/lib/mkxp31-merged.o" |
        grep -q '_mkxp_syntax_transform_target_ruby_version_major$'; then
        LINKED=yes
    else
        LINKED=no
    fi
    if [ "$LINKED" != "$COMPILED" ]; then
        echo "package-ios: the $sdk Ruby 3.1 and the core disagree about the syntax-transform patches" >&2
        exit 1
    fi
done
# Bit 1 is RGSS1, bit 2 RGSS2, bit 4 RGSS3 (mkxp_getSupportedRGSSVersionMask).
if [ "$COMPILED" = yes ]; then RGSS_MASK=7; else RGSS_MASK=3; fi

mkdir -p "$STAGE/include" "$STAGE/assets/Shaders" "$STAGE/assets/Fonts" \
    "$STAGE/assets/Preload" "$STAGE/assets/Postload"
cp "$ENGINE/src/app_bridge.h" "$STAGE/include/"
cp "$ENGINE"/shader/*.frag "$ENGINE"/shader/*.vert "$ENGINE"/shader/*.h "$STAGE/assets/Shaders/"
cp "$ENGINE"/assets/liberation.ttf "$ENGINE"/assets/wqymicrohei.ttf "$STAGE/assets/Fonts/"
cp "$ENGINE"/assets/gamecontrollerdb.txt "$ENGINE"/assets/icon.png \
    "$ENGINE"/assets/cacert.pem "$STAGE/assets/"
cp "$ENGINE"/scripts/preload/*.rb "$STAGE/assets/Preload/"
cp "$ENGINE"/scripts/postload/*.rb "$STAGE/assets/Postload/"

# The paths are relative to <sdk>/, so run the link from there.
# -force_load keeps every object of the core. A linker pulls an archive
# member only when something refers to it, and nothing in the link
# refers to most of the app_bridge.h functions.
cat >"$STAGE/LINK" <<LINK
-Wl,-force_load,lib/libmkxpz-core.a lib/mkxp18-merged.o lib/mkxp19-merged.o lib/mkxp31-merged.o
-Llib -lSDL2 -lSDL2_image -lSDL2_sound -lSDL2_ttf -lfreetype -lpixman-1
-logg -lvorbis -lvorbisfile -ltheora -ltheoradec -lphysfs -luchardet
-lopenal -lssl -lcrypto -lz -lbz2 -liconv
-lANGLE_static -lEGL_static -lGLESv2_static
-framework Foundation -framework UIKit -framework CoreFoundation
-framework CoreGraphics -framework CoreVideo -framework CoreAudio
-framework AudioToolbox -framework AVFoundation -framework Metal
-framework QuartzCore -framework GameController -framework CoreMotion
-framework IOSurface -weak_framework CoreBluetooth -weak_framework CoreHaptics
LINK

{
    echo "tag=$TAG"
    echo "commit=$(git -C "$ENGINE" rev-parse HEAD)"
    echo "angle=$(sed -n 's/^ANGLE_VERSION := //p' "$DEPS/common.make")"
    echo "rgss_mask=$RGSS_MASK"
} >"$STAGE/MANIFEST"

tar -czf "$OUT" -C "$STAGE" MANIFEST LINK include assets iphoneos iphonesimulator
echo "package-ios: $OUT"
shasum -a 256 "$OUT"
