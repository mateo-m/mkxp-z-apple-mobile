#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Tests for save_check.rb: the check of a new save before it replaces
# the old one, and the report and repair when a game loads a save.
# Run: ruby mkxp-z-apple-mobile/tools/test_save_check.rb

require_relative 'save_fs_harness'

# rubocop:disable Style/FileOpen, Security/MarshalLoad, Lint/ConstantDefinitionInBlock

module RPG
  class AudioFile
    attr_accessor :name, :volume, :pitch

    def initialize(name = '', volume = 100, pitch = 100)
      @name = name
      @volume = volume
      @pitch = pitch
    end
  end

  class BGM < AudioFile; end
end

# The engine classes give their own class from _load.
class Color
  attr_reader :red

  def initialize(red)
    @red = red
  end

  def _dump(_limit)
    [@red].pack('E')
  end

  def self._load(data)
    new(data.unpack1('E'))
  end
end

class Shape
  attr_accessor :parts
end

class Wrapped
  def initialize(value)
    @value = value
  end

  def marshal_dump
    [@value]
  end

  def marshal_load(value)
    @value = value[0]
  end
end

# A _dump that gives a String with an encoding writes 'I' 'u'. The
# name of the encoding is a String in the object table.
class Coded
  def _dump(_limit)
    'coded'.encode('Shift_JIS')
  end

  def self._load(_data)
    new
  end
end

# Ruby adds the encoding name of a _dump String to the table before the
# value.
class Tone
  def _dump(_limit)
    'tone'.encode('Shift_JIS')
  end

  def self._load(_data)
    new
  end
end

class Text < String; end
class List < Array; end
module Tag; end
Pair = Struct.new(:left, :right)

$userAgent = 'host'

reset_workspace!
load_windows_fs!

def problem_of(bytes)
  MKXPSaveCheck::Reader.new(bytes.unpack('C*')).problem_in_dumps
end

def ranges_problem(bytes, ranges)
  MKXPSaveCheck::Reader.new(bytes.unpack('C*')).problem_in_ranges(ranges)
end

# --- Each correct value reads back, and to its last byte ---
# The random graphs share objects, so the reader must count the object
# table as Ruby does, or a link to a String name reads as another type.
srand(20_261_119)
SHARED = []

def leaf
  case rand(16)
  when 0 then nil
  when 1 then true
  when 2 then rand(1 << 70) - (1 << 69)
  when 3 then rand(200) - 100
  when 4 then rand * 1000
  when 5 then "text #{rand(100)}".encode(%w[UTF-8 ASCII-8BIT US-ASCII Shift_JIS].sample)
  when 6 then :"sym#{rand(5)}"
  when 7 then "été".to_sym
  when 8 then /a#{rand(3)}b/i
  when 9 then Color.new(rand(255))
  when 10 then Text.new("sub #{rand(9)}")
  when 11 then RPG::AudioFile
  when 12 then Coded.new
  when 13 then 'tagged'.dup.extend(Tag)
  else SHARED.empty? ? 'empty' : SHARED.sample
  end
end

def name_value
  case rand(4)
  when 0 then nil
  when 1 then SHARED.grep(String).sample || 'Battle1'
  else "Audio #{rand(50)}"
  end
end

def graph(depth)
  return leaf if depth.zero? || rand(4).zero?

  value =
    case rand(9)
    when 0 then Array.new(rand(4)) { graph(depth - 1) }
    when 1 then Hash[Array.new(rand(3)) { [leaf, graph(depth - 1)] }]
    when 2 then Hash.new(graph(depth - 1)).merge!(1 => graph(depth - 1))
    when 3 then Pair.new(graph(depth - 1), graph(depth - 1))
    when 4 then Wrapped.new(graph(depth - 1))
    when 5 then List.new([graph(depth - 1)])
    when 6
      shape = Shape.new
      shape.parts = [graph(depth - 1), leaf]
      shape
    when 7 then (rand(2).zero? ? RPG::AudioFile : RPG::BGM).new(name_value, rand(100), rand(150))
    else
      text = "ivars #{rand(9)}"
      text.instance_variable_set(:@note, graph(depth - 1))
      text
    end
  SHARED << value if rand(3).zero?
  value
end

def audio_files(value, seen = {}, found = [])
  return found if seen[value.__id__]

  seen[value.__id__] = true
  found << value if value.is_a?(RPG::AudioFile)
  children =
    case value
    when Array then value
    when Hash then value.to_a.flatten(1) + [value.default]
    when Struct then value.to_a
    else value.instance_variables.map { |name| value.instance_variable_get(name) }
    end
  children.each { |child| audio_files(child, seen, found) }
  found
end

good = 0
bad = 0
400.times do |round|
  SHARED.clear
  value = Array.new(4) { graph(5) }
  value << RPG::AudioFile.new(SHARED.grep(String).first || 'link', 80, 100)
  bytes = Marshal.dump(value)
  assert_eq(problem_of(bytes), nil, "random save #{round} has no fault")
  assert_eq(ranges_problem(bytes, [[0, bytes.bytesize]]), nil, "random save #{round} reads to its last byte")
  good += 1

  sounds = audio_files(value)
  broken = sounds.sample
  wrong = [1.5, [1, 2], { 1 => 2 }, 7, :name, Color.new(3), true, Shape.new, Pair.new(1, 2), (1 << 80),
           SHARED.grep(Float).first || 2.5].sample
  broken.name = wrong
  problem = problem_of(Marshal.dump(value))
  assert_true(problem.is_a?(String) && problem.start_with?("the @name of an #{broken.class.name} is a"),
              "random save #{round} with a #{wrong.class} name has a fault")
  bad += 1
end
assert_eq([good, bad], [400, 400], 'the random saves ran')

# --- Each value adds to the object table as Ruby does ---
# A link to the name must not land on the Float next to the name, or
# on the String next to a Float name.
sjis = "\x82\xa0".dup.force_encoding('Shift_JIS')
extended = 'tagged'.dup.extend(Tag)
with_ivar = 'note'.dup
with_ivar.instance_variable_set(:@note, sjis.dup)
values = {
  'a Shift_JIS String' => sjis,
  'a Shift_JIS symbol' => sjis.to_sym,
  'a UTF-8 symbol' => "\u00e9t\u00e9".to_sym,
  'two links to symbols' => [sjis.to_sym, sjis.to_sym, :plain, :plain],
  'a _dump value with an encoding' => Coded.new,
  'a _dump value' => Color.new(1),
  'a marshal_dump value' => Wrapped.new(sjis),
  'a String subclass' => Text.new('sub'),
  'an Array subclass' => List.new([sjis]),
  'an extended String' => extended,
  'a String with an ivar' => with_ivar,
  'a Struct' => Pair.new(sjis, 1),
  'a Hash with a default' => Hash.new(sjis).merge!(1 => 2),
  'a Regexp' => Regexp.new(sjis),
  'a Bignum' => 1 << 90,
  'a class' => RPG::AudioFile,
  'a module' => Tag,
  'an object' => Shape.new.tap { |shape| shape.parts = [sjis] }
}
values.each do |label, value|
  name = 'Battle'
  float = 2.5
  correct = [value, 1.5, name, 3.5, RPG::AudioFile.new(name)]
  assert_eq(problem_of(Marshal.dump(correct)), nil, "a link to a String name after #{label}")
  broken = [value, 'left', float, 'right', RPG::AudioFile.new(float)]
  assert_eq(problem_of(Marshal.dump(broken)), 'the @name of an RPG::AudioFile is a Float',
            "a link to a Float name after #{label}")
end

tone = Tone.new
assert_eq(problem_of(Marshal.dump([tone, RPG::AudioFile.new(tone)])), 'the @name of an RPG::AudioFile is a Tone',
          'a link to a _dump name with an encoding')

# --- The fault names the type ---
assert_eq(problem_of(Marshal.dump([RPG::AudioFile.new(0.25)])),
          'the @name of an RPG::AudioFile is a Float', 'a Float name')
assert_eq(problem_of(Marshal.dump(RPG::BGM.new(Color.new(1)))),
          'the @name of an RPG::BGM is a Color', 'a Color name')
float = 3.5
assert_eq(problem_of(Marshal.dump([float, RPG::AudioFile.new(float)])),
          'the @name of an RPG::AudioFile is a Float', 'a link to a Float name')
text = 'Battle'
assert_eq(problem_of(Marshal.dump([text, RPG::AudioFile.new(text)])), nil, 'a link to a String name')
assert_eq(problem_of(Marshal.dump(RPG::AudioFile.new(Text.new('sub')))), nil, 'a String subclass name')
assert_eq(problem_of(Marshal.dump(RPG::AudioFile.new('tag'.dup.extend(Tag)))), nil, 'an extended String name')
assert_eq(problem_of(Marshal.dump(RPG::AudioFile.new(Wrapped.new(1)))),
          'the @name of an RPG::AudioFile is a Wrapped', 'a marshal_dump object name')
assert_eq(problem_of(Marshal.dump(RPG::AudioFile.new(Coded.new))), nil,
          'a _dump name that the check cannot know is not a fault')

# --- Only a fault in a dump that reads back counts ---
assert_eq(problem_of(Marshal.dump('a') + 'not a dump'), nil, 'a file with more than dumps')
assert_eq(problem_of(Marshal.dump(1) + Marshal.dump(RPG::AudioFile.new(1.5))),
          'the @name of an RPG::AudioFile is a Float', 'a fault in the second dump')
cut = Marshal.dump(['a' * 40])
assert_eq(problem_of(cut[0, 20]), nil, 'a cut file without the ranges of its dumps')
assert_eq(ranges_problem(cut[0, 20], [[0, cut.bytesize]]), "bytes 0 to #{cut.bytesize} do not read back as a dump",
          'a cut dump')
assert_eq(ranges_problem(cut, [[0, cut.bytesize - 1]]), "bytes 0 to #{cut.bytesize - 1} do not read back as a dump",
          'a range that ends before the dump')
assert_eq(ranges_problem(cut + 'x', [[0, cut.bytesize + 1]]), "bytes 0 to #{cut.bytesize + 1} do not read back as a dump",
          'a range that ends after the dump')

def game_file(name)
  File.join(USERDATA, name)
end

def saved(path)
  File.open(path, 'rb') { |file| Marshal.load(file) }
end

game = game_file('Game.rxdata')
rejected = MKXPSafeWrite.temp_path(game, 'rejected')
trainer = { 'name' => 'Gold', 'bgm' => RPG::AudioFile.new('Route 29') }

# --- A correct save replaces the old one ---
File.open(game, 'wb') { |file| Marshal.dump(trainer, file) }
assert_eq(saved(game)['bgm'].name, 'Route 29', 'a correct save replaces the old one')
assert_eq(SAVE_REPORTS.map(&:first), [:load], 'a correct save sends no report')

# --- A save with a broken name keeps the old one ---
SAVE_REPORTS.clear
broken = { 'name' => 'Gold', 'bgm' => RPG::AudioFile.new(0.75) }
File.open(game, 'wb') do |file|
  Marshal.dump(1, file)
  Marshal.dump(broken, file)
end
assert_eq(saved(game)['bgm'].name, 'Route 29', 'the old save stays')
assert_true(File._mkxp_orig_exist(rejected), 'the new file stays next to the save')
assert_eq(File.binread(rejected), Marshal.dump(1) + Marshal.dump(broken), 'the file next to the save holds the new save')
assert_eq(SAVE_REPORTS.first, [:rejected, 'Game.rxdata: the @name of an RPG::AudioFile is a Float'],
          'the host gets the file name and the fault')
assert_eq(Dir.entries(USERDATA).grep(/mkxp/), [], 'the game does not see the file next to the save')

# --- One Marshal.dump of a String written with write ---
SAVE_REPORTS.clear
File.open(game, 'wb') { |file| file.write(Marshal.dump(broken)) }
assert_eq(saved(game)['bgm'].name, 'Route 29', 'a written dump with a fault keeps the old save')
assert_eq(SAVE_REPORTS.map(&:first), %i[rejected load], 'a written dump with a fault sends a report')

# --- A dump that the game wrote over ---
SAVE_REPORTS.clear
File.open(game, 'wb') do |file|
  Marshal.dump(['a' * 40], file)
  file.seek(10)
  file.write('zz')
end
assert_eq(File.binread(game).bytesize, cut.bytesize, 'a save that moves in the file replaces the old one')
assert_eq(SAVE_REPORTS, [], 'a save that moves in the file sends no report')

# --- A file that is not a dump ---
File.open(game, 'wb') { |file| file.write('plain text') }
assert_eq(File.binread(game), 'plain text', 'a text file replaces the old one')

# --- A save with a dump that does not read back ---
# A dump only fails to read back when its bytes change on the way, so
# the test changes them.
SAVE_REPORTS.clear
File.open(game, 'wb') { |file| Marshal.dump(trainer, file) }
File.open(game, 'wb') do |file|
  Marshal.dump(trainer, file)
  watch = file.instance_variable_get(:@mkxp_save_watch)
  watch[:ranges][0][1] += 1
  file.write('x')
end
assert_eq(saved(game)['bgm'].name, 'Route 29', 'a dump that does not read back keeps the old save')
assert_eq(SAVE_REPORTS.map(&:first), %i[rejected load], 'a dump that does not read back sends a report')
assert_true(SAVE_REPORTS.first[1].start_with?('Game.rxdata: bytes 0 to '), 'the report names the bytes')

# --- A load of a save sends one report and repairs the names ---
SAVE_REPORTS.clear
File.open(game, 'wb') { |file| file.write(Marshal.dump(1) + Marshal.dump(broken)) }
File.open(game, 'wb') { |file| Marshal.dump(trainer, file) }
# A save from before the check: a write through File.open is refused.
File._mkxp_orig_open(game_file('Damaged.rxdata'), 'wb') { |file| file.write(File.binread(rejected)) }
loaded = File.open(game_file('Damaged.rxdata'), 'rb') { |file| [Marshal.load(file), Marshal.load(file)] }
assert_eq(loaded[1]['bgm'].instance_variable_get(:@name), '', 'a load repairs a broken name')
assert_eq(SAVE_REPORTS.last, [:load, 'Damaged.rxdata'], 'a load sends the file name')
assert_eq(SAVE_REPORTS.count { |kind, _| kind == :load }, 1, 'a load of two dumps from one file sends one report')
File.open(game, 'wb') { |file| Marshal.dump(loaded[1], file) }
assert_eq(saved(game)['bgm'].name, '', 'a save after the load of a broken save replaces the old one')

called = []
value = File.open(game, 'rb') { |file| Marshal.load(file, proc { |obj| called << obj.class && obj }) }
assert_true(called.include?(RPG::AudioFile), 'a load still calls the proc of the game')
assert_eq(value['bgm'].name, '', 'a load gives the value of the proc of the game')

SAVE_REPORTS.clear
Dir.chdir(GAME) do
  MKXPSaveFS.capture_game_root!
  FileUtils.mkdir_p('Data')
  File.binwrite('Data/Map001.rxdata', Marshal.dump(RPG::AudioFile.new(1.5)))
  map = File.open('Data/Map001.rxdata', 'rb') { |file| Marshal.load(file) }
  assert_eq(map.instance_variable_get(:@name), 1.5, 'a load of a game data file changes nothing')
end
Marshal.load(Marshal.dump(broken))
assert_eq(SAVE_REPORTS, [], 'a load of game data or of a String sends no report')

# rubocop:enable Style/FileOpen, Security/MarshalLoad, Lint/ConstantDefinitionInBlock

test_passed('test_save_check', 1275)
