# platform_compat.rb
# Engine-level platform compatibility layer.
# Auto-loaded before game scripts to ensure compatibility.
# Game-specific patches live in separate files (e.g. pokemon_compat.rb).

require 'zlib'

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
# Many RGSS games use ENV["TEMP"] / ENV["APPDATA"] for file operations.
_tmp = "/tmp"
begin
  _tmp = Dir.tmpdir
rescue
end
ENV["TEMP"] ||= _tmp
ENV["TMP"]  ||= _tmp
ENV["APPDATA"] ||= _tmp

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

# --- Auto-stub Error-suffix constants on missing lookup ---
# Win32-only library scripts (RGSS Linker, FMODEX, network loaders, etc.)
# reference exception types defined by native DLLs that never load on iOS.
# When a script does `raise Berka::NetErrorErr, "msg"` or
# `rescue Fmod::InitError`, Ruby needs those constants to resolve to real
# Exception subclasses - a generic NullStub would fail `raise`/`rescue`.
#
# Only Error/Err/Exception/Failure-suffixed constants are auto-stubbed.
# Everything else raises NameError (standard Ruby semantics) so the engine
# error-skip path in binding-mri.cpp picks it up and the script is skipped.
module IOS
  ErrorStubs = {}
  ERROR_SUFFIX_RE = /(?:Error|Err|Exception|Failure)\z/
end

class Module
  unless method_defined?(:_mkxp_orig_const_missing)
    alias_method :_mkxp_orig_const_missing, :const_missing
  end

  def const_missing(name)
    if name.to_s =~ ::IOS::ERROR_SUFFIX_RE
      key = [self, name]
      ::IOS::ErrorStubs[key] ||= begin
        klass = Class.new(StandardError)
        const_set(name, klass)
        klass
      end
    else
      _mkxp_orig_const_missing(name)
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
