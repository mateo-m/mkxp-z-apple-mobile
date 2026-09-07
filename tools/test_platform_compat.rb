#!/usr/bin/env ruby
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
USERDATA = Dir.mktmpdir('test_platform_compat')
at_exit { FileUtils.rm_rf(USERDATA) }

Object.const_set(:System, Module.new do
  module_function

  define_method(:data_directory) { USERDATA }
  define_method(:puts) { |*_args| nil }
end)

module Input
  @in_window = true

  def self.in_window=(value)
    @in_window = value
  end

  def self.mouse_in_window
    @in_window
  end
end

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

test_passed('test_platform_compat', 3)
