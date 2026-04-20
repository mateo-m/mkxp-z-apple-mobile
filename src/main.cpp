/*
** main.cpp
**
** This file is part of mkxp.
**
** Copyright (C) 2013 - 2021 Amaryllis Kulla <ancurio@mapleshrine.eu>
**
** mkxp is free software: you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation, either version 2 of the License, or
** (at your option) any later version.
**
** mkxp is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with mkxp.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef MKXPZ_BUILD_XCODE
#include "icon.png.xxd"
#endif

#include <atomic>

#include <alc.h>

#include <SDL.h>
#include <SDL_image.h>
#include <SDL_sound.h>
#include <SDL_ttf.h>

#include <assert.h>
#include <string.h>
#include <string>
#include <unistd.h>
#include <regex>
#include <climits>

#if TARGET_OS_IPHONE
#include "app_bridge.h"
#include <CoreFoundation/CoreFoundation.h>
#ifdef MKXPZ_HAS_ANGLE
#include <EGL/egl.h>
#include <SDL_syswm.h>
#endif
#else
// Stubs so the LSP doesn't complain when TARGET_OS_IPHONE is undefined
static inline const char *mkxp_waitForGamePath(void) { return ""; }
static inline void mkxp_setEngineTerminated(void) {}
static inline void mkxp_resetBridgeState(void) {}
#endif

#include "binding.h"
#include "sharedstate.h"
#include "eventthread.h"
#include "display/graphics.h"
#include "util/debugwriter.h"
#include "util/exception.h"
#include "display/gl/gl-debug.h"
#include "display/gl/gl-fun.h"
#include "display/gl/gl-util.h"

#include "filesystem/filesystem.h"

#include "system/system.h"

#if defined(__WIN32__)
#include "resource.h"
#include <Winsock2.h>
#include "util/win-consoleutils.h"

// Try to work around buggy GL drivers that tend to be in Optimus laptops
// by forcing MKXP to use the dedicated card instead of the integrated one
#include <windows.h>
extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}
#endif

#ifdef MKXPZ_STEAM
#include "steamshim_child.h"
#endif

#ifdef MKXPZ_BUILD_XCODE
#include <Availability.h>
#include <TargetConditionals.h>
#include "TouchBar.h"
#if !TARGET_OS_IPHONE && (!defined(__MAC_10_15) || __MAC_OS_X_VERSION_MAX_ALLOWED < __MAC_10_15)
#define MKXPZ_INIT_GL_LATER
#endif
#endif

#ifndef MKXPZ_INIT_GL_LATER
#define GLINIT_SHOWERROR(s) showInitError(s)
#else
#define GLINIT_SHOWERROR(s) rgssThreadError(threadData, s)
#endif

static void rgssThreadError(RGSSThreadData *rtData, const std::string &msg);
static void showInitError(const std::string &msg);
#if TARGET_OS_IPHONE
static bool initANGLE(SDL_Window *win);
static void teardownANGLE();
extern "C" void *mkxp_getANGLENativeLayer(void *sdlWindow);
#endif

static inline const char *glGetStringInt(GLenum name) {
  return (const char *)gl.GetString(name);
}

#if defined(GLES2_HEADER) && !TARGET_OS_IPHONE
static void setGLES2Attributes() {
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
}
#endif

/* Process-lifetime buffers populated by printGLInfo() once the EGL
 * context is current. Exposed to the app layer via
 * mkxp_getANGLEVersion() / mkxp_getMetalDeviceName() so the SwiftUI
 * debug overlay can show them without re-parsing GL strings. */
static char s_angleVersion[128]    = "unknown";
static char s_metalDeviceName[128] = "unknown";

extern "C" const char *mkxp_getANGLEVersion(void) {
    return s_angleVersion;
}

extern "C" const char *mkxp_getMetalDeviceName(void) {
    return s_metalDeviceName;
}

static void printGLInfo() {
    const std::string renderer(glGetStringInt(GL_RENDERER));
    const std::string version(glGetStringInt(GL_VERSION));
    std::regex rgx("ANGLE \\((.+), ANGLE Metal Renderer: (.+), Version (.+)\\)");

    std::smatch matches;
    if (std::regex_search(renderer, matches, rgx)) {

        Debug() << "Backend           :" << "Metal";
        Debug() << "Metal Device      :" << matches[2] << "(" + matches[1].str() + ")";
        Debug() << "Renderer Version  :" << matches[3].str();

        /* Cache the Metal device name for the debug overlay.
         * matches[2] is the device string (e.g. "Apple A15 GPU"). */
        snprintf(s_metalDeviceName, sizeof(s_metalDeviceName), "%s",
                 matches[2].str().c_str());

        std::smatch vmatches;
        if (std::regex_search(version, vmatches, std::regex("\\(ANGLE (.+) git hash: .+\\)"))) {
            Debug() << "ANGLE Version     :" << vmatches[1].str();
            /* Cache the ANGLE version for the debug overlay. */
            snprintf(s_angleVersion, sizeof(s_angleVersion), "%s",
                     vmatches[1].str().c_str());
        }
    } else {
      Debug() << "Backend      :" << "OpenGL";
      Debug() << "GL Vendor    :" << glGetStringInt(GL_VENDOR);
      Debug() << "GL Renderer  :" << renderer;
      Debug() << "GL Version   :" << version;
      Debug() << "GLSL Version :" << glGetStringInt(GL_SHADING_LANGUAGE_VERSION);
    }

    GLint maxTexSize = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexSize);
    Debug() << "Max Tex Size :" << maxTexSize;
}

static SDL_GLContext initGL(SDL_Window *win, Config &conf,
                            RGSSThreadData *threadData);

/* On iOS, ANGLE is the only renderer. The screen FBO is captured
 * once during initANGLE() (typically 0 under ANGLE/Metal) and reused
 * for all sessions, since the window and EGL context persist.
 * Re-querying GL_FRAMEBUFFER_BINDING on subsequent sessions would
 * be unsafe because SharedState::finiInstance deletes all game FBOs
 * and the binding may not be what we expect. */
#if TARGET_OS_IPHONE
static GLuint s_screenFBO = 0;
EGLDisplay s_eglDisplay = EGL_NO_DISPLAY;
EGLSurface s_eglSurface = EGL_NO_SURFACE;
EGLContext s_eglContext = EGL_NO_CONTEXT;
#endif

#if TARGET_OS_IPHONE
// iOS uses ANGLE/EGL exclusively. These wrappers forward to the EGL
// equivalents; `ctx` is a sentinel (the EGL context pointer cast to
// SDL_GLContext for type compatibility with the RGSSThreadData struct).
static void mkxpGL_MakeCurrent(SDL_Window * /*win*/, SDL_GLContext ctx) {
    if (ctx)
        eglMakeCurrent(s_eglDisplay, s_eglSurface, s_eglSurface, s_eglContext);
    else
        eglMakeCurrent(s_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static void mkxpGL_SwapWindow(SDL_Window * /*win*/) {
    eglSwapBuffers(s_eglDisplay, s_eglSurface);
}

// Query the EGL surface for real pixel dimensions. SDL_GL_GetDrawableSize
// would return logical points under ANGLE (no SDL GL context is bound).
void mkxpGL_GetDrawableSize(SDL_Window * /*win*/, int *w, int *h) {
    EGLint eglW = 0, eglH = 0;
    eglQuerySurface(s_eglDisplay, s_eglSurface, EGL_WIDTH, &eglW);
    eglQuerySurface(s_eglDisplay, s_eglSurface, EGL_HEIGHT, &eglH);
    if (w) *w = eglW;
    if (h) *h = eglH;
}

extern "C" void mkxp_refreshANGLENativeLayerSize(void *sdlWindow, int *outW, int *outH);

// Called on rotation / resize. eglQuerySurface returns a drawable size
// cached during the last obtainNextDrawable call (pre-rotation). Drive
// the CAMetalLayer update on the main thread ourselves and return the
// resulting pixel size.
void mkxpGL_RefreshDrawableSize(SDL_Window *win, int *w, int *h) {
    mkxp_refreshANGLENativeLayerSize(win, w, h);
}
#endif

#if TARGET_OS_IPHONE
/* Persistent RGSS thread for iOS.
 * Ruby 1.8's VM has internal state (parser, symbol table, thread-local
 * storage) bound to the thread that called ruby_init(). Creating a new
 * thread for each game session causes crashes because the VM's stack
 * boundaries and TLS references become stale.
 * Solution: keep the RGSS thread alive across sessions. The main thread
 * posts new RGSSThreadData via these shared variables. */
static SDL_sem *s_rgssSessionReady = nullptr;   // main → RGSS: "new session available"
static SDL_sem *s_rgssSessionDone  = nullptr;    // RGSS → main: "session finished"
static RGSSThreadData *s_nextRTData = nullptr;   // the data for the next session

int rgssThreadFun(void *userdata) {
  RGSSThreadData *threadData = static_cast<RGSSThreadData *>(userdata);

  mkxpGL_MakeCurrent(threadData->window, threadData->glContext);

  /* Set the screen framebuffer ID and reset the binding tracker. */
  FBO::screenFramebufferID = FBO::ID(s_screenFBO);
  gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
  FBO::boundFramebufferID = FBO::screenFramebufferID;

  /* AL context — persistent, just activate on this thread. */
  ALCcontext *alcCtx = threadData->alcCtx;
  alcMakeContextCurrent(alcCtx);

  /* --- Session loop: runs on the SAME thread forever --- */
  while (true) {
    /* Re-set FBO state for this session (SharedState::finiInstance
     * may have unbound it). */
    FBO::screenFramebufferID = FBO::ID(s_screenFBO);
    gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
    FBO::boundFramebufferID = FBO::screenFramebufferID;

    try {
      SharedState::initInstance(threadData);
    } catch (const Exception &exc) {
      rgssThreadError(threadData, exc.msg);
      break;
    }

    mkxp_setGameReady();

    /* Run game scripts */
    scriptBinding->execute();

    /* Detach disposables before destroying SharedState */
    shState->graphics().detachAllDisposables();

    threadData->rqTermAck.set();
    threadData->ethread->requestTerminate();

    /* Ensure the OpenAL context is current before tearing down Audio.
     * mkxp_checkPause() never nulls the context, so this is a no-op
     * in normal operation; kept as a safety net. */
    alcMakeContextCurrent(alcCtx);

    SharedState::finiInstance();

    /* Release GL context so the main thread can safely claim or
     * destroy it during a hot-swap. Deleting/reusing a context
     * that's still current on another thread is undefined behavior. */
    mkxpGL_MakeCurrent(threadData->window, NULL);

    /* Signal main thread that session is done */
    SDL_SemPost(s_rgssSessionDone);

    /* Wait for the main thread to provide the next session's data.
     * This blocks until main calls SDL_SemPost(s_rgssSessionReady). */
    SDL_SemWait(s_rgssSessionReady);

    /* Pick up the new RGSSThreadData */
    threadData = s_nextRTData;
    if (!threadData)
      break; // null = quit

    /* Reclaim the EGL context for this thread. The context is the
     * same one used by every session - ANGLE's EGL context persists
     * for the life of the process. */
    mkxpGL_MakeCurrent(threadData->window, threadData->glContext);

    /* Screen FBO is captured once at init and typically 0 under ANGLE. */
    FBO::screenFramebufferID = FBO::ID(s_screenFBO);
    gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
    FBO::boundFramebufferID = FBO::screenFramebufferID;
  }

  alcMakeContextCurrent(NULL);
  mkxpGL_MakeCurrent(threadData ? threadData->window : nullptr, NULL);

  return 0;
}

#else // !TARGET_OS_IPHONE — original single-session thread

int rgssThreadFun(void *userdata) {
  RGSSThreadData *threadData = static_cast<RGSSThreadData *>(userdata);

#ifdef MKXPZ_INIT_GL_LATER
  threadData->glContext =
      initGL(threadData->window, threadData->config, threadData);
  if (!threadData->glContext)
    return 0;
#else
  SDL_GL_MakeCurrent(threadData->window, threadData->glContext);
#endif

  /* Set the screen framebuffer ID and reset the binding tracker. */
  {
    /* On other platforms, query the real default framebuffer ID. */
    GLint defaultFBO = 0;
    gl.GetIntegerv(GL_FRAMEBUFFER_BINDING, &defaultFBO);
    FBO::screenFramebufferID = FBO::ID(static_cast<GLuint>(defaultFBO));
    gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
    FBO::boundFramebufferID = FBO::screenFramebufferID;
  }

  ALCcontext *alcCtx = threadData->alcCtx;

  if (!alcCtx) {
    alcCtx = alcCreateContext(threadData->alcDev, 0);
    if (!alcCtx) {
      rgssThreadError(threadData, "Error creating OpenAL context");
      return 0;
    }
  }

  alcMakeContextCurrent(alcCtx);

  try {
    SharedState::initInstance(threadData);
  } catch (const Exception &exc) {
    rgssThreadError(threadData, exc.msg);
    alcDestroyContext(alcCtx);
    return 0;
  }

  scriptBinding->execute();

  threadData->rqTermAck.set();
  threadData->ethread->requestTerminate();

  SharedState::finiInstance();

  alcDestroyContext(alcCtx);

  return 0;
}
#endif

static void printRgssVersion(int ver) {
  const char *const makers[] = {"", "XP", "VX", "VX Ace"};

  char buf[128];
  snprintf(buf, sizeof(buf), "RGSS version %d (RPG Maker %s)", ver,
           makers[ver]);

  Debug() << buf;
}

static void initSyntaxTransform(Config &conf) {
#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
  extern unsigned int mkxp_syntax_transform_target_ruby_version_major, mkxp_syntax_transform_target_ruby_version_minor, mkxp_syntax_transform_target_ruby_version_teeny;
#endif // MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES

  char buf[128];

  switch (conf.syntaxTransform) {
    default:
      conf.syntaxTransformCustomVersionMajor = INT_MAX;
      conf.syntaxTransformCustomVersionMinor = INT_MAX;
      conf.syntaxTransformCustomVersionTeeny = INT_MAX;
      snprintf(buf, sizeof(buf), "Disabled");
      break;
    case 1:
      conf.syntaxTransformCustomVersionMajor = std::max(0, conf.syntaxTransformCustomVersionMajor);
      conf.syntaxTransformCustomVersionMinor = std::max(0, conf.syntaxTransformCustomVersionMinor);
      conf.syntaxTransformCustomVersionTeeny = std::max(0, conf.syntaxTransformCustomVersionTeeny);
      snprintf(buf, sizeof(buf), "Ruby %u.%u.%u", conf.syntaxTransformCustomVersionMajor, conf.syntaxTransformCustomVersionMinor, conf.syntaxTransformCustomVersionTeeny);
      break;
    case 2:
      conf.syntaxTransformCustomVersionMajor = 1;
      conf.syntaxTransformCustomVersionMinor = conf.rgssVersion >= 3 ? 9 : 8;
      conf.syntaxTransformCustomVersionTeeny = conf.rgssVersion >= 3 ? 2 : 1;
      snprintf(buf, sizeof(buf), "Compatibility mode (Ruby %u.%u.%u)", conf.syntaxTransformCustomVersionMajor, conf.syntaxTransformCustomVersionMinor, conf.syntaxTransformCustomVersionTeeny);
      break;
  }

#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
  mkxp_syntax_transform_target_ruby_version_major = conf.syntaxTransformCustomVersionMajor == INT_MAX ? -1 : conf.syntaxTransformCustomVersionMajor;
  mkxp_syntax_transform_target_ruby_version_minor = conf.syntaxTransformCustomVersionMinor == INT_MAX ? -1 : conf.syntaxTransformCustomVersionMinor;
  mkxp_syntax_transform_target_ruby_version_teeny = conf.syntaxTransformCustomVersionTeeny == INT_MAX ? -1 : conf.syntaxTransformCustomVersionTeeny;
  Debug() << "Syntax transform:" << buf;
#else
  // The user configured a syntax-transform mode but this build was
  // compiled against an unpatched Ruby runtime. The setting has no
  // effect; make it loud in the logs so the mismatch doesn't look
  // like a silent misconfiguration.
  if (conf.syntaxTransform != 0)
    Debug() << "Syntax transform: requested" << buf << "but patches"
               " are not compiled in (MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES"
               " undefined); setting will be ignored.";
#endif // MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
}

static void rgssThreadError(RGSSThreadData *rtData, const std::string &msg) {
  rtData->rgssErrorMsg = msg;
  rtData->ethread->requestTerminate();
  rtData->rqTermAck.set();
}

static void showInitError(const std::string &msg) {
  Debug() << msg;
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "mkxp-z", msg.c_str(), 0);
}

static void setupWindowIcon(const Config &conf, SDL_Window *win) {
  SDL_RWops *iconSrc;

  if (conf.iconPath.empty())
#ifndef MKXPZ_BUILD_XCODE
    iconSrc = SDL_RWFromConstMem(___assets_icon_png, ___assets_icon_png_len);
#else
    iconSrc = SDL_RWFromFile(mkxp_fs::getPathForAsset("icon", "png").c_str(), "rb");
#endif
  else
    iconSrc = SDL_RWFromFile(conf.iconPath.c_str(), "rb");

  SDL_Surface *iconImg = IMG_Load_RW(iconSrc, SDL_TRUE);

  if (iconImg) {
    SDL_SetWindowIcon(win, iconImg);
    SDL_FreeSurface(iconImg);
  }
}

// Initialize SDL and its subsidiary libs in the order they depend on
// each other: SDL core (video+controller+timer) -> user events ->
// SDL_image -> SDL_ttf -> SDL_sound. If anything fails, tear down
// the previous ones before returning false so the process leaves
// no resources dangling even on init failure.
//
// Returns true on full success. On failure the caller should return
// from main() - an error message box has already been shown via
// showInitError().
static bool initSDLLibs() {
  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_TIMER) < 0) {
    showInitError(std::string("Error initializing SDL: ") + SDL_GetError());
    return false;
  }

  if (!EventThread::allocUserEvents()) {
    showInitError("Error allocating SDL user events");
    SDL_Quit();
    return false;
  }

  const int imgFlags = IMG_INIT_PNG | IMG_INIT_JPG;
  if (IMG_Init(imgFlags) != imgFlags) {
    showInitError(std::string("Error initializing SDL_image: ") + SDL_GetError());
    SDL_Quit();
    return false;
  }

  if (TTF_Init() < 0) {
    showInitError(std::string("Error initializing SDL_ttf: ") + SDL_GetError());
    IMG_Quit();
    SDL_Quit();
    return false;
  }

  if (Sound_Init() == 0) {
    showInitError(std::string("Error initializing SDL_sound: ") + Sound_GetError());
    TTF_Quit();
    IMG_Quit();
    SDL_Quit();
    return false;
  }

  return true;
}

// Reverse order of initSDLLibs. Safe to call even if only some libs
// were initialized (each *_Quit is idempotent-ish; SDL_sound's Quit
// is Sound_Quit).
static void shutdownSDLLibs() {
  Sound_Quit();
  TTF_Quit();
  IMG_Quit();
  SDL_Quit();
}

#if TARGET_OS_IPHONE
/* Create the iOS persistent SDL window. No SDL_WINDOW_OPENGL flag
 * because ANGLE uses a plain CALayer (not a CAEAGLLayer) as its
 * native window. Returns nullptr on failure after posting an error. */
static SDL_Window *createPersistentWindow(const Config &initConf) {
  Uint32 winFlags = SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_ALLOW_HIGHDPI;

  /* Allow all orientations. Without this, SDL infers supported
   * orientations from the window w/h: a landscape-shaped game
   * (e.g. 640x480) would lock the window to landscape only,
   * preventing portrait gameplay. */
  SDL_SetHint(SDL_HINT_ORIENTATIONS,
              "Portrait LandscapeLeft LandscapeRight");

  SDL_Window *win = SDL_CreateWindow(
      initConf.windowTitle.c_str(), SDL_WINDOWPOS_UNDEFINED,
      SDL_WINDOWPOS_UNDEFINED, initConf.defScreenW,
      initConf.defScreenH, winFlags);

  if (!win)
    showInitError(std::string("Error creating window: ") + SDL_GetError());

  return win;
}

/* Initialize ANGLE and yield the EGL context pointer. Must be called
 * from the main thread; the RGSS thread claims the context at session
 * start. Returns nullptr on failure. */
static SDL_GLContext createPersistentGL(SDL_Window *win) {
  if (!initANGLE(win))
    return nullptr;

  /* Use the EGL context pointer as a non-null sentinel so
   * mkxpGL_MakeCurrent can distinguish bind from unbind. */
  SDL_GLContext ctx = (SDL_GLContext)s_eglContext;

  /* Release from main thread - the RGSS thread will claim it.
   * EGL contexts can only be current on one thread at a time. */
  mkxpGL_MakeCurrent(win, NULL);
  Debug() << "Using ANGLE (Metal)";
  return ctx;
}

/* Open the default OpenAL device and create a context on it. The
 * device pointer is written to *outDev; the context to *outCtx.
 * Returns false on failure. */
static bool createPersistentAudio(ALCdevice **outDev, ALCcontext **outCtx) {
  ALCdevice *dev = alcOpenDevice(0);
  if (!dev) {
    showInitError("Could not detect an available audio device.");
    return false;
  }

  ALCcontext *ctx = alcCreateContext(dev, 0);
  if (ctx)
    alcMakeContextCurrent(ctx);

  *outDev = dev;
  *outCtx = ctx;
  return true;
}

/* Block until the Library UI selects a game. On quit, returns false.
 * On success, copies the selected path into `dataDir` and resets
 * bridge state + cwd so the engine picks up the new game. Called
 * between game sessions (not before the first one - that wait happens
 * before SDL_Init in main()). */
static bool waitForNextGame(char *dataDir, size_t dataDirLen) {
  mkxp_setEngineTerminated();
  EventThread::resetAllInputStates();

  const char *nextPath = mkxp_waitForGamePath();
  if (!nextPath || !nextPath[0])
    return false; // empty path = quit

  snprintf(dataDir, dataDirLen, "%s", nextPath);

  /* Reset bridge state AFTER copying the path, so the UI has had
   * time to observe mkxp_isEngineTerminated() during
   * mkxp_waitForGamePath(). */
  mkxp_resetBridgeState();

  mkxp_fs::setCurrentDirectory(dataDir);
  return true;
}

/* Wait for rqTermAck with run-loop pumping so SwiftUI stays responsive.
 * Gives up after 10 seconds. Returns true if ack received. */
static bool waitForRGSSAck(RGSSThreadData &rtData) {
  for (int i = 0; i < 1000; ++i) {
    if (rtData.rqTermAck) {
      Debug() << "RGSS thread ack'd request after" << i * 10 << "ms";
      return true;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
  }
  return false;
}

/* Block until the RGSS thread posts sessionDone. Pumps the run loop
 * meanwhile so the UI stays responsive during teardown. */
static void waitForSessionDone(SDL_sem *sessionDone) {
  while (SDL_SemTryWait(sessionDone) != 0) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
  }
}

/* Clear the framebuffer to black between sessions so the next session
 * doesn't briefly flash the last frame of the previous one. The GL
 * context is held by the RGSS thread (blocked on sessionReady at this
 * point); claim it on the main thread for this single clear, then
 * release. */
static void clearFramebufferBetweenSessions(SDL_Window *win,
                                             SDL_GLContext ctx,
                                             GLuint screenFBO) {
  mkxpGL_MakeCurrent(win, ctx);
  gl.BindFramebuffer(GL_FRAMEBUFFER, screenFBO);
  gl.ClearColor(0, 0, 0, 1);
  gl.Clear(GL_COLOR_BUFFER_BIT);
  mkxpGL_SwapWindow(win);
  mkxpGL_MakeCurrent(win, NULL);
}
#endif // TARGET_OS_IPHONE

int main(int argc, char *argv[]) {
  try {

#if TARGET_OS_IPHONE
    // --- FIRST LAUNCH: wait for Library UI before SDL_Init ---
    // SDL_Init creates an OpenGL window that would cover the Library UI,
    // so we wait for the user to pick a game first.
    char dataDir[512]{};
    const char *selectedPath = mkxp_waitForGamePath();
    if (selectedPath && selectedPath[0]) {
        // snprintf always null-terminates, unlike strncpy.
        snprintf(dataDir, sizeof(dataDir), "%s", selectedPath);
    }
#endif

    SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
    SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, "0");

#ifdef GLES2_HEADER
    SDL_SetHint(SDL_HINT_OPENGL_ES_DRIVER, "1");
#endif

    SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");

    if (!initSDLLibs()) {
#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif
      return 0;
    }

#ifndef WORKDIR_CURRENT
#if !TARGET_OS_IPHONE
    char dataDir[512]{};
#endif
#if defined(__linux__)
    char *tmp{};
    tmp = getenv("SRCDIR");
    if (tmp) {
      snprintf(dataDir, sizeof(dataDir), "%s", tmp);
    }
#endif
    if (!dataDir[0]) {
        snprintf(dataDir, sizeof(dataDir), "%s", mkxp_fs::getDefaultGameRoot().c_str());
    }
    bool cwdOk = mkxp_fs::setCurrentDirectory(dataDir);
    (void)cwdOk;
#endif

#ifdef MKXPZ_STEAM
    if (!STEAMSHIM_init()) {
      showInitError("Failed to initialize Steamworks. The application cannot "
                    "continue launching.");
      shutdownSDLLibs();
      return 0;
    }
#endif

#if defined(__WIN32__)
    WSAData wsadata = {0};
    if (WSAStartup(0x101, &wsadata) || wsadata.wVersion != 0x101) {
      char buf[200];
      snprintf(buf, sizeof(buf), "Error initializing winsock: %08X",
               WSAGetLastError());
      showInitError(std::string(buf));
    }
#endif

    // ================================================================
    // iOS: Create persistent window, GL context, and AL device ONCE.
    // These survive across game sessions to avoid GL context issues.
    // ================================================================
#if TARGET_OS_IPHONE
    // Set working directory for the first game (needed to read Config)
    mkxp_fs::setCurrentDirectory(dataDir);

    /* Read initial config to get window title/size (Config is re-read
     * per session, but we need one now for window creation). */
    Config initConf;
    initConf.read(argc, argv);

    SDL_Window *persistWin = createPersistentWindow(initConf);
    if (!persistWin)
      return 0;

    SDL_GLContext persistGLCtx = createPersistentGL(persistWin);
    if (!persistGLCtx) {
      SDL_DestroyWindow(persistWin);
      return 0;
    }

    ALCdevice *persistAlcDev = nullptr;
    ALCcontext *persistAlcCtx = nullptr;
    if (!createPersistentAudio(&persistAlcDev, &persistAlcCtx)) {
      teardownANGLE();
      SDL_DestroyWindow(persistWin);
      return 0;
    }

    SDL_DisplayMode mode;
    SDL_GetDisplayMode(0, 0, &mode);

    // ================================================================
    // Game session loop — persistent RGSS thread
    // ================================================================
    s_rgssSessionReady = SDL_CreateSemaphore(0);
    s_rgssSessionDone  = SDL_CreateSemaphore(0);
    SDL_Thread *rgssThread = nullptr;
    bool firstSession = true;
    while (true) {
      /* On sessions after the first, block until the Library UI
       * provides the next game. An empty path means the user quit. */
      if (!firstSession && !waitForNextGame(dataDir, sizeof(dataDir)))
        break;
      firstSession = false;

      /* Read the game's config. */
      Config conf;
      conf.read(argc, argv);

      if (conf.windowTitle.empty())
        conf.windowTitle = conf.game.title;

      assert(conf.rgssVersion >= 1 && conf.rgssVersion <= 3);
      printRgssVersion(conf.rgssVersion);

      initSyntaxTransform(conf);

      SDL_SetWindowTitle(persistWin, conf.windowTitle.c_str());

      if (!mode.refresh_rate)
        conf.syncToRefreshrate = false;

      EventThread eventThread;

      RGSSThreadData rtData(&eventThread, argv[0], persistWin, persistAlcDev,
                            persistAlcCtx, mode.refresh_rate,
                            mkxp_sys::getScalingFactor(), conf, persistGLCtx);

      int winW, winH, drwW, drwH;
      SDL_GetWindowSize(persistWin, &winW, &winH);
      rtData.windowSizeMsg.post(Vec2i(winW, winH));

      mkxpGL_GetDrawableSize(persistWin, &drwW, &drwH);
      rtData.drawableSizeMsg.post(Vec2i(drwW, drwH));

      rtData.bindingUpdateMsg.post(loadBindings(conf));

      /* Drain stale events (especially SDL_QUIT) left over from the
       * previous session so the event loop doesn't exit immediately. */
      SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);

      if (!rgssThread) {
        /* First session: create the persistent RGSS thread.
         * Ruby 3.1's GC is precise, so 1 MB is plenty. */
        rgssThread = SDL_CreateThreadWithStackSize(rgssThreadFun, "rgss",
                                                    1 * 1024 * 1024, &rtData);
      } else {
        /* Subsequent sessions: signal the persistent RGSS thread
         * with the new session data. */
        s_nextRTData = &rtData;
        SDL_SemPost(s_rgssSessionReady);
      }

      /* Run event processing until the game ends. */
      eventThread.process(rtData);

      /* Ask the RGSS thread to stop, then wait for it. */
      rtData.rqTerm.set();
      const bool acked = waitForRGSSAck(rtData);

      if (acked) {
        /* RGSS thread is shutting down: wait for it to finish
         * SharedState::finiInstance before we proceed. */
        waitForSessionDone(s_rgssSessionDone);
      } else {
        /* The RGSS thread is stuck (never called checkShutdown).
         * Our single-reused-thread architecture cannot respawn a
         * new VM while the old one is blocked, so the only safe
         * recovery is to force-quit the app. The UI will terminate
         * the process when the user taps OK. */
        mkxp_setEngineHung();
        /* Intentionally generic - by the time this alert is seen,
         * the user may have already selected a different game in
         * the Library. */
        mkxp_setErrorMessage(
            "The previous game stopped responding. The app will now close.");
      }

      if (!rtData.rgssErrorMsg.empty()) {
        Debug() << rtData.rgssErrorMsg;
        mkxp_setErrorMessage(rtData.rgssErrorMsg.c_str());
      }

      eventThread.cleanup();

      clearFramebufferBetweenSessions(persistWin, persistGLCtx, s_screenFBO);

      Debug() << "Game session ended.";
    } // end while(true) game session loop

    /* Signal the RGSS thread to exit */
    s_nextRTData = nullptr;
    SDL_SemPost(s_rgssSessionReady);
    SDL_WaitThread(rgssThread, 0);
    SDL_DestroySemaphore(s_rgssSessionReady);
    SDL_DestroySemaphore(s_rgssSessionDone);

    /* Cleanup persistent resources (unreachable in normal flow,
     * but good form in case we ever break out of the loop) */
    if (persistGLCtx)
      SDL_GL_DeleteContext(persistGLCtx);
    alcMakeContextCurrent(NULL);
    if (persistAlcCtx)
      alcDestroyContext(persistAlcCtx);
    alcCloseDevice(persistAlcDev);
    SDL_DestroyWindow(persistWin);

#else // !TARGET_OS_IPHONE — original single-session flow

    // ================================================================
    // Non-iOS: single-pass flow (no session loop)
    // ================================================================

    /* now we load the config */
    Config conf;
    conf.read(argc, argv);

#if defined(__WIN32__)
    // Create a debug console in debug mode
    if (conf.winConsole) {
      if (setupWindowsConsole()) {
        reopenWindowsStreams();
      } else {
        char buf[200];
        snprintf(buf, sizeof(buf), "Error allocating console: %lu",
                GetLastError());
        showInitError(std::string(buf));
      }
    }
#endif

    if (conf.windowTitle.empty())
      conf.windowTitle = conf.game.title;

    assert(conf.rgssVersion >= 1 && conf.rgssVersion <= 3);
    printRgssVersion(conf.rgssVersion);

    initSyntaxTransform(conf);

    int imgFlags = IMG_INIT_PNG | IMG_INIT_JPG;
    if (IMG_Init(imgFlags) != imgFlags) {
      showInitError(std::string("Error initializing SDL_image: ") +
                    SDL_GetError());
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif

      return 0;
    }

    if (TTF_Init() < 0) {
      showInitError(std::string("Error initializing SDL_ttf: ") +
                    SDL_GetError());
      IMG_Quit();
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif

      return 0;
    }

    if (Sound_Init() == 0) {
      showInitError(std::string("Error initializing SDL_sound: ") +
                    Sound_GetError());
      TTF_Quit();
      IMG_Quit();
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif

      return 0;
    }
#if defined(__WIN32__)
    WSAData wsadata = {0};
    if (WSAStartup(0x101, &wsadata) || wsadata.wVersion != 0x101) {
      char buf[200];
      snprintf(buf, sizeof(buf), "Error initializing winsock: %08X",
               WSAGetLastError());
      showInitError(
          std::string(buf)); // Not an error worth ending the program over
    }
#endif

    SDL_Window *win;
    Uint32 winFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_ALLOW_HIGHDPI;

    if (conf.winResizable)
      winFlags |= SDL_WINDOW_RESIZABLE;
    if (conf.fullscreen)
      winFlags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    
#ifdef GLES2_HEADER
  setGLES2Attributes();

    // LoadLibrary properly initializes EGL, it won't work otherwise.
    // Doesn't completely do it though, needs a small patch to SDL
#if defined(MKXPZ_BUILD_XCODE) && !TARGET_OS_IPHONE
    SDL_setenv("ANGLE_DEFAULT_PLATFORM", (conf.preferMetalRenderer) ? "metal" : "opengl", true);
    SDL_GL_LoadLibrary("@rpath/libEGL.dylib");
#endif
#endif
    
    win = SDL_CreateWindow(conf.windowTitle.c_str(), SDL_WINDOWPOS_UNDEFINED,
                           SDL_WINDOWPOS_UNDEFINED, conf.defScreenW,
                           conf.defScreenH, winFlags);

    if (!win) {
      showInitError(std::string("Error creating window: ") + SDL_GetError());
#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif
      return 0;
    }
    
#if defined(MKXPZ_BUILD_XCODE) && !TARGET_OS_IPHONE
    {
        std::string downloadsPath = "/Users/" + mkxp_sys::getUserName() + "/Downloads";
        
        if (mkxp_fs::getCurrentDirectory().find(downloadsPath) == 0) {
            showInitError(conf.game.title +
                          " cannot run from the Downloads directory.\n\n" +
                          "Please move the application to the Applications folder (or anywhere else) " +
                          "and try again.");
#ifdef MKXPZ_STEAM
            STEAMSHIM_deinit();
#endif
            return 0;
        }
    }
#endif
    
#if defined(MKXPZ_BUILD_XCODE)
#define DEBUG_FSELECT_MSG "Select the folder from which to load game files. This is the folder containing the game's INI."
#define DEBUG_FSELECT_PROMPT "Load Game"
    if (conf.manualFolderSelect) {
        std::string dataDirStr = mkxp_fs::selectPath(win, DEBUG_FSELECT_MSG, DEBUG_FSELECT_PROMPT);
        if (!dataDirStr.empty()) {
            conf.gameFolder = dataDirStr;
            mkxp_fs::setCurrentDirectory(dataDirStr.c_str());
            Debug() << "Current directory set to" << dataDirStr;
            conf.read(argc, argv);
            conf.readGameINI();
        }
    }
#endif

    /* OSX and Windows have their own native ways of
     * dealing with icons; don't interfere with them */
#ifdef __LINUX__
    setupWindowIcon(conf, win);
#else
    (void)setupWindowIcon;
#endif

    ALCdevice *alcDev = alcOpenDevice(0);

    if (!alcDev) {
      showInitError("Could not detect an available audio device.");
      SDL_DestroyWindow(win);
      shutdownSDLLibs();
#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif
      return 0;
    }

    ALCcontext *alcCtx = alcCreateContext(alcDev, 0);
    if (alcCtx)
      alcMakeContextCurrent(alcCtx);

    SDL_DisplayMode mode;
    SDL_GetDisplayMode(0, 0, &mode);

    /* Can't sync to display refresh rate if its value is unknown */
    if (!mode.refresh_rate)
      conf.syncToRefreshrate = false;

    EventThread eventThread;

#ifndef MKXPZ_INIT_GL_LATER
    SDL_GLContext glCtx = initGL(win, conf, nullptr);
#else
    SDL_GLContext glCtx = NULL;
#endif

    RGSSThreadData rtData(&eventThread, argv[0], win, alcDev, alcCtx, mode.refresh_rate,
                          mkxp_sys::getScalingFactor(), conf, glCtx);

    int winW, winH, drwW, drwH;
    SDL_GetWindowSize(win, &winW, &winH);
    rtData.windowSizeMsg.post(Vec2i(winW, winH));
    
    mkxpGL_GetDrawableSize(win, &drwW, &drwH);
    rtData.drawableSizeMsg.post(Vec2i(drwW, drwH));

    /* Load and post key bindings */
    rtData.bindingUpdateMsg.post(loadBindings(conf));
    
#ifdef MKXPZ_BUILD_XCODE
    // Create Touch Bar
    initTouchBar(win, conf);
#endif

    /* Start RGSS thread */
    SDL_Thread *rgssThread = SDL_CreateThread(rgssThreadFun, "rgss", &rtData);

    /* Start event processing */
    eventThread.process(rtData);

    /* Request RGSS thread to stop */
    rtData.rqTerm.set();

    /* Wait for RGSS thread response */
    for (int i = 0; i < 1000; ++i) {
      /* We can stop waiting when the request was ack'd */
      if (rtData.rqTermAck) {
        Debug() << "RGSS thread ack'd request after" << i * 10 << "ms";
        break;
      }

      /* Give RGSS thread some time to respond */
      SDL_Delay(10);
    }

    /* If RGSS thread ack'd request, wait for it to shutdown,
     * otherwise abandon hope and just end the process as is. */
    if (rtData.rqTermAck)
      SDL_WaitThread(rgssThread, 0);
    else
      SDL_ShowSimpleMessageBox(
          SDL_MESSAGEBOX_ERROR, conf.game.title.c_str(),
          std::string("The RGSS script seems to be stuck. "+conf.game.title+" will now force quit.").c_str(),
          win);

    if (!rtData.rgssErrorMsg.empty()) {
      Debug() << rtData.rgssErrorMsg;
      SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, conf.game.title.c_str(),
                               rtData.rgssErrorMsg.c_str(), win);
    }

    if (rtData.glContext)
      SDL_GL_DeleteContext(rtData.glContext);

    /* Clean up any remaining events */
    eventThread.cleanup();

    Debug() << "Game session ended.";

    alcMakeContextCurrent(NULL);
    if (alcCtx)
      alcDestroyContext(alcCtx);
    alcCloseDevice(alcDev);
    SDL_DestroyWindow(win);

#endif // TARGET_OS_IPHONE

    Debug() << "Shutting down.";

#if defined(__WIN32__)
    if (wsadata.wVersion)
      WSACleanup();
#endif

#ifdef MKXPZ_STEAM
    STEAMSHIM_deinit();
#endif
    shutdownSDLLibs();

    return 0;
  } catch (const Exception &exc) {
    Debug() << "FATAL uncaught Exception:" << exc.msg;
    return 1;
  } catch (const std::exception &e) {
    Debug() << "FATAL uncaught std::exception:" << e.what();
    return 1;
  } catch (...) {
    Debug() << "FATAL unknown exception caught";
    return 1;
  }
}

#if TARGET_OS_IPHONE
static bool initANGLE(SDL_Window *win) {
  s_eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (s_eglDisplay == EGL_NO_DISPLAY) {
    showInitError("ANGLE: eglGetDisplay failed");
    return false;
  }

  EGLint major, minor;
  if (!eglInitialize(s_eglDisplay, &major, &minor)) {
    showInitError("ANGLE: eglInitialize failed");
    return false;
  }
  Debug() << "ANGLE: EGL" << major << "." << minor;

  EGLint configAttribs[] = {
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
    EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
    EGL_RED_SIZE,        8,
    EGL_GREEN_SIZE,      8,
    EGL_BLUE_SIZE,       8,
    EGL_ALPHA_SIZE,      8,
    EGL_DEPTH_SIZE,      0,
    EGL_STENCIL_SIZE,    0,
    EGL_NONE
  };
  EGLConfig eglConfig;
  EGLint numConfigs;
  if (!eglChooseConfig(s_eglDisplay, configAttribs, &eglConfig, 1, &numConfigs) || numConfigs == 0) {
    showInitError("ANGLE: eglChooseConfig failed");
    return false;
  }

  // Upstream ANGLE's Metal backend expects a CALayer* as native window
  EGLNativeWindowType nativeWindow = (EGLNativeWindowType)mkxp_getANGLENativeLayer(win);
  if (!nativeWindow) {
    showInitError("ANGLE: failed to get native layer from SDL window");
    return false;
  }

  s_eglSurface = eglCreateWindowSurface(s_eglDisplay, eglConfig, nativeWindow, NULL);
  if (s_eglSurface == EGL_NO_SURFACE) {
    showInitError("ANGLE: eglCreateWindowSurface failed");
    return false;
  }

  EGLint contextAttribs[] = {
    EGL_CONTEXT_CLIENT_VERSION, 2,
    EGL_NONE
  };
  s_eglContext = eglCreateContext(s_eglDisplay, eglConfig, EGL_NO_CONTEXT, contextAttribs);
  if (s_eglContext == EGL_NO_CONTEXT) {
    showInitError("ANGLE: eglCreateContext failed");
    return false;
  }

  if (!eglMakeCurrent(s_eglDisplay, s_eglSurface, s_eglSurface, s_eglContext)) {
    showInitError("ANGLE: eglMakeCurrent failed");
    return false;
  }

  glGetProcAddressOverride = (GLGetProcAddressFunc)eglGetProcAddress;

  // Capture screen FBO (typically 0 under ANGLE/Metal).
  GLint fbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
  s_screenFBO = static_cast<GLuint>(fbo);

  try {
    initGLFunctions();
  } catch (const Exception &exc) {
    showInitError(exc.msg);
    return false;
  }

  gl.ClearColor(0, 0, 0, 1);
  gl.Clear(GL_COLOR_BUFFER_BIT);
  eglSwapBuffers(s_eglDisplay, s_eglSurface);

  printGLInfo();

  eglSwapInterval(s_eglDisplay, 1);

  return true;
}

static void teardownANGLE() {
  eglMakeCurrent(s_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (s_eglContext != EGL_NO_CONTEXT) {
    eglDestroyContext(s_eglDisplay, s_eglContext);
    s_eglContext = EGL_NO_CONTEXT;
  }
  if (s_eglSurface != EGL_NO_SURFACE) {
    eglDestroySurface(s_eglDisplay, s_eglSurface);
    s_eglSurface = EGL_NO_SURFACE;
  }
  if (s_eglDisplay != EGL_NO_DISPLAY) {
    eglTerminate(s_eglDisplay);
    s_eglDisplay = EGL_NO_DISPLAY;
  }
  glGetProcAddressOverride = nullptr;
}
#endif

static SDL_GLContext initGL(SDL_Window *win, Config &conf,
                            RGSSThreadData *threadData) {
  SDL_GLContext glCtx{};

  /* Setup GL context. Must be done in main thread since macOS 10.15 */
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    
  if (conf.debugMode)
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_DEBUG_FLAG);

  glCtx = SDL_GL_CreateContext(win);

  if (!glCtx) {
    GLINIT_SHOWERROR(std::string("Could not create OpenGL context: ") + SDL_GetError());
    return 0;
  }

  try {
    initGLFunctions();
  } catch (const Exception &exc) {
    GLINIT_SHOWERROR(exc.msg);
    SDL_GL_DeleteContext(glCtx);

    return 0;
  }

  if (!conf.enableBlitting)
    gl.BlitFramebuffer = 0;

  gl.ClearColor(0, 0, 0, 1);
  gl.Clear(GL_COLOR_BUFFER_BIT);
  SDL_GL_SwapWindow(win);

  printGLInfo();

  bool vsync = conf.vsync || conf.syncToRefreshrate;
  SDL_GL_SetSwapInterval(vsync ? 1 : 0);

  // GLDebugLogger dLogger;
  return glCtx;
}
