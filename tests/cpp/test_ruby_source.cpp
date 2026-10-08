/*
** Tests for src/util/ruby-source.h.
**
** Postload scripts run before the last script section with code. A
** game whose last section only holds comments runs Main in the
** section before it, and Main never returns.
*/

#include "harness.h"

#include "util/ruby-source.h"

#include <string>

namespace {

bool hasCode(const std::string &src)
{
    return rubySourceHasCode(src.data(), src.size());
}

} // namespace

TEST(ruby_source_without_text_has_no_code)
{
    CHECK(!hasCode(""));
    CHECK(!hasCode(" \n\t\r\n"));
}

TEST(ruby_source_with_only_comments_has_no_code)
{
    CHECK(!hasCode("# end of scripts\n"));
    CHECK(!hasCode("# encoding: utf-8\n  # indented\n"));
}

TEST(ruby_source_in_a_block_comment_has_no_code)
{
    CHECK(!hasCode("=begin\nmain\n=end\n"));
    CHECK(!hasCode("=begin\nmain\n"));
}

TEST(ruby_source_with_a_statement_has_code)
{
    CHECK(hasCode("rgss_main { $scene.main }"));
    CHECK(hasCode("# Main\n  begin\n"));
    CHECK(hasCode("=begin\n=end\nmain\n"));
}

TEST(ruby_source_with_an_indented_begin_has_code)
{
    CHECK(hasCode("  =begin\n"));
}
