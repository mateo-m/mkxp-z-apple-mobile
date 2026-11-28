#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for the Get Items adapter in cheat_pe19.rb, in a game whose
# PokemonMartAdapter only raises NotImplementedError and whose item mart
# uses the PokemonItemMartAdapter subclass. Some Essentials v21.1 kits
# split the adapter this way.
# Run: ruby tools/test_cheat_mart_adapter.rb

require_relative 'assertion_count'

SCRIPT = File.expand_path('../scripts/postload/cheat_pe19.rb', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

module MKXP
  def self.puts(_text); end
end

module GameData; end

class PokemonMartAdapter
  def getDisplayName(_item)
    raise NotImplementedError, "#{self.class} must implement #getDisplayName"
  end

  def getPrice(_item, _selling = false)
    raise NotImplementedError, "#{self.class} must implement #getPrice"
  end

  def showQuantity?(_item)
    raise NotImplementedError, "#{self.class} must implement #showQuantity?"
  end
end

class PokemonItemMartAdapter < PokemonMartAdapter
  def getDisplayName(item)
    "name of #{item}"
  end

  def getPrice(_item, _selling = false)
    200
  end

  def showQuantity?(_item)
    true
  end
end

PokemonMartScreen = Class.new
PokemonMart_Scene = Class.new

class Scene_Map
  def updateMaps; end
end

class Game_Player
  def passable?(_x, _y, _d, _strict = false)
    true
  end
end

load SCRIPT

adapter = CheatItemsAdapter.new
assert_eq(adapter.getDisplayName(:POTION), 'name of POTION', 'the cheat adapter names the item')
assert_eq(adapter.showQuantity?(:POTION), true, 'the cheat adapter shows the quantity')
assert_eq(adapter.getPrice(:POTION), 0, 'the cheat adapter gives each item for free')
assert_eq(adapter.getPrice(:POTION, true), 0, 'the cheat adapter sells each item for nothing')

test_passed('test_cheat_mart_adapter', 4)
