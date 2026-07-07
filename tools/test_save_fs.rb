#!/usr/bin/env ruby
# Unit tests for MKXPSaveFS save-path remapping in platform_compat.rb.
# Run: ruby mkxp-z-apple-mobile/tools/test_save_fs.rb

require 'fileutils'

ROOT = File.expand_path('..', __dir__)
WORK = File.expand_path('test_save_fs_workspace', __dir__)
USERDATA = File.join(WORK, 'UserData')
GAME = File.join(WORK, 'Game')

def reset_workspace!
  FileUtils.rm_rf(WORK)
  FileUtils.mkdir_p(USERDATA)
  FileUtils.mkdir_p(GAME)
end

def load_platform_compat!
  reset_workspace!
  Object.send(:remove_const, :System) if defined?(System)
  Object.const_set(:System, Module.new do
    module_function

    define_method(:data_directory) { USERDATA }
    define_method(:puts) { |*args| Kernel.puts(*args) }
  end)
  unless Kernel.method_defined?(:load_data)
    Kernel.module_eval do
      def load_data(_path, *_args); end
      def save_data(_obj, _path, *_args); end
    end
  end
  load File.join(ROOT, 'scripts', 'preload', 'platform_compat.rb')
end

def assert_eq(actual, expected, label)
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

def assert_true(value, label)
  assert_eq(value, true, label)
end

def assert_false(value, label)
  assert_eq(value, false, label)
end

load_platform_compat!

base = MKXPSaveFS.root
assert_eq(base, USERDATA, 'root')

assert_eq(
  MKXPSaveFS.path_for('Save01.rvdata2'),
  File.join(USERDATA, 'Save01.rvdata2'),
  'bare save filename'
)
assert_eq(
  MKXPSaveFS.path_for('Save/Save01.rvdata2'),
  File.join(USERDATA, 'Save01.rvdata2'),
  'Save/ prefix flatten'
)
assert_eq(
  MKXPSaveFS.path_for('Save Data/Save01.rvdata2'),
  File.join(USERDATA, 'Save01.rvdata2'),
  'Save Data/ prefix flatten'
)
assert_eq(
  MKXPSaveFS.path_for('Save\\Save01.rvdata2'),
  File.join(USERDATA, 'Save01.rvdata2'),
  'backslash path'
)
assert_eq(MKXPSaveFS.path_for('Save'), USERDATA, 'save directory')

twice = MKXPSaveFS.path_for(MKXPSaveFS.path_for('Save/Save01.rvdata2'))
assert_eq(twice, File.join(USERDATA, 'Save01.rvdata2'), 'idempotent path_for')

assert_eq(MKXPSaveFS.path_for('Data/Map001.rvdata2'), 'Data/Map001.rvdata2', 'non-save passthrough')
assert_eq(MKXPSaveFS.path_for('/etc/passwd'), '/etc/passwd', 'absolute passthrough')

File.write(File.join(USERDATA, 'Save01.rvdata2'), 'x')
assert_eq(
  MKXPSaveFS.glob_for('Save Data/*.rvdata2'),
  File.join(USERDATA, '*.rvdata2'),
  'glob remap tail'
)
globbed = MKXPSaveFS.normalize_glob_results(
  [File.join(USERDATA, 'Save01.rvdata2')],
  'Save Data/*.rvdata2'
)
assert_eq(globbed, ['Save Data/Save01.rvdata2'], 'glob prefix echo')

FileUtils.mkdir_p(File.join(GAME, 'Save'))
shipped = File.join(GAME, 'Save', 'Save02.rvdata2')
File.write(shipped, 'shipped')
Dir.chdir(GAME) do
  assert_eq(
    MKXPSaveFS.path_for('Save/Save02.rvdata2'),
    'Save/Save02.rvdata2',
    'read-fallback to Game/Save'
  )
end

File.write(File.join(USERDATA, 'keybindings.mkxp3'), '')
File.write(File.join(USERDATA, 'Save03.rvdata2'), 'x')
entries = MKXPSaveFS.filter_dir_entries(Dir.entries(USERDATA))
assert_false(entries.include?('keybindings.mkxp3'), 'engine file filtered')
assert_true(entries.include?('Save03.rvdata2'), 'save file kept')

assert_true(File.exist?('Save01.rvdata2'), 'File.exist? remapped')
assert_true(FileTest.exist?('Save01.rvdata2'), 'FileTest.exist? remapped')
assert_true(Dir.exist?('Save'), 'Dir.exist? save folder')

Dir.chdir(GAME) do
  assert_eq(Dir.mkdir('Save'), 0, 'Dir.mkdir Save no-op')
end

puts 'OK: test_save_fs.rb passed'
