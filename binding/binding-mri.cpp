/*
 ** binding-mri.cpp
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

#include "audio/audio.h"
#include "filesystem/filesystem.h"
#include "display/graphics.h"
#include "display/font.h"
#include "system/system.h"

#include "util/util.h"
#include "util/sdl-util.h"
#include "util/debugwriter.h"
#include "util/boost-hash.h"
#include "util/exception.h"
#include "util/encoding.h"

#include "config.h"

#include "binding-util.h"
#include "binding.h"

#include "sharedstate.h"
#include "patcher.h"
#include "eventthread.h"
#include "display/gl/glstate.h"

#include <vector>
#include <regex>
#include <algorithm>
#include <cstdio>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#include "app_bridge.h"
#include "util/rapidcsv.h"
#include "script-bootstrap.h"

extern "C" {
#include <ruby.h>

#if RAPI_FULL >= 190
#include <ruby/encoding.h>
#endif

/* Ruby 1.8 / 1.9 statically-linked extension init function.
 *
 * Init_ext() lives in our hand-rolled extinit.c (see
 * ios/Dependencies/ruby{18,19}/extinit.c) and calls ruby_init_ext()
 * for each bundled extension (zlib, stringio, etc), which both runs
 * the extension's Init_X and registers it with Ruby's `loaded`
 * features list so subsequent `require 'X'` is a no-op.
 *
 * Without this call, the extensions never initialize and game
 * scripts that reference Zlib::Inflate (or StringIO, etc.) fail
 * with NameError "uninitialized constant Zlib".
 *
 * Ruby 3.0+ doesn't need this: its `ruby_setup`/`ruby_options`
 * path calls Init_ext automatically. Ruby 1.8 / 1.9 only call it
 * from `require_libraries`, which fires only when -r command-line
 * options are present - we don't go through that path. */
#if RAPI_FULL < 200
extern "C" void Init_ext(void);
#endif

/* Ruby 1.8 statically-linked extension init functions */
#if RAPI_FULL <= 187
void Init_zlib(void);
void Init_stringio(void);
void Init_strscan(void);
void Init_thread(void);
void Init_digest(void);
void Init_fcntl(void);

/* Ruby 1.8 GC stack base; defined in gc.c. */
extern VALUE *rb_gc_stack_start;
#endif
}

#include <assert.h>
#include <string>
#include <zlib.h>

#include <SDL_cpuinfo.h>
#include <SDL_filesystem.h>
#include <SDL_loadso.h>
#include <SDL_power.h>

extern const char module_rpg1[];
extern const char module_rpg2[];
extern const char module_rpg3[];

static VALUE topSelf;

static void mriBindingExecute();
static void mriBindingTerminate();
static void mriBindingReset();

ScriptBinding scriptBindingImpl = {mriBindingExecute, mriBindingTerminate,
    mriBindingReset};

ScriptBinding *scriptBinding = &scriptBindingImpl;

void tableBindingInit();
void etcBindingInit();
void fontBindingInit();
void bitmapBindingInit();
void spriteBindingInit();
void viewportBindingInit();
void planeBindingInit();
void windowBindingInit();
void tilemapBindingInit();
void windowVXBindingInit();
void tilemapVXBindingInit();

void inputBindingInit();
void audioBindingInit();
void graphicsBindingInit();

void fileIntBindingInit();

void httpBindingInit();

void hmode7BindingInit();

RB_METHOD(mkxpDelta);
RB_METHOD(mriPrint);
RB_METHOD(mriP);
RB_METHOD(mkxpKernelPrint);
RB_METHOD(mkxpDataDirectory);
RB_METHOD(mkxpSetTitle);
RB_METHOD(mkxpGetTitle);
RB_METHOD(mkxpDesensitize);
RB_METHOD(mkxpPuts);

RB_METHOD(mkxpPlatform);
RB_METHOD(mkxpIsMacHost);
RB_METHOD(mkxpIsWindowsHost);
RB_METHOD(mkxpIsLinuxHost);
RB_METHOD(mkxpIsIOSHost);
RB_METHOD(mkxpIsUsingRosetta);
RB_METHOD(mkxpIsUsingWine);
RB_METHOD(mkxpIsReallyMacHost);
RB_METHOD(mkxpIsReallyLinuxHost);
RB_METHOD(mkxpIsReallyWindowsHost);

RB_METHOD(mkxpCheatsEnabled);
RB_METHOD(mkxpUseInGameKeyboard);
RB_METHOD(mkxpManagedConfigDir);
RB_METHOD(mkxpSyntaxTransformTarget);
RB_METHOD(mkxpApplyOverrides);
RB_METHOD(mkxpRpgVersion);
RB_METHOD(mkxpRubyVersion);

RB_METHOD(mkxpUserLanguage);
RB_METHOD(mkxpUserName);
RB_METHOD(mkxpGameTitle);
RB_METHOD(mkxpPowerState);
RB_METHOD(mkxpSettingsMenu);
RB_METHOD(mkxpCpuCount);
RB_METHOD(mkxpSystemMemory);
RB_METHOD(mkxpReloadPathCache);
RB_METHOD(mkxpAddPath);
RB_METHOD(mkxpRemovePath);
RB_METHOD(mkxpFileExists);
RB_METHOD(mkxpLaunch);

RB_METHOD(mkxpGetJSONSetting);
RB_METHOD(mkxpSetJSONSetting);
RB_METHOD(mkxpGetAllJSONSettings);

RB_METHOD(mkxpSetDefaultFontFamily);

RB_METHOD(mriRgssMain);
RB_METHOD(mriRgssStop);
RB_METHOD(_kernelCaller);

RB_METHOD(mkxpStringToUTF8);
RB_METHOD(mkxpStringToUTF8Bang);
RB_METHOD(mkxpStringAref);
RB_METHOD(mkxpStringAset);

VALUE json2rb(json5pp::value const &v);
json5pp::value rb2json(VALUE v);

RB_METHOD(mkxpParseCSV);

#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
#if RAPI_MAJOR > 1 || (RAPI_MAJOR == 1 && RAPI_MINOR > 8)
static VALUE legacy_array_choice(int argc, VALUE *argv, VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "choice");
    return rb_funcallv(self, rb_intern("sample"), argc, argv);
}

static VALUE legacy_array_indexes(int argc, VALUE *argv, VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "indexes");
    rb_warn("Array#indexes is deprecated; use Array#values_at");
    return rb_funcallv(self, rb_intern("values_at"), argc, argv);
}

static VALUE legacy_array_indices(int argc, VALUE *argv, VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "indices");
    rb_warn("Array#indices is deprecated; use Array#values_at");
    return rb_funcallv(self, rb_intern("values_at"), argc, argv);
}

static VALUE legacy_hash_indexes(int argc, VALUE *argv, VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "indexes");
    rb_warn("Hash#indexes is deprecated; use Hash#values_at");
    return rb_funcallv(self, rb_intern("values_at"), argc, argv);
}

static VALUE legacy_hash_indices(int argc, VALUE *argv, VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "indices");
    rb_warn("Hash#indices is deprecated; use Hash#values_at");
    return rb_funcallv(self, rb_intern("values_at"), argc, argv);
}

static VALUE legacy_kernel_id(VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "id");
    rb_warn("Object#id will be deprecated; use Object#object_id");
    return rb_obj_id(self);
}

static VALUE legacy_kernel_type(VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "type");
    rb_warn("Object#type is deprecated; use Object#class");
    return rb_obj_class(self);
}

static VALUE legacy_symbol_to_i(VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "to_i");
    return RB_LONG2FIX(rb_sym2id(self));
}

static VALUE legacy_symbol_to_int(VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(1, 8, -1))
        mkxp_raise_no_method_exception(self, "to_int");
    rb_warning("treating Symbol as an integer");
    return RB_LONG2FIX(rb_sym2id(self));
}
#endif // RAPI_MAJOR > 1 || (RAPI_MAJOR == 1 && RAPI_MINOR > 8)

#if RAPI_MAJOR > 2 || (RAPI_MAJOR == 2 && RAPI_MINOR > 7)
static VALUE legacy_hash_index(int argc, VALUE *argv, VALUE self) {
    if (!mkxp_ec_is_syntax_transform_active(2, 7, -1))
        mkxp_raise_no_method_exception(self, "index");
    rb_warn("Hash#index is deprecated; use Hash#key instead");
    return rb_funcallv(self, rb_intern("key"), argc, argv);
}
#endif // RAPI_MAJOR > 2 || (RAPI_MAJOR == 2 && RAPI_MINOR > 7)

#if RAPI_MAJOR > 3 || (RAPI_MAJOR == 3 && RAPI_MINOR > 1)
static VALUE legacy_dir_exists(VALUE self, VALUE path) {
    if (!mkxp_ec_is_syntax_transform_active(3, 1, -1))
        mkxp_raise_no_method_exception(self, "exists?");
    return rb_funcall(rb_cDir, rb_intern("exist?"), 1, path);
}

static VALUE legacy_file_exists(VALUE self, VALUE path) {
    if (!mkxp_ec_is_syntax_transform_active(3, 1, -1))
        mkxp_raise_no_method_exception(self, "exists?");
    return rb_funcall(rb_cFile, rb_intern("exist?"), 1, path);
}

static VALUE legacy_file_test_exists(VALUE self, VALUE path) {
    if (!mkxp_ec_is_syntax_transform_active(3, 1, -1))
        mkxp_raise_no_method_exception(self, "exists?");
    return rb_funcall(rb_mFileTest, rb_intern("exist?"), 1, path);
}

static VALUE legacy_kernel_match(VALUE self, VALUE other) {
    if (mkxp_ec_is_syntax_transform_active(1, 8, -1))
        return Qfalse;
    else if (!mkxp_ec_is_syntax_transform_active(3, 1, -1))
        mkxp_raise_no_method_exception(self, "=~");
    return Qnil;
}
#endif // RAPI_MAJOR > 3 || (RAPI_MAJOR == 3 && RAPI_MINOR > 1)
#endif // MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES

/* Idempotent wrapper around rb_define_alias. Defensive: callers
 * may run the same alias-then-redefine pattern more than once if
 * the engine ever loads them through a path that re-evaluates
 * the binding init. Skip the alias if it's already defined. */
static void mkxp_define_alias_once(VALUE klass, const char *aliasName,
                                   const char *origName) {
    if (rb_method_boundp(klass, rb_intern(aliasName), /*ex=*/0)) return;
    rb_define_alias(klass, aliasName, origName);
}

static void mriBindingInit() {
#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
#if RAPI_MAJOR > 1 || (RAPI_MAJOR == 1 && RAPI_MINOR > 8)
    rb_define_method(rb_cArray, "choice", legacy_array_choice, -1);
    rb_define_method(rb_cArray, "indexes", legacy_array_indexes, -1);
    rb_define_method(rb_cArray, "indices", legacy_array_indices, -1);
    rb_define_method(rb_cHash, "indexes", legacy_hash_indexes, -1);
    rb_define_method(rb_cHash, "indices", legacy_hash_indices, -1);
    rb_define_method(rb_mKernel, "id", legacy_kernel_id, 0);
    rb_define_method(rb_mKernel, "type", legacy_kernel_type, 0);
    rb_define_method(rb_cSymbol, "to_i", legacy_symbol_to_i, 0);
    rb_define_method(rb_cSymbol, "to_int", legacy_symbol_to_int, 0);
#endif // RAPI_MAJOR > 1 || (RAPI_MAJOR == 1 && RAPI_MINOR > 8)
#if RAPI_MAJOR > 2 || (RAPI_MAJOR == 2 && RAPI_MINOR > 7)
    rb_define_method(rb_cHash, "index", legacy_hash_index, -1);
#endif // RAPI_MAJOR > 2 || (RAPI_MAJOR == 2 && RAPI_MINOR > 7)
#if RAPI_MAJOR > 3 || (RAPI_MAJOR == 3 && RAPI_MINOR > 1)
    rb_define_singleton_method(rb_cDir, "exists?", legacy_dir_exists, 1);
    rb_define_singleton_method(rb_cFile, "exists?", legacy_file_exists, 1);
    rb_define_module_function(rb_mFileTest, "exists?", legacy_file_test_exists, 1);
    rb_define_method(rb_mKernel, "=~", legacy_kernel_match, 1);
#endif // RAPI_MAJOR > 3 || (RAPI_MAJOR == 3 && RAPI_MINOR > 1)
#endif // MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES

    tableBindingInit();
    etcBindingInit();
    fontBindingInit();
    bitmapBindingInit();
    spriteBindingInit();
    viewportBindingInit();
    planeBindingInit();
    
    if (rgssVer == 1) {
        windowBindingInit();
        tilemapBindingInit();
    } else {
        windowVXBindingInit();
        tilemapVXBindingInit();
    }
    
    inputBindingInit();
    audioBindingInit();
    graphicsBindingInit();
    
    fileIntBindingInit();

    httpBindingInit();

    /* H-Mode7 native binding. Depends on bitmapBindingInit +
     * tableBindingInit having run; registers the HM7::Native
     * module that the postload shim forwards HM7.self.xxx
     * method calls to. See binding/hmode7-binding.cpp. */
    hmode7BindingInit();
    
    if (rgssVer >= 3) {
        _rb_define_module_function(rb_mKernel, "rgss_main", mriRgssMain);
        _rb_define_module_function(rb_mKernel, "rgss_stop", mriRgssStop);
        
        _rb_define_module_function(rb_mKernel, "msgbox", mriPrint);
        _rb_define_module_function(rb_mKernel, "msgbox_p", mriP);
        
        rb_define_global_const("RGSS_VERSION", mkxp_str_new_cstr("3.0.1"));
    } else {
        // print -> debug log (NOT a dialog; see mkxpKernelPrint).
        // p stays bound to mriP -> showMessageBox; that's a debug
        // method games rarely use in production and a dialog is
        // a reasonable surface for it.
        _rb_define_module_function(rb_mKernel, "print", mkxpKernelPrint);
        _rb_define_module_function(rb_mKernel, "p", mriP);
        
        mkxp_define_alias_once(rb_singleton_class(rb_mKernel),
                               "_mkxp_kernel_caller_alias", "caller");
        _rb_define_module_function(rb_mKernel, "caller", _kernelCaller);
    }
    
    if (rgssVer == 1)
        rb_eval_string(module_rpg1);
    else if (rgssVer == 2)
        rb_eval_string(module_rpg2);
    else if (rgssVer == 3)
        rb_eval_string(module_rpg3);
    else
        assert(!"unreachable");
    
    VALUE mod = rb_define_module("System");
    _rb_define_module_function(mod, "delta", mkxpDelta);
    _rb_define_module_function(mod, "uptime", mkxpDelta);
    _rb_define_module_function(mod, "data_directory", mkxpDataDirectory);
    _rb_define_module_function(mod, "set_window_title", mkxpSetTitle);
    _rb_define_module_function(mod, "window_title", mkxpGetTitle);
    _rb_define_module_function(mod, "window_title=", mkxpSetTitle);
    _rb_define_module_function(mod, "show_settings", mkxpSettingsMenu);
    _rb_define_module_function(mod, "puts", mkxpPuts);
    _rb_define_module_function(mod, "desensitize", mkxpDesensitize);
    _rb_define_module_function(mod, "platform", mkxpPlatform);
    
    _rb_define_module_function(mod, "is_mac?", mkxpIsMacHost);
    _rb_define_module_function(mod, "is_rosetta?", mkxpIsUsingRosetta);

    _rb_define_module_function(mod, "is_linux?", mkxpIsLinuxHost);

    _rb_define_module_function(mod, "is_windows?", mkxpIsWindowsHost);
    _rb_define_module_function(mod, "is_ios?", mkxpIsIOSHost);
    _rb_define_module_function(mod, "is_wine?", mkxpIsUsingWine);
    _rb_define_module_function(mod, "is_really_mac?", mkxpIsReallyMacHost);
    _rb_define_module_function(mod, "is_really_linux?", mkxpIsReallyLinuxHost);
    _rb_define_module_function(mod, "is_really_windows?", mkxpIsReallyWindowsHost);

    _rb_define_module_function(mod, "cheats_enabled?", mkxpCheatsEnabled);
    _rb_define_module_function(mod, "use_in_game_keyboard?", mkxpUseInGameKeyboard);
    _rb_define_module_function(mod, "managed_config_dir", mkxpManagedConfigDir);
    _rb_define_module_function(mod, "apply_overrides", mkxpApplyOverrides);
    _rb_define_module_function(mod, "rpg_version", mkxpRpgVersion);
    _rb_define_module_function(mod, "ruby_version", mkxpRubyVersion);
    _rb_define_module_function(mod, "syntax_transform_target", mkxpSyntaxTransformTarget);
    
    
    _rb_define_module_function(mod, "user_language", mkxpUserLanguage);
    _rb_define_module_function(mod, "user_name", mkxpUserName);
    _rb_define_module_function(mod, "game_title", mkxpGameTitle);
    _rb_define_module_function(mod, "power_state", mkxpPowerState);
    _rb_define_module_function(mod, "nproc", mkxpCpuCount);
    _rb_define_module_function(mod, "memory", mkxpSystemMemory);
    _rb_define_module_function(mod, "reload_cache", mkxpReloadPathCache);
    _rb_define_module_function(mod, "mount", mkxpAddPath);
    _rb_define_module_function(mod, "unmount", mkxpRemovePath);
    _rb_define_module_function(mod, "file_exist?", mkxpFileExists);
    _rb_define_module_function(mod, "launch", mkxpLaunch);
    
    _rb_define_module_function(mod, "default_font_family=", mkxpSetDefaultFontFamily);
    
    _rb_define_module_function(mod, "parse_csv", mkxpParseCSV);
    
    _rb_define_method(rb_cString, "to_utf8", mkxpStringToUTF8);
    _rb_define_method(rb_cString, "to_utf8!", mkxpStringToUTF8Bang);
    
    /* Ruby 1.8 String#[] / String#[]= compatibility (C-level for $~ safety) */
#if RAPI_FULL > 187
    mkxp_define_alias_once(rb_cString, "_mkxp_c_aref",    "[]");
    mkxp_define_alias_once(rb_cString, "_mkxp_c_aset",    "[]=");
    mkxp_define_alias_once(rb_cString, "_mkxp_c_getbyte", "getbyte");
    rb_define_method(rb_cString, "[]",  RUBY_METHOD_FUNC(mkxpStringAref), -1);
    rb_define_method(rb_cString, "[]=", RUBY_METHOD_FUNC(mkxpStringAset), -1);
#endif
    
    VALUE cmod = rb_define_module("CFG");
    _rb_define_module_function(cmod, "[]", mkxpGetJSONSetting);
    _rb_define_module_function(cmod, "[]=", mkxpSetJSONSetting);
    _rb_define_module_function(cmod, "to_hash", mkxpGetAllJSONSettings);
    
    /* Load global constants */
    rb_gv_set("MKXP", Qtrue);
    rb_gv_set("MKXP_MAX_TEX_SIZE", INT2NUM(glState.caps.realMaxTexSize));
    
    VALUE debug = rb_bool_new(shState->config().editor.debug);
    if (rgssVer == 1)
        rb_gv_set("DEBUG", debug);
    else if (rgssVer >= 2)
        rb_gv_set("TEST", debug);
    
    rb_gv_set("BTEST", rb_bool_new(shState->config().editor.battleTest));
    
    std::string version = std::string(MKXPZ_VERSION "/") + getPlistValue("GIT_COMMIT_HASH");
    VALUE vers = mkxp_str_new_cstr(version.c_str());
    rb_str_freeze(vers);
    rb_define_const(mod, "VERSION", vers);
    
    // Automatically load zlib if it's present -- the correct way this time
    int state;
    rb_eval_string_protect("require('zlib') if !defined?(Zlib)", &state);
    if (state) {
        Debug() << "Could not load Zlib. If this is important, make sure Ruby was built with static extensions, or that"
        << ((MKXPZ_PLATFORM == MKXPZ_PLATFORM_MACOS) ? "zlib.bundle" : "zlib.so")
        << "is present and reachable by Ruby's loadpath.";
    }
    
}

static void showMsg(const std::string &msg) {
    shState->eThread().showMessageBox(msg.c_str());
}

static void printP(int argc, VALUE *argv, const char *convMethod,
                   const char *sep) {
    VALUE dispString = rb_str_buf_new(128);
    ID conv = rb_intern(convMethod);
    
    for (int i = 0; i < argc; ++i) {
        VALUE str = rb_funcall2(argv[i], conv, 0, NULL);
        rb_str_buf_append(dispString, str);
        
        if (i < argc)
            rb_str_buf_cat2(dispString, sep);
    }
    
    showMsg(RSTRING_PTR(dispString));
}


RB_METHOD_GUARD(mriPrint) {
    RB_UNUSED_PARAM;
    
    printP(argc, argv, "to_s", "");
    
    shState->checkShutdown();
    shState->checkReset();
    
    return Qnil;
}
RB_METHOD_GUARD_END

/* Kernel#print routed to the debug log instead of `showMessageBox`.
 *
 * mkxp historically bound `Kernel#print` to a Win32-style modal
 * message box, which on iOS surfaces in the host as the same alert
 * we use for engine errors ("Something went wrong"). Some games
 * call `print` for benign informational notices (Pokemon Infinite
 * Fusion's PokemonLoadScreen#copyKeybindings is the trigger we
 * found, but the pattern is general) and the resulting alert
 * forces the user to dismiss + restart the game even though
 * nothing has gone wrong.
 *
 * Routing `print` to `mkxp_debugLog` matches Ruby's mainline
 * convention (Kernel#print writes to stdout, no UI). Games that
 * explicitly want a dialog can call `msgbox` instead, which
 * stays bound to the original `mriPrint`/`showMessageBox` path.
 *
 * Same arg semantics as Ruby's Kernel#print: each arg is converted
 * via `to_s`, joined without separator, no trailing newline.
 */
RB_METHOD_GUARD(mkxpKernelPrint) {
    RB_UNUSED_PARAM;
    
    VALUE buf = rb_str_buf_new(128);
    ID conv = rb_intern("to_s");
    for (int i = 0; i < argc; ++i) {
        VALUE str = rb_funcall2(argv[i], conv, 0, NULL);
        rb_str_buf_append(buf, str);
    }
    
    Debug() << RSTRING_PTR(buf);
    mkxp_debugLog("SCRIPT", "Kernel.print [Ruby]", RSTRING_PTR(buf));
    
    shState->checkShutdown();
    shState->checkReset();
    
    return Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(mriP) {
    RB_UNUSED_PARAM;
    
    printP(argc, argv, "inspect", "\n");
    
    shState->checkShutdown();
    shState->checkReset();
    
    return Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD(mkxpDelta) {
    RB_UNUSED_PARAM;
    return rb_float_new(shState->runTime());
}

/* System.data_directory - per-game writable directory. On iOS Empo
   points this at `Documents/Games/<id>/UserData/` so saves and any
   companion app-data files are visible in the Files app and stay
   inside the imported game container. */
RB_METHOD(mkxpDataDirectory) {
    RB_UNUSED_PARAM;
    
    const std::string &path = shState->config().customDataPath;
    const char *s = path.empty() ? "." : path.c_str();
    
    std::string s_nml = shState->fileSystem().normalize(s, 1, 1);
    VALUE ret = mkxp_str_new_cstr(s_nml.c_str());
    
    return ret;
}

RB_METHOD(mkxpSetTitle) {
    RB_UNUSED_PARAM;
    
    VALUE s;
    rb_scan_args(argc, argv, "1", &s);
    SafeStringValue(s);
    
    shState->eThread().requestWindowRename(RSTRING_PTR(s));
    return s;
}

RB_METHOD(mkxpGetTitle) {
    RB_UNUSED_PARAM;
    
    rb_check_argc(argc, 0);
    
    return mkxp_str_new_cstr(SDL_GetWindowTitle(shState->sdlWindow()));
}

RB_METHOD(mkxpDesensitize) {
    RB_UNUSED_PARAM;
    
    VALUE filename;
    rb_scan_args(argc, argv, "1", &filename);
    SafeStringValue(filename);
    
    return mkxp_str_new_cstr(shState->fileSystem().desensitize(RSTRING_PTR(filename)));
}

RB_METHOD(mkxpPuts) {
    RB_UNUSED_PARAM;
    
    const char *str;
    rb_get_args(argc, argv, "z", &str RB_ARG_END);
    
    Debug() << str;
    // Mirror to the debug log so game scripts can trace behavior that
    // lives inside big RGSS scripts (like Main). Useful when tracking
    // down hangs.
    mkxp_debugLog("SCRIPT", "System.puts [Ruby]", str);
    
    return Qnil;
}

/* Platform methods exposed to Ruby scripts. This fork runs exclusively
 * on iOS / iPadOS / tvOS, so all legacy desktop predicates return false
 * and the host string is hardcoded. Methods are preserved (rather than
 * removed) so existing game scripts that call `System::is_mac?` etc.
 * continue to load without raising NoMethodError; they take
 * their "unknown platform" fallback path. `System::is_ios?` is
 * provided as the new positive check. */
RB_METHOD(mkxpPlatform) {
    RB_UNUSED_PARAM;
    return mkxp_str_new_cstr("iOS");
}

RB_METHOD(mkxpIsMacHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsUsingRosetta) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsLinuxHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsWindowsHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsIOSHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(true);
}

RB_METHOD(mkxpIsUsingWine) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsReallyMacHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsReallyLinuxHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

RB_METHOD(mkxpIsReallyWindowsHost) {
    RB_UNUSED_PARAM;
    return rb_bool_new(false);
}

/* MKXP.cheats_enabled? - reads the live bridge flag so the Ruby-side
   cheat menu can sync $CHEATS with the UI toggle each frame. */
RB_METHOD(mkxpCheatsEnabled) {
    RB_UNUSED_PARAM;
    return rb_bool_new(mkxp_getCheatsEnabled());
}

/* MKXP.use_in_game_keyboard? - true when the host requested that
   Pokemon Essentials text-entry scenes use the game's own
   keyboard scene instead of the iOS soft keyboard. Read by
   `pokemon_input.rb` to decide whether to force-disable
   `USEKEYBOARDTEXTENTRY`. */
RB_METHOD(mkxpUseInGameKeyboard) {
    RB_UNUSED_PARAM;
    return rb_bool_new(mkxp_getUseInGameKeyboard());
}

/* System.data_directory - per-game writable directory. On iOS Empo
   points this at `Documents/Games/<id>/UserData/` so saves and
   companion app-data files are visible in the Files app and stay
   inside the imported game container. */
/* MKXP.managed_config_dir - host-managed per-game state directory
   (Documents/EmpoState/<id>/ on iOS). Postload scripts use this
   to drop runtime-detection marker files that survive across
   sessions, e.g. `pokemon_input.rb` writes a
   `.pokemon_essentials_detected` marker so the next launch's
   GameSettings UI defaults the In-game keyboard toggle ON for
   PE games whose scripts live inside an rgssad archive (where
   filesystem-only detection from the host can't see PE
   signatures). Empty string when the host hasn't configured the
   bridge (desktop / non-iOS builds). */
RB_METHOD(mkxpManagedConfigDir) {
    RB_UNUSED_PARAM;
    const char *dir = mkxp_getManagedConfigDir();
    return rb_utf8_str_new_cstr(dir ? dir : "");
}

/* System.apply_overrides(str) - runs the JoiPlay-compatible
   script text-patcher over `str` and returns the rewritten text.
   Reborn and other PE fangames call MKXP.apply_overrides on each
   script section before Kernel#eval so config-driven fixes
   (from the `patches` mkxp.json field) can ship as data. When
   no patches are loaded this is effectively `str.dup`. */
RB_METHOD(mkxpApplyOverrides) {
    VALUE arg;
    rb_scan_args(argc, argv, "01", &arg);

    if (NIL_P(arg) || !RB_TYPE_P(arg, T_STRING))
        return arg;

    std::string data(RSTRING_PTR(arg), RSTRING_LEN(arg));
    shState->patcher().apply(data);
    return rb_str_new(data.data(), (long)data.size());
}

/* System.rpg_version - integer RGSS version (1 = XP, 2 = VX, 3 = VX
   Ace, 0 = unknown). JoiPlay's postload.rb branches on this to
   decide whether VX-Ace-only compat patches apply; some fangames
   feature-detect via MKXP.rpg_version too. */
RB_METHOD(mkxpRpgVersion) {
    RB_UNUSED_PARAM;
    int v = shState->rtData().config.rgssVersion;
    if (v < 1 || v > 3) v = 0;
    return INT2NUM(v);
}

/* System.ruby_version - "MAJOR.MINOR" string of the embedded MRI. A
   handful of plugins branch on `MKXP.ruby_version.to_f < 2.0` to
   decide between 1.8 and 1.9+ syntax. */
RB_METHOD(mkxpRubyVersion) {
    RB_UNUSED_PARAM;
    std::string v = std::to_string(RUBY_API_VERSION_MAJOR) + "." +
                    std::to_string(RUBY_API_VERSION_MINOR);
    return rb_str_new_cstr(v.c_str());
}

/* System.syntax_transform_target -> [major, minor, teeny,
   ec_active_at_1_8]. UINT_MAX in any slot = disabled. The fourth
   element matches the same check String#[] uses internally. */
#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
RB_METHOD(mkxpSyntaxTransformTarget) {
    RB_UNUSED_PARAM;
    extern unsigned int mkxp_syntax_transform_target_ruby_version_major,
                        mkxp_syntax_transform_target_ruby_version_minor,
                        mkxp_syntax_transform_target_ruby_version_teeny;
    VALUE ary = rb_ary_new_capa(4);
    rb_ary_push(ary, UINT2NUM(mkxp_syntax_transform_target_ruby_version_major));
    rb_ary_push(ary, UINT2NUM(mkxp_syntax_transform_target_ruby_version_minor));
    rb_ary_push(ary, UINT2NUM(mkxp_syntax_transform_target_ruby_version_teeny));
    rb_ary_push(ary, mkxp_ec_is_syntax_transform_active(1, 8, (unsigned int)-1) ? Qtrue : Qfalse);
    return ary;
}
#else
RB_METHOD(mkxpSyntaxTransformTarget) {
    RB_UNUSED_PARAM;
    VALUE ary = rb_ary_new_capa(4);
    rb_ary_push(ary, Qnil);
    rb_ary_push(ary, Qnil);
    rb_ary_push(ary, Qnil);
    rb_ary_push(ary, Qfalse);
    return ary;
}
#endif

RB_METHOD(mkxpUserLanguage) {
    RB_UNUSED_PARAM;
    
    return mkxp_str_new_cstr(mkxp_sys::getSystemLanguage().c_str());
}

RB_METHOD(mkxpUserName) {
    RB_UNUSED_PARAM;
    
    return mkxp_str_new_cstr(mkxp_sys::getUserName().c_str());
}

RB_METHOD(mkxpGameTitle) {
    RB_UNUSED_PARAM;
    
    return mkxp_str_new_cstr(shState->config().game.title.c_str());
}

RB_METHOD(mkxpPowerState) {
    RB_UNUSED_PARAM;
    
    int secs, pct;
    SDL_PowerState ps = SDL_GetPowerInfo(&secs, &pct);
    
    VALUE hash = rb_hash_new();
    
    rb_hash_aset(hash, ID2SYM(rb_intern("seconds")),
                 (secs > -1) ? INT2NUM(secs) : RUBY_Qnil);
    
    rb_hash_aset(hash, ID2SYM(rb_intern("percent")),
                 (pct > -1) ? INT2NUM(pct) : RUBY_Qnil);
    
    rb_hash_aset(hash, ID2SYM(rb_intern("discharging")),
                 rb_bool_new(ps == SDL_POWERSTATE_ON_BATTERY));
    
    return hash;
}

RB_METHOD(mkxpSettingsMenu) {
    RB_UNUSED_PARAM;
    
    shState->eThread().requestSettingsMenu();
    
    return Qnil;
}

RB_METHOD(mkxpCpuCount) {
    RB_UNUSED_PARAM;
    
    return INT2NUM(SDL_GetCPUCount());
}

RB_METHOD(mkxpSystemMemory) {
    RB_UNUSED_PARAM;
    
    return INT2NUM(SDL_GetSystemRAM());
}

RB_METHOD_GUARD(mkxpReloadPathCache) {
    RB_UNUSED_PARAM;
    
    shState->fileSystem().reloadPathCache();
    return Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(mkxpAddPath) {
    RB_UNUSED_PARAM;
    
    VALUE path, mountpoint, reload;
    rb_scan_args(argc, argv, "12", &path, &mountpoint, &reload);
    SafeStringValue(path);
    if (mountpoint != Qnil) SafeStringValue(mountpoint);
    
    const char *mp = (mountpoint == Qnil) ? 0 : RSTRING_PTR(mountpoint);
    
    bool rl = true;
    if (reload != Qnil)
        rb_bool_arg(reload, &rl);
    
    shState->fileSystem().addPath(RSTRING_PTR(path), mp, rl);
    
    return path;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(mkxpRemovePath) {
    RB_UNUSED_PARAM;
    
    VALUE path, reload;
    rb_scan_args(argc, argv, "11", &path, &reload);
    SafeStringValue(path);
    
    bool rl = true;
    if (reload != Qnil)
        rb_bool_arg(reload, &rl);
    
    shState->fileSystem().removePath(RSTRING_PTR(path), rl);
    
    return path;
}
RB_METHOD_GUARD_END

RB_METHOD(mkxpFileExists) {
    RB_UNUSED_PARAM;
    
    VALUE path;
    rb_scan_args(argc, argv, "1", &path);
    SafeStringValue(path);
    
    if (shState->fileSystem().exists(RSTRING_PTR(path)))
        return Qtrue;
    return Qfalse;
}

RB_METHOD(mkxpSetDefaultFontFamily) {
    RB_UNUSED_PARAM;
    
    VALUE familyV;
    rb_scan_args(argc, argv, "1", &familyV);
    SafeStringValue(familyV);
    
    std::string family(RSTRING_PTR(familyV));
    shState->fontState().setDefaultFontFamily(family);
    
    return Qnil;
}

#if RAPI_FULL > 187
/*
 * C-level String#[] override for Ruby 1.8 compatibility.
 *
 * Ruby 1.8: str[integer] returned the byte value (Integer).
 * Ruby 3.x: str[integer] returns a one-character String.
 *
 * We MUST implement this at the C level (not Ruby) because String#[regexp]
 * sets $~ (Regexp.last_match) via rb_backref_set(), which only propagates
 * to the nearest RUBY frame on the call stack.  C (CFUNC) frames are
 * transparent to $~ propagation.  A Ruby-level wrapper would create a new
 * RUBY frame, trapping $~ inside the wrapper and making it invisible to
 * the caller; breaking patterns like:
 *     while text[/regexp/]
 *       $~.pre_match   # => nil:NilClass (NoMethodError) if wrapped in Ruby
 *
 * Syntax-transform gate: the integer-byte branch ONLY fires when the
 * syntax transform is targeting Ruby <= 1.8. Without this gate we'd
 * break Ruby-3 source that does `name[idx].match?(...)` and expects
 * a String (hit in Infinite Fusion's FusionSprites.rb:401 where
 * `sprite_name[spriteName.length]` expects a 1-char String). The
 * underlying `_mkxp_c_aref` alias points at the original `rb_str_aref_m`,
 * which has its own transform-aware patch - so for the ungated default
 * path we just delegate and let that patch do the right thing.
 */
RB_METHOD(mkxpStringAref) {
    RB_UNUSED_PARAM;

#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
    /* Ruby 1.8 byte-return semantics only when the transform targets
     * Ruby <= 1.8 AND the single argument is an Integer. We call the
     * saved `_mkxp_c_getbyte` alias (not `rb_str_getbyte` directly)
     * to tolerate games that rebind `getbyte` themselves (e.g. Pokemon
     * Z's "Map - Klein"). */
    if (mkxp_ec_is_syntax_transform_active(1, 8, (unsigned int)-1) &&
        argc == 1 && RB_INTEGER_TYPE_P(argv[0])) {
        return rb_funcall(self, rb_intern("_mkxp_c_getbyte"), 1, argv[0]);
    }
#endif

    /* Everything else (Regexp, Range, String, [i,len], AND integer
     * args when the transform is disabled) → delegate to the original
     * `rb_str_aref_m` via the `_mkxp_c_aref` alias so $~ propagates
     * and the upstream transform-gated patch handles any 1.8 fallback. */
    return rb_funcallv(self, rb_intern("_mkxp_c_aref"), argc, argv);
}

/* C-level String#[]= override for Ruby 1.8 byte-write compatibility.
 * Ruby 1.8: str[int] = int  set the byte at that index.
 * Ruby 3.x: str[int] = val  expects a String replacement.
 *
 * Asymmetry vs mkxpStringAref: the READ case (`str[i]`) is
 * ambiguous - 1.8 code expects Integer, modern Ruby 3 code expects
 * String, and the argument types are identical, so we have to gate
 * on the syntax-transform target. The WRITE case (`str[i] = X`) is
 * UNAMBIGUOUS: if `X` is Integer, the caller is unmistakably 1.8
 * code (Ruby 3 code only ever does `str[i] = SomeString`). We
 * therefore keep the byte-write branch unconditional when `argv[1]`
 * is Integer - this preserves the legacy idiom used by our own
 * preload scripts (`win32_wrap.rb:237: dst[i] = b` where `b` comes
 * from `each_byte`) regardless of the per-game transform setting.
 *
 * Engine preload iseqs compile with `mkxp_syntax_transform_flag = 0`
 * (no transform-aware parser hook), so an `ec_active(1,8)`-style
 * gate would have returned FALSE inside our preloads on a modern-
 * Ruby game and failed the byte-write with `TypeError: no implicit
 * conversion of Integer into String` - the regression that hit
 * Insurgence / Z / Uranium after the matched gate was applied to
 * both aref and aset.
 */
RB_METHOD(mkxpStringAset) {
    RB_UNUSED_PARAM;

    /* str[int] = int → set byte (Ruby 1.8 semantics). Always.
     * Modern Ruby 3 code never reaches this branch because it
     * passes a String as the value. */
    if (argc == 2 && RB_INTEGER_TYPE_P(argv[0]) && RB_INTEGER_TYPE_P(argv[1])) {
        unsigned char byte = (unsigned char)(NUM2INT(argv[1]) & 0xFF);
        VALUE replacement = rb_str_new((const char *)&byte, 1);
        VALUE args[2] = { argv[0], replacement };
        return rb_funcallv(self, rb_intern("_mkxp_c_aset"), 2, args);
    }

    /* Everything else → original */
    return rb_funcallv(self, rb_intern("_mkxp_c_aset"), argc, argv);
}
#endif /* RAPI_FULL > 187 - String#[] overrides */

RB_METHOD_GUARD(mkxpStringToUTF8) {
    RB_UNUSED_PARAM;
    
    rb_check_argc(argc, 0);
    
    std::string ret(RSTRING_PTR(self), RSTRING_LEN(self));
    ret = Encoding::convertString(ret);
    
    return mkxp_str_new(ret.c_str(), ret.length());
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(mkxpStringToUTF8Bang) {
    RB_UNUSED_PARAM;
    
    rb_check_argc(argc, 0);
    
    std::string ret(RSTRING_PTR(self), RSTRING_LEN(self));
    ret = Encoding::convertString(ret);
    
    rb_str_resize(self, ret.length());
    memcpy(RSTRING_PTR(self), ret.c_str(), RSTRING_LEN(self));
    
#if RAPI_FULL >= 190
    rb_enc_set_index(self, rb_utf8_encindex());
#endif
    
    return self;
}
RB_METHOD_GUARD_END

#ifdef __APPLE__
#define OPENCMD "open "
#define OPENARGS "--args"
#elif defined(__linux__)
#define OPENCMD "xdg-open "
#define OPENARGS ""
#else
#define OPENCMD "start /b \"launch\" "
#define OPENARGS ""
#endif

RB_METHOD_GUARD(mkxpLaunch) {
    RB_UNUSED_PARAM;
    
    VALUE cmdname, args;
    
    rb_scan_args(argc, argv, "11", &cmdname, &args);
    SafeStringValue(cmdname);
    
    std::string command(OPENCMD);
    command += "\""; command += RSTRING_PTR(cmdname); command += "\"";
    
    if (args != RUBY_Qnil) {
#ifndef __linux__
        command += " ";
        command += OPENARGS;
        Check_Type(args, T_ARRAY);
        
        for (int i = 0; i < RARRAY_LEN(args); i++) {
            VALUE arg = rb_ary_entry(args, i);
            SafeStringValue(arg);
            
            if (RSTRING_LEN(arg) <= 0)
                continue;
            
            command += " ";
            command += RSTRING_PTR(arg);
        }
#else
        Debug() << command << ":" << "Arguments are not supported with xdg-open. Ignoring.";
#endif
    }
    
    // system() is unavailable on iOS
    throw Exception(Exception::MKXPError, "system() not available on iOS for \"%s\"", RSTRING_PTR(cmdname));
    
    return RUBY_Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(mkxpParseCSV) {
    RB_UNUSED_PARAM;
    
    VALUE str;
    rb_scan_args(argc, argv, "1", &str);
    SafeStringValue(str);
    
    VALUE ret = rb_ary_new();
    std::stringstream stream(RSTRING_PTR(str));
    try {
        rapidcsv::Document doc(stream, rapidcsv::LabelParams(-1,-1), rapidcsv::SeparatorParams(',', false, true, true, true));
        for (int r = 0; r < doc.GetRowCount(); r++) {
            VALUE col = rb_ary_new();
            for (int c = 0; c < doc.GetColumnCount(); c++) {
                std::string str = doc.GetCell<std::string>(c, r);
                rb_ary_push(col, mkxp_str_new(str.c_str(), str.length()));
            }
            rb_ary_push(ret, col);
        }
    } catch (std::exception &e) {
        throw Exception(Exception::MKXPError, "Failed to parse CSV: %s", e.what());
    }

    return ret;
}
RB_METHOD_GUARD_END

json5pp::value loadUserSettings() {
    json5pp::value ret;
    VALUE cpath = mkxp_str_new_cstr(shState->config().userConfPath.c_str());
    
    if (rb_funcall(rb_cFile, rb_intern("exists?"), 1, cpath) == Qtrue) {
        VALUE f = rb_funcall(rb_cFile, rb_intern("open"), 2, cpath, rb_str_new("r", 1));
        VALUE data = rb_funcall(f, rb_intern("read"), 0);
        rb_funcall(f, rb_intern("close"), 0);
        ret = json5pp::parse5(RSTRING_PTR(data));
    }
    
    if (!ret.is_object())
        ret = json5pp::object({});
    
    return ret;
}

void saveUserSettings(json5pp::value &settings) {
    VALUE cpath = mkxp_str_new_cstr(shState->config().userConfPath.c_str());
    VALUE f = rb_funcall(rb_cFile, rb_intern("open"), 2, cpath, rb_str_new("w", 1));
    rb_funcall(f, rb_intern("write"), 1, mkxp_str_new_cstr(settings.stringify5(json5pp::rule::space_indent<>()).c_str()));
    rb_funcall(f, rb_intern("close"), 0);
}

RB_METHOD(mkxpGetJSONSetting) {
    RB_UNUSED_PARAM;
    
    VALUE sname;
    rb_scan_args(argc, argv, "1", &sname);
    SafeStringValue(sname);
    
    auto settings = loadUserSettings();
    auto &s = settings.as_object();
    
    if (s[RSTRING_PTR(sname)].is_null()) {
        return json2rb(shState->config().raw.as_object()[RSTRING_PTR(sname)]);
    }
    
    return json2rb(s[RSTRING_PTR(sname)]);
    
}

RB_METHOD_GUARD(mkxpSetJSONSetting) {
    RB_UNUSED_PARAM;
    
    VALUE sname, svalue;
    rb_scan_args(argc, argv, "2", &sname, &svalue);
    SafeStringValue(sname);
    
    auto settings = loadUserSettings();
    auto &s = settings.as_object();
    s[RSTRING_PTR(sname)] = rb2json(svalue);
    saveUserSettings(settings);
    
    return Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD(mkxpGetAllJSONSettings) {
    RB_UNUSED_PARAM;
    
    return json2rb(shState->config().raw);
}

static VALUE rgssMainCb(VALUE block) {
    rb_funcall2(block, rb_intern("call"), 0, 0);
    return Qnil;
}

static VALUE rgssMainRescue(VALUE arg, VALUE exc) {
    VALUE *excRet = (VALUE *)arg;
    
    *excRet = exc;
    
    return Qnil;
}

static bool processReset(bool rubyExc) {
	const char *str = "Audio.__reset__; Graphics.__reset__;";
	
	if (rubyExc) {
		rb_eval_string(str);
	} else {
		int state;
		rb_eval_string_protect(str, &state);
		return state;
	}
	
	return 0;
}

struct evalArg {
    VALUE string;
    VALUE filename;
};

static VALUE evalHelper(evalArg *arg) {
    VALUE argv[] = {arg->string, Qnil, arg->filename};
    return rb_funcall2(topSelf, rb_intern("eval"), ARRAY_SIZE(argv), argv);
}

static VALUE evalString(VALUE string, VALUE filename, int *state) {
    mkxp::ScriptBootstrap::evalRubyString((void *)string, (void *)filename, state);
    return Qnil;
}

static void runCustomScript(const std::string &filename) {
    std::string scriptData;
    
    if (!readFileSDL(filename.c_str(), scriptData)) {
        showMsg(std::string("Unable to open '") + filename + "'");
        return;
    }
    
    evalString(mkxp_str_new(scriptData.c_str(), scriptData.size()),
               mkxp_str_new(filename.c_str(), filename.size()), NULL);
}

RB_METHOD_GUARD(mriRgssMain) {
    RB_UNUSED_PARAM;

    /* Execute postload scripts */
    const Config &conf = shState->rtData().config;
    for (std::vector<std::string>::const_iterator i = conf.postloadScripts.begin();
        i != conf.postloadScripts.end(); ++i)
    {
        if (shState->rtData().rqTerm)
            break;
        runCustomScript(*i);
    }

    while (true) {
        VALUE exc = Qnil;
#if RAPI_FULL < 270
        rb_rescue2((VALUE(*)(ANYARGS))rgssMainCb, rb_block_proc(),
                   (VALUE(*)(ANYARGS))rgssMainRescue, (VALUE)&exc, rb_eException,
                   (VALUE)0);
#else
        rb_rescue2(rgssMainCb, rb_block_proc(), rgssMainRescue, (VALUE)&exc,
                   rb_eException, (VALUE)0);
#endif
        
        if (NIL_P(exc))
            break;
        
        if (rb_obj_class(exc) == getRbData()->exc[Reset])
            processReset(true);
        else
            rb_exc_raise(exc);
    }
    
    return Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(mriRgssStop) {
    RB_UNUSED_PARAM;
    
    while (true)
        shState->graphics().update();
    
    return Qnil;
}
RB_METHOD_GUARD_END

RB_METHOD(_kernelCaller) {
    RB_UNUSED_PARAM;
    
    VALUE trace =
    rb_funcall2(rb_mKernel, rb_intern("_mkxp_kernel_caller_alias"), 0, 0);
    
    if (!RB_TYPE_P(trace, RUBY_T_ARRAY))
        return trace;
    
    long len = RARRAY_LEN(trace);
    
    if (len < 2)
        return trace;
    
    /* Remove useless "ruby:1:in 'eval'" */
    rb_ary_pop(trace);
    
    /* Also remove trace of this helper function */
    rb_ary_shift(trace);
    
    len -= 2;
    
    if (len == 0)
        return trace;
    
    /* RMXP does this, not sure if specific or 1.8 related */
    VALUE args[] = {mkxp_str_new_cstr(":in `<main>'"), mkxp_str_new_cstr("")};
    rb_funcall2(rb_ary_entry(trace, len - 1), rb_intern("gsub!"), 2, args);
    
    return trace;
}

VALUE kernelLoadDataInt(const char *filename, bool rubyExc, bool raw);

struct BacktraceData {
    /* Maps: Ruby visible filename, To: Actual script name */
    BoostHash<std::string, std::string> scriptNames;
};

bool evalScript(VALUE string, const char *filename)
{
    int state;
    evalString(string, mkxp_str_new_cstr(filename), &state);
    if (state) return false;
    return true;
}


#define SCRIPT_SECTION_FMT (rgssVer >= 3 ? "{%04ld}" : "Section%03ld")

// Declared in app_bridge.cpp - returns the debug log path set by the UI,
// or empty string if debug logging is disabled.
std::string mkxp_getDebugLogPath(void);
extern "C" void mkxp_debugLog(const char *tag, const char *source, const char *message);

static void logRubyError(const char *type, const char *detail) {
    mkxp_debugLog(type, "binding-mri.cpp [C++]", detail);
}

/* Counts script sections that ran to completion without error during
 * the current session. Reset at the top of runRMXPScripts and read
 * by mriBindingExecute to decide whether a no-pending-exception
 * shutdown should be classified as a clean exit. A session where
 * every script was skipped (e.g. all required missing native libs)
 * leaves this at 0 and the UI shows the recovery alert instead of
 * the "game has ended" message. */
static int s_scriptsExecutedThisSession = 0;

static void runRMXPScripts(BacktraceData &btData) {
    const Config &conf = shState->rtData().config;
    const std::string &scriptPack = conf.game.scripts;

    s_scriptsExecutedThisSession = 0;

    if (scriptPack.empty()) {
        showMsg("No script file has been specified. Check the game's INI and try again.");
        return;
    }
    
    if (!shState->fileSystem().exists(scriptPack.c_str())) {
        showMsg("Unable to load scripts from '" + scriptPack + "'");
        return;
    }
    
    VALUE scriptArray;
    
    /* We checked if Scripts.rxdata exists, but something might
     * still go wrong */
    try {
        scriptArray = kernelLoadDataInt(scriptPack.c_str(), false, false);
    } catch (const Exception &e) {
        showMsg(std::string("Failed to read script data: ") + e.msg);
        return;
    }
    
    if (!RB_TYPE_P(scriptArray, RUBY_T_ARRAY)) {
        showMsg("Failed to read script data");
        return;
    }
    
    rb_gv_set("$RGSS_SCRIPTS", scriptArray);
    
    long scriptCount = RARRAY_LEN(scriptArray);
    
    std::string decodeBuffer;
    decodeBuffer.resize(0x1000);
    
    for (long i = 0; i < scriptCount; ++i) {
        VALUE script = rb_ary_entry(scriptArray, i);
        
        if (!RB_TYPE_P(script, RUBY_T_ARRAY))
            continue;
        
        VALUE scriptName = rb_ary_entry(script, 1);
        VALUE scriptString = rb_ary_entry(script, 2);
        
        int result = Z_OK;
        unsigned long bufferLen;
        
        while (true) {
            unsigned char *bufferPtr = reinterpret_cast<unsigned char *>(
                                                                         const_cast<char *>(decodeBuffer.c_str()));
            const unsigned char *sourcePtr =
            reinterpret_cast<const unsigned char *>(RSTRING_PTR(scriptString));
            
            bufferLen = decodeBuffer.length();
            
            result = uncompress(bufferPtr, &bufferLen, sourcePtr,
                                RSTRING_LEN(scriptString));
            
            bufferPtr[bufferLen] = '\0';
            
            if (result != Z_BUF_ERROR)
                break;
            
            decodeBuffer.resize(decodeBuffer.size() * 2);
        }
        
        if (result != Z_OK) {
            static char buffer[256];
            snprintf(buffer, sizeof(buffer), "Error decoding script %ld: '%s'", i,
                     RSTRING_PTR(scriptName));
            
            showMsg(buffer);
            
            break;
        }
        
        /* Most modern Pokemon Essentials forks ship valid UTF-8
         * script sources and expect ordinary string literals to stay
         * UTF-8 at runtime. Only force binary parsing for the small
         * subset of legacy scripts that actually contains byte-range
         * regex escapes like `\x7f-\x9f`, which Ruby 3.1 otherwise
         * rejects with "invalid multibyte escape". Blanket-tagging
         * every script as ASCII-8BIT fixes those regexes but turns
         * normal text literals (item names, UI strings) binary too,
         * which later explodes in `_INTL`, battle text, debug logs,
         * etc. */
        {
            const char *src = decodeBuffer.c_str();
            size_t srcLen = bufferLen;
            bool hasEncoding = false;
            bool needsBinaryEncoding = false;
            if (srcLen >= 11 && (strncmp(src, "# encoding:", 11) == 0 ||
                                  strncmp(src, "#encoding:", 10) == 0 ||
                                  strncmp(src, "# coding:", 9) == 0 ||
                                  strncmp(src, "#coding:", 8) == 0)) {
                hasEncoding = true;
            }
            if (!hasEncoding) {
                static const char *binaryRegexMarkers[] = {
                    "\\x7f-\\x9f",
                    "\\x7F-\\x9F",
                    "\\x80-\\x9f",
                    "\\x80-\\x9F",
                    "\\x80-\\xFF",
                    "\\x81-\\x9f",
                    "\\x81-\\x9F",
                    nullptr
                };
                for (const char **marker = binaryRegexMarkers; *marker; ++marker) {
                    if (strstr(src, *marker) != nullptr) {
                        needsBinaryEncoding = true;
                        break;
                    }
                }
            }
            if (!hasEncoding && needsBinaryEncoding) {
                std::string prefixed = "# encoding: ASCII-8BIT\n";
                prefixed.append(src, srcLen);
                rb_ary_store(script, 3, mkxp_str_new(prefixed.c_str(), prefixed.size()));
            } else {
                rb_ary_store(script, 3, mkxp_str_new(src, srcLen));
            }
        }
    }
    
    
    mkxp::ScriptBootstrap::loadEnginePreloads();
    mkxp::ScriptBootstrap::loadConfigPreloadScripts(conf);
    
    VALUE exc = rb_gv_get("$!");
    if (exc != Qnil)
        return;
    
    while (true) {
        for (long i = 0; i < scriptCount; ++i) {
            if (shState->rtData().rqTerm)
                break;
            
            if (i == scriptCount - 1) {
                mkxp::ScriptBootstrap::loadEnginePostloadsBeforeMain();
                mkxp::ScriptBootstrap::loadCheatPostloadAndPoller();
            }
            
            VALUE script = rb_ary_entry(scriptArray, i);
            VALUE scriptDecoded = rb_ary_entry(script, 3);
            // Apply JoiPlay-style script text patches from
            // config.scriptPatches before handing text to the
            // Ruby VM. The patcher is a no-op when the patch
            // list is empty, so the hot path cost is one
            // std::string copy per script section.
            std::string rawScript(RSTRING_PTR(scriptDecoded),
                                  RSTRING_LEN(scriptDecoded));
            shState->patcher().apply(rawScript);
            VALUE string = mkxp_str_new(rawScript.data(), rawScript.size());
            
            VALUE fname;
            const char *scriptName = RSTRING_PTR(rb_ary_entry(script, 1));
            char buf[512];
            int len;
            
            if (conf.useScriptNames)
                len = snprintf(buf, sizeof(buf), "%03ld:%s", i, scriptName);
            else
                len = snprintf(buf, sizeof(buf), SCRIPT_SECTION_FMT, i);
            
            fname = mkxp_str_new(buf, len);
            btData.scriptNames.insert(buf, scriptName);
            
            
            // Per-platform script gating (|W|/|M|/|L| name prefix,
            // |!W| for negation) is unimplemented; the original block
            // sat here commented out and was removed.

            int state;
            bool wasSkipped = false;

            // Per-script trace. Useful when a game hangs inside a script:
            // the last TRACE line points at the culprit.
            {
                char trace[600];
                snprintf(trace, sizeof(trace), "enter %03ld %s", i,
                         scriptName[0] ? scriptName : "(unnamed)");
                mkxp_debugLog("TRACE", "binding-mri.cpp [C++]", trace);
            }

            {
#ifdef MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
                extern __thread int mkxp_syntax_transform_next_eval;
                struct SyntaxTransformGuard {
                    SyntaxTransformGuard() {
                        mkxp_syntax_transform_next_eval = 1;
                    }
                    ~SyntaxTransformGuard() {
                        mkxp_syntax_transform_next_eval = 0;
                    }
                };
                SyntaxTransformGuard guard;
#endif // MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
                evalString(string, fname, &state);
            }

            /* On iOS, native DLL/library loading (LoadError) and missing
             * native methods (NoMethodError from DLL-provided extensions)
             * are expected to fail. Many game scripts have optional native
             * extensions (e.g. RGSS Linker, F-mod, screenshot DLLs).
             * Skip these errors and continue to the next script section -
             * the game typically has fallback code paths. */
            if (state) {
                VALUE exc = rb_gv_get("$!");
                if (exc != Qnil) {
                bool shouldSkip = false;
                if (rb_obj_is_kind_of(exc, rb_eLoadError) ||
                    rb_obj_is_kind_of(exc, rb_eSyntaxError)) {
                    shouldSkip = true;
                } else if (rb_obj_is_kind_of(exc, rb_eNoMethodError)) {
                    /* Only skip NoMethodError from missing DLL/native methods.
                     * These are on Module/Class receivers (e.g. Kernel:Module).
                     * Game logic errors (nil:NilClass, false:FalseClass, or
                     * any object instance) must NOT be skipped. */
                    VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
                    const char *msgStr = StringValueCStr(msg);
                    shouldSkip = strstr(msgStr, ":Module") ||
                                 strstr(msgStr, ":Class");
                } else if (rb_obj_is_kind_of(exc, rb_eTypeError)) {
                    /* Skip "superclass mismatch for class X" errors.
                     * Common in community PE plugins that redefine a
                     * Window_* class against a different parent than
                     * the running PE version uses. The original
                     * hierarchy survives, so the game's stock UI still
                     * works; only the plugin's bonus features get
                     * dropped. Other TypeErrors (real bugs) stay fatal. */
                    VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
                    const char *msgStr = StringValueCStr(msg);
                    shouldSkip = strstr(msgStr, "superclass mismatch") != NULL;
                }
                if (shouldSkip) {
                    VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
                    Debug() << "Skipping" << rb_class2name(rb_obj_class(exc))
                            << "in script" << scriptName
                            << ":" << StringValueCStr(msg);
                    {
                        char buf[512];
                        snprintf(buf, sizeof(buf), "Script '%s': %s - %s",
                                 scriptName, rb_class2name(rb_obj_class(exc)),
                                 StringValueCStr(msg));
                        logRubyError("SKIPPED", buf);
                    }
                    rb_set_errinfo(Qnil);
                    state = 0;
                    wasSkipped = true;
                }
                }
            }
            if (state)
                break;

            if (!wasSkipped)
                s_scriptsExecutedThisSession++;

            {
                char trace[600];
                snprintf(trace, sizeof(trace), "exit  %03ld %s", i,
                         scriptName[0] ? scriptName : "(unnamed)");
                mkxp_debugLog("TRACE", "binding-mri.cpp [C++]", trace);
            }
        }
        
        VALUE exc = rb_gv_get("$!");
        if (rb_obj_class(exc) != getRbData()->exc[Reset])
            break;
        
        if (processReset(false))
            break;
    }
}

// Best-effort human-readable detail for a Ruby exception. Pokemon
// Essentials' EventScriptError stores its formatted script error in
// @event_message and passes nil to Exception#initialize, so .message
// is always empty even though the real text exists.
static VALUE exceptionDetailMessage(VALUE exc) {
    VALUE em = rb_iv_get(exc, "@event_message");
    if (!NIL_P(em) && RB_TYPE_P(em, T_STRING) && RSTRING_LEN(em) > 0)
        return em;

    if (rb_respond_to(exc, rb_intern("event_message"))) {
        em = rb_funcall(exc, rb_intern("event_message"), 0);
        if (!NIL_P(em) && RB_TYPE_P(em, T_STRING) && RSTRING_LEN(em) > 0)
            return em;
    }

    {
        int state = 0;
        rb_gv_set("$__mkxp_exc", exc);
        VALUE detail = rb_eval_string_protect(
            "begin; defined?(pbGetExceptionMessage) ? pbGetExceptionMessage($__mkxp_exc) : nil; "
            "ensure; $__mkxp_exc = nil; end",
            &state);
        if (!state && !NIL_P(detail) && RB_TYPE_P(detail, T_STRING) &&
            RSTRING_LEN(detail) > 0)
            return detail;
        if (state)
            rb_set_errinfo(Qnil);
    }

    if (rb_respond_to(exc, rb_intern("full_message"))) {
        VALUE fm = rb_funcall(exc, rb_intern("full_message"), 1, Qtrue);
        if (!NIL_P(fm) && RB_TYPE_P(fm, T_STRING) && RSTRING_LEN(fm) > 0)
            return fm;
    }

    VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
    if (!NIL_P(msg) && RB_TYPE_P(msg, T_STRING) && RSTRING_LEN(msg) > 0)
        return msg;
    return rb_funcall(exc, rb_intern("to_s"), 0);
}

static void showExc(VALUE exc, const BacktraceData &btData) {
    VALUE bt = rb_funcall2(exc, rb_intern("backtrace"), 0, NULL);
    VALUE msg = exceptionDetailMessage(exc);
    VALUE bt0 = rb_ary_entry(bt, 0);
    VALUE name = rb_class_path(rb_obj_class(exc));
    
    VALUE ds = rb_sprintf("%" PRIsVALUE ": %" PRIsVALUE " (%" PRIsVALUE ")",
#if RAPI_MAJOR >= 2
                          bt0, exc, name);
#else
    // Ruby 1.9's version of this function needs char*
    RSTRING_PTR(bt0), RSTRING_PTR(exc), RSTRING_PTR(name));
#endif
    /* omit "useless" last entry (from ruby:1:in `eval') */
    for (long i = 1, btlen = RARRAY_LEN(bt) - 1; i < btlen; ++i)
        rb_str_catf(ds, "\n\tfrom %" PRIsVALUE,
#if RAPI_MAJOR >= 2
                    rb_ary_entry(bt, i));
#else
    RSTRING_PTR(rb_ary_entry(bt, i)));
#endif
    Debug() << StringValueCStr(ds);
    // Also send the full backtrace to the per-game debug log so we can
    // inspect it post-crash without attaching a debugger.
    mkxp_debugLog("BACKTRACE", "binding-mri.cpp [C++]", StringValueCStr(ds));

    char *s = RSTRING_PTR(bt0);
    
    char line[16];
    std::string file(512, '\0');
    
    char *p = s + strlen(s);
    char *e;
    
    while (p != s)
        if (*--p == ':')
            break;
    
    e = p;
    
    while (p != s)
        if (*--p == ':')
            break;
    
    /* s         p  e
     * SectionXXX:YY: in 'blabla' */
    
    *e = '\0';
    strncpy(line, *p ? p + 1 : p, sizeof(line));
    line[sizeof(line) - 1] = '\0';
    *e = ':';
    e = p;
    
    /* s         e
     * SectionXXX:YY: in 'blabla' */
    
    *e = '\0';
    strncpy(&file[0], s, file.size());
    *e = ':';
    
    /* Shrink to fit */
    file.resize(strlen(file.c_str()));
    file = btData.scriptNames.value(file, file);
    
    const char *msgStr = StringValueCStr(msg);
    const char *nameStr = StringValueCStr(name);
    std::string ms = std::string("Script '") + file + "' line " + line + ": " +
                     nameStr + " occurred.\n\n" + (msgStr ? msgStr : "");
    
    logRubyError("FATAL", ms.c_str());
    showMsg(ms);
}


/* Single-shot game session: ruby_init + script execute + return.
 *
 * Called once per app process by `getActiveScriptBinding()->execute()`
 * in main.cpp's rgssThreadFun. Once this returns, the engine is dead
 * for the remainder of the process — App Store guideline 2.5.1 stops
 * us from terminating ourselves, so the user has to close + reopen
 * Empo to play another game. Ruby's VM has process-global state
 * (signal handlers, atexit, parser, symbol table) that doesn't
 * unwind cleanly via ruby_cleanup, and a second ruby_init in the
 * same process would crash anyway. */
static void mriBindingExecute() {
    Config &conf = shState->rtData().config;

#if RAPI_MAJOR >= 2
    /* Normally only a ruby executable would do a sysinit,
     * but not doing it will lead to crashes due to closed
     * stdio streams on some platforms (eg. Windows) */
    {
    int argc = 0;
    char **argv = 0;
    ruby_sysinit(&argc, &argv);
    }

    RUBY_INIT_STACK;
    ruby_init();
    
    std::vector<const char*> rubyArgsC{"mkxp-z"};
#if RAPI_FULL >= 190
    rubyArgsC.push_back(mkxpUsingRuby18Encoding() ? "-EASCII-8BIT" : "-EUTF-8");
#endif // RAPI_FULL >= 190
    rubyArgsC.push_back("-e ");
    void *node;
    if (conf.jit.enabled) {
#if RAPI_FULL >= 310
        // Ruby v3.1.0 renamed the --jit options to --mjit.
        std::string verboseLevel("--mjit-verbose=");
        std::string maxCache("--mjit-max-cache=");
        std::string minCalls("--mjit-min-calls=");
        rubyArgsC.push_back("--mjit");
#else
        std::string verboseLevel("--jit-verbose=");
        std::string maxCache("--jit-max-cache=");
        std::string minCalls("--jit-min-calls=");
        rubyArgsC.push_back("--jit");
#endif
        verboseLevel += std::to_string(conf.jit.verboseLevel);
        maxCache += std::to_string(conf.jit.maxCache);
        minCalls += std::to_string(conf.jit.minCalls);

        rubyArgsC.push_back(verboseLevel.c_str());
        rubyArgsC.push_back(maxCache.c_str());
        rubyArgsC.push_back(minCalls.c_str());
        node = ruby_options(rubyArgsC.size(), const_cast<char**>(rubyArgsC.data()));
    } else if (conf.yjit.enabled) {
        rubyArgsC.push_back("--yjit");
        // TODO: Maybe support --yjit-exec-mem-size, --yjit-call-threshold
        node = ruby_options(rubyArgsC.size(), const_cast<char**>(rubyArgsC.data()));
    } else {
        node = ruby_options(rubyArgsC.size(), const_cast<char**>(rubyArgsC.data()));
    }
    
    int state;
    bool valid = ruby_executable_node(node, &state);
    if (valid)
        state = ruby_exec_node(node);
    if (state || !valid) {
        // The message is formatted for and automatically spits
        // out to the terminal, so let's leave it that way for now
        /*
         VALUE exc = rb_errinfo();
         #if RAPI_FULL >= 250
         VALUE msg = rb_funcall(exc, rb_intern("full_message"), 0);
         #else
         VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
         #endif
         */
        showMsg("An error occurred while initializing Ruby. (Invalid JIT settings?)");
        ruby_cleanup(state);
        shState->rtData().rqTermAck.set();
        return;
    }
#else
    ruby_init();
#endif

    /* Ruby 1.8 / 1.9: explicitly initialize statically-linked
     * extensions. Must run after ruby_init() (so Ruby's globals
     * exist) but before any game script runs. See declaration
     * above for full rationale.
     *
     * Ruby 3.0+ initializes extensions automatically via its
     * setup path; this block is no-op-compiled out there. */
#if RAPI_FULL < 200
    Init_ext();
#endif

    // Set the default encoding for regular expressions to UTF-8 when using syntax transform targeting Ruby <= 1.8
    rb_gv_set("$KCODE", rb_str_new_cstr("UTF8"));
    rb_gv_set("$-K", rb_str_new_cstr("UTF8"));

    topSelf = rgssVer == 1 ? Qnil : rb_eval_string("self");
    rb_gc_register_address(&topSelf);
    mkxp::ScriptBootstrap::setEvalReceiver((void *)topSelf);

    /* RbData must be live before mriBindingInit: inputBindingInit on
     * RGSS3 writes getRbData()->buttoncodeHash. */
    RbData rbData;
    shState->setBindingData(&rbData);
    BacktraceData btData;

    mriBindingInit();

#if RAPI_FULL > 187
    VALUE rbArgv = rb_get_argv();
#else
    VALUE rbArgv = rb_argv;
#endif
    for (const auto &str : conf.launchArgs)
        rb_ary_push(rbArgv, mkxp_str_new_cstr(str.c_str()));
    
    // Duplicates get pushed for some reason
    rb_funcall(rbArgv, rb_intern("uniq!"), 0);
    
    VALUE lpaths = rb_gv_get(":");
    rb_ary_clear(lpaths);
    
#if defined(MKXPZ_BUILD_XCODE) && RAPI_MAJOR >= 2
    std::string resPath = mkxp_fs::getResourcePath();
    resPath += "/Ruby/" + std::to_string(RAPI_MAJOR) + "." + std::to_string(RAPI_MINOR) + ".0";
    rb_ary_push(lpaths, rb_str_new(resPath.c_str(), resPath.size()));
#endif
    
    if (!conf.rubyLoadpaths.empty()) {
        /* Setup custom load paths */
        for (size_t i = 0; i < conf.rubyLoadpaths.size(); ++i) {
            std::string &path = conf.rubyLoadpaths[i];
            
            VALUE pathv = mkxp_str_new(path.c_str(), path.size());
            rb_ary_push(lpaths, pathv);
        }
    }
    else {
        rb_ary_push(lpaths, mkxp_str_new_cstr(mkxp_fs::getCurrentDirectory().c_str()));
    }
    
    std::string &customScript = conf.customScript;
    if (!customScript.empty()) {
        runCustomScript(customScript);
    } else {
        runRMXPScripts(btData);
    }
    
#if RAPI_FULL > 187
    VALUE exc = rb_errinfo();
#else
    VALUE exc = rb_gv_get("$!");
#endif
    if (!NIL_P(exc) && !rb_obj_is_kind_of(exc, rb_eSystemExit))
        showExc(exc, btData);

    /* Flag the session as a clean exit whenever control reaches
     * here without a pending exception, or with a SystemExit - both
     * mean Ruby scripts finished normally (including the game's
     * own "Exit to desktop" menu calling Kernel.exit). Only real
     * crashes short-circuit past this path, so the default clean=
     * false state from mkxp_setGamePath stays false in those cases
     * and the UI shows the recovery alert.
     *
     * Additional gate: at least one script section must have
     * executed without being skipped. If every script bailed via
     * the LoadError/SyntaxError/NoMethodError tolerance path
     * (e.g. a game whose Main does nothing but `require 'socket'`),
     * the user never got a running game and shouldn't see the
     * "game has ended or requested a restart" message - that text
     * only makes sense for sessions where the game actually ran. */
    if ((NIL_P(exc) || rb_obj_is_kind_of(exc, rb_eSystemExit)) &&
        s_scriptsExecutedThisSession > 0) {
        mkxp_setEngineExitedCleanly();
    }

    /* No ruby_cleanup: Ruby's VM has process-global state (signal
     * handlers, atexit, parser, symbol table) that doesn't unwind
     * cleanly. The whole process exits when the user closes Empo
     * from the app switcher, which is what does the actual cleanup. */

    shState->rtData().rqTermAck.set();
}

static void mriBindingTerminate() { throw Exception(Exception::SystemExit, " "); }

static void mriBindingReset() { throw Exception(Exception::Reset, " "); }
