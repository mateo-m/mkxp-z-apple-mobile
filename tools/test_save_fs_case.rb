#!/usr/bin/env ruby
# Case-semantics tests for windows_fs.rb: write-mode case
# resolution, the live walk, the deletion-safe boot cache, the
# "pathCache": false probe folding, and predicate parity across the
# File / FileTest / Dir probe APIs. Save-path handling lives in
# test_save_fs.rb.
# Run: ruby mkxp-z-apple-mobile/tools/test_save_fs_case.rb

require_relative 'save_fs_harness'

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

# Boot-cache-resolvable spellings (the seed file predates the fake).
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
    MKXPSaveFS.open_target('Audio/BGS/Battle Open.wav', 'rb'),
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

# Files created after boot are invisible to the cache fake. Only the
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

# Rejuvenation-updater regression: a patch can change a file's
# spelling. The updater unlinks the old spelling, then extracts the
# new one. The boot cache still lists the deleted spelling, so the
# write must stay literal instead of resurrecting the old name.
# Otherwise the extractor's follow-up chmod of the new spelling
# raises Errno::ENOENT and the whole patch aborts.
def assert_respell_after_unlink(records)
  File.unlink('Audio/BGS/Respell Me.wav')
  File.open('Audio/BGS/Respell Me.wav', 'wb') { |f| f.write('new') }
  assert_true(
    records.include?('Audio/BGS/Respell Me.wav'),
    'write after a same-session unlink stays literal'
  )
  assert_true(
    raw_entries('Audio/BGS').include?('Respell Me.wav'),
    'the new spelling is on disk after the respell'
  )
  assert_eq(
    MKXPSaveFS.resolve_case_target('Audio/BGS/Respell Me.wav'),
    'Audio/BGS/Respell Me.wav',
    'a stale cache entry does not resolve a deleted file'
  )
end

# Without the engine path cache, the probe wrappers must fold case
# through the live walk on their own.
def assert_pathcache_off_exist_probes
  assert_true(
    File.exist?('Graphics/Icons/typeBlank.png'),
    'File.exist? folds case without the engine path cache'
  )
  assert_true(
    File.exist?('./Graphics/Icons/typeBlank.png'),
    'File.exist? folds case for a dot-prefixed relative path'
  )
  assert_true(
    FileTest.exist?('Graphics/Icons/typeBlank.png'),
    'FileTest.exist? folds case without the engine path cache'
  )
  assert_false(
    File.exist?('Graphics/Icons/missing.png'),
    'File.exist? still misses files with no case variant'
  )
  assert_false(
    File.exist?('graphics/icons/missing.png'),
    'a case-variant parent does not invent a missing file'
  )
end

# Rejuvenation-updater regression, second half: the game ships
# "pathCache": false, so exist? sees only the raw syscall. The
# updater respells a file by probing the new spelling, unlinking the
# old one, then extracting. A false miss on the probe skips the
# unlink, the extraction write folds back onto the old spelling, and
# the extractor's raw chmod of the new spelling aborts the patch.
def assert_pathcache_off_respell(records)
  path = './Graphics/Icons/typeBlank.png'
  # rubocop:disable Lint/NonAtomicFileOperation -- the guarded unlink
  # is the updater sequence under test.
  File.unlink(path) if File.exist?(path)
  # rubocop:enable Lint/NonAtomicFileOperation
  assert_true(
    records.include?('./Graphics/Icons/TypeBlank.png'),
    'the guarded unlink resolved to the on-disk spelling'
  )
  File.open(path, 'wb') { |f| f.write('new') }
  assert_true(
    raw_entries('Graphics/Icons').include?('typeBlank.png'),
    'the extraction write created the new spelling'
  )
  assert_false(
    raw_entries('Graphics/Icons').include?('TypeBlank.png'),
    'the old spelling is gone after the respell'
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

# Daybreak regression: AudioUtilities probes MP3 sizes with the
# game's own mismatched spelling after File.open already casefolded.
def assert_filetest_size_casefold
  FileUtils.mkdir_p('Audio/BGM')
  File._mkxp_orig_open('Audio/BGM/Title.mp3', 'wb') { |f| f.write('12345') }
  assert_eq(FileTest.size('Audio/BGM/TITLE.mp3'), 5, 'FileTest.size retries the on-disk spelling')
  assert_eq(FileTest.size('Audio/BGM/Title.mp3'), 5, 'FileTest.size exact spelling still works')
  assert_eq(FileTest.size?('Audio/BGM/TITLE.MP3'), 5, 'FileTest.size? retries the on-disk spelling')
  assert_eq(FileTest.size?('Audio/BGM/missing.mp3'), nil, 'FileTest.size? still nil for missing files')
  err = nil
  begin
    FileTest.size('Audio/BGM/missing.mp3')
  rescue Errno::ENOENT => e
    err = e
  end
  assert_eq(err.nil?, false, 'FileTest.size still raises ENOENT for missing files')
end

# --- Predicate parity ---
# Windows answers every probe API through the OS's case folding, so
# every API must give the same answer for every spelling a game might
# use. Type probes stay type probes: a fold must never turn a file
# into a directory or invent a missing path from a parent match.
# rubocop:disable Lint/DeprecatedClassMethods -- the deprecated
# spellings are part of the API surface games call. Parity must hold
# for them too.
EXIST_PROBES = {
  'File.exist?' => lambda { |p| File.exist?(p) },
  'File.exists?' => lambda { |p| File.exists?(p) },
  'FileTest.exist?' => lambda { |p| FileTest.exist?(p) }
}.freeze
FILE_TYPE_PROBES = {
  'File.file?' => lambda { |p| File.file?(p) },
  'FileTest.file?' => lambda { |p| FileTest.file?(p) }
}.freeze
DIR_TYPE_PROBES = {
  'File.directory?' => lambda { |p| File.directory?(p) },
  'FileTest.directory?' => lambda { |p| FileTest.directory?(p) },
  'Dir.exist?' => lambda { |p| Dir.exist?(p) }
}.freeze
# rubocop:enable Lint/DeprecatedClassMethods

def assert_parity_row(path, existing, type, label)
  EXIST_PROBES.each do |name, probe|
    assert_eq(probe.call(path), existing, "#{label}: #{name}(#{path.inspect})")
  end
  FILE_TYPE_PROBES.each do |name, probe|
    assert_eq(probe.call(path), existing && type == :file, "#{label}: #{name}(#{path.inspect})")
  end
  DIR_TYPE_PROBES.each do |name, probe|
    assert_eq(probe.call(path), existing && type == :directory, "#{label}: #{name}(#{path.inspect})")
  end
end

# Rows: an exact spelling, a case variant, a file created this
# session through the wrappers, directories both ways, and a missing
# file - including one under a case-variant parent, where the walk
# resolves the parent and a careless fold could report the child.
def assert_predicate_parity
  File.binwrite('Graphics/Icons/Fresh.png', 'x')
  assert_parity_row('Graphics/Icons/TypeBlank.png', true, :file, 'parity: exact file')
  assert_parity_row('graphics/icons/typeblank.PNG', true, :file, 'parity: case-variant file')
  assert_parity_row('graphics/icons/FRESH.png', true, :file, 'parity: session-created variant')
  assert_parity_row('Graphics/Icons', true, :directory, 'parity: exact dir')
  assert_parity_row('GRAPHICS/icons', true, :directory, 'parity: case-variant dir')
  assert_parity_row('Graphics/Icons/missing.png', false, :file, 'parity: missing file')
  assert_parity_row('graphics/icons/missing.png', false, :file, 'parity: missing file, variant parent')
end

# --- Device semantics with the boot case cache available ---
reset_workspace!
Dir.chdir(GAME) { load_windows_fs!(false) }
Dir.chdir(GAME) do
  FileUtils.mkdir_p('Audio/BGS')
  File._mkxp_orig_open('Audio/BGS/Battle Open.WAV', 'wb') { |f| f.write('old') }
  File._mkxp_orig_open('Audio/BGS/Respell Me.WAV', 'wb') { |f| f.write('old') }
  with_device_case_semantics do
    assert_write_mode_classification
    assert_case_resolution
    with_recorded_raw_paths do |records|
      assert_case_variant_writes(records)
      assert_session_created_resolution
      assert_case_variant_removals(records)
      assert_respell_after_unlink(records)
      assert_dir_case_resolution(records)
    end
    assert_userdata_case_resolution
    assert_chdir_anchoring
    assert_filetest_size_casefold
  end
end

# --- "pathCache": false semantics ---
reset_workspace!
Dir.chdir(GAME) { load_windows_fs!(false) }
Dir.chdir(GAME) do
  FileUtils.mkdir_p('Graphics/Icons')
  File._mkxp_orig_open('Graphics/Icons/TypeBlank.png', 'wb') { |f| f.write('old') }
  with_pathcache_off_semantics do
    assert_pathcache_off_exist_probes
    assert_predicate_parity
    with_recorded_raw_paths do |records|
      assert_pathcache_off_respell(records)
    end
  end
end

test_passed('test_save_fs_case', 101)
