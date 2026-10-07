# A path without an extension picks the first matching file in name
# order, as it does on Windows. Graphics/Lookup has lookup.bmp (2x1)
# and lookup.png (1x1). APFS lists that folder with the .png first, so
# the check fails when the engine takes the listing order.
#
#   tools/run-engine-tests.sh --suite file_lookup_order.rb

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('file-lookup-order', 2)

EngineTest.test('a path without an extension loads the first name in order') do
  EngineTest.assert_equal(2, Bitmap.new('Graphics/Lookup/lookup').width, 'lookup.bmp width')
end

EngineTest.test('a path with an extension loads that file') do
  EngineTest.assert_equal(1, Bitmap.new('Graphics/Lookup/lookup.png').width, 'lookup.png width')
end

EngineTest.finish
exit
