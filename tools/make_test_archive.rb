#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Writes tests/engine/Game.rgssad. Its entries have lowercase names,
# like the maps in Pokemon Insurgence's archive, and
# tests/engine/file_lookup_order.rb loads them with another case.
# Run: ruby tools/make_test_archive.rb

require 'zlib'

ROOT = File.expand_path('..', __dir__)
LOOKUP_PNG = File.binread(File.join(ROOT, 'tests/engine/Graphics/Lookup/lookup.png'))

def png(width)
  chunk = lambda do |type, data|
    [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
  end
  rows = "\0#{"\xFF\x00\x00\xFF".b * width}".b
  "\x89PNG\r\n\x1A\n".b +
    chunk.call('IHDR', [width, 1, 8, 6, 0, 0, 0].pack('NNCCCCC')) +
    chunk.call('IDAT', Zlib::Deflate.deflate(rows)) +
    chunk.call('IEND', '')
end

# Twin.png and twin.png differ only in case, like Branch and branch.
ENTRIES = [
  ['Data\\archcase.rxdata', Marshal.dump('from the archive')],
  ['Graphics\\Lookup\\archcase.png', LOOKUP_PNG],
  ['Graphics\\Lookup\\Twin.png', png(1)],
  ['Graphics\\Lookup\\twin.png', png(2)],
  ['Branch\\first.rxdata', Marshal.dump('first')],
  ['branch\\second.rxdata', Marshal.dump('second')],
  ['Branch\\one.png', png(1)],
  ['branch\\two.png', png(2)],
  ['Branch\\hero.txt', 'not an image'],
  ['branch\\hero.png', png(1)]
].freeze

key = 0xDEADCAFE
next_key = lambda do
  k = key
  key = ((key * 7) + 3) & 0xFFFFFFFF
  k
end

out = "RGSSAD\0\1".b
ENTRIES.each do |name, data|
  out << [name.bytesize ^ next_key.call].pack('V')
  out << name.bytes.map { |b| b ^ (next_key.call & 0xFF) }.pack('C*')
  out << [data.bytesize ^ next_key.call].pack('V')
  k = key
  padded = data + ("\0" * ((4 - (data.bytesize % 4)) % 4))
  words = padded.unpack('V*').map do |w|
    r = w ^ k
    k = ((k * 7) + 3) & 0xFFFFFFFF
    r
  end
  out << words.pack('V*')[0, data.bytesize]
end
File.binwrite(File.join(ROOT, 'tests/engine/Game.rgssad'), out)
