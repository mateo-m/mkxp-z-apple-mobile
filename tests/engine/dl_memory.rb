# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Hime's full keyboard script (LonaRPG) keeps the key states in
# `DL::CPtr.new(DL.malloc(256), 256)` and passes `ptr.to_i` to
# GetKeyboardState.
#
#   tools/run-engine-tests.sh --suite dl_memory.rb --ruby 19
#
# This file must parse on Ruby 1.8, 1.9 and 3.1.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('dl-memory', 3)

EngineTest.load_preloads(%w[windows_fs platform_compat win32_wrap])

EngineTest.test('two DL.malloc calls give two addresses') do
  EngineTest.refute_equal(DL.malloc(4), DL.malloc(4), 'second address')
end

EngineTest.test('a DL::CPtr keeps the bytes of its address') do
  address = DL.malloc(4)
  DL::CPtr.new(address, 4)[2] = 0x1ff
  EngineTest.assert_equal([0, 0, 0xff, 0], (0...4).map { |i| DL::CPtr.new(address)[i] }, 'bytes')
end

EngineTest.test('GetKeyboardState writes to the address of a DL::CPtr') do
  state = DL::CPtr.new(DL.malloc(256), 256)
  256.times { |i| state[i] = 0xff }
  result = Win32API.new('user32.dll', 'GetKeyboardState', 'I', 'I').call(state.to_i)
  EngineTest.assert_equal(1, result, 'GetKeyboardState result')
  # No key is down in the test host.
  EngineTest.assert_equal(0, state[0x41], 'state of the A key')
end

EngineTest.finish
exit
