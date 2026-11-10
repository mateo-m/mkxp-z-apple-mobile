#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for the System stand-ins in platform_compat.rb.
# System.mouse_in_window: mkxp-z moved the method to Input, and
# Pokemon Essentials v20 and v20.1 still call the System name from
# Mouse.getMousePos.
# Run: ruby mkxp-z-apple-mobile/tools/test_platform_compat.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

# platform_compat.rb targets the in-game VMs (1.8 / 1.9 / 3.1), which
# all still have the `exists?` aliases. Ruby 3.2 removed them.
[File, FileTest, Dir].each do |mod|
  mod.singleton_class.class_eval do
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
end

require 'tmpdir'
require 'fileutils'
require 'stringio'
USERDATA = Dir.mktmpdir('test_platform_compat')
at_exit { FileUtils.rm_rf(USERDATA) }

Object.const_set(:System, Module.new do
  module_function

  define_method(:data_directory) { USERDATA }
  define_method(:puts) { |line| LOGGED.push(line) }
  define_method(:debug_log?) { DEBUG_LOG_ON[0] }
end)
LOGGED = []
DEBUG_LOG_ON = [true]

module Input
  @in_window = true

  def self.in_window=(value)
    @in_window = value
  end

  def self.mouse_in_window
    @in_window
  end
end

# The app sets TMPDIR to its own temp folder, with a trailing slash.
ENV['TMPDIR'] = "#{USERDATA}/tmp/"
ENV.delete('TEMP')
ENV.delete('TMP')

prev_verbose = $VERBOSE
$VERBOSE = nil
begin
  load File.join(ROOT, 'scripts', 'preload', 'platform_compat.rb')
ensure
  $VERBOSE = prev_verbose
end

assert_eq(System.respond_to?(:mouse_in_window), true, 'System.mouse_in_window exists after the preload')
assert_eq(System.mouse_in_window, true, 'System.mouse_in_window answers true like Input')
Input.in_window = false
assert_eq(System.mouse_in_window, false, 'System.mouse_in_window follows Input.mouse_in_window')

assert_eq(ENV['TEMP'], "#{USERDATA}/tmp", 'ENV TEMP is the app temp folder from TMPDIR')

# --- A failed save names the value that stopped it ---
class Game_Variables
  def initialize
    @data = [nil, 5, 'text']
  end

  def []=(index, value)
    @data[index] = value
  end
end

vars = Game_Variables.new
assert_eq(Marshal.load(Marshal.dump(vars)).instance_variable_get(:@data), [nil, 5, 'text'],
          'Marshal.dump still dumps a value that can be dumped')
assert_eq(LOGGED, [], 'a dump that works writes nothing to the log')

vars[3] = proc { nil }
err = begin
  Marshal.dump(vars)
  nil
rescue TypeError => e
  e
end
assert_eq(err.class, TypeError, 'the game still gets the dump error')
assert_eq(LOGGED.length, 1, 'a failed dump writes one log line')
assert_eq(LOGGED[0].include?('Game_Variables@data[3] = a Proc'), true,
          "the log line names the value: #{LOGGED[0]}")

LOGGED.clear
bad_hash = Hash.new { |h, k| h[k] = 0 }
begin
  Marshal.dump([1, { :ok => bad_hash }])
rescue TypeError
  nil
end
assert_eq(LOGGED[0].include?('Array[1][:ok] = a Hash'), true,
          "a hash with a default proc is the value named: #{LOGGED[0]}")

LOGGED.clear
io = StringIO.new
Marshal.dump(vars.instance_variable_get(:@data)[0, 3], io)
assert_eq(Marshal.load(io.string), [nil, 5, 'text'], 'Marshal.dump to a stream still works')

closed = StringIO.new
closed.close_write
begin
  Marshal.dump([1], closed)
rescue IOError
  nil
end
assert_eq(LOGGED[0].include?('the write to the stream failed'), true,
          "a failed write is told apart from a value that cannot be dumped: #{LOGGED[0]}")

# A link back to a parent dumps fine, so it must not be blamed.
class Node
  attr_accessor :parent
end
LOGGED.clear
MKXPMarshalTrace.reset
node = Node.new
tree = [node, proc {}]
node.parent = tree
begin
  Marshal.dump(tree)
rescue TypeError
  nil
end
assert_eq(LOGGED[0].include?('Array[1] = a Proc'), true,
          "a link back to the parent is skipped: #{LOGGED[0]}")

# A crash alert names the first line of the backtrace.
trace = begin
  Marshal.dump(proc {})
  []
rescue TypeError => e
  e.backtrace
end
assert_eq(trace[0].start_with?("#{__FILE__}:"), true,
          "the backtrace starts at the caller: #{trace[0]}")

LOGGED.clear
begin
  Marshal.dump([[[1]]], 1)
rescue ArgumentError
  nil
end
assert_eq(LOGGED[0].include?('deeper than the depth limit of 1'), true,
          "a depth limit error says so: #{LOGGED[0]}")

LOGGED.clear
MKXPMarshalTrace.reset
12.times do
  begin
    Marshal.dump(proc {})
  rescue TypeError
    nil
  end
end
assert_eq(LOGGED.length, 10, 'one game writes at most 10 lines')
MKXPMarshalTrace.reset
begin
  Marshal.dump(proc {})
rescue TypeError
  nil
end
assert_eq(LOGGED.length, 11, 'the next game writes lines again')

LOGGED.clear
MKXPMarshalTrace.reset
DEBUG_LOG_ON[0] = false
begin
  Marshal.dump(proc {})
rescue TypeError
  nil
end
DEBUG_LOG_ON[0] = true
assert_eq(LOGGED, [], 'with debug logs off there is no search and no line')

if defined?(BasicObject)
  LOGGED.clear
  bare = BasicObject.new
  bad = proc {}
  bare.instance_eval { @bad = bad }
  begin
    Marshal.dump([bare])
  rescue TypeError
    nil
  end
  assert_eq(LOGGED.length, 1, "a BasicObject value still gets a line: #{LOGGED.inspect}")
end

def logged_for(value)
  LOGGED.clear
  MKXPMarshalTrace.reset
  begin
    Marshal.dump(value)
  rescue TypeError, ArgumentError, RuntimeError
    nil
  end
  LOGGED.join("\n")
end

module Tag
  def tag; end
end
line = logged_for({ :list => [1, proc {}].extend(Tag) })
assert_eq(line.include?('Hash[:list][1] = a Proc'), true, "an extended value is walked: #{line}")

line = logged_for([RuntimeError.new(proc {})])
assert_eq(line.include?('Could not find which value fails.'), true, "a missed value is not blamed on a stream: #{line}")

class HookRaises
  def marshal_dump
    raise 'broken hook'
  end
end
line = logged_for([1, HookRaises.new])
assert_eq(line.include?('Array[1] = a HookRaises'), true, "a marshal_dump that raises is named: #{line}")

Pair = Struct.new(:a, :b)
line = logged_for(Pair.new(1, proc {}))
assert_eq(line.include?('Pair.b = a Proc'), true, "a Struct member is named: #{line}")

single = Object.new
def single.extra; end
line = logged_for([single])
assert_eq(line.include?('Array[0] = an Object'), true, "a singleton is named with the right article: #{line}")

class NestedDump
  def _dump(_limit)
    begin
      Marshal.dump(proc {})
    rescue TypeError
      nil
    end
    raise TypeError, 'outer'
  end
end
logged_for([NestedDump.new])
assert_eq(LOGGED.length, 1, "a _dump that calls Marshal.dump gives one line: #{LOGGED.inspect}")

deep = []
cur = deep
100_000.times do
  n = []
  cur << n
  cur = n
end
overflow = begin
  Marshal.dump(deep)
  nil
rescue SystemStackError => e
  e
end
if overflow && overflow.backtrace && !overflow.backtrace.empty?
  assert_eq(overflow.backtrace[0].start_with?(MKXPMarshalTrace::FILE_PREFIX), false,
            "a stack overflow names the caller: #{overflow.backtrace[0]}")
end
assert_eq(Thread.current[:mkxp_marshal_dump], nil, 'the dump flag is cleared after an error')

class PrivateHook
  def marshal_load(_data); end

  private

  def marshal_dump
    [1]
  end
end
line = logged_for([PrivateHook.new, proc {}])
assert_eq(line.include?('Array[1] = a Proc'), true, "a private marshal_dump is followed: #{line}")

line = logged_for([proc {}] + Array.new(300_000, nil))
assert_eq(line.include?('Array[0] = a Proc'), true, "plain values do not fill the search: #{line}")

line = logged_for([Class.new.new])
assert_eq(line.include?('Array[0] = a value of a class with no name'), true, "an unnamed class is named: #{line}")

class NumberLike < Numeric
  def initialize
    super
    @bad = proc {}
  end
end
line = logged_for([NumberLike.new, proc {}])
assert_eq(line.include?('Array[0]@bad = a Proc'), true, "a Numeric subclass is walked: #{line}")

line = logged_for([proc {}] + Array.new(300_000) { |i| i.to_s })
assert_eq(line.include?('too many to search'), true, "a huge value stops the search: #{line}")

test_passed('test_platform_compat', 30)
