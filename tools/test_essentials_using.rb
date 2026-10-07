#!/usr/bin/env ruby
# Unit tests for essentials_using_compat.rb.
# Run: ruby tools/test_essentials_using.rb

require_relative 'assertion_count'

SCRIPT = File.expand_path('../scripts/postload/essentials_using_compat.rb', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

class FakeWindow
  attr_reader :disposed

  def dispose
    @disposed = true
  end
end

load SCRIPT
assert_eq(Module.instance_method(:using).owner, Module,
          'Module#using stays as it is when the game has no using helper')

# The helper from Essentials' MessageConfig section.
def using(window)
  begin
    yield if block_given?
  ensure
    window.dispose
  end
end

module UIHelper
  def self.pbChooseNumber(window)
    using(window) { 3 }
  end
end

raised = begin
  UIHelper.pbChooseNumber(FakeWindow.new)
  nil
rescue RuntimeError => e
  e.message
end
assert_eq(raised, 'Module#using is not permitted in methods',
          'a module method that calls using raises before the fix')

2.times do |i|
  load SCRIPT
  window = FakeWindow.new
  assert_eq(UIHelper.pbChooseNumber(window), 3, "load #{i + 1}: the block result comes back")
  assert_eq(window.disposed, true, "load #{i + 1}: the window is disposed")
end

test_passed('test_essentials_using', 6)
