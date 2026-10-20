# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Packs the harness and loader.rb into Data/Scripts.rxdata. The game
# code stays in Data/Scripts as plain files, the way the Essentials v21
# script extractor leaves it.
#
#   ruby tests/script-folder/pack_scripts.rb
#   tools/run-engine-tests.sh --game tests/script-folder

require 'zlib'

HERE = File.dirname(File.expand_path(__FILE__))

SOURCES = [
  [1, 'harness', File.join(HERE, '..', 'engine', 'harness.rb')],
  [2, 'Main', File.join(HERE, 'loader.rb')]
].freeze

# The extractor writes the Main section with CRLF line ends, double
# quotes and no final newline.
def extractor_shape(code)
  code.sub("'Data/Scripts'", '"Data/Scripts"').chomp.gsub("\n", "\r\n")
end

sections = SOURCES.map do |id, name, path|
  code = File.binread(path)
  code = extractor_shape(code) if name == 'Main'
  [id, name, Zlib::Deflate.deflate(code)]
end

target = File.join(HERE, 'Data', 'Scripts.rxdata')
File.binwrite(target, Marshal.dump(sections))
puts "pack_scripts: wrote #{target}"
