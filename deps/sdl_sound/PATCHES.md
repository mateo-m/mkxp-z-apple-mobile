# SDL_sound: patches and build notes

## Source

- **Upstream**: SDL_sound 2.0.1
- **Fork**: <https://github.com/mkxp-z/SDL_sound> branch `git`
- **Base commit**: `506b9f0` ("version: Bumping version to 2.0.1 for actual release.")

## Patches

One custom commit on top of upstream:

1. **`cfb2533`** (Struma): Build properly on macOS
   - Fixes a build issue specific to macOS/Darwin toolchains.

The build applies one more patch from this folder:

1. **`wav-24bit.patch`**: upstream commits `64b06cb` and `c653676`
   - Adds 24-bit integer PCM to the WAV decoder. Without it, the decoder
     rejects the file ("Sound format unsupported"), and the music does
     not play. The title music of Sweeter Yesterday is a 24-bit WAV.

## iOS build instructions

The build uses CMake (out-of-tree in `cmakebuild/`):

```text
cmake .. \
  -DSDLSOUND_BUILD_SHARED=false \
  -DSDLSOUND_BUILD_TEST=false \
  -DSDLSOUND_DECODER_COREAUDIO=false \
  <common CMAKE_ARGS from common.make>
```

Key flags:

- CoreAudio decoder disabled: the build uses the Vorbis/Ogg decoders instead
- Test programs disabled

Depends on: SDL2, libogg, libvorbis
