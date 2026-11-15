# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# A clone keeps what it points to through a garbage collection.
#
# Pokemon Essentials keeps a clone of the playing sound across a battle
# (`getPlayingBGS`, then `bgs_pause`, the battle, `bgs_resume`). The
# playing sound itself is dropped at the pause, so after that only the
# clone holds its name.
#
#   tools/run-engine-tests.sh --suite gc_clone.rb --ruby 18
#
# This file must parse on all three interpreters.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('gc-clone', 2)

ROUNDS = 40
SOUNDS = 2000

class Sound
  attr_reader :name

  def initialize(name)
    @name = name
  end
end

# Allocation between the clones, so that the collections start at
# different points of each round.
def churn
  Array.new(3000) { 'x' * 16 }
end

def collect_and_reuse
  3.times do
    GC.start
    churn
  end
end

# The live object at an object id, or nil when its slot was freed. A
# method call on a freed slot can crash the interpreter, so the check
# reads the slot by its id first.
def live(id)
  ObjectSpace._id2ref(id)
rescue RangeError
  nil
end

def keeps_name?(clone, id, text)
  name = live(id)
  name.is_a?(String) && name == text && clone.name.equal?(name)
end

EngineTest.test('a clone keeps its instance variables after the original is dropped') do
  sounds = Array.new(SOUNDS) { |i| Sound.new("bgs 0 #{i}") }
  kept = []
  ROUNDS.times do |round|
    churn
    sounds.each_index do |i|
      kept << [sounds[i].clone, sounds[i].name.object_id, sounds[i].name.dup]
      sounds[i] = Sound.new("bgs #{round + 1} #{i}")
    end
  end
  collect_and_reuse
  bad = kept.reject { |clone, id, text| keeps_name?(clone, id, text) }
  found = bad.map { |_, id, _| (name = live(id)) ? name.class.name : 'a freed slot' }.uniq.sort
  EngineTest.assert(bad.empty?,
                    "#{bad.size} of #{kept.size} clones lost their name, found #{found.join(', ')}")
end

def tagged_sound(name)
  sound = Sound.new(name)
  def sound.tag
    name
  end
  sound
end

# The kept name holds the string, so a failure here comes from the
# method or from the clone itself.
EngineTest.test('a clone keeps its singleton methods after the original is dropped') do
  sounds = Array.new(SOUNDS) { |i| tagged_sound("bgs 0 #{i}") }
  kept = []
  ROUNDS.times do |round|
    churn
    sounds.each_index do |i|
      kept << [sounds[i].clone, sounds[i].name]
      sounds[i] = tagged_sound("bgs #{round + 1} #{i}")
    end
  end
  collect_and_reuse
  bad = kept.reject { |clone, name| clone.tag.equal?(name) }
  EngineTest.assert(bad.empty?, "#{bad.size} of #{kept.size} clones lost their method")
end

EngineTest.finish
