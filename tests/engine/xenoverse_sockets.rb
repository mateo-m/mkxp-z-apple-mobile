# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Pokemon Xenoverse, script 005_Sockets, cut down: its own Winsock
# classes load only when no Socket exists. socket_classes.rb and
# tools/test_socket_classes.rb run it as a game script section.
#
# This file must parse on Ruby 1.8, 1.9 and 3.1.

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
