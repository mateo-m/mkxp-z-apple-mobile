#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for pokemon_input.rb in a game whose own `update` methods
# take arguments: the text entry window and the input module keep the
# arguments of the game's call.
# Run: ruby tools/test_pokemon_input_update_args.rb

require_relative 'assertion_count'

SCRIPT = File.expand_path('../scripts/postload/pokemon_input.rb', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

$PokemonSystem = Object.new

module MKXP
  def self.use_in_game_keyboard?
    false
  end

  def self.puts(_message); end
end

module Input
  class << self
    attr_reader :updated_with
  end

  def self.update(*args)
    @updated_with = args
  end

  def self.jupdate; end

  def self.delta
    0
  end

  def self.triggerex?(_key)
    false
  end
end

class Window_TextEntry_Keyboard
  attr_reader :updated_with

  def update(*args)
    @updated_with = args
  end
end

load SCRIPT

Input.update(:frame)
assert_eq(Input.updated_with, [:frame], 'Input.update gives its argument to the game update')
Input.update
assert_eq(Input.updated_with, [], 'Input.update with no argument calls the game update with none')

window = Window_TextEntry_Keyboard.new
window.update(:frame)
assert_eq(window.updated_with, [:frame], 'the text entry update gives its argument to the game update')
window.update
assert_eq(window.updated_with, [], 'the text entry update with no argument calls the game update with none')

test_passed('test_pokemon_input_update_args', 4)
