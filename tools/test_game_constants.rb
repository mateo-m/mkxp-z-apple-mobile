#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for the game-constant rule of the const_missing hook in
# platform_compat.rb. A constant that a later script section declares
# raises NameError, as on Windows, because games rescue it and take a
# fallback. Pokemon GS Vitro calls its language scene from section
# 202, the scene class is in section 215, and the stub made the
# chosen language a Class.
# Run: ruby mkxp-z-apple-mobile/tools/test_game_constants.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

prev_verbose = $VERBOSE
$VERBOSE = nil
begin
  load File.join(ROOT, 'scripts', 'preload', 'platform_compat.rb')
ensure
  $VERBOSE = prev_verbose
end

# The engine fills [3] with the decoded source and names each section
# "NNN:Name" when it evals it.
$RGSS_SCRIPTS = [
  [0, 'Skipped', '', "class SkippedWrapper\n  def self.ok; end\nend\n"],
  [0, 'PSystem_System', '', "LANGUAGES = []\n"],
  [0, 'Idioma Selector', '', "class LanguageScene < Object\nend\nSCENE_LIMIT = 4\n"],
  [0, 'Nested', '', "module Outer\n  class IndentedOnly\n  end\nend\n"]
]

def run_section(index, code)
  # rubocop:disable Security/Eval -- the engine evals each section the same way
  eval(code, TOPLEVEL_BINDING, "#{index.to_s.rjust(3, '0')}:#{$RGSS_SCRIPTS[index][1]}", 1)
  # rubocop:enable Security/Eval
end

language_section = <<-RUBY
  def choose_language
    LanguageScene.new.pick
  rescue StandardError
    :fallback
  end
  choose_language
RUBY
assert_eq(run_section(1, language_section), :fallback,
          'a class from a later section raises NameError, so the game falls back')

assert_eq(run_section(1, 'begin; SCENE_LIMIT; rescue NameError; :missing; end'), :missing,
          'a constant assigned in a later section raises NameError')

assert_eq(run_section(1, 'SkippedWrapper'), IOS::NullStub,
          'a class from a section that already ran and failed stays a stub')

assert_eq(run_section(1, 'IndentedOnly'), IOS::NullStub,
          'an indented declaration is not a top-level game constant')

assert_eq(run_section(1, 'NotInTheGame'), IOS::NullStub,
          'a name the game never declares stays a stub')

assert_eq(run_section(3, 'LanguageScene'), IOS::NullStub,
          'once the declaring section ran, a missing class is a stub again')

$RGSS_SCRIPTS = [[0, 'Other game', '', "class Unrelated\nend\n"],
                 [0, 'Idioma Selector', '', "class LanguageScene\nend\n"]]
assert_eq(run_section(0, 'begin; LanguageScene; rescue NameError; :missing; end'), :missing,
          'a new script list is read again')

test_passed('test_game_constants', 7)
