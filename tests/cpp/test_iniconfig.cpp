/*
** Tests for src/util/iniconfig.cpp.
**
** Every game ships a Game.ini, and the engine reads the title, the
** scripts path, and the library name out of it. A line the parser
** drops shows up to the player as a game with the wrong name or a
** game that will not boot.
*/

#include "harness.h"

#include "util/iniconfig.h"

#include <sstream>
#include <string>

namespace {

INIConfiguration parse(const std::string &text)
{
    std::istringstream in(text);
    INIConfiguration ini;
    ini.load(in);
    return ini;
}

std::string titleOf(const std::string &text)
{
    return parse(text).getStringProperty("Game", "Title", "<missing>");
}

} // namespace

TEST(iniconfig_reads_a_property_from_a_section)
{
    CHECK_EQ(std::string("Pokemon Example"),
             titleOf("[Game]\nTitle=Pokemon Example\n"));
}

TEST(iniconfig_matches_a_section_and_a_key_whatever_the_case)
{
    INIConfiguration ini = parse("[GAME]\nTITLE=Example\n");

    CHECK_EQ(std::string("Example"), ini.getStringProperty("game", "title"));
    CHECK_EQ(std::string("Example"), ini.getStringProperty("Game", "Title"));
}

TEST(iniconfig_returns_the_default_for_a_key_it_does_not_hold)
{
    CHECK_EQ(std::string("fallback"),
             parse("[Game]\nTitle=Example\n")
                 .getStringProperty("Game", "Library", "fallback"));
}

TEST(iniconfig_returns_the_default_for_a_section_it_does_not_hold)
{
    CHECK_EQ(std::string("fallback"),
             parse("[Game]\nTitle=Example\n")
                 .getStringProperty("Other", "Title", "fallback"));
}

TEST(iniconfig_reads_a_file_with_windows_line_endings)
{
    CHECK_EQ(std::string("Example"), titleOf("[Game]\r\nTitle=Example\r\n"));
}

TEST(iniconfig_trims_the_spaces_around_a_key_and_a_value)
{
    CHECK_EQ(std::string("Example"), titleOf("[Game]\n  Title  =  Example  \n"));
}

TEST(iniconfig_keeps_the_spaces_inside_a_value)
{
    CHECK_EQ(std::string("A Long Game Name"),
             titleOf("[Game]\nTitle=A Long Game Name\n"));
}

TEST(iniconfig_keeps_an_equals_sign_inside_a_value)
{
    CHECK_EQ(std::string("a=b"), titleOf("[Game]\nTitle=a=b\n"));
}

TEST(iniconfig_ignores_a_comment_line)
{
    CHECK_EQ(std::string("Example"),
             titleOf("[Game]\n# Title=Wrong\nTitle=Example\n"));
}

TEST(iniconfig_ignores_a_blank_line)
{
    CHECK_EQ(std::string("Example"), titleOf("[Game]\n\n\nTitle=Example\n"));
}

TEST(iniconfig_reads_the_last_line_when_the_file_has_no_trailing_newline)
{
    /* A hand-edited Game.ini often ends without a newline. The title
     * is usually the only line in the file, so losing the last line
     * loses the whole game name. */
    CHECK_EQ(std::string("Example"), titleOf("[Game]\nTitle=Example"));
}

TEST(iniconfig_keeps_the_sections_apart)
{
    INIConfiguration ini =
        parse("[Game]\nTitle=Right\n[Other]\nTitle=Wrong\n");

    CHECK_EQ(std::string("Right"), ini.getStringProperty("Game", "Title"));
    CHECK_EQ(std::string("Wrong"), ini.getStringProperty("Other", "Title"));
}

TEST(iniconfig_takes_the_last_value_when_a_key_repeats)
{
    CHECK_EQ(std::string("Second"),
             titleOf("[Game]\nTitle=First\nTitle=Second\n"));
}

TEST(iniconfig_reads_an_empty_file_without_failing)
{
    CHECK_EQ(std::string("<missing>"), titleOf(""));
}

TEST(iniconfig_reports_success_for_a_stream_it_could_read)
{
    std::istringstream in("[Game]\nTitle=Example\n");
    INIConfiguration ini;

    CHECK(ini.load(in));
    CHECK_EQ(std::string("Example"), ini.getStringProperty("Game", "Title"));
}

TEST(iniconfig_ignores_a_line_with_no_equals_sign)
{
    /* The stray line must not swallow the line after it. */
    CHECK_EQ(std::string("Example"),
             titleOf("[Game]\nthis line has no equals sign\nTitle=Example\n"));
}

TEST(iniconfig_keeps_a_key_written_before_any_section)
{
    /* A key ahead of the first header lands in the unnamed section.
     * It must not leak into [Game], or a stray line at the top of a
     * hand-edited file would override the real title. */
    INIConfiguration ini = parse("Title=Loose\n[Game]\nTitle=Real\n");

    CHECK_EQ(std::string("Real"), ini.getStringProperty("Game", "Title"));
    CHECK_EQ(std::string("Loose"), ini.getStringProperty("", "Title"));
}

TEST(iniconfig_keeps_the_case_of_a_value)
{
    /* Sections and keys fold to lower case. Values must not, or every
     * game title would arrive in lower case. */
    CHECK_EQ(std::string("PokEMon ExAMple"),
             titleOf("[Game]\nTitle=PokEMon ExAMple\n"));
}
