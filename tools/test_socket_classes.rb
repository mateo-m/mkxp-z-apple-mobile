#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Unit tests for the socket classes that a game sees when the network
# is on: win32_wrap.rb hides Ruby's socket classes on the 1.8 and 1.9
# VMs and keeps them for its Winsock bridge.
# Run: ruby tools/test_socket_classes.rb

require_relative 'assertion_count'
require 'socket'

ROOT = File.expand_path('..', __dir__)
WRAP = File.join(ROOT, 'scripts', 'preload', 'win32_wrap.rb')

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

$ruby_version = '3.1.3'
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

def load_wrap
  verbose = $VERBOSE
  $VERBOSE = nil
  load WRAP
  $VERBOSE = verbose
end

real_socket = Socket
server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]

load_wrap
assert_eq(Socket.equal?(real_socket), true, 'the 3.1 VM keeps the real Socket')

$ruby_version = '1.8.7'
load_wrap
assert_eq(%w[Socket TCPSocket TCPServer].select { |name| Object.const_defined?(name) }, [],
          'the 1.8 VM hides the real socket classes')

# Pokemon Xenoverse, script 005_Sockets, cut down: its own Winsock
# classes load only when no Socket exists.
# rubocop:disable all -- the game's code as it ships
if !Object.const_defined?(:Socket) # for compatibility
class Socket
  AF_INET = 2
  SOCK_STREAM = 1
  IPPROTO_TCP = 6
  attr_reader :fd

  def initialize(domain, type, protocol, blocking=false)
    @fd = Win32API.new('ws2_32', 'socket', 'lll', 'l').call(domain, type, protocol)
  end

  def connect(sockaddr)
    Win32API.new('ws2_32', 'connect', 'ppl', 'l').call(@fd, sockaddr, sockaddr.size)
  end
end

class TCPSocket < Socket
  def initialize(host, port, blocking = false)
    super(AF_INET, SOCK_STREAM, IPPROTO_TCP, blocking)
    @connected = connect([AF_INET, port].pack('sn') + host.split('.').map { |b| b.to_i }.pack('C4') + [].pack('x8'))
  end
  attr_reader :connected
end
end
# rubocop:enable all

socket = begin
  TCPSocket.new('127.0.0.1', port, true)
rescue TypeError => e
  e.message
end
assert_eq(socket.class.name, 'TCPSocket', "Xenoverse's TCPSocket.new(host, port, true) makes its own socket")
assert_eq(socket.connected, 0, "Xenoverse's socket connects through the Winsock bridge")
server.accept.close

game_socket = Socket
load_wrap
assert_eq(Socket.equal?(game_socket), true, "F12 keeps the game's Socket")
assert_eq(Win32API_Impl::Ws2_32.available?, true, 'F12 keeps the Winsock bridge')
assert_eq(TCPSocket.new('127.0.0.1', port, true).connected, 0, 'the bridge connects after F12')
server.accept.close
server.close

test_passed('test_socket_classes', 7)
