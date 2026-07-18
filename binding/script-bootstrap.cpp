/*
 ** script-bootstrap.cpp
 **
 ** Loads engine-bundled preload/postload Ruby scripts and cheat
 ** dispatch in a fixed order. See script-bootstrap.h.
 */

#include "script-bootstrap.h"

#include "config.h"
#include "sharedstate.h"
#include "eventthread.h"
#include "app_bridge.h"
#include "binding-util.h"

#include "util/debugwriter.h"
#include "util/sdl-util.h"
#include "util/util.h"
#include "filesystem/filesystem.h"

#include <cctype>
#include <string>
#include <vector>

extern "C" {
#include <ruby.h>
}

namespace mkxp {
namespace ScriptBootstrap {

static VALUE g_topSelf = Qnil;

void setEvalReceiver(void *self) {
    g_topSelf = (VALUE)self;
    rb_gc_register_address(&g_topSelf);
}

struct EvalArg {
    VALUE string;
    VALUE filename;
};

static VALUE evalHelper(EvalArg *arg) {
    VALUE argv[] = {arg->string, Qnil, arg->filename};
    return rb_funcall2(g_topSelf, rb_intern("eval"), ARRAY_SIZE(argv), argv);
}

void evalRubyString(void *string, void *filename, int *state) {
    EvalArg arg = {(VALUE)string, (VALUE)filename};
    rb_protect((VALUE(*)(VALUE))evalHelper, (VALUE)&arg, state);
}

static void runBundledScript(const char *subdir, const char *name, const char *logTag) {
    mkxp_debugLog(logTag, "script-bootstrap.cpp",
                  (std::string("loading ") + name).c_str());
    try {
        std::string script = mkxp_fs::contentsOfAssetAsString(
            (std::string(subdir) + "/" + name).c_str(), "rb");
        if (script.empty()) {
            mkxp_debugLog(logTag, "script-bootstrap.cpp",
                          (std::string("EMPTY content for ") + name).c_str());
            return;
        }
        VALUE scriptStr = rb_utf8_str_new_cstr(script.c_str());
        VALUE fname = rb_utf8_str_new_cstr(name);
        int state = 0;
        evalRubyString((void *)scriptStr, (void *)fname, &state);
        if (state) {
#if RAPI_FULL > 187
            VALUE exc = rb_errinfo();
#else
            VALUE exc = rb_gv_get("$!");
#endif
            if (exc != Qnil) {
                VALUE excClass = rb_class_name(rb_class_of(exc));
                VALUE excMsg = rb_funcall(exc, rb_intern("message"), 0);
                std::string detail = std::string("FAILED ") + name + ": "
                                   + StringValueCStr(excClass) + ": "
                                   + StringValueCStr(excMsg);
                mkxp_debugLog(logTag, "script-bootstrap.cpp", detail.c_str());
                Debug() << "Error in engine" << subdir << name;
                rb_set_errinfo(Qnil);
            }
        } else {
            mkxp_debugLog(logTag, "script-bootstrap.cpp",
                          (std::string("OK ") + name).c_str());
        }
    } catch (...) {
        mkxp_debugLog(logTag, "script-bootstrap.cpp",
                      (std::string("CXX EXC ") + name).c_str());
        Debug() << "Failed to load engine" << subdir << name;
    }
}

// Expose the host launcher's identity to game scripts (see
// mkxp_setLauncherIdentity in app_bridge.h): `$userAgent` carries the
// name verbatim; `$<name> = true` follows the JoiPlay `$joiplay`
// detection convention and is only defined when the name is a valid
// Ruby identifier.
static void setLauncherIdentityGlobals() {
    const std::string identity(mkxp_getLauncherIdentity());
    if (identity.empty())
        return;

    rb_gv_set("$userAgent", rb_utf8_str_new_cstr(identity.c_str()));

    bool validIdentifier = std::isalpha((unsigned char)identity[0])
                        || identity[0] == '_';
    for (size_t i = 1; validIdentifier && i < identity.size(); ++i)
        validIdentifier = std::isalnum((unsigned char)identity[i])
                       || identity[i] == '_';
    if (validIdentifier)
        rb_gv_set(("$" + identity).c_str(), Qtrue);
}

void loadEnginePreloads() {
    setLauncherIdentityGlobals();

    const char *enginePreloads[] = {
        "platform_compat",
        "pokemon_compat",
        "win32_wrap",
#if RUBY_API_VERSION_MAJOR > 1 || \
    (RUBY_API_VERSION_MAJOR == 1 && RUBY_API_VERSION_MINOR >= 9)
        "win32_wrap_encoding",
#endif
        "mkxp_wrap",
        "http_compat",
        "net_http_compat",
        nullptr
    };

    for (int p = 0; enginePreloads[p]; ++p)
        runBundledScript("Preload", enginePreloads[p], "PRELOAD");
}

static void runConfigScriptFromDisk(const std::string &filename, bool showDialogOnMissing) {
    std::string scriptData;
    if (!readFileSDL(filename.c_str(), scriptData)) {
        if (showDialogOnMissing)
            shState->eThread().showMessageBox(
                (std::string("Unable to open '") + filename + "'").c_str());
        else
            Debug() << "Unable to open '" << filename << "'";
        return;
    }
    evalRubyString(
        (void *)mkxp_str_new(scriptData.c_str(), scriptData.size()),
        (void *)mkxp_str_new(filename.c_str(), filename.size()),
        nullptr);
}

void runConfigScript(const std::string &path, bool showDialogOnMissing) {
    runConfigScriptFromDisk(path, showDialogOnMissing);
}

void loadConfigPreloadScripts(const Config &conf) {
    for (std::vector<std::string>::const_iterator i = conf.preloadScripts.begin();
         i != conf.preloadScripts.end(); ++i)
    {
        if (shState->rtData().rqTerm)
            break;
        runConfigScriptFromDisk(*i, false);
    }
}

void loadConfigPostloadScripts(const Config &conf) {
    for (std::vector<std::string>::const_iterator i = conf.postloadScripts.begin();
         i != conf.postloadScripts.end(); ++i)
    {
        if (shState->rtData().rqTerm)
            break;
        runConfigScriptFromDisk(*i, true);
    }
}

void loadEnginePostloadsBeforeMain() {
    if (!mkxp_getPostloadEnabled())
        return;

    const char *enginePostloads[] = {
        "rgss_plugin_stubs",
        "pokemon_input",
        "pokemon_online_stubs",
        "pokemon_tilemap_fix",
        "pokemon_graphics_compat",
        "nilclass_safe_stubs",
        "pokemon_windowskin_fix",
        "hmode7_shim",
        nullptr
    };

    for (int p = 0; enginePostloads[p]; ++p)
        runBundledScript("Postload", enginePostloads[p], "POSTLOAD");
}

void loadCheatPostloadAndPoller() {
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

    if (!cheatScript)
        return;

    runBundledScript("Postload", cheatScript, "POSTLOAD");

    int pollState = 0;
    rb_eval_string_protect(
        "$CHEATS = MKXP.cheats_enabled?\n"
        "module Input\n"
        "  unless respond_to?(:_mkxp_cheat_orig_update)\n"
        "    class << self\n"
        "      alias_method :_mkxp_cheat_orig_update, :update\n"
        "    end\n"
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
}

} // namespace ScriptBootstrap
} // namespace mkxp
