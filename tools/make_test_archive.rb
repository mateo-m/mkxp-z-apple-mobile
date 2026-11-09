#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Writes tests/engine/Game.rgssad. Its entries have lowercase names,
# like the maps in Pokemon Insurgence's archive, and
# tests/engine/file_lookup_order.rb loads them with another case.
# Run: ruby tools/make_test_archive.rb

ROOT = File.expand_path('..', __dir__)
ENTRIES = [
  ['Data\\archcase.rxdata', Marshal.dump('from the archive')],
  ['Graphics\\Lookup\\archcase.png', File.binread(File.join(ROOT, 'tests/engine/Graphics/Lookup/lookup.png'))]
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
