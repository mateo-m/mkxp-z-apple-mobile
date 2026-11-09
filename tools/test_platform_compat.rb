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
  define_method(:puts) { |*_args| nil }
  define_method(:debug_log) { |line| LOGGED.push(line) }
end)
LOGGED = []

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
assert_eq(LOGGED[0].include?('the write to the file failed'), true,
          "a failed write is told apart from a value that cannot be dumped: #{LOGGED[0]}")

test_passed('test_platform_compat', 11)
