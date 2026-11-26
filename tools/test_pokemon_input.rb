#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for pokemon_input.rb: the Pokemon Essentials marker, the
# name screen with the "In-game keyboard" setting on, and the press and
# repeat answers of the input module.
# Run: ruby tools/test_pokemon_input.rb

require 'tmpdir'
require_relative 'assertion_count'

SCRIPT = File.expand_path('../scripts/postload/pokemon_input.rb', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

$PokemonSystem = Object.new

$managed_dir = nil
$mkxp_log = []

module MKXP
  def self.use_in_game_keyboard?
    true
  end

  def self.managed_config_dir
    $managed_dir
  end

  def self.puts(message)
    $mkxp_log << message
  end
end

module Input
  def self.update; end
end

class Viewport
  def self.all
    @all ||= []
  end

  attr_reader :disposed

  def initialize
    Viewport.all << self
  end

  def dispose
    @disposed = true
  end
end

class Grid
  def update; end
end

$fades = []

def pbFadeInAndShow(sprites)
  $fades << sprites.keys
end

def pbDisposeSpriteHash(sprites)
  sprites.clear
end

# The stock Essentials scene: it builds the letter grid when
# USEKEYBOARD is off.
STOCK_SCENE = <<-RUBY.freeze
  class PokemonEntryScene
    USEKEYBOARD = true

    def pbStartScene(_helptext, _minlength, _maxlength, _initial, _subject = 0, _pokemon = nil)
      @sprites = {}
      @viewport = Viewport.new
      @sprites['entry'] = USEKEYBOARD ? :keyboard_window : :plain_window
      @sprites['entry2'] = Grid.new unless USEKEYBOARD
      pbFadeInAndShow(@sprites)
    end

    def pbEntry
      return :typed if USEKEYBOARD

      @sprites['entry2'].update
      :grid
    end
  end
RUBY

# Pokemon Xenoverse's 225_NewNameEntry.rb: the same scene, but its
# pbStartScene never builds the letter grid.
XENOVERSE_SCENE = STOCK_SCENE.sub(/^.*Grid\.new.*\n/, '')

def load_game(scene_source)
  Object.send(:remove_const, :PokemonEntryScene) if defined?(PokemonEntryScene)
  Object.class_eval(scene_source)
  load SCRIPT
  $fades = []
  PokemonEntryScene.new
end

scene = load_game(XENOVERSE_SCENE)
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq(scene.pbEntry, :typed, 'a scene without a letter grid takes typed text')
assert_eq($fades, [%w[entry]], 'the screen fades in once')
assert_eq(scene.instance_variable_get(:@sprites)['entry'], :keyboard_window,
          'the screen is built again with the typing window')
assert_eq(Viewport.all.map(&:disposed), [true, nil], 'the first viewport is disposed')
assert_eq(PokemonEntryScene::USEKEYBOARD, true, 'typing mode stays for the session')

$fades = []
scene = PokemonEntryScene.new
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq(scene.pbEntry, :typed, 'the next name screen also takes typed text')
assert_eq($fades.length, 1, 'the next name screen fades in once')

scene = load_game(STOCK_SCENE)
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq(scene.pbEntry, :grid, 'a stock scene keeps the letter grid')
assert_eq($fades, [%w[entry entry2]], 'a stock scene fades in once, with the grid')
assert_eq(PokemonEntryScene::USEKEYBOARD, false, 'a stock scene stays in grid mode')

# F12 runs the game scripts again, which puts the game's pbStartScene
# back, then runs this script again.
Object.class_eval(XENOVERSE_SCENE)
load SCRIPT
$fades = []
scene = PokemonEntryScene.new
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq(scene.pbEntry, :typed, 'after a reset, a scene without a letter grid takes typed text')
assert_eq($fades.length, 1, 'after a reset, the screen fades in once')

load SCRIPT
$fades = []
scene = PokemonEntryScene.new
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq($fades.length, 1, 'a second load of the script does not wrap the scene twice')

$fades = []
scene.pbFadeInAndShow({})
assert_eq($fades.length, 1, 'a fade outside the name screen goes through')

scene = load_game(XENOVERSE_SCENE.sub(/^.*Viewport\.new.*\n/, ''))
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq(scene.pbEntry, :typed, 'a scene with no viewport takes typed text')

scene = load_game(XENOVERSE_SCENE.sub(/^.*USEKEYBOARD = true.*\n/, ''))
scene.pbStartScene('Your name?', 1, 7, '', 1)
assert_eq(scene.pbEntry, :typed, 'a scene with no USEKEYBOARD of its own takes typed text')
assert_eq(USEKEYBOARDTEXTENTRY, true, 'the top-level setting also goes to typing mode')

# The engine side of the input module. Each frame sets the native
# answers for one button.
module Input
  class << self
    attr_accessor :engine
  end

  def self.jpress?(_button)
    @engine[:press]
  end

  def self.jtrigger?(_button)
    @engine[:trigger]
  end

  def self.jrepeat?(_button)
    @engine[:repeat]
  end

  def self.jupdate; end
end

RELEASED = { press: false, trigger: false, repeat: false }.freeze
PRESSED = { press: true, trigger: true, repeat: true }.freeze
HELD = { press: true, trigger: false, repeat: false }.freeze
HELD_REPEAT = { press: true, trigger: false, repeat: true }.freeze
DOWN = 2

def moves(frames)
  frames.map do |state|
    Input.engine = state
    Input.update
    yield ? 1 : 0
  end
end

load SCRIPT
frames = [RELEASED, PRESSED, HELD, HELD, HELD_REPEAT, HELD, RELEASED]
# Pokemon Xenoverse's DexMain#inputHandle moves the cursor like this.
assert_eq(moves(frames) { Input.repeat?(DOWN) || Input.trigger?(DOWN) }, [0, 1, 0, 0, 1, 0, 0],
          'repeat? then trigger? moves once for a press and once for each repeat')
assert_eq(moves(frames) { Input.trigger?(DOWN) }, [0, 1, 0, 0, 0, 0, 0],
          'trigger? is true once for a press')
assert_eq(moves(frames) { Input.repeat?(DOWN) }, [0, 1, 0, 0, 1, 0, 0],
          'repeat? is true for a press and for each repeat')

assert_eq(moves(frames) { Input.trigger?(DOWN) || Input.repeat?(DOWN) }, [0, 1, 0, 0, 1, 0, 0],
          'trigger? then repeat? moves once for a press and once for each repeat')

# The key goes up and down again while the game reads nothing, for
# example during an animation.
reads = [true, false, false, true, true]
answers = [PRESSED, HELD, RELEASED, PRESSED, RELEASED].zip(reads).map do |state, read|
  Input.engine = state
  Input.update
  read ? [Input.repeat?(DOWN), Input.trigger?(DOWN)] : nil
end
assert_eq(answers.compact, [[true, true], [true, true], [false, false]],
          'a new press is a press, also when no read saw the release')

# A second Input.update before the read hides the native trigger edge.
Input.engine = PRESSED
Input.update
Input.engine = HELD
Input.update
assert_eq([Input.repeat?(DOWN), Input.trigger?(DOWN)], [true, true],
          'a press that a second update hides still counts once')
Input.update
assert_eq([Input.repeat?(DOWN), Input.trigger?(DOWN)], [false, false],
          'the next frame of that press is not a new press')

# Ruby 1.8 has no File.write.
def without_file_write
  IO.singleton_class.send(:alias_method, :mkxp_test_write, :write)
  IO.singleton_class.send(:undef_method, :write)
  yield
ensure
  IO.singleton_class.send(:alias_method, :write, :mkxp_test_write)
end

def check_marker(ruby)
  Dir.mktmpdir do |dir|
    $managed_dir = dir
    $mkxp_log = []
    load SCRIPT
    assert_eq($mkxp_log, [], "#{ruby}: the script logs no error")
    assert_eq(File.exist?("#{dir}/.pokemon_essentials_detected"), true, "#{ruby}: the script writes the marker")
  end
ensure
  $managed_dir = nil
end

without_file_write { check_marker('Ruby 1.8') }

test_passed('test_pokemon_input', 26)
