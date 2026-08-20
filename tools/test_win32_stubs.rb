#!/usr/bin/env ruby
# Unit tests for the Berka-downloader boot and download fixes:
#   1. win32_wrap.rb: the wininet bridge. InternetOpenA returns a
#      nonzero session handle (Pokemon Daybreak's "LUKA DOWNLOADER
#      MODULE" aborts at load when it is 0), and the request
#      functions (InternetOpenUrl / InternetReadFile / HttpQueryInfo
#      / InternetCloseHandle / DeleteUrlCacheEntry) perform real
#      downloads through the engine's HTTPLite client.
#   2. platform_compat.rb: IOS::NullStub is raisable. `raise <stub>`
#      produces a StandardError instead of the fatal
#      "exception class/object expected" TypeError on Ruby 1.8.
#   3. net_http_compat.rb: the Net::HTTP facade binds lazily via
#      Net.const_missing, so a game-defined `module Net` holding a
#      `module HTTP` (Berka) loads instead of dying with "HTTP is
#      not a module".
# Run: ruby mkxp-z-apple-mobile/tools/test_win32_stubs.rb
#
# Caution for extenders: once platform_compat.rb loads, its global
# Module#const_missing hook is live in this process. A typo'd
# constant in test code resolves to a stub instead of raising
# NameError, so always assert against exact expected values.

require_relative 'assertion_count'

ROOT = File.expand_path('..', __dir__)

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  warn "FAIL: #{label}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
  exit 1
end

def assert_true(value, label)
  assert_eq(value, true, label)
end

def assert_nonzero(value, label)
  asserted
  return if value.is_a?(Integer) && value != 0

  warn "FAIL: #{label}\n  expected: nonzero Integer\n  actual:   #{value.inspect}"
  exit 1
end

# platform_compat.rb targets the in-game VMs (1.8 / 1.9 / 3.1), which
# all still have the `exists?` aliases. Ruby 3.2 removed them. Restore
# them so this harness also runs on a modern host Ruby.
def ensure_ruby31_compat_aliases!
  class << File
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
  FileTest.singleton_class.class_eval do
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
  class << Dir
    alias_method :exists?, :exist? unless method_defined?(:exists?)
  end
end

# The engine's C binding keeps Ruby 1.8 byte-write semantics for
# `str[int] = int` on every VM (binding-mri.cpp, mkxpStringAset), and
# memcpy_string in win32_wrap.rb relies on that. Host Ruby lacks the
# override. Mirror it.
class String
  alias _test_orig_aset []=
  def []=(*args)
    if args.length == 2 && args[0].is_a?(Integer) && args[1].is_a?(Integer)
      setbyte(args[0], args[1] & 0xFF)
    else
      _test_orig_aset(*args)
    end
  end
end

require 'tmpdir'
require 'fileutils'
USERDATA = Dir.mktmpdir('test_win32_stubs')
at_exit { FileUtils.rm_rf(USERDATA) }

ensure_ruby31_compat_aliases!
Object.const_set(:System, Module.new do
  module_function

  define_method(:data_directory) { USERDATA }
  define_method(:puts) { |*_args| nil }
  define_method(:joiplay_compat?) { false }
  define_method(:is_windows?) { false }
end)
unless Kernel.method_defined?(:load_data)
  Kernel.module_eval do
    def load_data(_path, *_args); end

    def save_data(_obj, _path, *_args); end
  end
end

# win32_wrap.rb wraps Graphics.update at load time. Give it a target.
module Graphics
  def self.update; end
end

# Stand-in for the engine's native HTTP client. Serves canned
# responses by URL. Records every call. A :raise sentinel models the
# native client refusing (network toggled off, TLS failure, ...).
module HTTPLite
  RESPONSES = {}
  CALLS = []

  def self.get(url, headers = nil, redirect = nil)
    CALLS << [url, headers, redirect]
    response = RESPONSES[url]
    raise 'native client refused' if response == :raise

    response || { :status => 0, :body => '', :headers => {} }
  end

  def self.post(_url, _data, _headers = nil, _redirect = nil)
    { :status => 0, :body => '', :headers => {} }
  end

  def self.post_body(_url, _body, _ctype, _headers = nil, _redirect = nil)
    { :status => 0, :body => '', :headers => {} }
  end
end

# Load in the engine's preload order (script-bootstrap.cpp):
# platform_compat, win32_wrap, http_compat, net_http_compat.
# net_http_compat gates on the game VMs (RUBY_VERSION < 2). Pose as
# 1.8 for the duration of its load.
prev_verbose = $VERBOSE
$VERBOSE = nil
begin
  load File.join(ROOT, 'scripts', 'preload', 'platform_compat.rb')
  load File.join(ROOT, 'scripts', 'preload', 'win32_wrap.rb')
  load File.join(ROOT, 'scripts', 'preload', 'http_compat.rb')
  real_ruby_version = RUBY_VERSION
  Object.send(:remove_const, :RUBY_VERSION)
  Object.const_set(:RUBY_VERSION, '1.8.1')
  begin
    load File.join(ROOT, 'scripts', 'preload', 'net_http_compat.rb')
  ensure
    Object.send(:remove_const, :RUBY_VERSION)
    Object.const_set(:RUBY_VERSION, real_ruby_version)
  end
ensure
  $VERBOSE = prev_verbose
end

# --- wininet: InternetOpenA returns a nonzero session handle ---
ioa = Win32API.new('wininet', 'InternetOpenA', 'plppl', 'l').call('', 0, '', '', 0)
assert_nonzero(ioa, 'InternetOpenA returns a nonzero handle')

# The unsuffixed and wide spellings route to the same stub.
assert_nonzero(
  Win32API.new('wininet', 'InternetOpen', 'plppl', 'l').call('', 0, '', '', 0),
  'InternetOpen alias returns a nonzero handle'
)
assert_nonzero(
  Win32API.new('wininet', 'InternetOpenW', 'plppl', 'l').call('', 0, '', '', 0),
  'InternetOpenW alias returns a nonzero handle'
)

# Berka-lineage scripts spell the DLL as 'wininet' or 'wininet.dll'
# (lowercase). Mixed-case spellings such as 'WinInet' miss every
# Win32API_Impl module - a pre-existing dispatch limitation, not
# covered here.
assert_nonzero(
  Win32API.new('wininet.dll', 'InternetOpenA', 'plppl', 'l').call('', 0, '', '', 0),
  'wininet.dll spelling routes to the same stub'
)

# Functions outside the bridge stay on the tolerant fallback: log + 0.
assert_eq(
  Win32API.new('wininet', 'InternetConnectA', 'lplpplll', 'l').call(1, 'files.test', 80, '', '', 3, 0, 0),
  0,
  'unimplemented wininet functions still return 0'
)

# --- NullStub raise protocol ---
# The fatal path lives on the game's Ruby 1.8 VM: 1.8's raise
# requires a REAL `exception` method (1.8 checks the method table
# only. method_missing and respond_to_missing? do not satisfy it)
# that returns an Exception. This host runs modern Ruby, where
# one-arg raise takes the `to_str` coercion path instead, so the
# 1.8 behavior is tested through the protocol contract, not through
# raise dispatch. respond_to? is useless here: NullStub's
# respond_to_missing? answers true for every name, so only
# method_defined? proves the hook exists.
assert_true(
  IOS::NullStub.singleton_class.method_defined?(:exception),
  'exception is a real singleton method (what 1.8 raise checks)'
)
assert_true(
  IOS::NullStub.method_defined?(:exception),
  'exception is a real instance method (raised stub instances on 1.8)'
)
exc = IOS::NullStub.exception
assert_eq(exc.class, StandardError, 'NullStub.exception builds exactly StandardError')
assert_eq(
  exc.message,
  'a Win32-only feature is unavailable on this platform',
  'NullStub.exception carries the default message'
)
assert_eq(
  IOS::NullStub.exception('with message').message,
  'with message',
  'NullStub.exception(msg) keeps the message'
)

# Instance-level twin: NullStub.new returns the class, so reach an
# actual instance through allocate, like a hostile game script could.
inst_exc = IOS::NullStub.allocate.exception
assert_eq(inst_exc.class, StandardError, 'instance exception builds exactly StandardError')
assert_eq(
  IOS::NullStub.allocate.exception('inst message').message,
  'inst message',
  'instance exception(msg) keeps the message'
)

# One-arg raise on this host takes the to_str path (RuntimeError).
# The regression this guards against is the fatal TypeError.
err = nil
begin
  raise IOS::NullStub
rescue Exception => e # rubocop:disable Lint/RescueException -- regression check must catch everything
  err = e
end
assert_eq(err.is_a?(TypeError), false, 'raise NullStub is not a fatal TypeError')
assert_true(err.is_a?(StandardError), 'raise NullStub is rescuable as StandardError')

# The two-arg form calls the exception hook on every VM, so this
# exercises the hook through real raise dispatch.
err = nil
begin
  raise IOS::NullStub, 'custom message'
rescue Exception => e # rubocop:disable Lint/RescueException -- regression check must catch everything
  err = e
end
assert_eq(err.class, StandardError, 'raise NullStub, msg produces exactly StandardError')
assert_eq(err.message, 'custom message', 'raise NullStub, msg keeps the message')

# --- const_missing split stays intact ---
module TestHost; end

error_klass = TestHost::FakeDownloadError
assert_true(error_klass.is_a?(Class), 'Error-suffixed constant becomes a Class')
assert_true(error_klass.ancestors.include?(StandardError), 'Error-suffixed constant subclasses StandardError')
assert_eq(TestHost::FakeDownloadError, error_klass, 'Error-suffixed constant is memoized')

plain = TestHost::PlainNamespace
assert_eq(plain, IOS::NullStub, 'non-error constant resolves to NullStub')

# --- Daybreak repro: the exact failing pattern, end to end ---
# Mirrors "LUKA DOWNLOADER MODULE" lines 143-157. Before the fixes
# this snippet died three times over: IOA was 0. The typo'd constant
# (`NetErrorErr::ConIn` instead of `NetError::ErrConIn`) made the
# raise itself fatal. And `module HTTP` collided with the eagerly
# defined Net::HTTP facade class ("HTTP is not a module").
DAYBREAK_SNIPPET = <<-RUBY
  module Berka
    module NetError
      ErrConIn = "Unable to connect to Internet"
    end
  end
  module Net
    W = 'wininet'
    SPC = Win32API.new('kernel32','SetPriorityClass','pi','i').call(-1,128)
    IOA = Win32API.new(W,'InternetOpenA','plppl','l').call('',0,'','',0)
    IC = Win32API.new(W,'InternetConnectA','lplpplll','l')
    raise Berka::NetErrorErr::ConIn if IOA == 0
    module HTTP
      IOU = Win32API.new(W,'InternetOpenUrl','lppllp','l')
      IRF = Win32API.new(W,'InternetReadFile','lpip','l')
      ICH = Win32API.new(W,'InternetCloseHandle','l','l')
      HQI = Win32API.new(W,'HttpQueryInfo','llppp','i')
      CCD = Win32API.new(W,'DeleteUrlCacheEntry','p','l')
    end
  end
RUBY

err = nil
begin
  eval(DAYBREAK_SNIPPET) # rubocop:disable Security/Eval -- fixture mirrors the game script verbatim
rescue Exception => e # rubocop:disable Lint/RescueException -- regression check must catch everything
  err = e
end
assert_eq(err, nil, 'Daybreak downloader module loads without raising')
assert_nonzero(Net::IOA, 'Daybreak IOA handle is nonzero')
assert_true(Net::HTTP.instance_of?(Module), 'Berka owns Net::HTTP as a module')

# Even when a script reaches a typo'd raise (Berka line 230 style),
# it must surface as rescuable, never as a fatal TypeError. On this
# host the raise takes the to_str path (RuntimeError), so this
# documents rescuability. The 1.8 fatal path is pinned by the
# protocol-contract assertions above.
assert_eq(Berka::NetErrorErr::ErrNoFile, IOS::NullStub, 'typo constant resolves to NullStub')
err = nil
begin
  raise Berka::NetErrorErr::ErrNoFile
rescue Exception => e # rubocop:disable Lint/RescueException -- regression check must catch everything
  err = e
end
assert_eq(err.is_a?(TypeError), false, 'typo raise is not a fatal TypeError')
assert_true(err.is_a?(StandardError), 'typo raise is rescuable as StandardError')

# --- Download loop, driven Berka-style through the game's handles ---
# Body includes NULs and high bytes to prove binary transport. The
# driver uses binary buffers, matching the byte semantics game
# buffers have on the 1.8 VM.
BODY = ("GIF89a\x00\xFF\x10stream" * 128).force_encoding('ASCII-8BIT')
URL = 'http://files.test/big.bin'
HTTPLite::RESPONSES[URL] = { :status => 200, :body => BODY.dup, :headers => {} }

fs = Net::HTTP::IOU.call(Net::IOA, URL, nil, 0, 0, 0)
assert_nonzero(fs, 'InternetOpenUrl returns a request handle')
assert_eq(HTTPLite::CALLS.last[0], URL, 'bridge fetches the requested URL')
assert_eq(HTTPLite::CALLS.last[2], true, 'bridge asks HTTPLite to follow redirects')

# Content-length query, exactly as Daybreak issues it (text mode).
k = "\0" * 32
assert_eq(Net::HTTP::HQI.call(fs, 5, k, [k.size - 1].pack('l'), nil), 1, 'HttpQueryInfo succeeds')
assert_eq(k.delete("\0"), BODY.length.to_s, 'content length arrives as header text')

# Status code with HTTP_QUERY_FLAG_NUMBER: binary DWORD.
status_buf = ("\0" * 4).force_encoding('ASCII-8BIT')
assert_eq(
  Net::HTTP::HQI.call(fs, 19 | 0x20000000, status_buf, [4].pack('l'), nil),
  1,
  'numeric HttpQueryInfo succeeds'
)
assert_eq(status_buf.unpack('V')[0], 200, 'status code arrives as DWORD')

# Unknown info levels fail cleanly.
assert_eq(Net::HTTP::HQI.call(fs, 22, "\0" * 8, [8].pack('l'), nil), 0, 'unknown query level returns 0')

# Undersized buffers fail cleanly (Windows: ERROR_INSUFFICIENT_BUFFER),
# never overflow into an IndexError inside the game script.
tiny = ("\0" * 2).force_encoding('ASCII-8BIT')
assert_eq(Net::HTTP::HQI.call(fs, 5, tiny, [2].pack('l'), nil), 0, 'undersized text buffer fails cleanly')
assert_eq(Net::HTTP::HQI.call(fs, 19 | 0x20000000, tiny, [2].pack('l'), nil), 0,
          'undersized DWORD buffer fails cleanly')
assert_eq(tiny, ("\0" * 2).force_encoding('ASCII-8BIT'), 'undersized buffer stays untouched')

collected = ''.force_encoding('ASCII-8BIT')
40.times do
  buf = (' ' * 1024).force_encoding('ASCII-8BIT')
  o = [0].pack('i!')
  r = Net::HTTP::IRF.call(fs, buf, 1024, o)
  n = o.unpack('i!')[0]
  assert_eq(r, 1, 'InternetReadFile succeeds on an open handle')
  break if n == 0

  collected << buf[0, n]
end
assert_eq(collected, BODY, 'read loop reconstructs the body byte for byte')
assert_eq(collected.length, BODY.length, 'read loop delivers every byte exactly once')

assert_eq(Net::HTTP::ICH.call(fs), 1, 'InternetCloseHandle succeeds')
assert_eq(Net::HTTP::ICH.call(fs), 1, 'closing twice stays harmless')
assert_eq(Net::HTTP::CCD.call(URL), 1, 'DeleteUrlCacheEntry reports success')

# After close, reads fail with 0 bytes - the loop terminator.
o = [99].pack('i!')
buf = (' ' * 16).force_encoding('ASCII-8BIT')
assert_eq(Net::HTTP::IRF.call(fs, buf, 16, o), 0, 'read on a closed handle fails')
assert_eq(o.unpack('i!')[0], 0, 'read on a closed handle reports 0 bytes')

# --- UTF-8-tagged text body: reads must stay byte-based ---
# The native binding tags text content types UTF-8 (getResponseBody
# in http-binding.cpp), where [] and length count characters. The
# bridge retags the body binary at open. Without that, a multibyte
# chunk carries more bytes than its character count and overruns the
# caller's buffer. Small 64-byte reads force chunk boundaries inside
# multibyte sequences.
UTF8_URL = 'http://files.test/manifest.txt'
UTF8_BODY = "version=1.2 ééé notes\n" * 40
HTTPLite::RESPONSES[UTF8_URL] = { :status => 200, :body => UTF8_BODY.dup, :headers => {} }

fs_utf8 = Net::HTTP::IOU.call(Net::IOA, UTF8_URL, nil, 0, 0, 0)
assert_nonzero(fs_utf8, 'InternetOpenUrl handles a text response')
k = "\0" * 32
Net::HTTP::HQI.call(fs_utf8, 5, k, [k.size - 1].pack('l'), nil)
assert_eq(k.delete("\0"), UTF8_BODY.bytesize.to_s, 'content length counts bytes, not characters')
collected = ''.force_encoding('ASCII-8BIT')
200.times do
  buf = (' ' * 64).force_encoding('ASCII-8BIT')
  o = [0].pack('i!')
  Net::HTTP::IRF.call(fs_utf8, buf, 64, o)
  n = o.unpack('i!')[0]
  break if n == 0

  collected << buf[0, n]
end
assert_eq(collected, UTF8_BODY.dup.force_encoding('ASCII-8BIT'),
          'multibyte body arrives byte for byte')
Net::HTTP::ICH.call(fs_utf8)

# --- Facade internals resolve while a game owns Net::HTTP ---
# set_form_data's url_encode call must reference the facade by its
# canonical name: with Berka owning the Net::HTTP constant, a lexical
# `HTTP.url_encode` would resolve to Berka's module and NoMethodError.
form_req = Net::HTTPFacade::Post.new('/submit')
form_req.set_form_data('a b' => 'c&d')
assert_eq(form_req.body, 'a%20b=c%26d', 'form encoding works while a game owns Net::HTTP')

# --- Download failure paths ---
# Transport failure (status 0): no handle, like a dead connection.
assert_eq(
  Net::HTTP::IOU.call(Net::IOA, 'http://files.test/missing.bin', nil, 0, 0, 0),
  0,
  'transport failure yields no request handle'
)
# Native client refusal (network toggled off) raises inside the
# stack. The bridge converts it into the same no-handle result.
HTTPLite::RESPONSES['http://files.test/refused.bin'] = :raise
assert_eq(
  Net::HTTP::IOU.call(Net::IOA, 'http://files.test/refused.bin', nil, 0, 0, 0),
  0,
  'native refusal yields no request handle'
)
# Berka then reads with @fs == 0: must terminate the loop at once.
o = [99].pack('i!')
assert_eq(Net::HTTP::IRF.call(0, buf, 16, o), 0, 'read with handle 0 fails')
assert_eq(o.unpack('i!')[0], 0, 'read with handle 0 reports 0 bytes')
assert_eq(Net::HTTP::HQI.call(0, 5, "\0" * 8, [8].pack('l'), nil), 0, 'query with handle 0 fails')

# --- Net::HTTP facade binds lazily for non-Berka games ---
Net.send(:remove_const, :HTTP)
assert_eq(defined?(Net::HTTP), nil, 'defined? does not trigger the lazy bind')
facade = Net::HTTP
assert_eq(facade, Net::HTTPFacade, 'first reference installs the facade class')
# `false` = no ancestor fallback: without it the top-level HTTP
# module from http_compat.rb satisfies const_defined? and the pin
# assertion is vacuous.
assert_true(Net.const_defined?(:HTTP, false), 'the lazy bind pins the constant on Net itself')
assert_eq(Net::HTTP, facade, 'later references see the same class')

HTTPLite::RESPONSES['http://host.test/ping'] = {
  :status => 200, :body => 'pong', :headers => { 'Content-Type' => 'text/plain' }
}
assert_eq(Net::HTTP.get('host.test', '/ping'), 'pong', 'facade GET works after lazy bind')
response = Net::HTTP.get_response('host.test', '/ping')
assert_eq(response.code, '200', 'facade response carries the status')
assert_true(response.is_a?(Net::HTTPSuccess), 'facade response matches HTTPSuccess')

# Other missing Net constants still route to the global stub hook.
net_err = Net::SomeProtocolError
assert_true(net_err.is_a?(Class) && net_err.ancestors.include?(StandardError),
            'error-suffixed Net constant becomes a StandardError subclass')
assert_eq(Net::SomePlainThing, IOS::NullStub, 'plain Net constant resolves to NullStub')

test_passed('test_win32_stubs', 65)
