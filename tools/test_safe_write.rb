#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Tests for MKXPSafeWrite in windows_fs.rb: a save that stops half
# way keeps the save from before it.
# Run: ruby mkxp-z-apple-mobile/tools/test_safe_write.rb

require 'English'
require 'pathname'
require_relative 'save_fs_harness'

# The tests write the way games do: File.open with a block, a delete
# after an exist? check, and Marshal.load of the save.
# rubocop:disable Style/FileWrite, Style/FileOpen, Lint/NonAtomicFileOperation, Security/MarshalLoad

$userAgent = 'host'

reset_workspace!
load_windows_fs!

def game_file(name)
  File.join(USERDATA, name)
end

def temp_files
  raw_entries(USERDATA).select { |name| name.end_with?('.mkxp-tmp') }
end

# The order of Pokemon Insurgence's pbSave (115_PokemonSave.rb): it
# moves the backups down, renames Game.rxdata to the first backup,
# then writes a new Game.rxdata one Marshal.dump at a time.
def insurgence_save(game, backup, values)
  File.delete(backup) if File.exist?(backup)
  File.rename(game, backup) if File.exist?(game)
  File.open(game, 'wb') do |f|
    values.each { |value| Marshal.dump(value, f) }
  end
end

def assert_raises(error, message)
  yield
  assert_true(false, message)
rescue error
  assert_true(true, message)
end

def load_all(path)
  values = []
  File.open(path, 'rb') do |f|
    values << Marshal.load(f) until f.eof?
  end
  values
end

game = game_file('Game.rxdata')
backup = game_file('Save_0_Backup_1.rxdata')

# --- A write that ends replaces the file ---
File.open(game, 'wb') { |f| Marshal.dump(%w[trainer old], f) }
File.open(game, 'wb') { |f| Marshal.dump(%w[trainer new], f) }
assert_eq(load_all(game), [%w[trainer new]], 'a finished write replaces the file')
assert_eq(temp_files, [], 'a finished write leaves no temp file')

# --- The block's value comes back ---
assert_eq(File.open(game, 'wb') { |f| f.write('x') && :done }, :done, 'File.open returns the block value')

# --- A write that raises keeps the old file ---
File.open(game, 'wb') { |f| Marshal.dump('whole save', f) }
raised = begin
  File.open(game, 'wb') do |f|
    Marshal.dump('half', f)
    raise 'marshal_dump returned same class instance'
  end
  false
rescue RuntimeError
  true
end
assert_true(raised, 'the error still reaches the game')
assert_eq(load_all(game), ['whole save'], 'a write that raises keeps the old file')
assert_eq(temp_files, [], 'a write that raises leaves no temp file')

# --- Insurgence: a save that fails after the switches ---
# This is the broken save from the player: the file ended right after
# $game_switches, and Continue failed with EOFError.
File.delete(game)
insurgence_save(game, backup, ['trainer', 1000, 'switches', 'variables'])
saved = begin
  insurgence_save(game, backup, ['trainer', 2000, 'switches', proc { 'cannot dump' }])
  true
rescue TypeError
  false
end
assert_false(saved, 'the failed dump still raises')
last_save = ['trainer', 1000, 'switches', 'variables']
assert_eq(load_all(game), last_save, 'Insurgence keeps the last save to continue')
assert_eq(load_all(backup), last_save, 'Insurgence keeps its backup')
assert_eq(temp_files, [], 'the failed save leaves no temp file')

# --- Insurgence: a save that ends gives two separate files ---
insurgence_save(game, backup, ['trainer', 3000])
assert_eq(load_all(game), ['trainer', 3000], 'the new save is in Game.rxdata')
assert_eq(load_all(backup), last_save, 'the old save moved to the backup')
File.open(game, 'wb') { |f| Marshal.dump('later', f) }
assert_eq(load_all(backup), last_save, 'a later write does not change the backup')

# --- Insurgence: the game crashes during the save ---
File.open(game, 'wb') { |f| Marshal.dump('before the crash', f) }
pid = fork do
  File.delete(backup) if File.exist?(backup)
  File.rename(game, backup)
  File.open(game, 'wb') do |f|
    Marshal.dump('half', f)
    f.flush
    Process.kill(:KILL, Process.pid)
  end
end
Process.wait(pid)
assert_true($CHILD_STATUS.signaled?, 'the save process was killed')
assert_eq(load_all(game), ['before the crash'], 'a crash during the save keeps the last save')
assert_eq(load_all(backup), ['before the crash'], 'a crash during the save keeps the backup')
assert_eq(temp_files, ['Game.rxdata.mkxp-tmp'], 'the temp file of the crash has a name the Files app shows')
assert_eq(Dir.glob(File.join(USERDATA, '*')).grep(/\.mkxp-tmp\z/), [], 'a glob hides the temp file')
assert_eq(Dir[File.join(USERDATA, 'Game*')].grep(/\.mkxp-tmp\z/), [], 'Dir[] hides the temp file')
listed = []
Dir.glob(File.join(USERDATA, 'Game*')) { |name| listed << name }
assert_eq(listed.grep(/\.mkxp-tmp\z/), [], 'a glob with a block hides the temp file')
assert_eq(Dir.children(USERDATA).grep(/\.mkxp-tmp\z/), [], 'Dir.children hides the temp file')
assert_eq(Dir.foreach(USERDATA).to_a.grep(/\.mkxp-tmp\z/), [], 'Dir.foreach hides the temp file')
insurgence_save(game, backup, ['after the crash'])
assert_eq(load_all(game), ['after the crash'], 'the next save works after a crash')
assert_eq(temp_files, [], 'the next save removes the temp file of the crash')

# --- A rename that the game does not write back is not undone ---
File.open(game_file('Old.rxdata'), 'wb') { |f| f.write('old') }
File.rename(game_file('Old.rxdata'), game_file('Old.bak'))
assert_false(File.exist?(game_file('Old.rxdata')), 'a plain rename leaves no file behind')

# --- A rename to a file that changed after it does not come back ---
File.open(game_file('Slot.rxdata'), 'wb') { |f| f.write('first') }
File.rename(game_file('Slot.rxdata'), game_file('Slot.bak'))
File.delete(game_file('Slot.bak'))
File.open(game_file('Slot.bak'), 'wb') { |f| f.write('other') }
begin
  File.open(game_file('Slot.rxdata'), 'wb') { raise 'stop' }
rescue RuntimeError
  nil
end
assert_false(File.exist?(game_file('Slot.rxdata')), 'a failed write does not bring back an unrelated file')

# --- A return from inside the block keeps the write ---
def save_and_return(path)
  File.open(path, 'wb') do |f|
    f.write('returned')
    return true
  end
end
save_and_return(game)
assert_eq(File.binread(game), 'returned', 'a return from the block keeps the write')
assert_eq(temp_files, [], 'a return from the block leaves no temp file')

# --- Other opens do not change ---
f = File.open(game, 'wb')
f.write('no block')
assert_eq(f.path, game, 'an open with no block writes the file itself')
f.close
assert_eq(File.binread(game), 'no block', 'an open with no block writes')
File.open(game, 'ab') { |file| file.write(' and more') }
assert_eq(File.binread(game), 'no block and more', 'append mode writes to the file itself')
File.open(game, 'r+b') { |file| file.write('NO') }
assert_eq(File.binread(game), 'NO block and more', 'update mode writes to the file itself')
File.open(game, File::WRONLY | File::TRUNC | File::CREAT) { |file| file.write('flags') }
assert_eq(File.binread(game), 'flags', 'a mode given as flags with TRUNC writes')
assert_eq(temp_files, [], 'the flag write leaves no temp file')
assert_eq(File.open(game, 'rb', &:read), 'flags', 'a read still works')
# --- The game closes the file inside the block ---
File.open(game, 'wb') do |file|
  file.write('closed by the game')
  file.close
end
assert_eq(File.binread(game), 'closed by the game', 'a file the game closes in the block is saved')

# --- The same file opened again inside the block ---
File.open(game, 'wb') do |outer|
  File.open(game, 'wb') { |inner| inner.write('inner') }
  outer.write('outer')
end
assert_eq(File.binread(game), 'outer', 'a nested open of the same file does not fail')
assert_eq(temp_files, [], 'a nested open leaves no temp file')

# --- The path of the open file is the name the game asked for ---
File.open(game, 'wb') { |file| assert_eq(file.path, game, 'file.path is the target name') }

# --- After a failed save, the save and the backup are two files ---
File.delete(backup) if File.exist?(backup)
File.open(game, 'wb') { |file| file.write('kept') }
begin
  insurgence_save(game, backup, ['new', proc { 'cannot dump' }])
rescue TypeError
  nil
end
assert_false(File.stat(game).ino == File.stat(backup).ino, 'the kept save is a copy, not a link')
f = File.open(game, 'wb')
f.write('PARTIAL')
f.close
assert_eq(File.binread(backup), 'kept', 'a later write to the save does not change the backup')

# --- A rename is forgotten after the next save of another file ---
File.open(game_file('A.rxdata'), 'wb') { |file| file.write('a') }
File.rename(game_file('A.rxdata'), game_file('A.bak'))
File.open(game_file('Other.rxdata'), 'wb') { |file| file.write('other') }
begin
  File.open(game_file('A.rxdata'), 'wb') { raise 'stop' }
rescue RuntimeError
  nil
end
assert_false(File.exist?(game_file('A.rxdata')), 'an old rename does not bring back a file')

# --- A failed fsync does not lose the save ---
File.class_eval do
  alias_method :_test_fsync, :fsync
  define_method(:fsync) { raise Errno::EINVAL }
end
File.open(game, 'wb') { |file| file.write('no fsync') }
File.class_eval do
  alias_method :fsync, :_test_fsync
  remove_method :_test_fsync
end
assert_eq(File.binread(game), 'no fsync', 'a save on a disk without fsync is written')

# --- Modes and files that the safe write leaves to the system ---
assert_raises(Errno::EEXIST, 'an exclusive open of a file that exists still fails') do
  File.open(game, File::WRONLY | File::CREAT | File::TRUNC | File::EXCL) { |file| file.write('x') }
end
assert_raises(Errno::EEXIST, 'a "wx" open of a file that exists still fails') do
  File.open(game, 'wx') { |file| file.write('x') }
end
locked = game_file('Locked.rxdata')
File.open(locked, 'wb') { |file| file.write('locked') }
File.chmod(0o444, locked)
assert_raises(Errno::EACCES, 'a read-only file is not overwritten') do
  File.open(locked, 'wb') { |file| file.write('x') }
end
assert_eq(File.binread(locked), 'locked', 'the read-only file keeps its data')
File.chmod(0o600, game)
File.open(game, 'wb') { |file| file.write('private') }
assert_eq(File.stat(game).mode & 0o777, 0o600, 'a save keeps the mode of the old file')
real = game_file('Real.rxdata')
link = game_file('Link.rxdata')
File.open(real, 'wb') { |file| file.write('real') }
File.symlink(real, link)
File.open(link, 'wb') { |file| file.write('through the link') }
assert_true(File.symlink?(link), 'a save through a link keeps the link')
assert_eq(File.binread(real), 'through the link', 'a save through a link writes the file it points to')
leftover = MKXPSafeWrite.temp_path(game)
File._mkxp_orig_open(leftover, 'wb') { |file| file.write('left over') }
File.chmod(0o444, leftover)
File.open(game, 'wb') { |file| file.write('after leftover') }
assert_eq(File.binread(game), 'after leftover', 'a read-only temp file from a crash does not stop the save')
fd = IO.sysopen(game, 'w')
File.open(fd, 'w') { |file| file.write('fd') }
assert_eq(File.binread(game), 'fd', 'an open of a file descriptor still writes')

# --- An Errno::ENOENT from the game code runs the block once ---
runs = 0
assert_raises(Errno::ENOENT, 'the game error reaches the game') do
  File.open(game_file('Case.rxdata'), 'wb') do
    runs += 1
    raise Errno::ENOENT, 'from the game'
  end
end
assert_eq(runs, 1, 'the block runs once')
assert_eq(temp_files, [], 'the temp files are gone at the end')
# --- Integer flags without File::CREAT ---
File.open(game, 'wb') { |file| file.write('old flags') }
File.open(game, File::WRONLY | File::TRUNC) { |file| file.write('new flags') }
assert_eq(File.binread(game), 'new flags', 'flags without CREAT write a file that exists')
assert_raises(Errno::ENOENT, 'flags without CREAT still fail for a missing file') do
  File.open(game_file('Missing.rxdata'), File::WRONLY | File::TRUNC) { |file| file.write('x') }
end

# --- A folder change inside the block ---
start_dir = Dir.pwd
Dir.chdir(USERDATA)
File.open('Relative.rxdata', 'wb') do |file|
  file.write('relative')
  Dir.chdir('/')
end
Dir.chdir(start_dir)
assert_eq(File.binread(game_file('Relative.rxdata')), 'relative', 'a folder change inside the block keeps the save in place')

# --- A case lookup inside the block sees the new file after it ---
File.open(game_file('Fresh Case.rxdata'), 'wb') do |file|
  File.exist?(game_file('fresh case.rxdata'))
  file.write('fresh')
end
assert_true(File.exist?(game_file('fresh case.rxdata')), 'a case lookup after the save finds the new file')
# --- A name that starts with ~ is not a home folder ---
Dir.chdir(USERDATA)
File.open('~autosave.rxdata', 'wb') { |file| file.write('tilde') }
Dir.chdir(start_dir)
assert_eq(File.binread(game_file('~autosave.rxdata')), 'tilde', 'a name that starts with ~ saves in the folder')

# --- Keyword options ---
File.open(game, mode: File::WRONLY | File::TRUNC) { |file| file.write('keyword flags') }
assert_eq(File.binread(game), 'keyword flags', 'a mode keyword with flags without CREAT writes the file')
assert_raises(Errno::EEXIST, 'a flags keyword with EXCL still fails for a file that exists') do
  File.open(game, 'w', flags: File::EXCL) { |file| file.write('x') }
end
assert_eq(File.binread(game), 'keyword flags', 'the EXCL open keeps the file')
assert_raises(ArgumentError, 'an empty mode string fails as a direct open does') do
  File.open(game, '') { |file| file.write('x') }
end

# --- Two opens of one save at the same time ---
File.open(game, 'wb') do |file|
  file.write('outer')
  File.open(game.sub('Game', 'GAME'), 'wb') { |inner| inner.write('inner') }
end
assert_eq(File.binread(game), 'outer', 'an open of the same save in another case does not break the outer save')
File.delete(game.sub('Game', 'GAME')) if raw_entries(USERDATA).include?('GAME.rxdata')
threads = Array.new(2) do |n|
  Thread.new { 200.times { File.open(game, 'wb') { |file| file.write("t#{n}") } } }
end
threads.each(&:join)
assert_true(%w[t0 t1].include?(File.binread(game)), 'two threads that save one file both finish')
assert_eq(temp_files, [], 'two threads leave no temp file')

# --- Names and links the temp file cannot use ---
long = game_file("#{'L' * 240}.rxdata")
File.open(long, 'wb') { |file| file.write('long') }
assert_eq(File.binread(long), 'long', 'a long name writes directly')
other = game_file('Other Name.rxdata')
File.link(game, other)
File.open(other, 'wb') { |file| file.write('hard link') }
assert_eq(File.binread(game), 'hard link', 'a save through a hard link writes the shared file')

# --- The temp file stays out of the game lists ---
File.open(game, 'wb') do |file|
  file.write('listed')
  assert_eq(Dir.entries(USERDATA).grep(/\.mkxp-tmp\z/), [], 'a folder list during a save hides the temp file')
  assert_eq(file.to_path, game, 'to_path gives the save name')
end
sub = game_file('Slots')
Dir.mkdir(sub)
File.open(File.join(sub, 'Save1.rxdata'), 'wb') do |file|
  file.write('in a folder')
  assert_eq(Dir.entries(sub).grep(/\.mkxp-tmp\z/), [], 'a list of another folder during a save hides the temp file')
  assert_eq(Dir.each_child(sub).to_a.grep(/\.mkxp-tmp\z/), [], 'Dir.each_child hides the temp file')
end
File.delete(File.join(sub, 'Save1.rxdata'))
Dir.rmdir(sub)
# --- A Pathname save is safe too ---
File.delete(other)
File.open(game, 'wb') { |file| file.write('before path') }
assert_raises(RuntimeError, 'a Pathname save that raises reaches the game') do
  File.open(Pathname.new(game), 'wb') do |file|
    file.write('H')
    raise 'stop'
  end
end
assert_eq(File.binread(game), 'before path', 'a Pathname save that raises keeps the old file')

# --- A save from a signal handler ---
trapped = nil
old_trap = Signal.trap('USR1') { File.open(game, 'wb') { |file| file.write('trap') } && (trapped = true) }
Process.kill('USR1', Process.pid)
sleep 0.01 until trapped
Signal.trap('USR1', old_trap)
assert_eq(File.binread(game), 'trap', 'a save from a signal handler writes the file')

# --- The block deletes its own folder ---
gone = game_file('Gone')
Dir.mkdir(gone)
File.open(File.join(gone, 'Game.rxdata'), 'wb') do |file|
  file.write('x')
  File._mkxp_orig_delete(MKXPSafeWrite.temp_path(File.join(gone, 'Game.rxdata')))
  Dir.rmdir(gone)
end
assert_true(!File.directory?(gone), 'a save whose block deletes the folder ends without an error')

# --- A leftover folder with the restore name ---
stuck = MKXPSafeWrite.temp_path(game, 'restore')
Dir.mkdir(stuck)
File.open(game, 'wb') { |file| file.write('past folder') }
Dir.rmdir(stuck)
assert_eq(File.binread(game), 'past folder', 'a folder with the restore name does not stop the save')
# rubocop:enable Style/FileWrite, Style/FileOpen, Lint/NonAtomicFileOperation, Security/MarshalLoad

test_passed('test_safe_write', 78)
