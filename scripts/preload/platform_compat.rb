# platform_compat.rb
# Engine-level platform compatibility layer.
# Auto-loaded before game scripts to ensure compatibility.
# Game-specific patches live in separate files (e.g. pokemon_compat.rb).

require 'zlib'

# --- JoiPlay-compat signal ---
# Several Pokemon Essentials fangames (Reborn, Rejuvenation,
# Desolation, etc.) branch on `$joiplay` to pick between JoiPlay's
# stripped-down API surface and desktop mkxp-z's extended one.
# Example: Reborn's `internal_se_play` uses `Audio.se_play` on
# JoiPlay but `Audio.se_play_position` on desktop - the latter is
# an mkxp-z extension our iOS build doesn't carry. Since we ship
# JoiPlay-compat shims (NilClass safe-stubs, Win32API/DL stubs,
# poke_* graphics aliases, cheats, network stubs) the JoiPlay code
# path is what actually works here, so we set the flag.
$joiplay = true

# --- Process spawning neutralization ---
# fork()/exec() are forbidden on iOS and cause immediate SIGKILL.
# Neutralize all process-spawning methods at the engine level.
module Kernel
  # Process-spawning methods are no-ops on iOS: fork/exec would be
  # killed by the sandbox and system("game.exe") only makes sense on
  # Windows. Return nil so games keep running; real exec() would
  # terminate the process but that's the entire iOS app here, so a
  # silent no-op is the safer default.
  def system(*args) nil end
  def exec(*args)   nil end
  def fork(*args)   nil end
  def spawn(*args)  nil end
  module_function :system, :exec, :fork, :spawn
end

# --- Windows environment variable stubs ---
# Many RGSS games use ENV["TEMP"] / ENV["APPDATA"] for file operations,
# and some derive save paths from USERPROFILE / LOCALAPPDATA /
# COMPUTERNAME. Mirror JoiPlay's full fake-Windows environment so
# scripts constructing paths from ENV don't return nil and crash.
# Values point into the iOS sandbox (or are blank strings) so File.exist?
# returns false rather than reading unrelated system dirs.
_tmp = "/tmp"
begin
  _tmp = Dir.tmpdir
rescue
end
_userdata = "#{_tmp}/UserData"
ENV["TEMP"] ||= _tmp
ENV["TMP"]  ||= _tmp
ENV["APPDATA"]              ||= "#{_userdata}/AppData"
ENV["LOCALAPPDATA"]         ||= "#{_userdata}/AppData"
ENV["ALLUSERSPROFILE"]      ||= _userdata
ENV["USERPROFILE"]          ||= _userdata
ENV["HOMEDRIVE"]            ||= ""
ENV["HOMEPATH"]             ||= _userdata
ENV["SystemRoot"]           ||= _userdata
ENV["windir"]               ||= _userdata
ENV["COMPUTERNAME"]         ||= "Empo"
ENV["USERNAME"]             ||= "Empo"
ENV["USERDOMAIN"]           ||= "Empo"
ENV["SESSIONNAME"]          ||= "Empo"
ENV["OS"]                   ||= "Windows_NT"
ENV["PATH"]                 ||= ""
ENV["PATHEXT"]              ||= ""
ENV["Platform"]             ||= ""
ENV["NUMBER_OF_PROCESSORS"] ||= "4"
ENV["PROCESSOR_ARCHITECTURE"] ||= "x86"
ENV["PROCESSOR_IDENTIFIER"] ||= "Intel64 Family6"
ENV["PROCESSOR_LEVEL"]      ||= "6"
ENV["PROCESSOR_REVISION"]   ||= "2a07"
ENV["AV_APPDATA"]           ||= "#{_userdata}/AppData"

# --- Float bitwise-op monkey-patches ---
# RGSS scripts occasionally do `x ^ 2` when they mean `x ** 2` (a
# Game-Maker-idiom leak) or `x << n` to cheaply multiply by 2**n. On
# stock Ruby these raise NoMethodError against Float. Adding the ops
# is a zero-risk unlock for a long tail of buggy scripts.
class Float
  def ^(power) self ** power end
  def <<(num)  self * (2 ** num) end
  def >>(num)  self / (2 ** num) end
end

# --- Input::Controller state stubs ---
# Some indie games (cited: Sometimes Always Monsters) probe
# Input::Controller.states / first_state optimistically at startup
# and crash with NoMethodError when the mkxp-z Input module doesn't
# expose a matching surface. Provide an inert State whose every
# method returns a sensible zero so probes succeed and the game
# falls through to keyboard / touch input. Mirrors JoiPlay preload.rb.
module Input
  module Controller
    class State
      def left_trigger_value;   0 end
      def right_trigger_value;  0 end
      def thumb_left_x;  0 end
      def thumb_left_y;  0 end
      def thumb_right_x; 0 end
      def thumb_right_y; 0 end
      def thumb_left_dir4;  0 end
      def thumb_left_dir8;  0 end
      def thumb_right_dir4; 0 end
      def thumb_right_dir8; 0 end
      def press?(button);   false end
      def trigger?(button); false end
      def repeat?(button);  false end
      def pressed_buttons;  [] end
    end

    def self.states;      [State.new] end
    def self.first_state; State.new end
  end
end

# --- MKXP module shim ---
# Some game preload scripts expect the MKXP module from Ancurio's
# original mkxp. mkxp-z uses "System" module instead.
module MKXP
  def self.zinflate(string)
    Zlib::Inflate.inflate(string)
  end

  def self.zdeflate(string, level = Zlib::DEFAULT_COMPRESSION)
    Zlib::Deflate.deflate(string, level)
  end

  def self.data_directory(*args)
    System.data_directory(*args) if defined?(System)
  end

  def self.puts(*args)
    if defined?(System)
      System.puts(*args)
    else
      Kernel.puts(*args)
    end
  end
end

# --- Win32 library null-stub via const_missing ---
# Win32-only library scripts (RGSS Linker, FMODEX, network loaders, etc.)
# reference constants that never get defined on iOS because DLL loading is a
# no-op (see win32_wrap.rb). Instead of adding per-library stubs, hook
# Module#const_missing so any undefined constant - top-level OR nested
# inside a partially-defined module like Berka::NetErrorErr - resolves to
# a safe stub rather than raising NameError.
#
# Two kinds of stubs are returned:
#
# 1. Constants whose name ends in Error, Err, Exception, or Failure become
#    real StandardError subclasses. This matters because games commonly
#    write `raise Berka::NetErrorErr, "msg"`; the raised exception must
#    inherit from Exception or Ruby rejects it, and if it is NullStub the
#    alert ends up showing "IOS::NullStub" as the error message.
#
# 2. Everything else becomes IOS::NullStub, which silently absorbs any
#    method call and any nested constant lookup. This covers library
#    namespaces like FmodEx, FmodEx::System, etc.
module IOS
  class NullStub
    def self.method_missing(name, *args, &block); self; end
    def self.respond_to_missing?(name, include_private = false); true; end
    def self.const_missing(name); self; end
    def self.new(*args, &block); self; end
    # to_s/to_str return empty string so `"prefix: #{stub}"` and any implicit
    # string coercion produce clean output instead of leaking the internal
    # class name or raising TypeError on Ruby 3.x strict coercion.
    def self.to_s;    ""; end
    def self.to_str;  ""; end
    def self.inspect; "#<IOS::NullStub>"; end

    def method_missing(name, *args, &block); nil; end
    def respond_to_missing?(name, include_private = false); true; end
  end

  ErrorStubs = {}
  ERROR_SUFFIX_RE = /(?:Error|Err|Exception|Failure)\z/
end

class Module
  def const_missing(name)
    if name.to_s =~ ::IOS::ERROR_SUFFIX_RE
      key = [self, name]
      ::IOS::ErrorStubs[key] ||= begin
        klass = Class.new(StandardError)
        const_set(name, klass)
        klass
      end
    else
      ::IOS::NullStub
    end
  end
end

# --- Dir.chdir nil-safety ---
# Some games pass nil to Dir.chdir, which crashes Ruby.
class << Dir
  unless method_defined?(:_mkxp_orig_chdir)
    alias_method :_mkxp_orig_chdir, :chdir
  end
  def chdir(dir = nil, &block)
    return _mkxp_orig_chdir(&block) if dir.nil?
    _mkxp_orig_chdir(dir, &block)
  end
end

# --- DL / DL::CFunc legacy fake module ---
# Older Pokemon Essentials forks and a few community plugins use
# Ruby 1.8's `require 'dl'` + `DL::CFunc` to call user32 / kernel32
# functions directly (pre-dating Win32API). On Ruby 3 the stdlib
# `dl` gem doesn't exist and our `const_missing` hook only returns
# `IOS::NullStub`, which is not hash-indexable. Scripts doing
# `dll = DL.dlopen('user32'); dll['GetSystemMetrics']` therefore
# fail on `Hash#[]` even though the constant itself resolves.
#
# Ported from JoiPlay's preload.rb. `dlopen` returns a populated
# hash so the lookup succeeds; `CFunc.new` stores the function
# name and delegates `call` to Win32API (which our win32_wrap
# already routes to noop / safe-default returns on iOS).
module DL
  class CFunc
    def initialize(func, type = "i")
      @func_name = func.to_s
      @type = type
      @impl = begin
        Win32API.new("User32", @func_name, %w(l p), 'i') if defined?(Win32API)
      rescue
        nil
      end
    end

    def call(*args)
      return @impl.call(*args) if @impl
      0
    end

    def to_s;  @func_name.to_s; end
    def to_str; @func_name.to_s; end
  end

  USER32_FUNCS = %w(
    GetActiveWindow GetSystemMetrics GetWindowRect SetWindowLong
    SetWindowPos FindWindow GetForegroundWindow GetCursorPos
    SetWindowText
  ).freeze

  KERNEL32_FUNCS = %w(
    GetModuleHandle GetPrivateProfileString GetCurrentThreadId
    GetCurrentProcess SetPriorityClass
  ).freeze

  def self.dlopen(lib = '')
    name = lib.to_s.downcase
    table = case name
            when /user32/   then USER32_FUNCS
            when /kernel32/ then KERNEL32_FUNCS
            else []
            end
    h = Hash.new { |_, k| k.to_s }  # unknown keys echo their own name
    table.each { |fn| h[fn] = fn }
    h
  end
end

# --- Socket / network stubs ---
# Our embedded Ruby doesn't compile the network stdlib (socket,
# net/http, net/https, openssl, uri) and games can't install user
# gems (discord-rpc, poke-api-v2, rest-client). Without help a
# single `require 'socket'` at the top of a bootstrap script
# raises LoadError and terminates the whole eval, so Reborn and
# similar games don't even reach the title screen. We solve this
# in two layers:
#
# 1. Provide minimal no-op classes for socket primitives (below)
#    so scripts that do `TCPSocket.open(...)` don't NameError
#    later on.
# 2. Intercept Kernel#require with an allowlist of known-missing
#    network stdlib + gems. If the require matches the allowlist
#    and the original require raises LoadError, we swallow it and
#    return false (mimicking "already loaded") so the calling
#    script continues. Non-network requires still propagate.
#
# TODO: compile Ruby with network stdlib so online features
# actually work. See TODO.md "Engine / compatibility".

module Kernel
  # Known-missing networking requires. Match by exact path or by
  # prefix so `net/http`, `net/https`, `net/http/status`, etc. are
  # all absorbed by a single `net/` entry.
  _NETWORK_REQUIRE_PATHS = [
    "socket", "resolv", "resolv-replace",
    "openssl", "digest",
    "uri", "ipaddr",
    "net", "net/",
    "httparty", "rest-client", "rest_client",
    "discord", "discord-rpc", "discordrb",
    "poke-api-v2", "pokeapi",
    "websocket", "websocket-client",
    "json-jwt", "jwt",
  ].freeze

  _orig_require = instance_method(:require)

  define_method(:require) do |path|
    _orig_require.bind(self).call(path)
  rescue LoadError => e
    p = path.to_s
    matched = _NETWORK_REQUIRE_PATHS.any? { |entry|
      entry.end_with?("/") ? p.start_with?(entry) : p == entry
    }
    raise e unless matched
    # Mark as loaded so future `require` calls short-circuit.
    feature = p.end_with?(".rb") ? p : "#{p}.rb"
    $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature)
    false
  end
end

class BasicSocket
  def self.do_not_reverse_lookup; false; end
  def self.do_not_reverse_lookup=(*); end
  def initialize(*); end
  def close; end
  def closed?; true; end
  def read(*); ""; end
  def write(*); 0; end
  def puts(*); nil; end
  def gets(*); nil; end
  def send(*); 0; end
  def recv(*); ""; end
  def setsockopt(*); 0; end
  def shutdown(*); 0; end
  def addr; ["AF_INET", 0, "0.0.0.0", "0.0.0.0"]; end
  def peeraddr; ["AF_INET", 0, "0.0.0.0", "0.0.0.0"]; end
end

class IPSocket < BasicSocket
  def self.getaddress(*); "0.0.0.0"; end
end

class TCPSocket < IPSocket
  def self.open(*); new; end
  def self.new(*); super(); end
end

class UDPSocket < IPSocket
  def bind(*); 0; end
  def connect(*); 0; end
end

class TCPServer < TCPSocket
  def accept; TCPSocket.new; end
  def accept_nonblock; raise IO::WaitReadable; end
  def listen(*); 0; end
end

class UNIXSocket < BasicSocket
  def self.open(*); new; end
end

class UNIXServer < UNIXSocket
  def accept; UNIXSocket.new; end
end
