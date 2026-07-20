/*
** patcher.h
**
** Ports JoiPlay's Patcher class. Reads JSON files listed in
** `mkxp.json.scriptPatches` and applies literal / regex script
** replacements as each RGSS script section is loaded into the
** Ruby VM via newStringUTF8. Lets us ship per-game compat fixes
** (e.g. a single problematic line in a fangame) without
** modifying the game's own files.
**
** Patch file format:
**   { "rpgm": [ { "key": "<search>", "value": "<replace>" }, ... ] }
**
** If "key" starts with "[regex]" the remainder is treated as an
** ECMAScript regex (std::regex_replace semantics). Otherwise the
** replacement is a plain substring replace.
*/

#ifndef PATCHER_H
#define PATCHER_H

#include <string>
#include <vector>

class Patcher
{
public:
    struct Patch
    {
        std::string key;
        std::string value;
    };

    Patcher(const std::vector<std::string> &patches);
    void apply(std::string &data) const;

private:
    void load(const char *path);
    std::vector<Patch> patchList;
};

#endif // PATCHER_H
