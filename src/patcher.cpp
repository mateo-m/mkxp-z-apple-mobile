/*
** patcher.cpp
**
** Ports JoiPlay's Patcher. Parses each JSON file listed in
** `mkxp.json.patches`, pulls the "rpgm" array, and applies each
** entry as either a literal substring replacement or, if the
** key starts with "[regex]", as an ECMAScript regex replacement.
*/

#include "patcher.h"

#include "util/debugwriter.h"
#include "util/json5pp.hpp"

#include <fstream>
#include <regex>
#include <sstream>

namespace json = json5pp;

Patcher::Patcher(const std::vector<std::string> &patches)
{
    for (const std::string &patch : patches)
        load(patch.c_str());
}

void Patcher::load(const char *path)
{
    try {
        std::ifstream f(path);
        if (!f.is_open()) {
            Debug() << "Patcher: could not open patch file" << path;
            return;
        }

        std::stringstream buf;
        buf << f.rdbuf();
        json::value root = json::parse5(buf.str());

        if (!root.is_object())
            return;

        auto &rootObj = root.as_object();
        auto it = rootObj.find("rpgm");
        if (it == rootObj.end() || !it->second.is_array())
            return;

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

        Debug() << "Patcher: loaded" << count << "patches from" << path;
    } catch (const std::exception &e) {
        Debug() << "Patcher: failed to read" << path << ":" << e.what();
    } catch (...) {
        Debug() << "Patcher: failed to read" << path;
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
                    Debug() << "Patcher: applied regex" << p.key;
            } catch (const std::regex_error &e) {
                Debug() << "Patcher: invalid regex in patch" << p.key
                        << ":" << e.what();
            }
        } else if (replaceLiteralInPlace(data, p.key, p.value)) {
            Debug() << "Patcher: applied literal" << p.key;
        }
    }
}
