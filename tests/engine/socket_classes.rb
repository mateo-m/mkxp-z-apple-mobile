# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# With the network on, the 1.8 and 1.9 VMs start Ruby's socket
# extension. Pokemon Xenoverse then must not see it, and must reach
# the network through its own Winsock classes.
#
#   tools/run-engine-tests.sh --suite socket_classes.rb --ruby 18 --network
#
# This file must parse on Ruby 1.8, 1.9 and 3.1.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('socket-classes', 6)

def run_game_sockets
  path = File.join(File.dirname(__FILE__), 'xenoverse_sockets.rb')
  eval(File.read(path), TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval
end

# A connect that reports success with no peer must not hang the suite.
def accept_one(server)
  server.accept.close if IO.select([server], nil, nil, 5) # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler -- 1.8 has no wait_readable
end

def wsa_last_error
  Win32API.new('ws2_32', 'WSAGetLastError', '', 'l').call
end

# The preloads hide TCPServer, so open both servers first.
network = defined?(TCPServer) ? true : false
server = network ? TCPServer.new('127.0.0.1', 0) : nil
refused = network ? TCPServer.new('127.0.0.1', 0) : nil
refused_port = refused ? refused.addr[1] : 0
refused.close if refused

EngineTest.test('the network is on') do
  EngineTest.assert_equal(true, System.network_enabled?, 'System.network_enabled?')
  EngineTest.assert_equal(true, network, 'Ruby defines TCPServer')
end

EngineTest.load_preloads(%w[windows_fs platform_compat win32_wrap])

EngineTest.test('the preloads hide the socket classes') do
  defined_names = %w[Socket BasicSocket TCPSocket TCPServer].select { |name| Object.const_defined?(name) }
  EngineTest.assert_equal([], defined_names, 'socket classes the game sees')
end

EngineTest.test("a require 'socket' does not define Socket again") do
  begin
    require 'socket'
  rescue LoadError
    nil
  end
  EngineTest.assert_equal(false, Object.const_defined?(:Socket), 'Socket defined')
end

run_game_sockets
port = server.addr[1]

EngineTest.test("Xenoverse's TCPSocket connects through the Winsock bridge") do
  result = TCPSocket.new('127.0.0.1', port, true).connected
  accept_one(server)
  EngineTest.assert_equal(0, result, 'connect result')
end

EngineTest.test('a refused connect fails with ECONNREFUSED') do
  EngineTest.assert_equal(-1, TCPSocket.new('127.0.0.1', refused_port, true).connected, 'connect result')
  EngineTest.assert_equal(Errno::ECONNREFUSED::Errno, wsa_last_error, 'WSAGetLastError')
end

# F12 runs the game's script sections again, but not the preloads.
game_socket = Socket
run_game_sockets

EngineTest.test('Xenoverse connects again after F12') do
  EngineTest.assert_equal(true, Socket.equal?(game_socket), "the game's Socket stays")
  result = TCPSocket.new('127.0.0.1', port, true).connected
  accept_one(server)
  EngineTest.assert_equal(0, result, 'connect result')
end

server.close
EngineTest.finish
exit
