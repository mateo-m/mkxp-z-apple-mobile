# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The Ruby 1.8 build reports the Ruby version of RPG Maker XP and VX.
# Zeus Video Player v2.3 takes any version other than 1.8.1 for VX Ace
# and calls String#force_encoding, which Ruby 1.8 does not have.
#
#   tools/run-engine-tests.sh --suite rgss_ruby_version.rb --ruby 18
#
# This file must parse on Ruby 1.8.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('rgss-ruby-version', 2)

EngineTest.test('RUBY_VERSION is 1.8.1 on Ruby 1.8') do
  EngineTest.assert_equal('1.8', System.ruby_version, 'interpreter')
  EngineTest.assert_equal('1.8.1', RUBY_VERSION, 'RUBY_VERSION')
end

EngineTest.test('VERSION is the same as RUBY_VERSION') do
  EngineTest.assert_equal(RUBY_VERSION, VERSION, 'VERSION')
end

EngineTest.finish
exit
