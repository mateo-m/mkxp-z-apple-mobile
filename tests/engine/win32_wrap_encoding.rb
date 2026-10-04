# Text conversion in the Win32API stand-ins (scripts/preload/
# win32_wrap_encoding.rb). The engine loads that preload only on
# Ruby 1.9 and 3.1, so run this suite on those two:
#
#   tools/run-engine-tests.sh --suite win32_wrap_encoding.rb --ruby 19
#   tools/run-engine-tests.sh --suite win32_wrap_encoding.rb --ruby 31

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('win32-wrap-encoding', 3)

# A game that boots from "customScript" gets no engine preloads, so
# the suite loads them from the host's asset bundle, in the order of
# loadEnginePreloads(). platform_compat must come first: on Ruby 1.9
# the engine has no Encoding::UTF_8, and its const_missing hook turns
# the missing name into IOS::NullStub. The host runs the suite from a
# copy in Documents, and the only app bundle path Ruby can see is the
# stdlib folder on $LOAD_PATH.
app = $LOAD_PATH.map { |dir| dir[/\A.*\.app/] }.compact.first
%w[windows_fs platform_compat pokemon_compat win32_wrap win32_wrap_encoding].each do |name|
  path = File.join(app, 'Assets.bundle', 'Preload', "#{name}.rb")
  eval(File.read(path), TOPLEVEL_BINDING, name) # rubocop:disable Security/Eval
end

KERNEL32 = Win32API_Impl::Kernel32

# The engine's Ruby 1.9 has no transcoders, so the conversions give
# an empty result there. The calls must still return a count.
TRANSCODES = begin
  'a'.encode('UTF-16LE')
  true
rescue StandardError
  false
end

def utf16(text)
  text.encode('UTF-16LE').force_encoding('ASCII-8BIT')
end

EngineTest.test('MultiByteToWideChar measures a null-terminated string') do
  count = KERNEL32::MultiByteToWideChar.new.call([65_001, 0, "abc\0xyz", -1, nil, 0])
  EngineTest.assert_equal(TRANSCODES ? 3 : 0, count, 'UTF-16 code units before the null')
end

EngineTest.test('MultiByteToWideChar writes UTF-16') do
  out = "\0" * 8
  count = KERNEL32::MultiByteToWideChar.new.call([65_001, 0, 'hi', 2, out, 4])
  EngineTest.assert_equal(TRANSCODES ? 2 : 0, count, 'code units written')
  EngineTest.assert_equal(utf16('hi'), out.byteslice(0, 4).force_encoding('ASCII-8BIT'), 'bytes written') if TRANSCODES
end

EngineTest.test('WideCharToMultiByte writes UTF-8') do
  out = "\0" * 8
  wide = TRANSCODES ? utf16("h\u00E9\0") : "h\0\0\0"
  count = KERNEL32::WideCharToMultiByte.new.call([65_001, 0, wide, -1, out, 8])
  EngineTest.assert_equal(TRANSCODES ? 3 : 0, count, 'bytes written')
  EngineTest.assert_equal("h\xC3\xA9".force_encoding('ASCII-8BIT'), out.byteslice(0, 3).force_encoding('ASCII-8BIT'), 'bytes') if TRANSCODES
end

EngineTest.finish
exit
