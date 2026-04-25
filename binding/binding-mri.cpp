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

extern "C" {
#include <ruby.h>

#if RAPI_FULL >= 190
#include <ruby/encoding.h>
#endif

/* Ruby 1.8 statically-linked extension init functions */
#if RAPI_FULL <= 187
void Init_zlib(void);
void Init_stringio(void);
void Init_strscan(void);
void Init_thread(void);
void Init_digest(void);
void Init_fcntl(void);

/* Ruby 1.8 GC stack base — defined in gc.c.
 * Must be updated when the RGSS thread changes between sessions,
 * otherwise GC's mark_locations_array scans the old thread's
 * (now-unmapped) stack and crashes with SIGSEGV. */
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
static void mriBindingExecuteInitOnce(Config &conf);
static void mriBindingExecutePerSession(Config &conf);
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

/* Idempotent wrapper around rb_define_alias for iOS, where mriBindingInit
 * runs once per game session in a persistent Ruby VM. On the second and
 * later sessions, the original implementation has already been replaced by
 * our own wrapper (from session 1). Re-aliasing would capture our wrapper
 * as the "original", producing infinite recursion when the wrapper calls
 * the alias. Skip the alias if it's already defined. */
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
        _rb_define_module_function(rb_mKernel, "print", mriPrint);
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
    rb_define_method(rb_cString, "[]",  mkxpStringAref, -1);
    rb_define_method(rb_cString, "[]=", mkxpStringAset, -1);
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
 * continue to load without raising NoMethodError; they simply take
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

/* System.syntax_transform_target - `[major, minor, teeny,
   ec_active_at_1_8]` diagnostic. Exposes the raw values of the
   three `mkxp_syntax_transform_target_ruby_version_*` globals
   (UINT_MAX meaning "disabled") so Ruby-side probes can verify
   whether the transform is actually reaching the runtime - we
   hit a case with Infinite Fusion where `syntaxTransform: 0` in
   mkxp.json appeared to set the target to disabled, yet
   String#[] was still returning Integer-per-Ruby-1.8 semantics.
   The fourth array element is what `mkxp_ec_is_syntax_transform_active(1, 8, -1)`
   returns from the current frame - the same check the `String#[]`
   patch uses to decide whether to swap in Ruby 1.8 behaviour. */
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
 * the caller — breaking patterns like:
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
    evalArg arg = {string, filename};
    return rb_protect((VALUE(*)(VALUE))evalHelper, (VALUE)&arg, state);
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

static void runRMXPScripts(BacktraceData &btData) {
    const Config &conf = shState->rtData().config;
    const std::string &scriptPack = conf.game.scripts;

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
        
        /* Prepend a magic encoding comment so the Ruby 3.1 parser
         * treats source as raw bytes rather than UTF-8. Without this,
         * regex literals with \x7f-\x9f byte ranges (common in older
         * Pokemon Essentials utility scripts) fail to parse with
         * "invalid multibyte escape". Only add it if not already
         * present at the top of the script. */
        {
            const char *src = decodeBuffer.c_str();
            size_t srcLen = bufferLen;
            bool hasEncoding = false;
            if (srcLen >= 11 && (strncmp(src, "# encoding:", 11) == 0 ||
                                  strncmp(src, "#encoding:", 10) == 0 ||
                                  strncmp(src, "# coding:", 9) == 0 ||
                                  strncmp(src, "#coding:", 8) == 0)) {
                hasEncoding = true;
            }
            if (!hasEncoding) {
                std::string prefixed = "# encoding: ASCII-8BIT\n";
                prefixed.append(src, srcLen);
                rb_ary_store(script, 3, mkxp_str_new(prefixed.c_str(), prefixed.size()));
            } else {
                rb_ary_store(script, 3, mkxp_str_new(src, srcLen));
            }
        }
    }
    
    
    /* Execute engine-bundled preload scripts (platform compatibility layer) */
    {
        const char *enginePreloads[] = {
            "platform_compat",
            "pokemon_compat",
            "win32_wrap",
            "mkxp_wrap",
            "http_compat",
            nullptr
        };
        
        for (int p = 0; enginePreloads[p]; ++p) {
            try {
                std::string script = mkxp_fs::contentsOfAssetAsString(
                    (std::string("Preload/") + enginePreloads[p]).c_str(), "rb");
                VALUE scriptStr = rb_utf8_str_new_cstr(script.c_str());
                VALUE fname = rb_utf8_str_new_cstr(enginePreloads[p]);
                int state;
                evalString(scriptStr, fname, &state);
                if (state) {
#if RAPI_FULL > 187
                    VALUE exc = rb_errinfo();
#else
                    VALUE exc = rb_gv_get("$!");
#endif
                    if (exc != Qnil) {
                        Debug() << "Error in engine preload" << enginePreloads[p];
#if RAPI_FULL > 187
                        rb_set_errinfo(Qnil);
#else
                        rb_set_errinfo(Qnil);
#endif
                    }
                }
            } catch (...) {
                Debug() << "Failed to load engine preload:" << enginePreloads[p];
            }
        }
    }
    
    /* Execute preloaded scripts */
    for (std::vector<std::string>::const_iterator i = conf.preloadScripts.begin();
         i != conf.preloadScripts.end(); ++i)
    {
        if (shState->rtData().rqTerm)
            break;
        runCustomScript(*i);
    }
    
    VALUE exc = rb_gv_get("$!");
    if (exc != Qnil)
        return;
    
    while (true) {
        for (long i = 0; i < scriptCount; ++i) {
            if (shState->rtData().rqTerm)
                break;
            
            /* Run postload scripts right before the last game script (Main).
               At this point all game classes/modules are defined, so scripts
               like pokeinput.rb can check $PokemonSystem and override Input
               methods that were replaced by the game. */
            if (i == scriptCount - 1 && mkxp_getPostloadEnabled()) {
                const char *enginePostloads[] = {
                    "rgss_plugin_stubs",
                    "pokemon_input",
                    "pokemon_online_stubs",
                    "pokemon_tilemap_fix",
                    "pokemon_graphics_compat",
                    "pokemon_session_reset",
                    "nilclass_safe_stubs",
                    "pokemon_windowskin_fix",
                    "hmode7_shim",
                    nullptr
                };
                
                for (int p = 0; enginePostloads[p]; ++p) {
                    try {
                        std::string pscript = mkxp_fs::contentsOfAssetAsString(
                            (std::string("Postload/") + enginePostloads[p]).c_str(), "rb");
                        VALUE pscriptStr = rb_utf8_str_new_cstr(pscript.c_str());
                        VALUE pfname = rb_utf8_str_new_cstr(enginePostloads[p]);
                        int pstate;
                        evalString(pscriptStr, pfname, &pstate);
                        if (pstate) {
#if RAPI_FULL > 187
                            VALUE pexc = rb_errinfo();
#else
                            VALUE pexc = rb_gv_get("$!");
#endif
                            if (pexc != Qnil) {
                                Debug() << "Error in engine postload" << enginePostloads[p];
#if RAPI_FULL > 187
                                rb_set_errinfo(Qnil);
#else
                                rb_set_errinfo(Qnil);
#endif
                            }
                        }
                    } catch (...) {
                        Debug() << "Failed to load engine postload:" << enginePostloads[p];
                    }
                }

                /* Cheat menu dispatch.
                   Pick the right JoiPlay-derived cheat script based on the
                   RGSS version the game targets and whether Pokemon
                   Essentials is detected. Load only one: the scripts
                   each define Scene_Cheat / aliases on Game_Player, so
                   loading multiple would overwrite each other's hooks. */
                {
                    int cheatRgssVer = shState->rtData().config.rgssVersion;
                    bool isPE = false;
                    {
                        int st = 0;
                        VALUE pe = rb_eval_string_protect(
                            "Object.const_defined?(:GameData) || Object.const_defined?(:PBItems)",
                            &st);
                        if (!st && pe != Qnil && pe != Qfalse) isPE = true;
                    }

                    const char *cheatScript = nullptr;
                    if (isPE) {
                        cheatScript = "cheat_pe19";
                    } else if (cheatRgssVer == 1) {
                        cheatScript = "cheat_rpgmxp";
                    } else if (cheatRgssVer == 2) {
                        cheatScript = "cheat_rpgmvx";
                    } else if (cheatRgssVer >= 3) {
                        cheatScript = "cheat_rpgmvxace";
                    }

                    if (cheatScript) {
                        try {
                            std::string pscript = mkxp_fs::contentsOfAssetAsString(
                                (std::string("Postload/") + cheatScript).c_str(), "rb");
                            VALUE pscriptStr = rb_utf8_str_new_cstr(pscript.c_str());
                            VALUE pfname = rb_utf8_str_new_cstr(cheatScript);
                            int pstate;
                            evalString(pscriptStr, pfname, &pstate);
                            if (pstate) {
#if RAPI_FULL > 187
                                VALUE pexc = rb_errinfo();
#else
                                VALUE pexc = rb_gv_get("$!");
#endif
                                if (pexc != Qnil) {
                                    Debug() << "Error in cheat postload" << cheatScript;
                                    rb_set_errinfo(Qnil);
                                }
                            }

                            /* Install a Ruby-side poller that mirrors the
                               bridge flag into $CHEATS each time Input is
                               updated. This lets the iOS toolbar toggle
                               take effect mid-game without re-entering
                               the scripts. */
                            int pollState = 0;
                            rb_eval_string_protect(
                                "$CHEATS = MKXP.cheats_enabled?\n"
                                "module Input\n"
                                "  unless respond_to?(:_mkxp_cheat_orig_update)\n"
                                "    singleton_class.send(:alias_method, :_mkxp_cheat_orig_update, :update)\n"
                                "    def self.update\n"
                                "      _mkxp_cheat_orig_update\n"
                                "      $CHEATS = MKXP.cheats_enabled?\n"
                                "    end\n"
                                "  end\n"
                                "end\n",
                                &pollState);
                            if (pollState) {
#if RAPI_FULL > 187
                                VALUE pollExc = rb_errinfo();
#else
                                VALUE pollExc = rb_gv_get("$!");
#endif
                                if (pollExc != Qnil) {
                                    VALUE msg = rb_funcall(pollExc, rb_intern("message"), 0);
                                    Debug() << "Error installing cheat-poller:" << StringValueCStr(msg);
                                    rb_set_errinfo(Qnil);
                                } else {
                                    Debug() << "Error installing cheat-poller";
                                }
                            }
                        } catch (...) {
                            Debug() << "Failed to load cheat postload:" << cheatScript;
                        }
                    }
                }
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
            
            
            // if the script name starts with |s|, only execute
            // it if "s" is the same first letter as the platform
            // we're running on
            
            // |W| - Windows, |M| - Mac OS X, |L| - Linux
            
            // Adding a 'not' symbol means it WON'T run on that
            // platform (i.e. |!W| won't run on Windows)
            /*
             if (scriptName[0] == '|') {
             int len = strlen(scriptName);
             if (len > 2) {
             if (scriptName[1] == '!' && len > 3 &&
             scriptName[3] == scriptName[0]) {
             if (toupper(scriptName[2]) == platform[0])
             continue;
             }
             if (scriptName[2] == scriptName[0] &&
             toupper(scriptName[1]) != platform[0])
             continue;
             }
             }
             */
            
            int state;

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
                }
                }
            }
            if (state)
                break;

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

static void showExc(VALUE exc, const BacktraceData &btData) {
    VALUE bt = rb_funcall2(exc, rb_intern("backtrace"), 0, NULL);
    VALUE msg = rb_funcall2(exc, rb_intern("message"), 0, NULL);
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
    
    std::string ms(640, '\0');
    snprintf(&ms[0], ms.size(), "Script '%s' line %s: %s occurred.\n\n%s",
             file.c_str(), line, RSTRING_PTR(name), RSTRING_PTR(msg));
    
    logRubyError("FATAL", ms.c_str());
    showMsg(ms);
}

/* On iOS the Ruby VM is initialized once and reused across game sessions
 * because Ruby 3.1 does not support ruby_init/ruby_cleanup cycles within a
 * single process. On non-iOS the VM is torn down at the end of execute()
 * and the process exits, so everything runs exactly once. */
static bool s_rubyVMInitialized = false;
static int s_lastRgssVer = 0;

/* Reset per-session state that accumulated in the persistent VM during
 * the previous session. This handles engine-generic cleanup only: the C
 * side scrubs constants, class ivars, and the standard RGSS $game_*
 * globals. Any game-specific cleanup (e.g. Pokemon Essentials' $mouse,
 * $PokemonSystem, $Trainer) lives in Ruby preloads and is invoked via
 * the `$__mkxp_reset_hooks` hook array. */
static void resetBetweenSessions() {
    /* 1. Remove constants defined by game scripts.
     *    - Constants in the session-1 baseline are engine-owned, keep them.
     *    - Constants listed in $__mkxp_preload_keep_consts are defined by
     *      our own preloads (e.g. MkxpNullMouse), keep them too.
     *    - Anything else was defined by game scripts in the previous
     *      session; remove to prevent superclass-mismatch errors when
     *      the new game re-defines them. */
    VALUE baseConsts = rb_gv_get("$__mkxp_base_consts");
    if (!NIL_P(baseConsts)) {
        VALUE preloadKeep = rb_gv_get("$__mkxp_preload_keep_consts");
        if (NIL_P(preloadKeep)) preloadKeep = rb_ary_new();
        VALUE currentConsts = rb_funcall(rb_cObject, rb_intern("constants"), 0);
        long len = RARRAY_LEN(currentConsts);
        for (long ci = 0; ci < len; ++ci) {
            VALUE cname = rb_ary_entry(currentConsts, ci);
            if (rb_funcall(baseConsts, rb_intern("include?"), 1, cname) == Qtrue)
                continue;
            if (rb_funcall(preloadKeep, rb_intern("include?"), 1, cname) == Qtrue)
                continue;
            int err = 0;
            rb_protect([](VALUE arg) -> VALUE {
                rb_funcall(rb_cObject, rb_intern("remove_const"), 1, arg);
                return Qnil;
            }, cname, &err);
        }
    }

    /* (Game-script method cleanup is unnecessary: mriBindingInit re-runs
     *  every session in mriBindingExecutePerSession and re-installs all
     *  C methods, overwriting any game-script redefinitions from the
     *  previous session.) */

    /* 2. Clear class/module instance variables AND class variables on
     *    engine-owned classes. Games use both as one-shot guards for
     *    their alias blocks:
     *      - `@SpriteResizerMethodsAliased` (instance var on Sprite)
     *      - `@@haveresizescreen` (class var on Graphics)
     *    These survive across sessions in the persistent VM. If we
     *    leave them alone, the alias blocks silently skip on session
     *    2+ while step 2b below has already removed the actual aliased
     *    methods - leaving NO working alias, breaking game features
     *    that depend on it (e.g. Pokemon Essentials' resize pipeline). */
    {
        int err = 0;
        rb_protect([](VALUE) -> VALUE {
            const char *classesToClear[] = {
                "Bitmap", "Sprite", "Window", "Viewport", "Plane",
                "Tilemap", "Font", "String", "Input", "Graphics",
                "Audio", nullptr
            };
            for (int i = 0; classesToClear[i]; ++i) {
                ID id = rb_intern(classesToClear[i]);
                if (!rb_const_defined(rb_cObject, id)) continue;
                VALUE klass = rb_const_get(rb_cObject, id);

                VALUE ivars = rb_funcall(klass, rb_intern("instance_variables"), 0);
                long n = RARRAY_LEN(ivars);
                for (long k = 0; k < n; ++k) {
                    VALUE name = rb_ary_entry(ivars, k);
                    rb_ivar_set(klass, SYM2ID(name), Qnil);
                }

                VALUE cvars = rb_funcall(klass, rb_intern("class_variables"), 0);
                long m = RARRAY_LEN(cvars);
                for (long k = 0; k < m; ++k) {
                    VALUE name = rb_ary_entry(cvars, k);
                    int inner = 0;
                    rb_protect([](VALUE args) -> VALUE {
                        VALUE klass = rb_ary_entry(args, 0);
                        VALUE name = rb_ary_entry(args, 1);
                        rb_funcall(klass, rb_intern("remove_class_variable"), 1, name);
                        return Qnil;
                    }, rb_ary_new3(2, klass, name), &inner);
                }
            }
            return Qnil;
        }, Qnil, &err);
    }

    /* 2b. Remove non-baseline singleton methods from engine-owned
     *     modules. Games alias + redefine methods like `Input.update`;
     *     the alias (e.g. `Input.update_KGC_ScreenCapture`) survives
     *     across sessions in the persistent VM, and its body can
     *     reference class ivars that step 2 just nilified, producing
     *     "undefined method `call` for nil:NilClass" when the alias
     *     fires in the next session.
     *     `mriBindingInit` re-installs the engine's C methods, so the
     *     primary names (`update`, `trigger?`, etc.) are safe. But any
     *     extra aliases the previous game's scripts added stay around.
     *     Clear them based on baseline snapshot. */
    {
        int err = 0;
        rb_protect([](VALUE) -> VALUE {
            /* (module_name, baseline_gvar) */
            struct Target { const char *name; const char *gvar; };
            Target targets[] = {
                { "Input",    "$__mkxp_base_input_smethods" },
                { "Graphics", "$__mkxp_base_graphics_smethods" },
                { "Audio",    "$__mkxp_base_audio_smethods" },
            };
            for (const Target &t : targets) {
                VALUE base = rb_gv_get(t.gvar);
                if (NIL_P(base)) continue;
                ID id = rb_intern(t.name);
                if (!rb_const_defined(rb_cObject, id)) continue;
                VALUE mod = rb_const_get(rb_cObject, id);
                VALUE sclass = rb_singleton_class(mod);
                VALUE current = rb_funcall(sclass, rb_intern("instance_methods"), 1, Qfalse);
                long n = RARRAY_LEN(current);
                for (long k = 0; k < n; ++k) {
                    VALUE mname = rb_ary_entry(current, k);
                    if (rb_funcall(base, rb_intern("include?"), 1, mname) == Qtrue)
                        continue;
                    int inner = 0;
                    rb_protect([](VALUE args) -> VALUE {
                        VALUE sc = rb_ary_entry(args, 0);
                        VALUE mn = rb_ary_entry(args, 1);
                        rb_funcall(sc, rb_intern("remove_method"), 1, mn);
                        return Qnil;
                    }, rb_ary_new3(2, sclass, mname), &inner);
                }
            }
            return Qnil;
        }, Qnil, &err);
    }

    /* 3. Clear standard RGSS globals (used by every RPG Maker game). */
    rb_set_errinfo(Qnil);
    static const char *rgssGlobals[] = {
        "$game_switches", "$game_variables", "$game_self_switches",
        "$game_screen", "$game_map", "$game_player", "$game_party",
        "$game_troop", "$game_temp", "$game_system", "$scene",
        "$data_system", "$data_actors", "$data_classes", "$data_skills",
        "$data_items", "$data_weapons", "$data_armors", "$data_enemies",
        "$data_troops", "$data_states", "$data_animations",
        "$data_tilesets", "$data_common_events",
        nullptr
    };
    /* Set to nil rather than truly undefining (Ruby's C API has no
     * public way to undefine a global once it's been assigned). PE
     * fangames (notably Reborn) use `if defined?($game_system)` as a
     * "already-initialized" guard, which returns "global-variable"
     * even when the value is nil. That causes their between-run
     * init path to skip resize_screen and fullscreen-setup calls,
     * leaving the Graphics state stuck on the previous session's
     * scRes. Step 5 below compensates by force-resetting `@@width`
     * and `@@height` class vars on the Graphics module back to the
     * engine's real default so the fangame's width-check picks up
     * the mismatch and runs its init code. */
    for (int i = 0; rgssGlobals[i]; ++i)
        rb_gv_set(rgssGlobals[i], Qnil);

    /* 4. Run game-specific reset hooks registered by preloads.
     *    Each preload may push a Proc onto $__mkxp_reset_hooks to
     *    participate in between-session cleanup (e.g. pokemon_compat
     *    clears $PokemonSystem, $Trainer, and replaces $mouse with a
     *    fresh MkxpNullMouse instance). */
    {
        int err = 0;
        rb_protect([](VALUE) -> VALUE {
            VALUE hooks = rb_gv_get("$__mkxp_reset_hooks");
            if (NIL_P(hooks) || !RB_TYPE_P(hooks, T_ARRAY)) return Qnil;
            long n = RARRAY_LEN(hooks);
            for (long i = 0; i < n; ++i) {
                VALUE hook = rb_ary_entry(hooks, i);
                int inner = 0;
                rb_protect([](VALUE h) -> VALUE {
                    return rb_funcall(h, rb_intern("call"), 0);
                }, hook, &inner);
            }
            return Qnil;
        }, Qnil, &err);
    }

    /* 5. Force GC to collect stale Ruby objects from previous session. */
    rb_gc();
}

/* Remove Window/Tilemap classes and the RGSS data module so the next
 * session (with a possibly different rgssVer) can rebind them to the
 * correct C implementation. */
static void unbindRgssVersionSpecifics() {
    int err = 0;
    rb_protect([](VALUE) -> VALUE {
        ID winId = rb_intern("Window");
        if (rb_const_defined(rb_cObject, winId))
            rb_funcall(rb_cObject, rb_intern("remove_const"), 1, ID2SYM(winId));
        ID tmId = rb_intern("Tilemap");
        if (rb_const_defined(rb_cObject, tmId))
            rb_funcall(rb_cObject, rb_intern("remove_const"), 1, ID2SYM(tmId));
        ID rpgId = rb_intern("RPG");
        if (rb_const_defined(rb_cObject, rpgId))
            rb_funcall(rb_cObject, rb_intern("remove_const"), 1, ID2SYM(rpgId));
        return Qnil;
    }, Qnil, &err);
}

/* Rebind rgssVer-dependent classes and evaluate the matching RPG module. */
static void bindRgssVersionSpecifics(Config &conf) {
    if (rgssVer == 1) {
        windowBindingInit();
        tilemapBindingInit();
    } else {
        windowVXBindingInit();
        tilemapVXBindingInit();
    }

    if (rgssVer >= 3) {
        _rb_define_module_function(rb_mKernel, "rgss_main", mriRgssMain);
        _rb_define_module_function(rb_mKernel, "rgss_stop", mriRgssStop);

        _rb_define_module_function(rb_mKernel, "msgbox", mriPrint);
        _rb_define_module_function(rb_mKernel, "msgbox_p", mriP);

        rb_define_global_const("RGSS_VERSION", mkxp_str_new_cstr("3.0.1"));
    } else {
        _rb_define_module_function(rb_mKernel, "print", mriPrint);
        _rb_define_module_function(rb_mKernel, "p", mriP);
    }

    if (rgssVer == 1)
        rb_eval_string(module_rpg1);
    else if (rgssVer == 2)
        rb_eval_string(module_rpg2);
    else if (rgssVer == 3)
        rb_eval_string(module_rpg3);
}

static void mriBindingExecute() {
    Config &conf = shState->rtData().config;

    /* On iOS the Ruby VM is persistent across sessions. Do the one-time
     * initialization only on session 1; subsequent sessions reuse the
     * existing VM but reset per-session game state. */
    const bool firstSession = !s_rubyVMInitialized;
    const bool rgssVerChanged = s_rubyVMInitialized && (rgssVer != s_lastRgssVer);

    if (!firstSession) {
        resetBetweenSessions();
        if (rgssVerChanged) {
            unbindRgssVersionSpecifics();
            bindRgssVersionSpecifics(conf);
        }
        s_lastRgssVer = rgssVer;
    } else {
        s_rubyVMInitialized = true;
        s_lastRgssVer = rgssVer;
        mriBindingExecuteInitOnce(conf);
    }

    mriBindingExecutePerSession(conf);
}

/* One-time Ruby VM setup, runs on the first mriBindingExecute() call per
 * process. On iOS the VM persists across game sessions; on other platforms
 * ruby_cleanup is called after each session and the process exits. */
static void mriBindingExecuteInitOnce(Config &conf) {
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

    // Set the default encoding for regular expressions to UTF-8 when using syntax transform targeting Ruby <= 1.8
    rb_gv_set("$KCODE", rb_str_new_cstr("UTF8"));
    rb_gv_set("$-K", rb_str_new_cstr("UTF8"));

    topSelf = rgssVer == 1 ? Qnil : rb_eval_string("self");
    // Register as a GC root so Ruby doesn't collect the value between
    // sessions when nothing on the stack references it.
    static bool topSelfRegistered = false;
    if (!topSelfRegistered) {
        rb_gc_register_address(&topSelf);
        topSelfRegistered = true;
    }
}

/* Per-session Ruby setup and game script execution, runs every call to
 * mriBindingExecute(). Runs mriBindingInit every session to reinstall C
 * methods on top of any game-script redefinitions from the previous
 * session. All rb_define_alias sites in mriBindingInit must be
 * idempotent across sessions (see mkxp_define_alias_once). */
static void mriBindingExecutePerSession(Config &conf) {
    /* RbData must be live before mriBindingInit: inputBindingInit on RGSS3
     * writes getRbData()->buttoncodeHash. */
    RbData rbData;
    shState->setBindingData(&rbData);
    BacktraceData btData;

    mriBindingInit();

    /* Snapshot Object.constants right after mriBindingInit registers the
     * RGSS classes but before game scripts run. On subsequent sessions,
     * any constants not in this baseline were defined by game scripts and
     * must be removed to prevent superclass-mismatch errors between
     * different games.
     * Only capture once — the baseline is the same across sessions
     * because mriBindingInit is deterministic. */
    {
        VALUE existing = rb_gv_get("$__mkxp_base_consts");
        if (NIL_P(existing)) {
            VALUE consts = rb_funcall(rb_cObject, rb_intern("constants"), 0);
            VALUE dup = rb_funcall(consts, rb_intern("dup"), 0);
            rb_gv_set("$__mkxp_base_consts", dup);
        }
    }

    /* Snapshot singleton method lists for engine-owned modules right
     * after mriBindingInit. The per-session reset uses these baselines
     * to remove game-added aliases (Input.update_KGC_ScreenCapture
     * etc.) that would otherwise survive across games and misbehave
     * when their closed-over ivars are cleaned. */
    {
        int err = 0;
        rb_protect([](VALUE) -> VALUE {
            struct Target { const char *name; const char *gvar; };
            Target targets[] = {
                { "Input",    "$__mkxp_base_input_smethods" },
                { "Graphics", "$__mkxp_base_graphics_smethods" },
                { "Audio",    "$__mkxp_base_audio_smethods" },
            };
            for (const Target &t : targets) {
                VALUE existing = rb_gv_get(t.gvar);
                if (!NIL_P(existing)) continue;
                ID id = rb_intern(t.name);
                if (!rb_const_defined(rb_cObject, id)) continue;
                VALUE mod = rb_const_get(rb_cObject, id);
                VALUE sclass = rb_singleton_class(mod);
                VALUE methods = rb_funcall(sclass, rb_intern("instance_methods"), 1, Qfalse);
                VALUE dup = rb_funcall(methods, rb_intern("dup"), 0);
                rb_gv_set(t.gvar, dup);
            }
            return Qnil;
        }, Qnil, &err);
    }

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
     * and the UI shows the recovery alert. */
    if (NIL_P(exc) || rb_obj_is_kind_of(exc, rb_eSystemExit)) {
        mkxp_setEngineExitedCleanly();
    }

    /* On iOS, keep the Ruby VM alive across game sessions.
     * ruby_cleanup() corrupts Ruby 1.8's internal state and
     * makes ruby_init() crash on subsequent calls. */
    
    shState->rtData().rqTermAck.set();
}

static void mriBindingTerminate() { throw Exception(Exception::SystemExit, " "); }

static void mriBindingReset() { throw Exception(Exception::Reset, " "); }
