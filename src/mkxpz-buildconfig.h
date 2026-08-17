/* mkxpz-buildconfig.h - shared build-variant feature flags.
 *
 * This header is the single source of truth for the feature flags
 * that every mkxp-z translation unit must agree on. The engine core
 * (tools/build-core-ios.sh) and the binding objects (the launcher's
 * make recipes) force-include it with `-include`. Do not pass these
 * flags as -D options. Add or change them here instead. Valueless
 * flags are defined as 1 to match -D semantics, because some
 * sources test them with #if or #elif.
 *
 * Both fingerprint scripts hash this file (it lives under src/). A
 * change here therefore invalidates prebuilt cores and prebuilt
 * binding objects, and stale artifacts fail the launcher build
 * instead of shipping with mismatched features.
 *
 * Per-consumer parameters do NOT belong here. These stay as -D
 * options because their values differ per translation unit set:
 *   - MKXPZ_VERSION, MKXPZ_GIT_HASH
 *   - MKXPZ_RUBY_VERSION, MKXPZ_RUBY_VERSION_MAJOR/_MINOR
 *   - MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES (Ruby 3.1 builds only,
 *     because the parse.y patches exist only in that libruby)
 */

#ifndef MKXPZ_BUILDCONFIG_H
#define MKXPZ_BUILDCONFIG_H

/* Apple/Xcode build variant of mkxp-z. */
#ifndef MKXPZ_BUILD_XCODE
#define MKXPZ_BUILD_XCODE 1
#endif

/* Forward-decl helper for ALCdevice. Apple's <OpenAL/alc.h> names
 * the struct `ALCdevice_struct`. OpenAL-Soft's <AL/alc.h> names it
 * just `ALCdevice`. We are on OpenAL-Soft. */
#ifndef MKXPZ_ALCDEVICE
#define MKXPZ_ALCDEVICE ALCdevice
#endif

/* TLS for the in-engine HTTP client (src/net/net.cpp). Deliberately
 * NOT the upstream MKXPZ_SSL flag: upstream couples that flag to the
 * xBRZ shader paths, which this fork does not build. Without this
 * flag the client is http-only, and every https request raises
 * "'https' scheme is not supported" (shipped broken in Empo
 * 0.4.0/0.4.1 when this flag fell out of the core recipe). */
#ifndef MKXPZ_NET_TLS
#define MKXPZ_NET_TLS 1
#endif

/* Use OpenGL ES 2 headers. */
#ifndef GLES2_HEADER
#define GLES2_HEADER 1
#endif

/* Render through the ANGLE prebuilt (GLES on Metal). */
#ifndef MKXPZ_HAS_ANGLE
#define MKXPZ_HAS_ANGLE 1
#endif

/* mkxp-z sources include their config.h. */
#ifndef HAVE_CONFIG_H
#define HAVE_CONFIG_H 1
#endif

#endif /* MKXPZ_BUILDCONFIG_H */
