#!/usr/bin/env ruby
# Regression test for scripts/postload/pokemon_multi_save_paths.rb.
# The plugin under test splits System.data_directory on "\\" and
# replaces the last name. With "/" separators that drops the whole
# directory. The postload must put the name back under the parent
# of the data directory, and must create the game's own folder.
# Run: ruby mkxp-z-apple-mobile/tools/test_multi_save_paths.rb

require 'fileutils'
require 'tmpdir'
require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

TMP = Dir.mktmpdir('multi-save')
DATA_DIR = File.join(TMP, 'Data', 'Pokemon Entropy')
Dir.mkdir(File.join(TMP, 'Data'))
Dir.mkdir(DATA_DIR)

# The engine returns the data directory with a trailing "/".
module System
  def self.data_directory
    "#{DATA_DIR}/"
  end
end

# Scripts.rxdata defines the module before the postload runs.
module SaveData; end

load File.join(ROOT, 'scripts', 'postload', 'pokemon_multi_save_paths.rb')

# The plugin's own code, as shipped in Pokemon Entropic Eclipse,
# runs from Main after the postload.
$STORY_TO_RUN = 1
begin
  module SaveData
    SAVE_DIR = File.directory?(System.data_directory) ? System.data_directory : '.'

    def self.get_engine_saves(region = nil)
      if region.nil?
        region = case $STORY_TO_RUN
                 when 1 then 7
                 when 2 then 3
                 else 0
                 end
      end
      f = SAVE_DIR.split('\\')
      case region
      when 1 then nil
      when 3 then f[-1] = 'Pokemon Empathic Emerald'
      when 7 then f[-1] = 'Pokemon Entropic Eclipse'
      else f[-1] = 'Pokemon Entropy'
      end
      f.join('\\')
    end

    def self.get_full_path(file, region = nil)
      "#{get_engine_saves(region)}/#{file}.rxdata"
    end
  end

  own = File.join(TMP, 'Data', 'Pokemon Entropic Eclipse')
  assert_eq(SaveData.get_engine_saves, own, 'own saves sit next to the data directory')
  assert_eq(File.directory?(own), true, 'the own save folder exists after the first path build')
  assert_eq(SaveData.get_full_path('Slot1'), "#{own}/Slot1.rxdata", 'slot files join under the own folder')

  other = File.join(TMP, 'Data', 'Pokemon Empathic Emerald')
  assert_eq(SaveData.get_engine_saves(3), other, 'another game of the family resolves to its own sibling')
  assert_eq(File.directory?(other), false, 'a lookup of another game creates no folder')

  assert_eq(SaveData.get_engine_saves(1), "#{DATA_DIR}/",
            'a region without a rename keeps the data directory')

  File.write(File.join(own, 'Slot1.rxdata'), 'x')
  assert_eq(File.file?(SaveData.get_full_path('Slot1')), true,
            'a written slot is found again through the same path')
ensure
  FileUtils.rm_rf(TMP)
end

test_passed('test_multi_save_paths', 7)
