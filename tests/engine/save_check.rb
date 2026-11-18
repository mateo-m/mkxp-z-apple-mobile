# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# MKXPSaveCheck on the interpreters that the engine ships. Marshal.load
# with a proc goes through the engine's own Marshal.load on Ruby 1.9
# and 3.1, and tools/test_save_check.rb runs only on the host Ruby.
#
#   tools/run-engine-tests.sh --suite save_check.rb --ruby 18
#
# This file must parse on all three.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('save-check', 5)

EngineTest.load_preloads(%w[save_check windows_fs])

unless defined?(RPG::AudioFile)
  module RPG
    class AudioFile
      attr_accessor :name

      def initialize(name = '', volume = 100, pitch = 100)
        @name = name
        @volume = volume
        @pitch = pitch
      end
    end
  end
end

CHECK_REPORTS = [] # rubocop:disable Style/MutableConstant -- the System stand-ins add to it.

class << System
  [:report_save_load, :report_save_rejected].each do |name| # rubocop:disable Style/SymbolArray -- %i is not on Ruby 1.8.
    next unless System.respond_to?(name)

    alias_method("_check_suite_#{name}", name)
    define_method(name) do |detail|
      CHECK_REPORTS.push([name, detail])
      send("_check_suite_#{name}", detail)
    end
  end
end

# rubocop:disable Security/MarshalLoad -- the suite loads only its own files.
CHECK_DIR = File.join(Dir.pwd, 'save_check_suite')
CHECK_GAME = File.join(CHECK_DIR, 'Game.rxdata')
CHECK_REJECTED = "#{CHECK_GAME}.mkxp-rejected".freeze
Dir.mkdir(CHECK_DIR) unless File.directory?(CHECK_DIR)

def check_read(path)
  File._mkxp_orig_open(path, 'rb', &:read)
end

def check_save(value)
  File.open(CHECK_GAME, 'wb') { |file| Marshal.dump(value, file) }
end

# Writes the file as the engine before #81 did, past the check.
def check_old_save(value)
  File._mkxp_orig_open(CHECK_GAME, 'wb') { |file| file.write(Marshal.dump(value)) }
end

def check_reset
  CHECK_REPORTS.clear
  File.delete(CHECK_REJECTED) if File._mkxp_orig_exist(CHECK_REJECTED)
end

EngineTest.test('the engine gives the save reports to the host') do
  EngineTest.assert(System.respond_to?(:_check_suite_report_save_load), 'System.report_save_load')
  EngineTest.assert(System.respond_to?(:_check_suite_report_save_rejected), 'System.report_save_rejected')
end

EngineTest.test('a save with a broken sound name keeps the old save and the refused file') do
  check_reset
  check_save(['Gold', RPG::AudioFile.new('Route 29')])
  good = check_read(CHECK_GAME)
  check_save(['Gold', RPG::AudioFile.new(0.75)])
  EngineTest.assert_equal(good, check_read(CHECK_GAME), 'save after the refused save')
  EngineTest.assert(File._mkxp_orig_exist(CHECK_REJECTED), 'the refused file stays')
  EngineTest.assert_equal([[:report_save_rejected, 'Game.rxdata: the @name of an RPG::AudioFile is a Float']],
                          CHECK_REPORTS, 'reports')
end

EngineTest.test('a correct save replaces the old one') do
  check_reset
  check_save(['Gold', RPG::AudioFile.new('Route 29')])
  check_save(['Gold', RPG::AudioFile.new('Route 30'), nil])
  saved = File.open(CHECK_GAME, 'rb') { |file| Marshal.load(file) }
  EngineTest.assert_equal('Route 30', saved[1].name, 'the new save')
  EngineTest.assert(!File._mkxp_orig_exist(CHECK_REJECTED), 'no refused file')
  EngineTest.assert_equal([[:report_save_load, 'Game.rxdata']], CHECK_REPORTS, 'reports')
end

EngineTest.test('a load repairs a broken sound name and reports one load for each file') do
  check_reset
  check_old_save(RPG::AudioFile.new([1, 2]))
  File._mkxp_orig_open(CHECK_GAME, 'ab') { |file| file.write(Marshal.dump(RPG::AudioFile.new(nil))) }
  names = File.open(CHECK_GAME, 'rb') { |file| [Marshal.load(file).name, Marshal.load(file).name] }
  EngineTest.assert_equal(['', nil], names, 'names after the load')
  EngineTest.assert_equal([[:report_save_load, 'Game.rxdata']], CHECK_REPORTS, 'reports')
end

EngineTest.test('a load with a game proc repairs the name and calls the proc') do
  check_reset
  check_old_save(['Gold', RPG::AudioFile.new(1.5)])
  seen = []
  game_proc = proc do |obj|
    seen.push(obj.name) if obj.is_a?(RPG::AudioFile)
    obj
  end
  saved = File.open(CHECK_GAME, 'rb') { |file| Marshal.load(file, game_proc) }
  EngineTest.assert_equal([''], seen, 'names that the game proc got')
  EngineTest.assert_equal('', saved[1].name, 'name after the load')
  check_save(saved)
  EngineTest.assert(!File._mkxp_orig_exist(CHECK_REJECTED), 'the next save is not refused')
end
# rubocop:enable Security/MarshalLoad

EngineTest.finish
exit
