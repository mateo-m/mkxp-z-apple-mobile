#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Download GeneralUser GS, the SoundFont the engine plays MIDI with
# when the game and the host name none, and print its path. Every SDK
# uses the same file, so it stays out of the dependency trees.
#
# The project has no releases, so the pin is a commit.
set -eu

COMMIT=684543d5e5efaef08d02be50dcda8d552478fa60
SHA256=9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ENGINE/deps/downloads/GeneralUser-GS.sf2"

if ! { [ -f "$OUT" ] && echo "$SHA256  $OUT" | shasum -a 256 -c --status; }
then
    mkdir -p "$(dirname "$OUT")"
    curl -fsSL --retry 3 -o "$OUT.part" \
        "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/$COMMIT/GeneralUser-GS.sf2"
    echo "$SHA256  $OUT.part" | shasum -a 256 -c --status ||
        {
            echo "fetch-soundfont: the download does not match its sha256" >&2
            rm -f "$OUT.part"
            exit 1
        }
    mv "$OUT.part" "$OUT"
fi

echo "$OUT"
