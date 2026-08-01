#!/usr/bin/env ruby
# Unit tests for MKXPSaveFS save-path handling in platform_compat.rb:
# bare-filename remap into UserData, literal portable "Save Data",
# UserData-root protections, and the alias->literal save migration.
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

# platform_compat.rb targets the in-game VMs (1.8 / 1.9 / 3.1), which
# all still have the `exists?` aliases; Ruby 3.2 removed them. Restore
# them so this harness also runs on a modern host Ruby.
def ensure_ruby31_compat_aliases!
  class << File
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
  FileTest.singleton_class.class_eval do
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
  class << Dir
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
end

# Loads (or reloads) platform_compat.rb. Does NOT reset the
# workspace - callers seed files first so the boot-time portable-save
# migration sees them, and must chdir into GAME when the migration's
# cwd-relative behavior is under test.
def load_platform_compat!(joiplay = false)
  ensure_ruby31_compat_aliases!
  Object.send(:remove_const, :System) if defined?(System)
  Object.const_set(:System, Module.new do
    module_function

    define_method(:data_directory) { USERDATA }
    define_method(:puts) { |*args| Kernel.puts(*args) }
    define_method(:joiplay_compat?) { joiplay }
  end)
  unless Kernel.method_defined?(:load_data)
    Kernel.module_eval do
      def load_data(_path, *_args); end
      def save_data(_obj, _path, *_args); end
    end
  end
  # Reloading the whole file re-evaluates constants that production
  # only defines once per VM; silence the redefinition warnings.
  prev_verbose = $VERBOSE
  $VERBOSE = nil
  begin
    load File.join(ROOT, 'scripts', 'preload', 'platform_compat.rb')
  ensure
    $VERBOSE = prev_verbose
  end
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

# Raw filesystem probes that bypass every wrapper.
def raw_entries(dir)
  Dir._mkxp_orig_entries(dir)
end

def raw_dir?(path)
  File._mkxp_orig_directory(path)
end

def set_mtime(path, time)
  File.utime(time, time, path)
end

reset_workspace!
load_platform_compat!

base = MKXPSaveFS.root
assert_eq(base, USERDATA, 'root')

# --- Every path resolves literally ---
[
  'Save01.rvdata2', 'Save/Save01.rvdata2', 'Save Data/Save01.rvdata2',
  'Save', 'Data/Map001.rvdata2', '/etc/passwd'
].each do |path|
  assert_eq(MKXPSaveFS.path_for(path), path, "literal path_for: #{path}")
end

# --- UserData root listings hide engine-internal entries ---
File.write(File.join(USERDATA, 'keybindings.mkxp3'), '')
File.write(File.join(USERDATA, 'Save03.rvdata2'), 'x')
entries = Dir.entries(USERDATA)
assert_false(entries.include?('keybindings.mkxp3'), 'engine file filtered')
assert_true(entries.include?('Save03.rvdata2'), 'save file kept')
root_list = Dir.entries("#{USERDATA}/")
assert_false(root_list.include?('keybindings.mkxp3'), 'data_directory listing filters engine file')
assert_true(root_list.include?('Save03.rvdata2'), 'data_directory listing keeps saves')

# --- UserData root is host-owned: mkdir/rmdir no-op, never destroy ---
assert_eq(Dir.mkdir(USERDATA), 0, 'mkdir of root no-op')
assert_eq(Dir.mkdir("#{USERDATA}/"), 0, 'mkdir of root (trailing sep) no-op')
assert_eq(Dir.rmdir(USERDATA), 0, 'rmdir of root no-op')
assert_eq(Dir.delete("#{USERDATA}/"), 0, 'Dir.delete of root no-op')
assert_true(raw_dir?(USERDATA), 'UserData survives root rmdir')

# --- Portable mode is literal: the Rejuvenation PBDebug flow ---
#   getSaveFolder: Dir.mkdir("Save Data/") unless File.exists?("Save Data/")
#   PBDebug:       Dir.mkdir("Save Data/" + "Battle Debug Logs/") unless ...
# Both must really create directories in the game folder, like on
# Windows/JoiPlay.
Dir.chdir(GAME) do
  # rubocop:disable Lint/DeprecatedClassMethods -- the deprecated
  # aliases are exactly what Reborn-lineage getSaveFolder/PBDebug
  # call; exercise their wrappers.
  assert_false(File.exists?('Save Data/'), 'portable dir absent before mkdir')
  assert_false(Dir.exist?('Save Data/'), 'Dir.exist? portable dir absent')
  Dir.mkdir('Save Data/')
  assert_true(raw_dir?(File.join(GAME, 'Save Data')), 'portable dir created in game folder')
  assert_true(Dir.exist?('Save Data'), 'Dir.exist? sees literal portable dir')
  assert_true(Dir.exists?('Save Data'), 'Dir.exists? sees literal portable dir')

  logdir = 'Save Data/Battle Debug Logs/'
  assert_false(File.exists?(logdir), 'log subdir absent before mkdir')
  # rubocop:enable Lint/DeprecatedClassMethods
  Dir.mkdir(logdir)
  assert_true(
    raw_dir?(File.join(GAME, 'Save Data', 'Battle Debug Logs')),
    'log subdir created in game folder'
  )

  logfile = "#{logdir}battlelog - test.txt"
  File.open(logfile, 'a+b') { |f| f.write("x\r\n") }
  assert_true(
    File.exist?(File.join(GAME, 'Save Data', 'Battle Debug Logs', 'battlelog - test.txt')),
    'log file written in game folder'
  )
  assert_false(
    raw_entries(USERDATA).include?('Battle Debug Logs'),
    'UserData untouched by portable logging'
  )

  assert_true(
    Dir.entries('Save Data/Battle Debug Logs').include?('battlelog - test.txt'),
    'entries lists literal log subdir'
  )
  assert_true(
    Dir.children('Save Data').include?('Battle Debug Logs'),
    'children lists literal portable dir'
  )
  ngplus = []
  Dir.each_child('Save Data/') { |entry| ngplus << entry }
  assert_true(ngplus.include?('Battle Debug Logs'), 'each_child lists literal portable dir')

  globbed = Dir.glob('Save Data/Battle Debug Logs/battlelog - *.txt')
  assert_eq(globbed.length, 1, 'glob finds literal log file')
  File.delete(globbed[0])
  Dir.rmdir(logdir)
  Dir.rmdir('Save Data')
  assert_false(raw_entries(GAME).include?('Save Data'), 'game can remove its portable dir')

  plain = File.join(GAME, 'PlainDir')
  Dir.mkdir(plain)
  File.write(File.join(plain, 'a.txt'), '')
  assert_true(Dir.children('PlainDir').include?('a.txt'), 'children passthrough')
  passthrough = []
  Dir.each_child('PlainDir') { |entry| passthrough << entry }
  assert_true(passthrough.include?('a.txt'), 'each_child passthrough')
end

# --- Migration: $joiplay boot moves alias-era root saves into the
# literal portable dir ---
reset_workspace!
File.write(File.join(USERDATA, 'Game.rxdata'), 'active root save')
File.write(File.join(USERDATA, 'Save 1 - Aevis - 5h 3m - 2 badges.rxdata'), 'slot')
File.write(File.join(USERDATA, 'Game.rxdata.bak'), 'root backup')
File.write(File.join(USERDATA, 'keybindings.mkxp3'), '')
File.write(File.join(USERDATA, 'notes.txt'), 'not a save')
Dir.chdir(GAME) { load_platform_compat!(true) }

migrated = File.join(GAME, 'Save Data')
assert_true(raw_dir?(migrated), 'migration created portable dir')
assert_eq(File.read(File.join(migrated, 'Game.rxdata')), 'active root save', 'save migrated')
assert_true(
  raw_entries(migrated).include?('Save 1 - Aevis - 5h 3m - 2 badges.rxdata'),
  'slot save migrated'
)
assert_true(raw_entries(migrated).include?('Game.rxdata.bak'), 'backup migrated')
leftover = raw_entries(USERDATA)
assert_false(leftover.include?('Game.rxdata'), 'root save gone after migration')
assert_true(leftover.include?('keybindings.mkxp3'), 'engine file stays at root')
assert_true(leftover.include?('notes.txt'), 'non-save file stays at root')

# Reload with the folder in place: nothing further moves.
File.write(File.join(USERDATA, 'Save03.rvdata2'), 'post-migration root save')
Dir.chdir(GAME) { load_platform_compat!(true) }
assert_true(
  raw_entries(migrated).include?('Save03.rvdata2'),
  'later root saves keep migrating on boot'
)

# --- Migration collision, alias-era shape: the root copy is the
# newer alias-active save, it wins; the stale literal copy is kept
# as *.pre-literal.bak ---
reset_workspace!
FileUtils.mkdir_p(File.join(GAME, 'Save Data'))
File.write(File.join(GAME, 'Save Data', 'Game.rxdata'), 'old literal save')
set_mtime(File.join(GAME, 'Save Data', 'Game.rxdata'), Time.now - 86_400)
File.write(File.join(USERDATA, 'Game.rxdata'), 'root active save')
Dir.chdir(GAME) { load_platform_compat!(true) }
assert_eq(
  File.read(File.join(GAME, 'Save Data', 'Game.rxdata')),
  'root active save',
  'collision: newer root copy wins'
)
assert_eq(
  File.read(File.join(GAME, 'Save Data', 'Game.rxdata.pre-literal.bak')),
  'old literal save',
  'collision: stale literal copy kept as backup'
)

# --- Migration collision, post-literal shape: a stale save-shaped
# straggler at the root must NOT displace the newer save the player
# has since written into the literal folder ---
reset_workspace!
FileUtils.mkdir_p(File.join(GAME, 'Save Data'))
File.write(File.join(GAME, 'Save Data', 'Game.rxdata'), 'current literal save')
File.write(File.join(USERDATA, 'Game.rxdata'), 'stale root save')
set_mtime(File.join(USERDATA, 'Game.rxdata'), Time.now - 86_400)
Dir.chdir(GAME) { load_platform_compat!(true) }
assert_eq(
  File.read(File.join(GAME, 'Save Data', 'Game.rxdata')),
  'current literal save',
  'collision: newer literal save keeps canonical name'
)
assert_eq(
  File.read(File.join(GAME, 'Save Data', 'Game.rxdata.pre-literal.bak')),
  'stale root save',
  'collision: stale root copy archived'
)
assert_false(
  raw_entries(USERDATA).include?('Game.rxdata'),
  'collision: root straggler removed either way'
)

# --- Migration gate: .portable marker triggers it without $joiplay ---
reset_workspace!
FileUtils.mkdir_p(File.join(GAME, 'Save Data'))
File.write(File.join(GAME, 'Save Data', '.portable'), '')
File.write(File.join(USERDATA, 'Game.rxdata'), 'marker save')
Dir.chdir(GAME) { load_platform_compat!(false) }
assert_eq(
  File.read(File.join(GAME, 'Save Data', 'Game.rxdata')),
  'marker save',
  'marker-gated migration ran'
)

# --- Migration gate: non-portable boots leave root saves alone ---
reset_workspace!
File.write(File.join(USERDATA, 'Game.rxdata'), 'non-portable save')
Dir.chdir(GAME) { load_platform_compat!(false) }
assert_true(raw_entries(USERDATA).include?('Game.rxdata'), 'non-portable root save untouched')
assert_false(raw_entries(GAME).include?('Save Data'), 'non-portable boot creates no portable dir')

# --- Legacy-save recovery ---
# Earlier builds redirected bare working-directory save names into
# UserData, so upgraded installs have saves stranded at the UserData
# root. The first bare-name access (probe, read, glob, load_data)
# moves the stranded copy into the game folder; after that every
# operation is literal. Modern games address UserData by absolute
# path and never trigger it.
reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
File.write(File.join(USERDATA, 'Game.rxdata'), 'stranded save')
File.write(File.join(USERDATA, 'keybindings.mkxp3'), '')
Dir.chdir(GAME) do
  assert_true(File.exist?('Game.rxdata'), 'probe recovers the stranded save')
  assert_true(raw_entries(GAME).include?('Game.rxdata'), 'save now lives in the game folder')
  assert_false(raw_entries(USERDATA).include?('Game.rxdata'), 'root copy gone')
  assert_eq(File.read('Game.rxdata'), 'stranded save', 'recovered content intact')

  # New writes are literal from the first byte.
  File.write('Save05.rxdata', 'fresh')
  assert_true(raw_entries(GAME).include?('Save05.rxdata'), 'new save lands in the game folder')
  assert_false(raw_entries(USERDATA).include?('Save05.rxdata'), 'UserData untouched by new writes')
  assert_eq(File.binread('Save05.rxdata'), 'fresh', 'binread agrees with the write')
end

# Recovery through glob: a bare save pattern sweeps matching stranded
# saves in before the literal glob, so slot enumeration and the open
# that follows agree. Engine-internal files never move.
File.write(File.join(USERDATA, 'Save06.rxdata'), 'stranded slot')
Dir.chdir(GAME) do
  listed = Dir.glob('*.rxdata')
  assert_true(listed.include?('Save06.rxdata'), 'glob lists the recovered slot')
  assert_true(raw_entries(GAME).include?('Save06.rxdata'), 'glob recovery moved the file')
  assert_eq(File.read('Save06.rxdata'), 'stranded slot', 'glob-recovered content intact')

  Dir.glob('*')
  assert_true(
    raw_entries(USERDATA).include?('keybindings.mkxp3'),
    'bare * glob cannot drag engine files into the game folder'
  )
end

# Recovery through load_data (how ancient games load saves).
File.write(File.join(USERDATA, 'Save07.rxdata'), 'loadable')
Dir.chdir(GAME) do
  load_data('Save07.rxdata')
  assert_true(raw_entries(GAME).include?('Save07.rxdata'), 'load_data recovers the stranded save')
end

# Collision: the newer copy keeps the canonical name; the loser is
# kept as *.pre-literal.bak. Shipped starter save vs real progress:
reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
File.write(File.join(GAME, 'Game.rxdata'), 'shipped starter')
set_mtime(File.join(GAME, 'Game.rxdata'), Time.now - 86_400)
File.write(File.join(USERDATA, 'Game.rxdata'), 'real progress')
Dir.chdir(GAME) do
  assert_eq(File.read('Game.rxdata'), 'real progress', 'newer stranded save wins the name')
  assert_eq(
    File._mkxp_orig_open('Game.rxdata.pre-literal.bak', 'rb', &:read),
    'shipped starter',
    'starter save kept as backup'
  )
end

# Reverse collision: a stale root straggler must not displace the
# save the player has since written into the game folder.
reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
File.write(File.join(GAME, 'Game.rxdata'), 'current save')
File.write(File.join(USERDATA, 'Game.rxdata'), 'stale straggler')
set_mtime(File.join(USERDATA, 'Game.rxdata'), Time.now - 86_400)
Dir.chdir(GAME) do
  assert_eq(File.read('Game.rxdata'), 'current save', 'current save keeps the name')
  assert_true(raw_entries(GAME).include?('Game.rxdata.pre-literal.bak'), 'straggler archived')
  assert_false(raw_entries(USERDATA).include?('Game.rxdata'), 'root straggler removed')
end

# Modern games: absolute UserData paths never trigger recovery.
reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
modern = File.join(USERDATA, 'Game.rvdata2')
File.write(modern, 'modern save')
Dir.chdir(GAME) do
  assert_true(File.exist?(modern), 'absolute UserData probe works')
  assert_eq(File.read(modern), 'modern save', 'absolute UserData read works')
  assert_true(raw_entries(USERDATA).include?('Game.rvdata2'), 'modern save stays in UserData')
  assert_false(raw_entries(GAME).include?('Game.rvdata2'), 'modern save never moves')

  # Non-save globs stay fully literal.
  File.write(File.join(GAME, 'readme.txt'), '')
  assert_eq(Dir.glob('*.txt'), ['readme.txt'], 'non-save glob passthrough')
end

# --- Cross-API consistency matrix ---
# The property every savefs bug in this file's history violated:
# every wrapped API must agree about where a given path points. The
# matrix deliberately does NOT assert where anything lands on disk -
# the targeted tests above own that - only that create/probe/write/
# read/enumerate/delete see one coherent world through every spelling
# a game might use. New wrappers must be added to these API lists.
# rubocop:disable Lint/DeprecatedClassMethods -- the deprecated
# spellings are part of the API surface games call; the matrix must
# hold for them too.
FILE_PROBES = {
  'File.exist?' => lambda { |p| File.exist?(p) },
  'File.exists?' => lambda { |p| File.exists?(p) },
  'FileTest.exist?' => lambda { |p| FileTest.exist?(p) },
  'FileTest.exists?' => lambda { |p| FileTest.exists?(p) },
  'File.file?' => lambda { |p| File.file?(p) }
}.freeze
DIR_PROBES = {
  'Dir.exist?' => lambda { |p| Dir.exist?(p) },
  'Dir.exists?' => lambda { |p| Dir.exists?(p) },
  'File.directory?' => lambda { |p| File.directory?(p) },
  'FileTest.directory?' => lambda { |p| FileTest.directory?(p) }
}.freeze
# rubocop:enable Lint/DeprecatedClassMethods
FILE_READERS = {
  'File.read' => lambda { |p| File.read(p) },
  'File.binread' => lambda { |p| File.binread(p) },
  # rubocop:disable Style/FileRead -- File.open IS the API under comparison.
  'File.open' => lambda { |p| File.open(p, 'rb', &:read) },
  # rubocop:enable Style/FileRead
  'File.readlines' => lambda { |p| File.readlines(p).join }
}.freeze
DIR_LISTERS = {
  'Dir.entries' => lambda { |d| Dir.entries(d) - ['.', '..'] },
  'Dir.children' => lambda { |d| Dir.children(d) },
  'Dir.each_child(block)' => lambda { |d|
    acc = []
    Dir.each_child(d) { |e| acc << e }
    acc
  },
  'Dir.foreach(block)' => lambda { |d|
    acc = []
    Dir.foreach(d) { |e| acc << e }
    acc - ['.', '..']
  }
}.freeze

def assert_probes(probes, path, expected, label)
  probes.each do |name, probe|
    assert_eq(probe.call(path), expected, "#{label}: #{name}(#{path.inspect}) == #{expected}")
  end
end

def assert_lifecycle_consistent(file_path, label)
  dir_path = File.dirname(file_path)
  basename = File.basename(file_path)
  content = "payload for #{label}"

  assert_probes(FILE_PROBES, file_path, false, "#{label} before write")

  File.write(file_path, content)
  assert_probes(FILE_PROBES, file_path, true, "#{label} after write")
  assert_eq(File.size(file_path), content.length, "#{label}: File.size sees the write")
  FILE_READERS.each do |name, reader|
    assert_eq(reader.call(file_path), content, "#{label}: #{name} reads the write")
  end
  File.mtime(file_path)

  assert_listings(dir_path, basename, label)

  File.delete(file_path)
  assert_probes(FILE_PROBES, file_path, false, "#{label} after delete")
  DIR_LISTERS.each do |name, lister|
    assert_false(lister.call(dir_path).include?(basename), "#{label}: #{name} forgets the delete")
  end
end

def assert_listings(dir_path, basename, label)
  DIR_LISTERS.each do |name, lister|
    assert_true(
      lister.call(dir_path).include?(basename),
      "#{label}: #{name} lists the write"
    )
  end
  globbed = Dir.glob(File.join(dir_path, '*'))
  assert_true(
    globbed.any? { |entry| File.basename(entry) == basename },
    "#{label}: glob array form lists the write"
  )
  block_glob = []
  Dir.glob(File.join(dir_path, '*')) { |entry| block_glob << entry }
  assert_eq(block_glob, globbed, "#{label}: glob block form matches array form")
end

def assert_dir_lifecycle_consistent(dir_path, label)
  assert_probes(DIR_PROBES, dir_path, false, "#{label} before mkdir")
  Dir.mkdir(dir_path)
  assert_probes(DIR_PROBES, dir_path, true, "#{label} after mkdir")

  assert_lifecycle_consistent(File.join(dir_path, 'inner.rxdata'), "#{label}/inner")

  Dir.rmdir(dir_path)
  assert_probes(DIR_PROBES, dir_path, false, "#{label} after rmdir")
end

reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
Dir.chdir(GAME) do
  # Bare save filename - fully literal, no asymmetry left.
  assert_lifecycle_consistent('Matrix.rxdata', 'bare save name')

  # The portable dir, a subdirectory of it, and files inside both.
  assert_dir_lifecycle_consistent('Save Data', 'portable dir')
  Dir.mkdir('Save Data')
  assert_dir_lifecycle_consistent('Save Data/Battle Debug Logs', 'portable subdir')
  assert_lifecycle_consistent('Save Data/Slot 1.rxdata', 'portable save file')
  Dir.rmdir('Save Data')

  # Absolute spelling inside UserData.
  assert_lifecycle_consistent(File.join(USERDATA, 'Abs.rxdata'), 'absolute UserData file')

  # Plain non-save relative paths.
  assert_dir_lifecycle_consistent('PlainMatrix', 'plain dir')
end

# --- Case-variant writes land on the on-disk spelling ---
# The host filesystem folds case on its own, so this section emulates
# the device: a strict-spelling exist? (the engine's
# _mkxp_native_orig_exist?) and the engine's BOOT-TIME case cache
# (System.resolve_case_path). The cache snapshot is taken when the
# stubs install, so files created afterwards stay invisible to it -
# exactly like the engine, where only the live-walk fallback in
# case_variant can resolve them. With both in place, write-mode
# opens, whole-file writes, mkdir, unlink, and rename must land on
# the existing spelling instead of creating a duplicate - the
# Rejuvenation updater extracts "Battle Open.wav" over
# "Battle Open.WAV" this way.
def device_strict_exist?(path)
  str = path.to_s
  Dir._mkxp_orig_entries(File.dirname(str)).include?(File.basename(str))
rescue StandardError
  false
end

def build_boot_case_cache
  cache = {}
  walk = nil
  walk = lambda do |dir, rel|
    Dir._mkxp_orig_entries(dir).each do |name|
      next if ['.', '..'].include?(name)

      path = rel.empty? ? name : "#{rel}/#{name}"
      cache[path.downcase] = path
      full = File.join(dir, name)
      walk.call(full, path) if File._mkxp_orig_directory(full)
    end
  end
  walk.call('.', '')
  cache
end

def with_device_case_semantics
  boot_cache = build_boot_case_cache
  File.define_singleton_method(:_mkxp_native_orig_exist?) { |p| device_strict_exist?(p) }
  System.define_singleton_method(:resolve_case_path) do |rel|
    boot_cache[rel.to_s.gsub('\\', '/').downcase]
  end
  yield
ensure
  File.singleton_class.send(:remove_method, :_mkxp_native_orig_exist?)
  System.singleton_class.send(:remove_method, :resolve_case_path)
end

# Shadows the raw-syscall aliases with recorders so the assertions
# can see the exact paths the wrappers hand down. The host filesystem
# folds case, so disk state alone cannot prove the wiring.
RECORDED_RAW_METHODS = [
  [File, :_mkxp_orig_open], [File, :_mkxp_orig_delete],
  [File, :_mkxp_orig_rename], [Dir, :_mkxp_orig_mkdir]
].freeze

def with_recorded_raw_paths
  records = []
  originals = {}
  RECORDED_RAW_METHODS.each do |receiver, name|
    original = receiver.method(name)
    originals[[receiver, name]] = original
    receiver.define_singleton_method(name) do |*args, &blk|
      records << args[0].to_s
      original.call(*args, &blk)
    end
  end
  yield records
ensure
  originals.each { |(receiver, name), original| receiver.define_singleton_method(name, original) }
end

def assert_write_mode_classification
  assert_false(MKXPSaveFS.write_mode?('rb'), 'rb is not a write mode')
  assert_false(MKXPSaveFS.write_mode?(nil), 'default mode is not a write mode')
  assert_true(MKXPSaveFS.write_mode?('wb'), 'wb is a write mode')
  assert_true(MKXPSaveFS.write_mode?('a'), 'a is a write mode')
  assert_true(MKXPSaveFS.write_mode?('r+'), 'r+ is a write mode')
  assert_true(
    MKXPSaveFS.write_mode?(File::WRONLY | File::CREAT | File::TRUNC),
    'integer create flags are a write mode'
  )
  assert_false(MKXPSaveFS.write_mode?(File::RDONLY), 'RDONLY is not a write mode')
  assert_false(
    MKXPSaveFS.write_mode?('r:windows-1252'),
    'encoding suffix letters do not classify a read as a write'
  )
  assert_true(MKXPSaveFS.write_mode?('w:utf-8'), 'write mode with encoding suffix')
  assert_true(MKXPSaveFS.write_mode?({ :mode => 'wb' }), 'keyword-style mode hash')
  assert_false(MKXPSaveFS.write_mode?({ :mode => 'rb' }), 'keyword-style read hash')
end

# Boot-cache-resolvable spellings (the seed file predates the stubs).
def assert_case_resolution
  assert_eq(
    MKXPSaveFS.resolve_case_target('Audio/BGS/Battle Open.wav'),
    'Audio/BGS/Battle Open.WAV',
    'relative case-variant resolves to the on-disk spelling'
  )
  assert_eq(
    MKXPSaveFS.resolve_case_target(File.expand_path('Audio/BGS/Battle Open.wav')),
    "#{File.expand_path('.')}/Audio/BGS/Battle Open.WAV",
    'absolute case-variant resolves inside the game dir'
  )
  assert_eq(
    MKXPSaveFS.resolve_case_target('/outside/the/game/File.wav'),
    '/outside/the/game/File.wav',
    'absolute path outside the known roots stays literal'
  )
  assert_eq(
    MKXPSaveFS.resolve_case_target('Audio/BGS/Battle Open.WAV'),
    'Audio/BGS/Battle Open.WAV',
    'exact spelling stays literal'
  )
  assert_eq(
    MKXPSaveFS.write_casefold('Audio/BGS/Battle Open.wav', 'rb'),
    'Audio/BGS/Battle Open.wav',
    'read-mode open skips the resolution'
  )
end

def read_raw(path)
  File._mkxp_orig_open(path, 'rb', &:read)
end

# Write-mode File.open is the unit under test here, so the
# File.binwrite style preference does not apply.
# rubocop:disable Style/FileWrite
def assert_case_variant_writes(records)
  File.open('Audio/BGS/Battle Open.wav', 'wb') { |f| f.write('new') }
  assert_true(
    records.include?('Audio/BGS/Battle Open.WAV'),
    'wrapper handed the resolved spelling to the raw open'
  )
  assert_eq(read_raw('Audio/BGS/Battle Open.WAV'), 'new', 'case-variant write reached the file')

  File.open(File.expand_path('Audio/BGS/Battle Open.wav'), 'wb') { |f| f.write('abs') }
  assert_eq(read_raw('Audio/BGS/Battle Open.WAV'), 'abs', 'absolute case-variant write reached the file')

  if File.respond_to?(:_mkxp_orig_binwrite)
    File.binwrite('Audio/BGS/Battle Open.wav', 'bin')
    assert_eq(read_raw('Audio/BGS/Battle Open.WAV'), 'bin', 'binwrite reached the file')
  end

  File.open('Audio/BGS/Fresh.wav', 'wb') { |f| f.write('fresh') }
  assert_true(
    records.include?('Audio/BGS/Fresh.wav'),
    'fresh name stays literal through the raw open'
  )
end

# Files created after boot are invisible to the cache stub; only the
# live walk can resolve them.
def assert_session_created_resolution
  File.open('Audio/BGS/New Track.WAV', 'wb') { |f| f.write('x') }
  assert_eq(
    MKXPSaveFS.resolve_case_target('Audio/BGS/new track.wav'),
    'Audio/BGS/New Track.WAV',
    'session-created file resolves through the live walk'
  )
  assert_eq(
    MKXPSaveFS.resolve_case_target('audio/bgs/brand new.ogg'),
    'Audio/BGS/brand new.ogg',
    'new file in a case-variant directory resolves its parents'
  )
end
# rubocop:enable Style/FileWrite

def assert_case_variant_removals(records)
  # The updater's pre-extract unlink passes the new spelling.
  File.unlink('Audio/BGS/Battle Open.wav')
  assert_true(
    records.include?('Audio/BGS/Battle Open.WAV'),
    'case-variant unlink removed the on-disk file'
  )

  File._mkxp_orig_open('Audio/BGS/Old Name.WAV', 'wb') { |f| f.write('x') }
  File.rename('Audio/BGS/Old Name.wav', 'Audio/BGS/Renamed.wav')
  assert_true(
    records.include?('Audio/BGS/Old Name.WAV'),
    'session-created rename source resolved through the live walk'
  )
  assert_true(
    raw_entries('Audio/BGS').include?('Renamed.wav'),
    'case-variant rename moved the on-disk file'
  )
end

def assert_dir_case_resolution(records)
  FileUtils.mkdir_p('audio/bgs/deeper')
  assert_true(
    records.include?('Audio/BGS/deeper'),
    'mkdir_p extends the on-disk tree instead of duplicating it'
  )
end

def assert_userdata_case_resolution
  File._mkxp_orig_open(File.join(USERDATA, 'Save09.rvdata2'), 'wb') { |f| f.write('x') }
  assert_eq(
    MKXPSaveFS.resolve_case_target(File.join(USERDATA, 'SAVE09.RVDATA2')),
    File.join(USERDATA, 'Save09.rvdata2'),
    'absolute case-variant under UserData resolves'
  )
end

def assert_chdir_anchoring
  FileUtils.mkdir_p('sub')
  File._mkxp_orig_open('sub/Thing.WAV', 'wb') { |f| f.write('x') }
  Dir.chdir('sub') do
    assert_eq(
      MKXPSaveFS.resolve_case_target('thing.wav'),
      'Thing.WAV',
      'relative resolution follows the working directory after chdir'
    )
  end
end

reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
Dir.chdir(GAME) do
  FileUtils.mkdir_p('Audio/BGS')
  File._mkxp_orig_open('Audio/BGS/Battle Open.WAV', 'wb') { |f| f.write('old') }
  with_device_case_semantics do
    assert_write_mode_classification
    assert_case_resolution
    with_recorded_raw_paths do |records|
      assert_case_variant_writes(records)
      assert_session_created_resolution
      assert_case_variant_removals(records)
      assert_dir_case_resolution(records)
    end
    assert_userdata_case_resolution
    assert_chdir_anchoring
  end
end

puts 'OK: test_save_fs.rb passed'
