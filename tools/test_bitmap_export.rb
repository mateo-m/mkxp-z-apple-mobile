#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for the Zeus81 Bitmap Export rebuild in
# pokemon_graphics_compat.rb.
# Run: ruby tools/test_bitmap_export.rb

require_relative 'assertion_count'

SCRIPT = File.expand_path('../scripts/postload/pokemon_graphics_compat.rb', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

module Graphics
end

# The native methods that the rebuild needs, plus the
# `last_row_address` that the game's own copy of the Zeus script
# defines.
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
end

prev_verbose = $VERBOSE
$VERBOSE = nil
begin
  load SCRIPT
ensure
  $VERBOSE = prev_verbose
end

# Ecchi Version saves the player outfit and the camera photo with
# `if $MKXP then save_to_file(path) else export(path)`. On Windows,
# `$MKXP` is not set, so the game calls `export`. Each case gives the
# two paths of one call in the game.
[
  ['Graphics/Characters/player_walk.png', 'Graphics/Characters/player_walk'],
  ['Graphics/Transitions/vsPlayer.png', 'Graphics/Transitions/vsPlayer'],
  ['Saves/Photo - 1794778193', 'Saves/Photo - 1794778193']
].each do |mkxp_path, windows_path|
  windows = Bitmap.new
  windows.export(windows_path)

  bitmap = Bitmap.new
  written = begin
    bitmap.save_to_file(mkxp_path)
    bitmap.written
  rescue NoMethodError => e
    e.message
  end
  assert_eq(written, windows.written, "save_to_file(#{mkxp_path.inspect}) writes the Windows file")
end

test_passed('test_bitmap_export', 3)
