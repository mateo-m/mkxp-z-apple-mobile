# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# MKXPSafeWrite on the interpreters that the engine ships. Thread
# stops and Dir readers differ between Ruby 1.8, 1.9 and 3.1, and
# tools/test_safe_write.rb runs only on the host Ruby.
#
#   tools/run-engine-tests.sh --suite safe_write.rb --ruby 18
#
# This file must parse on all three.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('safe-write', 7)

EngineTest.load_preloads(%w[windows_fs])

# rubocop:disable Style/FileWrite, Style/FileRead -- File.binread and
# File.binwrite are not on Ruby 1.8.
SAFE_DIR = File.join(Dir.pwd, 'safe_write_suite')
SAFE_GAME = File.join(SAFE_DIR, 'Game.rxdata')
Dir.mkdir(SAFE_DIR) unless File.directory?(SAFE_DIR)

def safe_save(text)
  File.open(SAFE_GAME, 'wb') { |file| file.write(text) }
end

def safe_read
  File.open(SAFE_GAME, 'rb', &:read)
end

def safe_temp_files
  Dir._mkxp_orig_entries(SAFE_DIR).grep(/\.mkxp-tmp\z/)
end

def during_save
  result = nil
  File.open(SAFE_GAME, 'wb') do |file|
    file.write('during')
    result = yield
  end
  result
end

EngineTest.test('a save that raises keeps the old file') do
  safe_save('before')
  begin
    File.open(SAFE_GAME, 'wb') do |file|
      file.write('HALF')
      raise IOError, 'stop'
    end
  rescue IOError
    nil
  end
  EngineTest.assert_equal('before', safe_read, 'save after the error')
  EngineTest.assert_equal([], safe_temp_files, 'temp files after the error')
end

def stopped_save(how)
  safe_save('before kill')
  started = false
  saver = Thread.new do
    File.open(SAFE_GAME, 'wb') do |file|
      file.write('HALF')
      started = true
      how == :exit ? Thread.exit : sleep
    end
  end
  Thread.pass until started
  saver.kill if how == :kill
  Thread.kill(saver) if how == :class_kill
  saver.join
  EngineTest.assert_equal('before kill', safe_read, "save after #{how}")
  EngineTest.assert_equal([], safe_temp_files, "temp files after #{how}")
end

EngineTest.test('a save on a stopped thread keeps the old file') do
  stopped_save(:kill)
  stopped_save(:class_kill)
  stopped_save(:exit)
end

EngineTest.test('a save that ends before a deferred kill writes the new file') do
  if Thread.respond_to?(:handle_interrupt)
    safe_save('before deferred')
    ready = false
    go = false
    saver = Thread.new do
      Thread.handle_interrupt(Object => :never) do
        File.open(SAFE_GAME, 'wb') do |file|
          ready = true
          Thread.pass until go
          file.write('deferred')
        end
      end
    end
    Thread.pass until ready
    saver.kill
    go = true
    saver.join
    EngineTest.assert_equal('deferred', safe_read, 'save after a deferred kill')
  else
    EngineTest.assert_equal(false, Thread.respond_to?(:handle_interrupt),
                            'no handle_interrupt before Ruby 2.0')
  end
end

EngineTest.test('the Dir class lists hide the temp file') do
  entries = during_save { Dir.entries(SAFE_DIR) }
  EngineTest.assert_equal(['Game.rxdata'], entries - ['.', '..'], 'Dir.entries')
  found = []
  returned = during_save { Dir.foreach(SAFE_DIR) { |name| found.push(name) } }
  EngineTest.assert_equal(['Game.rxdata'], found - ['.', '..'], 'Dir.foreach')
  EngineTest.assert_equal(nil, returned, 'Dir.foreach with a block')
end

EngineTest.test('a Dir object hides the temp file') do
  each = during_save { Dir.open(SAFE_DIR, &:to_a) }
  EngineTest.assert_equal(['Game.rxdata'], each - ['.', '..'], 'Dir#each')
  read = during_save do
    Dir.open(SAFE_DIR) do |dir|
      names = []
      while (name = dir.read)
        names.push(name)
      end
      names
    end
  end
  EngineTest.assert_equal(['Game.rxdata'], read - ['.', '..'], 'Dir#read')
end

EngineTest.test('Dir#each_child hides the temp file and stops where the block breaks') do
  if Dir.method_defined?(:each_child)
    children = during_save { Dir.open(SAFE_DIR) { |dir| dir.each_child.to_a } }
    EngineTest.assert_equal(['Game.rxdata'], children, 'Dir#each_child')
    File.open(File.join(SAFE_DIR, 'Other.rxdata'), 'wb') { |file| file.write('other') }
    rest = Dir.open(SAFE_DIR) do |dir|
      dir.each_child { break } # rubocop:disable Lint/UnreachableLoop
      dir.read
    end
    EngineTest.assert(!rest.nil?, 'Dir#read after a break in Dir#each_child')
  else
    EngineTest.assert_equal(false, Dir.method_defined?(:each_child), 'no Dir#each_child before Ruby 2.6')
  end
end

EngineTest.test('the save writes the new text') do
  safe_save('after')
  EngineTest.assert_equal('after', safe_read, 'save after a normal write')
end
# rubocop:enable Style/FileWrite, Style/FileRead

EngineTest.finish
exit
