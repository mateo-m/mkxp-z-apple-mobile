#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Tests for MKXPSafeWrite in windows_fs.rb: a save that stops half
# way keeps the save from before it.
# Run: ruby mkxp-z-apple-mobile/tools/test_safe_write.rb

require 'English'
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
assert_eq(temp_files, [], 'a finished write leaves no hidden file')

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
assert_eq(temp_files, [], 'a write that raises leaves no hidden file')

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
assert_eq(temp_files, [], 'the failed save leaves no hidden file')

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
insurgence_save(game, backup, ['after the crash'])
assert_eq(load_all(game), ['after the crash'], 'the next save works after a crash')
assert_eq(temp_files, [], 'the next save removes the hidden file of the crash')

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
assert_eq(temp_files, [], 'a return from the block leaves no hidden file')

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
assert_eq(temp_files, [], 'the flag write leaves no hidden file')
assert_eq(File.open(game, 'rb', &:read), 'flags', 'a read still works')
# rubocop:enable Style/FileWrite, Style/FileOpen, Lint/NonAtomicFileOperation, Security/MarshalLoad

test_passed('test_safe_write', 29)
