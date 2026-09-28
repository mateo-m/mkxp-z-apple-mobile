#!/usr/bin/env bash
# Build the dependencies for one iOS SDK into deps/build-<sdk>-arm64.
# The engine build (make mkxp-merged mkxp-core in deps) needs them.
#
# Usage: tools/build-deps-ios.sh <iphoneos|iphonesimulator>
set -euo pipefail

SDK="${1:?usage: tools/build-deps-ios.sh <iphoneos|iphonesimulator>}"
cd "$(dirname "$0")/../deps"
LIB="$PWD/build-$SDK-arm64/lib"

# A fresh clone gives the checked-in autotools outputs a random mtime
# order. Make then runs the installed automake again, which fails on
# the version mismatch. Touch the outputs in dependency order.
find sources -maxdepth 2 -name aclocal.m4 -exec touch {} +
sleep 1
find sources -maxdepth 2 \( -name configure -o -name config.h.in \) -exec touch {} +
find sources -name Makefile.in -exec touch {} +

# The targets share source trees, so they run one after the other.
make -f "$SDK.make" angle
make -f "$SDK.make" libogg libvorbis
make -f "$SDK.make" freetype
make -f "$SDK.make" deps-core
make -f "$SDK.make" ruby19 ruby18
make -f "$SDK.make" "$LIB/libruby.3.1-static.a"
make -f "$SDK.make" "$LIB/libruby.3.1-ext.a"
make -f "$SDK.make" ruby-stdlib
