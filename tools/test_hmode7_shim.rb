#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for hmode7_shim.rb: the map renderer that Pokemon
# Insurgence 1.2 and 2.0 get.
# Run: ruby tools/test_hmode7_shim.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)
SHIM = File.join(ROOT, 'scripts', 'postload', 'hmode7_shim.rb')

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

Object.const_set(:System, Module.new do
  module_function

  define_method(:puts) { |*_args| nil }
  define_method(:is_windows?) { false }
end)

# win32_wrap.rb wraps Graphics.update at load time. Give it a target.
module Graphics
  def self.update; end
end

$VERBOSE = nil
load File.join(ROOT, 'scripts', 'preload', 'win32_wrap.rb')

module Platform
  def self.lib_path(base)
    "./lib#{base}.so"
  end

  def self.log(_message); end
end

# Both Insurgence versions set this flag from the [HM7] map name, and
# Spriteset_Map builds HM7::Tilemap when it is true.
def load_game_system
  Object.const_set(:Game_System, Class.new) unless defined?(Game_System)
  Game_System.class_eval { attr_accessor :hm7 }
end

class Spriteset_Map
  attr_reader :tilemap

  def initialize
    @tilemap = $game_system.hm7 ? HM7::Tilemap.new(nil, self) : :flat
  end
end

def open_hm7_map
  load_game_system
  $game_system = Game_System.new
  $game_system.hm7 = true
end

# Insurgence 1.2: HM7 calls the MGC DLL through Win32API.
module HM7; end
open_hm7_map
load SHIM
assert_eq($game_system.hm7, true, 'Insurgence 1.2 keeps the 3D renderer')

# Insurgence 2.0.2, scripts 211 and 212: the mkxp-z port checks its
# native library first.
# rubocop:disable all -- the game's code as it ships
module HM7
  LIB = Platform.lib_path("hmode7")
  class Error < RuntimeError; end

  @funcs = {}

  def self.func(name, imports, exports = "l")
    @funcs[name] ||= Win32API.new(LIB, name, imports, exports)
  end

  def self.available?
    return @available if !@available.nil?
    begin
      @available = (func("hm7_abi_version", "", "l").call == 1)
    rescue Exception => e
      Platform.log("H-Mode7 library unavailable: #{e.message}")
      @available = false
    end
    return @available
  end

  class Tilemap
    def initialize(viewport, spriteset)
      raise HM7::Error, "H-Mode7 library (#{HM7::LIB}) is not available" if !HM7.available?
    end
  end
end
# rubocop:enable all

open_hm7_map
error = begin
  Spriteset_Map.new
  nil
rescue HM7::Error => e
  e.message
end
assert_eq(error, 'H-Mode7 library (./libhmode7.so) is not available', '2.0 raises without the shim')

load SHIM
assert_eq(Spriteset_Map.new.tilemap, :flat, 'Insurgence 2.0 draws an [HM7] map flat')

# F12 runs the game's scripts again, then the postloads.
open_hm7_map
load SHIM
assert_eq(Spriteset_Map.new.tilemap, :flat, 'Insurgence 2.0 draws an [HM7] map flat after F12')

test_passed('test_hmode7_shim', 4)
