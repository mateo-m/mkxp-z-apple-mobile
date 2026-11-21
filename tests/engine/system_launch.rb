# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# System.launch with a web link and with a program name.
#
#   tools/run-engine-tests.sh --suite system_launch.rb
#
# The web link opens Safari, which sends the app to the background,
# where iOS can suspend it. So this suite runs in its own launch and
# finishes right after the link opens.
#
# This file must parse on Ruby 1.8, 1.9, and 3.x.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('system-launch', 2)

EngineTest.test('System.launch with a program name raises MKXPError') do
  EngineTest.assert_raises('notepad.exe', 'System.launch("notepad.exe")') { System.launch('notepad.exe') }
end

EngineTest.test('System.launch opens an https link and the game goes on') do
  EngineTest.assert_equal(nil, System.launch('https://example.com/?team=AQAI'), 'System.launch(https link)')
end

EngineTest.finish
exit
