#!/usr/bin/env ruby
# Regression tests for the Graphics compat delegates: the preload
# snapshot (pokemon_compat.rb) plus the postload poke_* / mkxp_*
# delegates (pokemon_graphics_compat.rb). The bug class under test:
# a game redefines a live Graphics method as a wrapper over a compat
# name (Daybreak's snap_to_bitmap returns mkxp_snap_to_bitmap), and
# a late-bound delegate then closes a call loop that dies with
# SystemStackError at the first battle transition.
# Run: ruby mkxp-z-apple-mobile/tools/test_graphics_compat.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

Object.const_set(:System, Module.new do
  module_function

  define_method(:puts) { |*_args| nil }
  # Pokemon Essentials is XP-based. The preload gates its
  # disposed-safe wrappers on this (see 51b16905).
  define_method(:rpg_version) { 1 }
end)

# Native Graphics stand-in, defined before the preload snapshot runs
# (in production these are C bindings present at VM boot).
module Graphics
  CALLS = []

  def self.width
    640
  end

  def self.height
    384
  end

  def self.snap_to_bitmap
    CALLS << :native_snap
    :native_bitmap
  end

  def self.resize_screen(w, h)
    CALLS << [:native_resize, w, h]
  end

  def self.play_movie(filename)
    CALLS << [:native_movie, filename]
  end
end

# Native display classes the preload wraps (C bindings in
# production). Empty shells satisfy its guarded method wrapping.
class Sprite; end
class Window; end
class Viewport; end
class Plane; end
class Tilemap; end

prev_verbose = $VERBOSE
$VERBOSE = nil
begin
  load File.join(ROOT, 'scripts', 'preload', 'pokemon_compat.rb')
ensure
  $VERBOSE = prev_verbose
end

assert_eq(
  Graphics.instance_variable_get(:@__mkxp_native_snap_to_bitmap).nil?,
  false,
  'preload snapshots native snap_to_bitmap'
)

# --- Game scripts load and rebind the live names ---
# Daybreak's "MKXP Compatbility Fix": the live method becomes a
# wrapper over the compat name.
module Graphics
  def self.snap_to_bitmap
    Graphics.mkxp_snap_to_bitmap
  end
end

# JoiPlay-runtime wrapper some games ship verbatim: the live name
# delegates to the poke_* flavor.
module Graphics
  def self.width
    Graphics.poke_width
  end
end

prev_verbose = $VERBOSE
$VERBOSE = nil
begin
  load File.join(ROOT, 'scripts', 'postload', 'pokemon_graphics_compat.rb')
ensure
  $VERBOSE = prev_verbose
end

# --- The Daybreak battle-transition path ---
result = begin
  Graphics.snap_to_bitmap
rescue SystemStackError
  :stack_overflow
end
assert_eq(result, :native_bitmap, 'snap_to_bitmap reaches the native method through the game wrapper')
assert_eq(Graphics::CALLS.last, :native_snap, 'the native snapshot was what ran')

result = begin
  Graphics.mkxp_snap_to_bitmap
rescue SystemStackError
  :stack_overflow
end
assert_eq(result, :native_bitmap, 'mkxp_snap_to_bitmap resolves to the native method')
assert_eq(Graphics.poke_snap_to_bitmap, :native_bitmap, 'poke_snap_to_bitmap resolves to the native method')

# --- The JoiPlay width wrapper path ---
result = begin
  Graphics.width
rescue SystemStackError
  :stack_overflow
end
assert_eq(result, 640, 'width reaches the native method through the game wrapper')
assert_eq(Graphics.poke_height, 384, 'poke_height resolves to the native method')

# --- Argument-taking delegates hit the snapshots ---
Graphics.poke_resize_screen(800, 600)
assert_eq(Graphics::CALLS.last, [:native_resize, 800, 600], 'poke_resize_screen forwards to native')
Graphics.zeus_play_movie('intro.avi', true, false)
assert_eq(Graphics::CALLS.last, [:native_movie, 'intro.avi'], 'zeus_play_movie forwards to native')

# --- Fallback: a missing snapshot uses the live name ---
Graphics.instance_variable_set(:@__mkxp_native_play_movie, nil)
Graphics.zeus_play_movie('late.avi')
assert_eq(Graphics::CALLS.last, [:native_movie, 'late.avi'], 'missing snapshot falls back to the live method')

test_passed('test_graphics_compat', 10)
