#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for the socket classes that a game sees when the network
# is on: win32_wrap.rb hides Ruby's socket classes on the 1.8 and 1.9
# VMs and keeps them for its Winsock bridge.
# tests/engine/socket_classes.rb runs the same game code on the real
# VMs.
# Run: ruby tools/test_socket_classes.rb

require_relative 'assertion_count'
require 'socket'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
WRAP = File.join(ROOT, 'scripts', 'preload', 'win32_wrap.rb')
GAME_SOCKETS = File.join(ROOT, 'tests', 'engine', 'xenoverse_sockets.rb')
SOCKET_CLASSES = %w[Socket BasicSocket IPSocket TCPSocket TCPServer UDPSocket
                    UNIXSocket UNIXServer SOCKSSocket Addrinfo].freeze
REAL_CLASSES = SOCKET_CLASSES.select { |name| Object.const_defined?(name) }.to_h { |name| [name, Object.const_get(name)] }

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

$ruby_version = nil
Object.const_set(:System, Module.new do
  module_function

  define_method(:puts) { |*_args| nil }
  define_method(:is_windows?) { false }
  define_method(:ruby_version) { $ruby_version }
end)

# win32_wrap.rb wraps Graphics.update at load time. Give it a target.
module Graphics
  def self.update; end
end

# Each VM boots with Ruby's classes and runs the preload once.
def boot_vm(ruby_version)
  verbose = $VERBOSE
  $VERBOSE = nil
  SOCKET_CLASSES.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  REAL_CLASSES.each { |name, klass| Object.const_set(name, klass) }
  $ruby_version = ruby_version
  load WRAP
  $VERBOSE = verbose
end

def defined_socket_classes
  %w[Socket TCPSocket TCPServer].select { |name| Object.const_defined?(name) }
end

def run_game_sockets
  load GAME_SOCKETS
end

server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
refused = TCPServer.new('127.0.0.1', 0)
refused_port = refused.addr[1]
refused.close

boot_vm('3.1')
assert_eq(Socket.equal?(REAL_CLASSES['Socket']), true, 'the 3.1 VM keeps the real Socket')

# The 1.8 VM ships no socket.rb.
boot_vm('1.8')
assert_eq(defined_socket_classes, [], 'the 1.8 VM hides the real socket classes')

run_game_sockets
socket = begin
  TCPSocket.new('127.0.0.1', port, true)
rescue TypeError => e
  e.message
end
assert_eq(socket.class.name, 'TCPSocket', "Xenoverse's TCPSocket.new(host, port, true) makes its own socket")
assert_eq(socket.connected, 0, "Xenoverse's socket connects through the Winsock bridge")
server.accept.close

assert_eq(TCPSocket.new('127.0.0.1', refused_port, true).connected, -1, 'a refused connect fails')
assert_eq(Win32API.new('ws2_32', 'WSAGetLastError', '', 'l').call, Errno::ECONNREFUSED::Errno,
          'a refused connect gives ECONNREFUSED')

# F12 runs the game's script sections again, but not the preloads.
game_socket = Socket
run_game_sockets
assert_eq(Socket.equal?(game_socket), true, "F12 keeps the game's Socket")
assert_eq(TCPSocket.new('127.0.0.1', port, true).connected, 0, 'the bridge connects after F12')
server.accept.close
server.close

# The 1.9 VM starts only socket.so. A stand-in for the shipped
# socket.rb shows that a later `require 'socket'` would define Socket
# again.
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'socket.rb'), <<~RUBY)
    class Addrinfo; end
    class BasicSocket < IO; end
    class Socket < BasicSocket; end
  RUBY
  $LOADED_FEATURES.reject! { |path| File.basename(path) == 'socket.rb' }
  $LOAD_PATH.unshift(dir)

  boot_vm('1.9')
  assert_eq(defined_socket_classes, [], 'the 1.9 VM hides the real socket classes')
  require 'socket'
  assert_eq(Object.const_defined?(:Socket), false, "a require 'socket' after the preload does not define Socket again")

  $LOAD_PATH.delete(dir)
end

test_passed('test_socket_classes', 10)
