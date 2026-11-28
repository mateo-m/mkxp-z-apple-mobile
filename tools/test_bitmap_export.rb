#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Bitmap#save_to_file comes from the always-on preload, so it works with
# the fix-up scripts off. The postload `export` writes the same files.
# Run: ruby tools/test_bitmap_export.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

def load_quietly(path)
  prev_verbose = $VERBOSE
  $VERBOSE = nil
  load path
ensure
  $VERBOSE = prev_verbose
end

Object.const_set(:System, Module.new do
  module_function

  define_method(:puts) { |*_args| nil }
  define_method(:rpg_version) { 3 }
end)

class Bitmap
  attr_reader :written

  def raw_data; end

  def to_file(filename)
    (@written ||= []) << filename
    nil
  end

  def last_row_address
    0
  end

  def print(_text); end
end

# Some games call `save_to_file(path)` when `$MKXP` is set, and
# `export(path)` with no extension on Windows, which adds `.png`.
FILES = [
  ['Graphics/Characters/player_walk.png', 'Graphics/Characters/player_walk.png'],
  ['Graphics/Pictures/photo.JPG', 'Graphics/Pictures/photo.JPG'],
  ['Saves/Photo - 1794778193', 'Saves/Photo - 1794778193.png']
].freeze

load_quietly(File.join(ROOT, 'scripts', 'preload', 'pokemon_compat.rb'))

FILES.each do |path, file|
  bitmap = Bitmap.new
  assert_eq(bitmap.save_to_file(path), file, "save_to_file(#{path.inspect}) gives the file name")
  assert_eq(bitmap.written, [file], "save_to_file(#{path.inspect}) writes the file with the fix-up scripts off")
end

bitmap = Bitmap.new
assert_eq(bitmap.save_to_file('photo.gif'), nil, 'save_to_file of an unsupported format gives nil')
assert_eq(bitmap.written, nil, 'save_to_file of an unsupported format writes no file')

load_quietly(File.join(ROOT, 'scripts', 'postload', 'pokemon_graphics_compat.rb'))

FILES.each do |path, file|
  bitmap = Bitmap.new
  finished = false
  assert_eq(bitmap.export(path) { finished = true }, file, "export(#{path.inspect}) gives the file name")
  assert_eq([bitmap.written, finished], [[file], true], "export(#{path.inspect}) writes the file, then calls the block")
end

bitmap = Bitmap.new
finished = false
assert_eq(bitmap.export('photo.gif') { finished = true }, nil, 'export of an unsupported format gives nil')
assert_eq(finished, false, 'export of an unsupported format does not call the block')

test_passed('test_bitmap_export', 16)
