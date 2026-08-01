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

# --- Bare working-directory save filenames remap into UserData ---
assert_eq(
  MKXPSaveFS.path_for('Save01.rvdata2'),
  File.join(USERDATA, 'Save01.rvdata2'),
  'bare save filename'
)
twice = MKXPSaveFS.path_for(MKXPSaveFS.path_for('Save01.rvdata2'))
assert_eq(twice, File.join(USERDATA, 'Save01.rvdata2'), 'idempotent path_for')

# --- Everything else is literal ---
assert_eq(
  MKXPSaveFS.path_for('Save/Save01.rvdata2'),
  'Save/Save01.rvdata2',
  'save-dir-prefixed path is literal'
)
assert_eq(
  MKXPSaveFS.path_for('Save Data/Save01.rvdata2'),
  'Save Data/Save01.rvdata2',
  'portable path is literal'
)
assert_eq(MKXPSaveFS.path_for('Save'), 'Save', 'save dir name is literal')
assert_eq(MKXPSaveFS.path_for('Data/Map001.rvdata2'), 'Data/Map001.rvdata2', 'non-save passthrough')
assert_eq(MKXPSaveFS.path_for('/etc/passwd'), '/etc/passwd', 'absolute passthrough')

# --- Glob: only bare save-file patterns remap ---
File.write(File.join(USERDATA, 'Save01.rvdata2'), 'x')
assert_eq(MKXPSaveFS.glob_for('Save Data/*.rvdata2'), nil, 'portable glob is literal')
assert_eq(
  MKXPSaveFS.glob_for('*.rvdata2'),
  File.join(USERDATA, '*.rvdata2'),
  'bare glob remap'
)
globbed = MKXPSaveFS.normalize_glob_results(
  [File.join(USERDATA, 'Save01.rvdata2')],
  '*.rvdata2'
)
assert_eq(globbed, ['Save01.rvdata2'], 'glob results relative to root')

# Shipped starter save in the game folder wins while UserData has no copy.
File.write(File.join(GAME, 'Game.rxdata'), 'shipped')
Dir.chdir(GAME) do
  assert_eq(MKXPSaveFS.path_for('Game.rxdata'), 'Game.rxdata', 'read-fallback to shipped save')
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

assert_true(File.exist?('Save01.rvdata2'), 'File.exist? remapped bare save')
assert_true(FileTest.exist?('Save01.rvdata2'), 'FileTest.exist? remapped bare save')

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

# --- Probe/enumeration gap closure ---
# FileTest.exists? routes through the bare-name remap like every
# other existence probe, and bare save globs see BOTH the UserData
# remap and shipped/imported saves in the game folder.
reset_workspace!
Dir.chdir(GAME) { load_platform_compat!(false) }
File.write(File.join(USERDATA, 'Game.rxdata'), 'userdata copy')
File.write(File.join(GAME, 'Game.rxdata'), 'shipped duplicate')
File.write(File.join(GAME, 'Save02.rxdata'), 'shipped only')
Dir.chdir(GAME) do
  assert_true(FileTest.exists?('Game.rxdata'), 'FileTest.exists? sees remapped bare save')
  assert_true(FileTest.exists?('Save02.rxdata'), 'FileTest.exists? read fallback')

  merged = Dir.glob('*.rxdata')
  assert_eq(merged.sort, ['Game.rxdata', 'Save02.rxdata'], 'bare glob merges both sides')
  assert_eq(merged.length, 2, 'bare glob dedupes duplicated name')
  assert_eq(merged[0], 'Game.rxdata', 'UserData side listed first')

  yielded = []
  block_result = Dir.glob('*.rxdata') { |entry| yielded << entry }
  assert_eq(yielded.sort, ['Game.rxdata', 'Save02.rxdata'], 'block form yields merged names')
  assert_eq(block_result, nil, 'block form returns nil')

  # Each merged name resolves per file: the duplicated name opens the
  # UserData copy, the shipped-only name falls back to the game folder.
  assert_eq(File.read('Game.rxdata'), 'userdata copy', 'duplicated name resolves to UserData')
  assert_eq(File.read('Save02.rxdata'), 'shipped only', 'shipped-only name resolves to game folder')
  # rubocop:disable Style/FileRead -- deliberately comparing the
  # File.open path against File.read's resolution.
  assert_eq(File.open('Game.rxdata', 'rb', &:read), 'userdata copy', 'File.open agrees with File.read')
  # rubocop:enable Style/FileRead

  # Whole-file writes of bare save names land where File.open would.
  File.write('Save03.rxdata', 'written')
  assert_true(raw_entries(USERDATA).include?('Save03.rxdata'), 'File.write bare save goes to UserData')
  assert_false(raw_entries(GAME).include?('Save03.rxdata'), 'File.write leaves game folder alone')
  assert_eq(File.binread('Save03.rxdata'), 'written', 'File.binread resolves like File.open')

  # Non-save patterns stay fully literal.
  File.write(File.join(GAME, 'readme.txt'), '')
  assert_eq(Dir.glob('*.txt'), ['readme.txt'], 'non-save glob passthrough')
end

puts 'OK: test_save_fs.rb passed'
