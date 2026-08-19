//
//  config.cpp
//  Player
//
//  Created by ゾロアーク on 11/21/20.
//

#include "config.h"
#include <SDL_filesystem.h>
#include <assert.h>
#include <cctype>
#include <dirent.h>

#include <stdint.h>
#include <vector>

#include "filesystem/filesystem.h"
#include "util/exception.h"
#include "util/debugwriter.h"
#include "util/sdl-util.h"
#include "util/util.h"

#include "util/json5pp.hpp"
#include "app_bridge.h"

#include "util/iniconfig.h"
#include "util/encoding.h"

#include "system/system.h"


namespace json = json5pp;

std::string prefPath(const char *org, const char *app) {
    char *path = SDL_GetPrefPath(org, app);
    if (!path)
        return std::string("");
    std::string ret(path);
    SDL_free(path);
    return ret;
}

void fillStringVec(json::value &item, std::vector<std::string> &vector) {
    if (!item.is_array()) {
        if (item.is_string()) {
            vector.push_back(item.as_string());
        }
        return;
    }
    auto &array = item.as_array();
    for (size_t i = 0; i < array.size(); i++) {
        if (!array[i].is_string())
            continue;
        
        vector.push_back(array[i].as_string());
    }
}

static void mergeConfigOverlay(json::value &optsJ, const json::value &overlay) {
    if (!overlay.is_object())
        return;

    auto &opts = optsJ.as_object();
    for (auto &it : overlay.as_object()) {
        /* Shallow merge: each top-level overlay key wins outright,
         * including JSON null (neutralizes the key for GUARDed reads)
         * and whole-object replacement for bindingNames. */
        opts[it.first] = it.second;
    }
}

bool copyObject(json::value &dest, json::value &src, const char *objectName = "") {
    assert(dest.is_object());
    if (src.is_null())
        return false;
    
    if (!src.is_object())
        return false;
    
    auto &srcVec = src.as_object();
    auto &destVec = dest.as_object();
    
    for (auto it : srcVec) {
        // Specifically processs this object later.
        if (it.second.is_object() && destVec[it.first].is_object())
            continue;
        
        if ((it.second.is_array() && destVec[it.first].is_array())    ||
            (it.second.is_number() && destVec[it.first].is_number())  ||
            (it.second.is_string() && destVec[it.first].is_string())  ||
            (it.second.is_boolean() && destVec[it.first].is_boolean()) ||
            (destVec[it.first].is_null()))
        {
            destVec[it.first] = it.second;
        }
        else {
            Debug() << "Invalid variable in configuration:" << objectName << it.first;
        }
    }
    return true;
}

bool getEnvironmentBool(const char *env, bool defaultValue) {
    const char *e = SDL_getenv(env);
    if (!e)
        return defaultValue;
    
    if (!strcmp(e, "0"))
        return false;
    else if (!strcmp(e, "1"))
        return true;
    
    return defaultValue;
}

json::value readConfFile(const char *path, bool isBaseConf) {
    
    json::value ret(0);
    if (!mkxp_fs::fileExists(path)) {
        // Base config default = "legacy" (Ruby 1.8 compat) since
        // most RPG Maker games use the historical syntax. iOS overrides
        // per-game via the bridge regardless. See config.h.
        return isBaseConf ? json::object({{"syntaxTransform", "legacy"}})
                          : json::object({});
    }
    
    try {
        std::string cfg = mkxp_fs::contentsOfFileAsString(path);
        std::string converted;
        try {
            converted = Encoding::convertString(cfg);
        } catch (...) {
            // If encoding detection fails, assume UTF-8 (the common case for mkxp.json)
            converted = cfg;
        }
        ret = json::parse5(converted);
    }
    catch (const std::exception &e) {
        Debug() << "Failed to parse" << path << ":" << e.what();
    }
    catch (const Exception &e) {
        Debug() << "Failed to parse" << path << ":" << "Unknown encoding";
    }
    
    if (!ret.is_object())
        ret = json::object({});
    
    return ret;
}

#define CONF_FILE "mkxp.json"

Config::Config() {}

void Config::read(int argc, char *argv[]) {
    auto optsJ = json::object({
        // Default = "disabled" (no transform). Per-game override
        // via mkxp.json string ("disabled" | "custom" | "legacy")
        // or, on iOS, via mkxp_setSyntaxTransformMode() bridge.
        {"syntaxTransform", "disabled"},
        {"syntaxTransformCustomVersionMajor", 1},
        {"syntaxTransformCustomVersionMinor", 0},
        {"syntaxTransformCustomVersionTeeny", 0},
        {"rgssVersion", 0},
        {"debugMode", false},
        {"displayFPS", false},
        {"printFPS", false},
        {"winResizable", true},
        {"fullscreen", false},
        {"fixedAspectRatio", true},
        {"smoothScaling", 0},
        {"smoothScalingDown", 0},
        {"bitmapSmoothScaling", 0},
        {"bitmapSmoothScalingDown", 0},
        {"smoothScalingMipmaps", false},
        {"bicubicSharpness", 100},
#ifdef MKXPZ_SSL
        {"xbrzScalingFactor", 1.},
#endif
        {"enableHires", false},
        {"textureScalingFactor", 1.},
        {"framebufferScalingFactor", 1.},
        {"atlasScalingFactor", 1.},
        {"vsync", false},
        {"defScreenW", 0},
        {"defScreenH", 0},
        {"windowTitle", ""},
        {"fixedFramerate", 0},
        {"frameSkip", false},
        {"syncToRefreshrate", false},
        {"solidFonts", json::array({})},
        {"preferMetalRenderer", true},
        {"subImageFix", false},
        {"enableBlitting", true},
        {"integerScalingActive", false},
        {"integerScalingLastMile", true},
        {"maxTextureSize", 0},
        {"gameFolder", ""},
        {"anyAltToggleFS", false},
        {"enableReset", true},
        {"enableSettings", true},
        {"allowSymlinks", true},
        {"dataPathOrg", ""},
        {"dataPathApp", ""},
        {"iconPath", ""},
        {"execName", "Game"},
        {"midiSoundFont", ""},
        {"midiChorus", false},
        {"midiReverb", false},
        {"SESourceCount", 6},
        {"BGMTrackCount", 1},
        {"customScript", ""},
        {"pathCache", true},
        {"useScriptNames", true},
        {"preloadScript", json::array({})},
        {"postloadScript", json::array({})},
        {"RTP", json::array({})},
        {"patches", json::array({})},
        {"scriptPatches", json::array({})},
        {"fontSub", json::array({})},
        {"fontScale", 0.0f},
        {"fontKerning", true},
        {"fontHinting", 3}, // TTF_HINTING_NONE
        {"fontHeightReporting", 0},
        {"fontOutlineCrop", true},
        {"rubyLoadpath", json::array({})},
        {"JITEnable", false},
        {"JITVerboseLevel", 0},
        {"JITMaxCache", 100},
        {"JITMinCalls", 10000},
        {"YJITEnable", false},
        {"dumpAtlas", false},
        {"bindingNames", json::object({
            {"a", "A"},
            {"b", "B"},
            {"c", "C"},
            {"x", "X"},
            {"y", "Y"},
            {"z", "Z"},
            {"l", "L"},
            {"r", "R"}
        })}
    });
    
    auto &opts = optsJ.as_object();
    
#define GUARD(exp) \
try { exp } catch (...) {}
    
    editor.debug = false;
    editor.battleTest = false;
    
    if (argc > 1) {
        if (!strcmp(argv[1], "debug") || !strcmp(argv[1], "test"))
            editor.debug = true;
        else if (!strcmp(argv[1], "btest"))
            editor.battleTest = true;
        
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "debug"))
                launchArgs.push_back(argv[i]);
        }
    }
    
    /* Resolve the path to the base mkxp.json.
     *
     * A host may keep per-game state outside the game folder (a
     * managed per-game state directory) so the imported game
     * directory stays a faithful mirror of what the user dropped
     * in. The host UI sets that path via `mkxp_setManagedConfigDir`
     * before each session. If a managed config file exists there,
     * prefer it; otherwise fall back to the historic cwd-relative
     * `mkxp.json` (desktop builds, raw mkxp-z usage, hosts that
     * don't manage state). */
    /* A host that set no managed directory hands back a null
     * pointer, which std::string must not be built from. */
    const char *managedPath = mkxp_getManagedConfigDir();
    std::string managedDir(managedPath ? managedPath : "");
    std::string conf_path = CONF_FILE;
    if (!managedDir.empty()) {
        std::string managedConf = managedDir + "/" + CONF_FILE;
        if (mkxp_fs::fileExists(managedConf.c_str()))
            conf_path = managedConf;
    }
    json::value baseConf = readConfFile(conf_path.c_str(), true);
    copyObject(optsJ, baseConf);
    copyObject(opts["bindingNames"], baseConf.as_object()["bindingNames"], "bindingNames .");

    const char *overlayJSON = mkxp_getConfigOverlayJSON();
    if (overlayJSON && overlayJSON[0]) {
        try {
            json::value overlayConf = json::parse5(overlayJSON);
            if (!overlayConf.is_object())
                overlayConf = json::object({});
            mergeConfigOverlay(optsJ, overlayConf);
        }
        catch (const std::exception &e) {
            Debug() << "Failed to parse config overlay:" << e.what();
        }
    }
    
#define SET_OPT_CUSTOMKEY(var, key, type) GUARD(var = opts[#key].as_##type();)
#define SET_OPT(var, type) SET_OPT_CUSTOMKEY(var, var, type)
#define SET_STRINGOPT(var, key) GUARD(var = std::string(opts[#key].as_string());)
    
    SET_STRINGOPT(gameFolder, gameFolder);
    SET_STRINGOPT(dataPathOrg, dataPathOrg);
    SET_STRINGOPT(dataPathApp, dataPathApp);
    SET_STRINGOPT(iconPath, iconPath);
    SET_STRINGOPT(execName, execName);
    SET_OPT(allowSymlinks, boolean);
    SET_OPT(pathCache, boolean);
    SET_OPT_CUSTOMKEY(jit.enabled, JITEnable, boolean);
    SET_OPT_CUSTOMKEY(jit.verboseLevel, JITVerboseLevel, integer);
    SET_OPT_CUSTOMKEY(jit.maxCache, JITMaxCache, integer);
    SET_OPT_CUSTOMKEY(jit.minCalls, JITMinCalls, integer);
    SET_OPT_CUSTOMKEY(yjit.enabled, YJITEnable, boolean);
    // syntaxTransform: prefer the string form
    // ("disabled" / "custom" / "legacy") for self-documenting
    // configs. Fall back to integer (0/1/2) for backward
    // compatibility with developer-shipped mkxp.json files that
    // predate the string schema.
    syntaxTransform = MKXP_SYNTAX_TRANSFORM_DISABLED;
    GUARD({
        const auto &v = opts["syntaxTransform"];
        if (v.is_string()) {
            const std::string &s = v.as_string();
            if      (s == "disabled") syntaxTransform = MKXP_SYNTAX_TRANSFORM_DISABLED;
            else if (s == "custom")   syntaxTransform = MKXP_SYNTAX_TRANSFORM_CUSTOM;
            else if (s == "legacy")   syntaxTransform = MKXP_SYNTAX_TRANSFORM_LEGACY;
            else Debug() << "Unknown syntaxTransform value:" << s.c_str()
                         << "(expected disabled|custom|legacy); defaulting to disabled.";
        } else if (v.is_integer()) {
            int n = (int)v.as_integer();
            if (n == 0 || n == 1 || n == 2)
                syntaxTransform = (MKXPSyntaxTransformMode)n;
            else Debug() << "Out-of-range integer syntaxTransform:" << n
                         << "(expected 0/1/2); defaulting to disabled.";
        }
    });
    SET_OPT(syntaxTransformCustomVersionMajor, integer);
    SET_OPT(syntaxTransformCustomVersionMinor, integer);
    SET_OPT(syntaxTransformCustomVersionTeeny, integer);
    SET_OPT(rgssVersion, integer);
    SET_OPT(defScreenW, integer);
    SET_OPT(defScreenH, integer);
    
    // Take a break real quick and witch to set game folder and read the game's ini
    if (!gameFolder.empty() && !mkxp_fs::setCurrentDirectory(gameFolder.c_str())) {
        throw Exception(Exception::MKXPError, "Unable to switch into gameFolder %s", gameFolder.c_str());
    }
    
    readGameINI();
    
    // Now check for an extra mkxp.conf in the user's save directory and merge anything else from that
    userConfPath = mkxp_fs::normalizePath(std::string(customDataPath + "/" CONF_FILE).c_str(), 0, 1);
    json::value userConf = readConfFile(userConfPath.c_str(), false);
    copyObject(optsJ, userConf);
    
    // now RESUME
    
    SET_OPT(debugMode, boolean);
    SET_OPT(displayFPS, boolean);
    SET_OPT(printFPS, boolean);
    SET_OPT(fullscreen, boolean);
    SET_OPT(fixedAspectRatio, boolean);
    SET_OPT(smoothScaling, integer);
    SET_OPT(smoothScalingDown, integer);
    SET_OPT(bitmapSmoothScaling, integer);
    SET_OPT(bitmapSmoothScalingDown, integer);
    SET_OPT(smoothScalingMipmaps, boolean);
    SET_OPT(bicubicSharpness, integer);
#ifdef MKXPZ_SSL
    SET_OPT(xbrzScalingFactor, integer);
#endif
    SET_OPT(enableHires, boolean);
    SET_OPT(textureScalingFactor, number);
    SET_OPT(framebufferScalingFactor, number);
    SET_OPT(atlasScalingFactor, number);
    SET_OPT(winResizable, boolean);
    SET_OPT(vsync, boolean);
    SET_STRINGOPT(windowTitle, windowTitle);
    SET_OPT(fixedFramerate, integer);
    SET_OPT(frameSkip, boolean);
    SET_OPT(syncToRefreshrate, boolean);
    fillStringVec(opts["solidFonts"], solidFonts);
    for (std::string & solidFont : solidFonts)
        std::transform(solidFont.begin(), solidFont.end(), solidFont.begin(),
            [](unsigned char c) { return std::tolower(c); });
    SET_OPT(preferMetalRenderer, boolean);
    SET_OPT(subImageFix, boolean);
    SET_OPT(enableBlitting, boolean);
    SET_OPT_CUSTOMKEY(integerScaling.active, integerScalingActive, boolean);
    SET_OPT_CUSTOMKEY(integerScaling.lastMileScaling, integerScalingLastMile, boolean);
    SET_OPT(maxTextureSize, integer);
    SET_OPT(anyAltToggleFS, boolean);
    SET_OPT(enableReset, boolean);
    SET_OPT(enableSettings, boolean);
    SET_STRINGOPT(midi.soundFont, midiSoundFont);
    SET_OPT_CUSTOMKEY(midi.chorus, midiChorus, boolean);
    SET_OPT_CUSTOMKEY(midi.reverb, midiReverb, boolean);
    SET_OPT_CUSTOMKEY(SE.sourceCount, SESourceCount, integer);
    SET_OPT_CUSTOMKEY(BGM.trackCount, BGMTrackCount, integer);
    SET_STRINGOPT(customScript, customScript);
    SET_OPT(useScriptNames, boolean);
    SET_OPT(dumpAtlas, boolean);
    
    fillStringVec(opts["preloadScript"], preloadScripts);
    fillStringVec(opts["postloadScript"], postloadScripts);
    fillStringVec(opts["RTP"], rtps);
    fillStringVec(opts["patches"], patches);
    fillStringVec(opts["scriptPatches"], scriptPatches);
    fillStringVec(opts["fontSub"], fontSubs);
    for (std::string & fontSub : fontSubs)
        std::transform(fontSub.begin(), fontSub.end(), fontSub.begin(),
            [](unsigned char c) { return std::tolower(c); });
    SET_OPT(fontScale, number);
    SET_OPT(fontKerning, boolean);
    SET_OPT(fontHinting, integer);
    SET_OPT(fontHeightReporting, integer);
    SET_OPT(fontOutlineCrop, boolean);
    fillStringVec(opts["rubyLoadpath"], rubyLoadpaths);
    
    auto &bnames = opts["bindingNames"].as_object();
    
#define BINDING_NAME(btn) kbActionNames.btn = bnames[#btn].as_string()
    BINDING_NAME(a);
    BINDING_NAME(b);
    BINDING_NAME(c);
    BINDING_NAME(x);
    BINDING_NAME(y);
    BINDING_NAME(z);
    BINDING_NAME(l);
    BINDING_NAME(r);
    
    rgssVersion = clamp(rgssVersion, 0, 3);
    SE.sourceCount = clamp(SE.sourceCount, 1, 64);
    BGM.trackCount = clamp(BGM.trackCount, 1, 16);
    
    /* winConsole / manualFolderSelect / MKXPZ_MACOS_METAL env overrides
     * were all desktop-only knobs. On iOS the config values are whatever
     * the JSON declares and the values remain at their defaults. */
    winConsole = false;
    manualFolderSelect = false;
    
    raw = optsJ;
}

static void setupScreenSize(Config &conf) {
    if (conf.defScreenW <= 0)
        conf.defScreenW = (conf.rgssVersion == 1 ? 640 : 544);
    
    if (conf.defScreenH <= 0)
        conf.defScreenH = (conf.rgssVersion == 1 ? 480 : 416);
}

bool Config::fontIsSolid(const char *fontName) const {
    for (std::string solidfont : solidFonts)
        if (!strcmp(solidfont.c_str(), fontName)) return true;
    
    return false;
}

void Config::readGameINI() {
    if (!customScript.empty()) {
        game.title = customScript.c_str();
        
        if (rgssVersion == 0)
            rgssVersion = 1;
        
        setupScreenSize(*this);
        
        return;
    }
    
    // The canonical RPG Maker `Game.ini` filename is derived from
    // `execName` (defaults to "Game"). Games like Pokemon Uranium
    // ship their ini under a custom name (Uranium.ini) and rely on
    // the desktop launcher to match - Windows picks `Foo.ini` by
    // looking up the .exe name at runtime. On iOS there's no .exe
    // to sniff, so when `execName + ".ini"` doesn't exist, fall
    // back to scanning the game root for any *.ini that has the
    // two mandatory `[Game]` keys (`Library` + `Scripts`). Every
    // real RPG Maker XP / VX / VX Ace title has both; sibling
    // inis shipped for things like audio configs / language files
    // lack one or the other, so this check filters them out.
    std::string iniFileName(execName + ".ini");

    auto tryLoadIni = [&](const std::string &path,
                          bool requireGameKeys) -> bool {
        SDLRWStream iniFile(path.c_str(), "r");
        if (!iniFile) return false;
        INIConfiguration ic;
        if (!ic.load(iniFile.stream())) return false;

        std::string localTitle, localScripts, localLibrary;
        GUARD(localTitle = ic.getStringProperty("Game", "Title"););
        GUARD(localScripts = ic.getStringProperty("Game", "Scripts"););
        GUARD(localLibrary = ic.getStringProperty("Game", "Library"););
        strReplace(localScripts, '\\', '/');

        if (requireGameKeys &&
            (localScripts.empty() || localLibrary.empty())) {
            return false;
        }

        game.title = localTitle;
        game.scripts = localScripts;
        if (game.title.empty()) {
            Debug() << path + ": Could not find Game.Title";
        }
        if (game.scripts.empty()) {
            Debug() << path + ": Could not find Game.Scripts";
        }
        return true;
    };

    bool convSuccess = false;
    bool iniLoaded = tryLoadIni(iniFileName, false);

    if (!iniLoaded || game.scripts.empty()) {
        Debug() << "Could not read" << iniFileName
                << "- scanning game root for alternate game ini";
        DIR *dir = opendir(".");
        if (dir) {
            while (struct dirent *ent = readdir(dir)) {
                std::string name(ent->d_name);
                if (name.size() < 5) continue;
                std::string suffix = name.substr(name.size() - 4);
                for (char &c : suffix) c = std::tolower(c);
                if (suffix != ".ini") continue;
                if (name == iniFileName) continue;
                if (tryLoadIni(name, true)) {
                    iniFileName = name;
                    // Sync execName to the ini's basename so
                    // sharedstate.cpp picks up `Uranium.rgssad`
                    // instead of `Game.rgssad` when mounting the
                    // RGSS archive. Everything else downstream
                    // that keys off execName (mkxp.json
                    // overrides, save-data paths) also benefits.
                    execName = name.substr(0, name.size() - 4);
                    iniLoaded = true;
                    Debug() << "Using alternate game ini:" << name
                            << "(execName -> " << execName << ")";
                    break;
                }
            }
            closedir(dir);
        }
    }

    if (!iniLoaded) {
        Debug() << "No usable game ini found";
    }
    
    try {
        game.title = Encoding::convertString(game.title);
        convSuccess = true;
    }
    catch (const Exception &e) {
        Debug() << iniFileName + ": Could not determine encoding of Game.Title";
    }
    
    if (game.title.empty() || !convSuccess)
        game.title = "mkxp-z";
    
    if (dataPathOrg.empty())
        dataPathOrg = ".";
    
    if (dataPathApp.empty())
        dataPathApp = game.title;
    
    const char *userDataDirOverride = mkxp_getUserDataDirectory();
    if (userDataDirOverride && *userDataDirOverride) {
        customDataPath = mkxp_fs::normalizePath(userDataDirOverride, 0, 1);
    } else {
        customDataPath = mkxp_fs::normalizePath(prefPath(dataPathOrg.c_str(), dataPathApp.c_str()).c_str(), 0, 1);
    }

    const char *sharedFontsDirOverride = mkxp_getSharedFontsDirectory();
    if (sharedFontsDirOverride && *sharedFontsDirOverride)
        sharedFontsPath = mkxp_fs::normalizePath(sharedFontsDirOverride, 0, 1);
    
    if (rgssVersion == 0) {
        /* Try to guess RGSS version based on Data/Scripts extension */
        rgssVersion = 1;
        
        if (!game.scripts.empty()) {
            const char *p = &game.scripts[game.scripts.size()];
            const char *head = &game.scripts[0];
            
            while (--p != head)
                if (*p == '.')
                    break;
            
            if (!strcmp(p, ".rvdata"))
                rgssVersion = 2;
            else if (!strcmp(p, ".rvdata2"))
                rgssVersion = 3;
        }
    }
    
    setupScreenSize(*this);
}
