# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Code like a game keeps its objects whole while the garbage collector
# runs as often as it can, and its save loads back the same.
#
# GC.stress starts a collection at each allocation. Stress mode alone
# can hide a fault: when a collection does not mark what a clone holds,
# the original often still holds it, and in stress mode the next
# collection comes before the game drops the original. So one schedule
# memorizes the sounds with stress mode off, between two stressed
# steps, as a game does between frames.
#
# Each check compares the result with the same rounds run with the
# collector off.
#
#   tools/run-engine-tests.sh --suite gc_stress.rb --ruby 18
#
# This file must parse on all three interpreters.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

# Ruby 3.1 reads 2 as stress mode with a lazy sweep. Ruby 1.8 and 1.9
# read any value other than false and nil as true.
GC.stress = 2
STRESS_MODES = GC.stress == 2 ? [true, 2] : [true]
GC.stress = false

EngineTest.suite('gc-stress', (3 * STRESS_MODES.size) + 1)

STRESS_ROUNDS = 12
STRESS_SOUND_EFFECTS = 16
STRESS_FOES = 3
STRESS_TURNS = 2
STRESS_LOG_SIZE = 40
STRESS_WALK = 3000
STRESS_FRAME = 20
STRESS_LEFTOVERS = 20_000
STRESS_KEPT_LEFTOVERS = 500

def stressed(mode)
  GC.stress = mode
  yield
ensure
  GC.stress = false
end

module Nicknamed
  def nickname
    "#{name} the brave"
  end
end

class Battler
  attr_reader :name, :hp, :moves, :stats, :tone

  def initialize(name, level)
    @name = name
    @hp = level * 3
    @moves = %w[Tackle Growl Ember Surf].map { |move| "#{move} #{level}" }
    @stats = { :attack => level * 2, :speed => level / 3.0, :types => %w[fire water] }
    @tone = Tone.new(level % 255, 0, 0, 0)
  end

  def speed
    @stats[:speed]
  end

  def hit(damage)
    @hp -= damage
    @moves = @moves.reverse
    @stats[:speed] += 0.5
    @stats[:types] = @stats[:types].sort.uniq
  end
end

def sound(name, volume)
  RPG::AudioFile.new(name, volume, 100)
end

def walk
  Array.new(STRESS_WALK) { 'x' * 16 }
end

def new_save
  map = Table.new(16, 8, 2)
  16.times { |x| 8.times { |y| map[x, y, 0] = (x * 8) + y } }
  party = Array.new(6) { |i| Battler.new("Mon #{i}", i + 5) }
  party.each_with_index { |battler, i| battler.extend(Nicknamed) if i.even? }
  save = {
    'system' => {},
    'party' => party,
    'lead' => party.first,
    'switches' => Array.new(100) { |i| (i % 3).zero? },
    'variables' => Array.new(100) { |i| i * 7 },
    'map' => map,
    'flashes' => [Color.new(255, 0, 0, 128)],
    'log' => [],
    'played' => []
  }
  save['system']['save'] = save
  save
end

def play_map_sounds(system, round)
  system['bgm'] = sound("Town #{round}", 100)
  system['bgs'] = sound("Rain #{round}", 80)
  system['se'] = Array.new(STRESS_SOUND_EFFECTS) { |i| sound("Step #{round} #{i}", 60) }
end

def pause_sounds(system)
  memorized = ([system['bgm'], system['bgs']] + system['se']).map(&:clone)
  system['bgm'] = system['bgs'] = nil
  system['se'] = []
  memorized
end

def fight_turn(fighters, log, round, turn)
  fighters.each_with_index do |attacker, i|
    target = fighters[(i + turn + 1) % fighters.size]
    damage = (((round * 7) + (turn * 3) + i) % 13) + 1
    target.hit(damage)
    log << "#{attacker.name} hit #{target.name} for #{damage}"
  end
end

def fight(save, party, round)
  foes = Array.new(STRESS_FOES) { |i| Battler.new("Foe #{round} #{i}", 5 + ((round + i) % 50)) }
  log = save['log']
  STRESS_TURNS.times do |turn|
    fighters = (party + foes).sort_by { |battler| [-battler.speed, battler.name] }
    fight_turn(fighters, log, round, turn)
    save['map'][turn, round % 8, 1] = log.size
  end
  save['flashes'] << Color.new(round * 10, (round * 37) % 256, 0, 255)
  log.shift while log.size > STRESS_LOG_SIZE
end

# Pokemon Essentials keeps a clone of the playing sounds through a
# battle (getPlayingBGS, bgs_pause, the battle, bgs_resume). After the
# pause only the clones hold the names.
def battle(save, round, memorize_mode, battle_mode)
  system = save['system']
  walk
  play_map_sounds(system, round)
  walk
  stressed(battle_mode) { Array.new(STRESS_FRAME) { 'x' * 16 } }
  memorized = stressed(memorize_mode) { pause_sounds(system) }
  stressed(battle_mode) do
    party = save['party'].map(&:clone)
    fight(save, party, round)
    save['party'] = party
    save['lead'] = party.first
    system['bgm'] = memorized[0]
    system['bgs'] = memorized[1]
    system['se'] = memorized[2..-1]
    save['played'].concat(memorized)
  end
end

def play(memorize_mode, battle_mode)
  save = new_save
  STRESS_ROUNDS.times { |round| battle(save, round, memorize_mode, battle_mode) }
  save
end

def unstressed_save
  GC.start
  GC.disable
  play(false, false)
ensure
  GC.enable
end

def immediate?(value)
  value.nil? || value.equal?(true) || value.equal?(false) || value.is_a?(Symbol) || value.is_a?(Numeric)
end

# The live object at an object id, or nil when its slot was freed. A
# method call on a freed slot can crash the interpreter, so the checks
# read each object by its id first.
def alive_at(id)
  ObjectSpace._id2ref(id)
rescue RangeError
  nil
end

def alive?(value)
  immediate?(value) || alive_at(value.object_id).equal?(value)
end

def array_difference(expected, actual, path, pairs)
  return "#{path} has #{actual.size} items, not #{expected.size}" unless expected.size == actual.size

  expected.each_index do |i|
    found = difference(expected[i], actual[i], "#{path}[#{i}]", pairs)
    return found if found
  end
  nil
end

def hash_difference(expected, actual, path, pairs)
  return "#{path} has #{actual.size} keys, not #{expected.size}" unless expected.size == actual.size

  expected.each_pair do |key, value|
    return "#{path} has no key #{key.inspect}" unless actual.key?(key)

    found = difference(value, actual[key], "#{path}[#{key.inspect}]", pairs)
    return found if found
  end
  nil
end

def object_difference(expected, actual, path, pairs)
  methods = actual.singleton_methods.sort
  return "#{path} has the methods #{methods.inspect}" unless expected.singleton_methods.sort == methods

  names = expected.instance_variables.sort
  return "#{path} has other instance variables" unless names == actual.instance_variables.sort

  names.each do |name|
    found = difference(expected.instance_variable_get(name), actual.instance_variable_get(name),
                       "#{path}.#{name}", pairs)
    return found if found
  end
  nil
end

def value_difference(expected, actual, path)
  # Color#== is always false on Ruby 1.8.
  same = if immediate?(expected) || expected.is_a?(String)
           expected == actual
         else
           Marshal.dump(expected) == Marshal.dump(actual)
         end
  same ? nil : "#{path} is #{actual.inspect}, not #{expected.inspect}"
end

# The first path where `actual` differs from `expected`, or nil.
# `pairs` maps each object of `expected` to its object in `actual`,
# so a shared object or a cycle must be shared in both.
# rubocop:disable Lint/HashCompareByIdentity -- Hash#compare_by_identity is not on Ruby 1.8.
def difference(expected, actual, path, pairs = {})
  return "#{path} is a freed object" unless alive?(actual)
  return "#{path} is a #{actual.class}, not a #{expected.class}" unless actual.instance_of?(expected.class)
  return value_difference(expected, actual, path) if immediate?(expected)

  if pairs.key?(expected.object_id)
    return pairs[expected.object_id].equal?(actual) ? nil : "#{path} is not shared as in the original"
  end

  pairs[expected.object_id] = actual
  case expected
  when String, Color, Tone, Rect, Table then value_difference(expected, actual, path)
  when Array then array_difference(expected, actual, path, pairs)
  when Hash then hash_difference(expected, actual, path, pairs)
  else object_difference(expected, actual, path, pairs)
  end
end
# rubocop:enable Lint/HashCompareByIdentity

def label(mode)
  mode == true ? 'stress mode' : "stress mode #{mode}, with a lazy sweep"
end

STRESS_SAVE = File.join(Dir.pwd, 'gc_stress_save.rxdata')

def save_and_load(save, mode)
  stressed(mode) do
    File.open(STRESS_SAVE, 'wb') { |file| Marshal.dump(save, file) }
    loaded = File.open(STRESS_SAVE, 'rb') { |file| Marshal.load(file) } # rubocop:disable Security/MarshalLoad
    File.delete(STRESS_SAVE)
    loaded
  end
end

STRESS_MODES.each do |mode|
  stressed_save = nil

  EngineTest.test("battles in #{label(mode)} keep the party, the log and the memorized sounds") do
    stressed_save = play(mode, mode)
    found = difference(unstressed_save, stressed_save, 'save')
    EngineTest.assert(found.nil?, found)
  end

  EngineTest.test("sounds memorized between battles in #{label(mode)} keep their names") do
    save = play(false, mode)
    found = difference(unstressed_save, save, 'save')
    EngineTest.assert(found.nil?, found)
  end

  EngineTest.test("a save written and read in #{label(mode)} loads back the same") do
    loaded = save_and_load(stressed_save || play(mode, mode), mode)
    found = difference(unstressed_save, loaded, 'loaded save')
    EngineTest.assert(found.nil?, found)
  end
end

StressLeftover = Class.new

# The leftovers are garbage that no collection freed yet. Stress mode
# starts in the block: an allocation before the walk starts a
# collection that frees all of them. Then each call of the block starts
# a collection while each_object walks the heaps.
EngineTest.test('an object from each_object in stress mode stays alive') do
  GC.disable
  STRESS_LEFTOVERS.times { StressLeftover.new }
  GC.enable
  kept = []
  begin
    ObjectSpace.each_object(StressLeftover) do |leftover|
      GC.stress = true
      kept << [leftover, leftover.object_id]
      break if kept.size >= STRESS_KEPT_LEFTOVERS
    end
  ensure
    GC.stress = false
  end
  GC.start
  bad = kept.reject { |_, id| alive_at(id).is_a?(StressLeftover) }
  EngineTest.assert(bad.empty?, "#{bad.size} of #{kept.size} kept objects were freed")
end

EngineTest.finish
