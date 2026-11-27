#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# A game can ship its own H-Mode7 library and call it through
# Win32API, as "./libhmode7.so" (or "./libhmode7.dylib" on a Mac).
# These tests check two things:
#   1. win32_wrap.rb sends each hm7_* call to HM7::Native, with the
#      arguments unchanged.
#   2. hmode7_shim.rb leaves the HM7 scripts of such a game alone. Its
#      Surface#get_data adapter puts a Bitmap in the surface record,
#      and these games pack that record with "l<*".
# The engine suite tests/engine/hmode7_flat.rb draws a map with the
# real library.
# Run: ruby tools/test_hmode7_flat.rb

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

Object.const_set(:System, Module.new do
  module_function

  define_method(:puts) { |*_args| nil }
  define_method(:is_windows?) { false }
end)

module Graphics
  def self.update; end
end

module MKXP
  def self.puts(*_args); end
end

# The engine defines HM7::Native before it runs the preload scripts.
module HM7
  module Native
    AVAILABLE = true
    CALLS = []

    def self.hm7_abi_version
      1
    end

    def self.hm7_render(*args)
      CALLS << args
      7
    end

    # The entry point of the MGC plugin renderer. It is not an hm7_* export.
    def self.render_hm7(*_args)
      0
    end
  end
end

prev_verbose = $VERBOSE
$VERBOSE = nil
load File.join(ROOT, 'scripts', 'preload', 'win32_wrap.rb')
$VERBOSE = prev_verbose

%w[./libhmode7.so ./libhmode7.dylib libhmode7.so ./hmode7.dll hmode7].each do |lib|
  abi = Win32API.new(lib, 'hm7_abi_version', '', 'l').call
  assert_eq(abi, 1, "#{lib} answers hm7_abi_version")
end

buf = "\0" * 16
surfaces = [0, 320, 240, 5, 0, 0].pack('l<*')
ret = Win32API.new('./libhmode7.so', 'hm7_render', 'lpllllllpl', 'l')
                .call(3, buf, 16, 1, 2, 3, 0, 0, surfaces, 1)
assert_eq(ret, 7, 'hm7_render returns what the library returns')
assert_eq(HM7::Native::CALLS.last, [3, buf, 16, 1, 2, 3, 0, 0, surfaces, 1],
          'hm7_render gets the arguments unchanged')
assert_eq(HM7::Native::CALLS.last[1].equal?(buf), true,
          'hm7_render gets the game buffer itself, so it can draw into it')

render_hm7 = Win32API.new('./libhmode7.so', 'render_hm7', 'lll', 'l')
assert_eq(render_hm7.instance_variable_get(:@mkxp_wrap_impl), nil,
          'only hm7_* functions reach HM7::Native')

# Other libraries keep their names.
assert_eq(Win32API.new('user32', 'GetSystemMetrics', 'I', 'I')
                  .instance_variable_get(:@mkxp_wrap_impl).nil?, false,
          'user32 still reaches its stand-in')

# The HM7 scripts of a game with its own library, reduced to what the
# shim looks at.
module HM7
  def self.ctx_create(*_args)
    1
  end

  class Surface
    def bitmap
      Object.new
    end

    def get_data
      [0, 320, 240, 5, 0, 0]
    end
  end

  class Tilemap
    def initialize; end
  end
end

# The engine evals the shim from C, with no Ruby method around it, so a
# top-level return raises LocalJumpError. A thread block is the same.
shim = File.join(ROOT, 'scripts', 'postload', 'hmode7_shim.rb')
shim_error = Thread.new do
  begin
    eval(File.read(shim), TOPLEVEL_BINDING, shim) # rubocop:disable Security/Eval
    nil
  rescue LocalJumpError => e
    e
  end
end.value
assert_eq(shim_error, nil, 'the shim runs to its end under eval')

assert_eq(HM7::Surface.new.get_data, [0, 320, 240, 5, 0, 0],
          'the shim keeps the surface record of the game library')
assert_eq(HM7::Surface.new.get_data.pack('l<*').bytesize, 24,
          'the surface record packs as six integers')
assert_eq(HM7.respond_to?(:draw_map_tileset), false,
          'the shim adds no MGC plugin methods')
assert_eq(defined?($mkxp_hm7_native), nil,
          'the shim does not report the MGC plugin renderer as active')

test_passed('test_hmode7_flat', 15)
