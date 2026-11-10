# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# A path without an extension picks the first matching file in name
# order, as it does on Windows. Graphics/Lookup has lookup.bmp (2x1)
# and lookup.png (1x1). APFS lists that folder with the .png first, so
# the check fails when the engine takes the listing order.
#
# CI runs it with and without --config '{"pathCache":false}'. The
# engine lists folders in a different way in each case.
#
# Graphics/Lookup/late.txt is there at launch, and the suite writes
# late.png after the engine has listed the folder.
#
# Game.rgssad holds lowercase names, like the maps in Pokemon
# Insurgence's archive. tools/make_test_archive.rb writes it.
#
#   tools/run-engine-tests.sh --suite file_lookup_order.rb

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('file-lookup-order', 10)

EngineTest.test('a path without an extension loads the first name in order') do
  EngineTest.assert_equal(2, Bitmap.new('Graphics/Lookup/lookup').width, 'lookup.bmp width')
end

EngineTest.test('a path with an extension loads that file') do
  EngineTest.assert_equal(1, Bitmap.new('Graphics/Lookup/lookup.png').width, 'lookup.png width')
end

# Windows raises Errno::ENOENT here, and games rescue it.
EngineTest.test('a folder path raises Errno::ENOENT') do
  error = nil
  begin
    Bitmap.new('Graphics/Lookup/')
  rescue Exception => e # rubocop:disable Lint/RescueException
    error = e
  end
  EngineTest.assert_equal(Errno::ENOENT, error.class, 'error class')
end

EngineTest.test('a file written after launch loads when an older file has the same name') do
  File.binwrite('Graphics/Lookup/late.png', File.binread('Graphics/Lookup/lookup.png'))
  EngineTest.assert_equal(1, Bitmap.new('Graphics/Lookup/late').width, 'late.png width')
end

# Windows finds a file in any case. Pokemon Insurgence loads
# "Data/Map150.rxdata", and its archive holds "Data/map150.rxdata".
EngineTest.test('load_data finds an archive file in another case') do
  EngineTest.assert_equal('from the archive', load_data('Data/ArchCase.rxdata'), 'loaded value')
end

EngineTest.test('a bitmap loads from an archive file in another case') do
  EngineTest.assert_equal(1, Bitmap.new('Graphics/LOOKUP/ArchCase').width, 'archcase.png width')
end

EngineTest.test('a name that only shares a prefix does not load') do
  EngineTest.assert_raises('ArchCas', 'Graphics/Lookup/ArchCas') { Bitmap.new('Graphics/Lookup/ArchCas') }
end

# The path cache keeps one name for each spelling, so only a run
# without it can tell Twin.png from twin.png.
EngineTest.test('the name in the asked case loads first') do
  path_cache = CFG['pathCache']
  EngineTest.info('pathCache', path_cache.inspect)
  if path_cache == false
    EngineTest.assert_equal(1, Bitmap.new('Graphics/Lookup/Twin').width, 'Twin.png width')
    EngineTest.assert_equal(2, Bitmap.new('Graphics/Lookup/twin').width, 'twin.png width')
  else
    EngineTest.assert_equal(true, [1, 2].include?(Bitmap.new('Graphics/Lookup/Twin').width), 'Twin.png loads')
  end
end

EngineTest.test('load_data looks in each folder whose name differs only in case') do
  EngineTest.assert_equal('second', load_data('Branch/second.rxdata'), 'branch/second.rxdata')
  EngineTest.assert_equal('first', load_data('BRANCH/FIRST.rxdata'), 'Branch/first.rxdata')
end

EngineTest.test('a bitmap looks in each folder whose name differs only in case') do
  EngineTest.assert_equal(2, Bitmap.new('Branch/two').width, 'branch/two.png width')
end

EngineTest.finish
exit
