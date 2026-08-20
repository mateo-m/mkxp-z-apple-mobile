/*
** patcher.cpp
**
** Ports JoiPlay's Patcher. Parses each JSON file listed in
** `mkxp.json.scriptPatches`, pulls the "rpgm" array, and applies each
** entry as either a literal substring replacement or, if the
** key starts with "[regex]", as an ECMAScript regex replacement.
*/

#include "patcher.h"

#include "app_bridge.h"
#include "util/debugwriter.h"
#include "util/json5pp.hpp"

#include <fstream>
#include <regex>
#include <sstream>

namespace json = json5pp;

/* Helper: route patcher diagnostics through the iOS debug-log
 * file (so they show up in the player's Debug Logs view) AND
 * through std::cerr via Debug() for desktop builds. The cerr
 * path is unhelpful on iOS because the SDL log redirector
 * doesn't surface it in the user-visible log. */
static void patcherLog(const std::string &msg)
{
    Debug() << msg.c_str();
    mkxp_debugLog("PATCHER", "patcher.cpp [C++]", msg.c_str());
}

Patcher::Patcher(const std::vector<std::string> &patches)
{
    for (const std::string &patch : patches)
        load(patch.c_str());

    /* Auto-discovery fallback: if mkxp.json's `scriptPatches` list
     * is empty, look for a `patches.json` in (a) the host-managed
     * config directory (see `mkxp_setManagedConfigDir`),
     * then (b) the current working directory (game folder, the
     * historical location used by JoiPlay-style desktop installs).
     *
     * The two-tier lookup lets a host write its curated
     * patches.json into a state directory parallel to the game
     * folder so the imported game folder stays untouched, while
     * still honoring user-dropped `patches.json` files in the
     * game folder for power-user / desktop-mkxp usage. The
     * managed-dir version takes priority since it represents
     * the host's curated rule set. Users who really want their
     * own patches today can edit the file there. (User-override
     * support without trampling the curated file is on the
     * roadmap.) */
    if (patches.empty()) {
        /* A host that set no managed directory hands back a null
         * pointer, which std::string must not be built from. */
        const char *managedPath = mkxp_getManagedConfigDir();
        std::string managedDir(managedPath ? managedPath : "");
        if (!managedDir.empty()) {
            std::string managed = managedDir + "/patches.json";
            std::ifstream check(managed.c_str());
            if (check.good()) {
                check.close();
                patcherLog("auto-discovered patches.json in managed dir " +
                           managedDir);
                load(managed.c_str());
                return;
            }
        }

        std::ifstream check("patches.json");
        if (check.good()) {
            check.close();
            patcherLog("auto-discovered patches.json in game folder");
            load("patches.json");
        } else {
            patcherLog("no explicit scriptPatches and no patches.json "
                       "found in managed dir or cwd");
        }
    } else {
        patcherLog("loaded " + std::to_string(patches.size()) +
                   " explicit scriptPatches path(s) from mkxp.json");
    }
}

void Patcher::load(const char *path)
{
    try {
        std::ifstream f(path);
        if (!f.is_open()) {
            patcherLog(std::string("could not open patch file ") + path);
            return;
        }

        std::stringstream buf;
        buf << f.rdbuf();
        json::value root = json::parse5(buf.str());

        if (!root.is_object()) {
            patcherLog(std::string(path) + ": top-level value is not an object");
            return;
        }

        auto &rootObj = root.as_object();
        auto it = rootObj.find("rpgm");
        if (it == rootObj.end() || !it->second.is_array()) {
            patcherLog(std::string(path) + ": missing/invalid \"rpgm\" array");
            return;
        }

        int count = 0;
        for (const auto &entry : it->second.as_array()) {
            if (!entry.is_object()) continue;
            auto &obj = entry.as_object();
            auto kit = obj.find("key");
            auto vit = obj.find("value");
            if (kit == obj.end() || vit == obj.end()) continue;
            if (!kit->second.is_string() || !vit->second.is_string()) continue;

            patchList.push_back({
                kit->second.as_string(),
                vit->second.as_string()
            });
            count++;
        }

        patcherLog(std::string("loaded ") + std::to_string(count) +
                   " patches from " + path);
    } catch (const std::exception &e) {
        patcherLog(std::string("failed to read ") + path + ": " + e.what());
    } catch (...) {
        patcherLog(std::string("failed to read ") + path);
    }
}

static bool replaceLiteralInPlace(std::string &subject,
                                  const std::string &search,
                                  const std::string &replace)
{
    if (search.empty()) return false;

    size_t pos = 0;
    int found = 0;
    while ((pos = subject.find(search, pos)) != std::string::npos) {
        subject.replace(pos, search.length(), replace);
        pos += replace.length();
        found++;
    }
    return found > 0;
}

void Patcher::apply(std::string &data) const
{
    static const std::string regexMarker = "[regex]";

    for (const auto &p : patchList) {
        if (p.key.rfind(regexMarker, 0) == 0) {
            try {
                std::regex re(p.key.substr(regexMarker.length()));
                std::string before = data;
                data = std::regex_replace(data, re, p.value);
                if (data != before)
                    patcherLog(std::string("applied regex ") + p.key);
            } catch (const std::regex_error &e) {
                patcherLog(std::string("invalid regex in patch ") + p.key +
                           ": " + e.what());
            }
        } else if (replaceLiteralInPlace(data, p.key, p.value)) {
            patcherLog(std::string("applied literal ") + p.key);
        }
    }
}
