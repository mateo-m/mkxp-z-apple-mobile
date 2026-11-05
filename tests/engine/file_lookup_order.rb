# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# A path without an extension picks the first matching file in name
# order, as it does on Windows. Graphics/Lookup has lookup.bmp (2x1)
# and lookup.png (1x1). APFS lists that folder with the .png first, so
# the check fails when the engine takes the listing order.
#
# Run it with and without --config '{"pathCache":false}'. The engine
# lists folders in a different way in each case.
#
#   tools/run-engine-tests.sh --suite file_lookup_order.rb

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('file-lookup-order', 3)

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

EngineTest.finish
exit
