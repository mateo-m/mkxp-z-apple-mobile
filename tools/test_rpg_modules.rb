#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Loads the RPG module of each RGSS version (scripts/preload/rpg_*.rb).
# Rubocop skips those files, so this is their syntax check too.
# Run: ruby mkxp-z-apple-mobile/tools/test_rpg_modules.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

# Engine classes that the modules use. The XP module subclasses
# Sprite when it loads, and RPG::Map#initialize makes a Table.
Sprite = Class.new

class Table
  def initialize(*); end
end

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

def load_rpg(version)
  Object.send(:remove_const, :RPG) if Object.const_defined?(:RPG)
  load File.join(ROOT, 'scripts', 'preload', "rpg_#{version}.rb")
end

load_rpg('xp')
assert_eq(RPG::Sprite.superclass, Sprite, 'XP: RPG::Sprite subclasses the engine Sprite')
assert_eq(RPG::Cache.respond_to?(:load_bitmap), true, 'XP: RPG::Cache loads bitmaps')
assert_eq(RPG::Map.new(20, 15).width, 20, 'XP: RPG::Map')

load_rpg('vx')
assert_eq(RPG::BGM.superclass, RPG::AudioFile, 'VX: RPG::BGM')
assert_eq(RPG::Map.new(17, 13).width, 17, 'VX: RPG::Map')

load_rpg('vxace')
assert_eq(RPG::Weapon.superclass, RPG::EquipItem, 'VX Ace: RPG::Weapon')
map = RPG::Map.new(17, 13)
assert_eq([map.battleback1_name, map.battleback2_name], ['', ''],
          'VX Ace: RPG::Map has the battleback names that games read')

test_passed('rpg_modules', 7)
