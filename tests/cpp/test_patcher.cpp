/*
** Tests for src/patcher.cpp.
**
** The patcher rewrites RGSS script text as it loads, which is how a
** per-game compat fix ships without touching the game's own files. A
** patch that silently fails to apply looks exactly like a game that
** was never broken, so the failure modes below matter as much as the
** happy path.
*/

#include "harness.h"

#include "patcher.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

/* Writes patch files under a directory of its own and removes them
 * again. Tests must not leave files behind, and two tests must not
 * see each other's patches. */
class PatchDir
{
public:
    PatchDir()
    {
        char pattern[] = "/tmp/mkxp-cpp-tests-XXXXXX";
        const char *made = mkdtemp(pattern);
        path_ = made ? made : "";
    }

    ~PatchDir()
    {
        for (const std::string &file : files_)
            std::remove(file.c_str());
        if (!path_.empty())
            rmdir(path_.c_str());
    }

    const std::string &path() const { return path_; }

    /* Writes one file and returns its path.
     *
     * Every check below reads the file back. A write that quietly did
     * nothing would leave the patcher with no patch to apply, and the
     * "the patcher leaves this alone" cases would then pass for the
     * wrong reason. So this fails the case instead. */
    std::string write(const std::string &name, const std::string &body)
    {
        CHECK(!path_.empty());
        if (path_.empty())
            return std::string();

        std::string full = path_ + "/" + name;
        std::ofstream out(full.c_str());
        out << body;
        out.close();
        files_.push_back(full);

        std::ifstream back(full.c_str(), std::ios::binary);
        std::string written((std::istreambuf_iterator<char>(back)),
                            std::istreambuf_iterator<char>());
        CHECK_EQ(body, written);
        return full;
    }

private:
    std::string path_;
    std::vector<std::string> files_;
};

std::string patched(const std::vector<std::string> &paths,
                    const std::string &script)
{
    Patcher patcher(paths);
    std::string data = script;
    patcher.apply(data);
    return data;
}

const char *const ONE_LITERAL =
    "{ \"rpgm\": [ { \"key\": \"broken\", \"value\": \"fixed\" } ] }";

/* Every "the patcher ignores this file" case runs the same script
 * text that ONE_LITERAL rewrites. Pair the case with this control and
 * the assertion means something: the text stayed put because the file
 * held no usable patch, not because the patcher was never reached. */
void checkAValidPatchStillApplies(PatchDir &dir)
{
    std::string good = dir.write("control.json", ONE_LITERAL);
    CHECK_EQ(std::string("fixed"), patched({good}, "broken"));
}

} // namespace

TEST(patcher_replaces_every_occurrence_of_a_literal)
{
    PatchDir dir;
    std::string file = dir.write("patches.json", ONE_LITERAL);

    CHECK_EQ(std::string("a fixed and fixed line"),
             patched({file}, "a broken and broken line"));
}

TEST(patcher_leaves_a_script_alone_when_nothing_matches)
{
    PatchDir dir;
    std::string file = dir.write("patches.json", ONE_LITERAL);

    CHECK_EQ(std::string("nothing to do here"),
             patched({file}, "nothing to do here"));
    /* The same patcher input does rewrite the text it was given for. */
    CHECK_EQ(std::string("fixed"), patched({file}, "broken"));
}

TEST(patcher_treats_a_regex_key_as_a_pattern)
{
    PatchDir dir;
    std::string file = dir.write(
        "patches.json",
        "{ \"rpgm\": [ { \"key\": \"[regex]v([0-9]+)\", "
        "\"value\": \"version $1\" } ] }");

    CHECK_EQ(std::string("version 12 and version 3"),
             patched({file}, "v12 and v3"));
}

TEST(patcher_replaces_a_bracket_key_literally_without_the_regex_marker)
{
    PatchDir dir;
    std::string file = dir.write(
        "patches.json",
        "{ \"rpgm\": [ { \"key\": \"[abc]\", \"value\": \"x\" } ] }");

    /* A literal key that starts with a bracket must not become a
     * character class. Read as a regex, "[abc]" would hit all three
     * letters instead of the bracketed text. */
    CHECK_EQ(std::string("x and abc"), patched({file}, "[abc] and abc"));
}

TEST(patcher_skips_an_invalid_regex_and_keeps_going)
{
    PatchDir dir;
    std::string file = dir.write(
        "patches.json",
        "{ \"rpgm\": [ { \"key\": \"[regex](unclosed\", \"value\": \"x\" }, "
        "{ \"key\": \"broken\", \"value\": \"fixed\" } ] }");

    CHECK_EQ(std::string("fixed"), patched({file}, "broken"));
}

TEST(patcher_ignores_a_missing_file)
{
    /* Point at a path inside a directory that was just removed, so
     * the file cannot exist by accident. */
    std::string gone;
    {
        PatchDir dir;
        gone = dir.path() + "/patches.json";
    }
    CHECK(std::ifstream(gone.c_str()).fail());

    CHECK_EQ(std::string("broken"), patched({gone}, "broken"));

    PatchDir dir;
    checkAValidPatchStillApplies(dir);
}

TEST(patcher_ignores_a_file_that_is_not_json)
{
    PatchDir dir;
    std::string file = dir.write("patches.json", "this is not json at all");

    CHECK_EQ(std::string("broken"), patched({file}, "broken"));
    checkAValidPatchStillApplies(dir);
}

TEST(patcher_ignores_a_file_with_no_rpgm_array)
{
    PatchDir dir;
    std::string file = dir.write("patches.json", "{ \"other\": [] }");

    CHECK_EQ(std::string("broken"), patched({file}, "broken"));
    checkAValidPatchStillApplies(dir);
}

TEST(patcher_skips_entries_that_are_not_a_pair_of_strings)
{
    PatchDir dir;
    std::string file = dir.write(
        "patches.json",
        "{ \"rpgm\": [ { \"key\": 7, \"value\": \"x\" }, "
        "{ \"key\": \"only-a-key\" }, "
        "{ \"key\": \"broken\", \"value\": \"fixed\" } ] }");

    CHECK_EQ(std::string("fixed"), patched({file}, "broken"));
}

TEST(patcher_reads_every_file_it_is_given)
{
    PatchDir dir;
    std::string first = dir.write(
        "first.json",
        "{ \"rpgm\": [ { \"key\": \"one\", \"value\": \"1\" } ] }");
    std::string second = dir.write(
        "second.json",
        "{ \"rpgm\": [ { \"key\": \"two\", \"value\": \"2\" } ] }");

    CHECK_EQ(std::string("1 and 2"), patched({first, second}, "one and two"));
}

TEST(patcher_survives_an_empty_patch_list)
{
    /* With no explicit paths the patcher looks for a patches.json of
     * its own accord, first in the host-managed config directory and
     * then in the working directory. A host that set no managed
     * directory hands back a null pointer here. */
    CHECK_EQ(std::string("untouched"), patched({}, "untouched"));
}
