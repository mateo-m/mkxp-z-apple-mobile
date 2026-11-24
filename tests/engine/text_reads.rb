# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# A Windows game reads its text files in text mode, which drops the CR of
# each CR LF, and it reads them as UTF-8. LonaRPG's JSON parser recurses
# forever on a CR, and it encodes its translation files to UTF-8.
#
#   tools/run-engine-tests.sh --suite text_reads.rb --ruby 31
#   tools/run-engine-tests.sh --suite text_reads.rb --ruby 19
#   tools/run-engine-tests.sh --suite text_reads.rb --ruby 18
#
# This file must parse on Ruby 1.8, 1.9 and 3.1.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('text-reads', defined?(Encoding) ? 4 : 3)

EngineTest.load_preloads(%w[windows_fs])

# rubocop:disable Style/FileWrite -- File.binwrite is not on Ruby 1.8.
TEXT_FILE = 'text_reads.json'.freeze
File.open(TEXT_FILE, 'wb') { |file| file.write("[\r\n1,\r\n2\r\n]\r\n") }
# rubocop:enable Style/FileWrite

# Ruby 1.8 takes no "t" in a mode, so it keeps the CR.
FOLDED = System.ruby_version == '1.8' ? "[\r\n1,\r\n2\r\n]\r\n" : "[\n1,\n2\n]\n"

EngineTest.test('File.read drops the CR of each CR LF') do
  EngineTest.assert_equal(FOLDED, File.read(TEXT_FILE), 'File.read')
end

# rubocop:disable Style/FileRead -- these tests read through File.open with a mode, and File.binread is not on Ruby 1.8.
EngineTest.test('a block read in mode r drops the CR of each CR LF') do
  EngineTest.assert_equal(FOLDED, File.open(TEXT_FILE, 'r', &:read), "File.open 'r'")
end

EngineTest.test('a binary read keeps the CR') do
  EngineTest.assert_equal("[\r\n1,\r\n2\r\n]\r\n", File.open(TEXT_FILE, 'rb', &:read), "File.open 'rb'")
end
# rubocop:enable Style/FileRead

# Ruby 1.8 has no Encoding.
if defined?(Encoding)
  EngineTest.test('a text file reads as UTF-8') do
    EngineTest.assert_equal(Encoding::UTF_8, Encoding.default_external, 'Encoding.default_external')
    EngineTest.assert_equal(Encoding::UTF_8, File.read(TEXT_FILE).encoding, 'File.read encoding')
  end
end

File.delete(TEXT_FILE)

EngineTest.finish
exit
