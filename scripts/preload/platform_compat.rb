# platform_compat.rb
# Engine-level platform compatibility layer.
# Auto-loaded before game scripts to ensure compatibility.
# Game-specific patches live in separate files (e.g. pokemon_compat.rb).

# DEBUG: marker BEFORE require so we can tell whether the script
# even starts evaluating, vs failing at the require call.
begin
  if defined?(System) && System.respond_to?(:puts)
    System.puts "[platform_compat] preload TOP (Ruby #{RUBY_VERSION})"
  end
rescue StandardError => e
  # System.puts itself missing? Fall back to stderr (which the engine
  # captures into the session log).
  warn "[platform_compat] System.puts unavailable: #{e.class}: #{e.message}"
end

# Try the require under exception handling so a failure doesn't
# abort the whole preload silently.
begin
  require 'zlib'
  if defined?(System)
    has_zlib = $LOADED_FEATURES.any? { |f| f.include?('zlib') }
    System.puts "[platform_compat] require 'zlib' OK ($LOADED_FEATURES has zlib? #{has_zlib})"
  end
rescue LoadError => e
  System.puts "[platform_compat] require 'zlib' FAILED: #{e.message}" if defined?(System)
rescue StandardError => e
  System.puts "[platform_compat] require 'zlib' EXC: #{e.class}: #{e.message}" if defined?(System)
end

# --- JoiPlay-compat signal ---
# Several Pokemon Essentials fangames (Reborn, Rejuvenation,
# Desolation, etc.) branch on `$joiplay` to pick between JoiPlay's
# stripped-down API surface and desktop mkxp-z's extended one.
# Example: Reborn's `internal_se_play` uses `Audio.se_play` on
# JoiPlay but `Audio.se_play_position` on desktop - the latter is
# an mkxp-z extension our iOS build doesn't carry. Since we ship
# JoiPlay-compat shims (NilClass safe-stubs, Win32API/DL stubs,
# poke_* graphics aliases, cheats, network stubs) the JoiPlay code
# path is what works here, so we set the flag.
$joiplay = true

# --- Thread.critical / Thread.critical= no-op shims (Ruby 1.9+) ---
# Ruby 1.8 had `Thread.critical` and `Thread.critical=` to disable
# thread switching during a critical section; both were removed in
# Ruby 1.9 when the GIL was replaced by per-thread locks. Vintage
# RGSS / Pokemon Essentials code commonly wraps Marshal.load and
# save-file I/O with `Thread.critical = true` ... `Thread.critical
# = false`, expecting the methods to exist.
#
# On Ruby 1.9+ those calls now raise `NoMethodError: undefined
# method 'critical' for class 'Thread'`. The error often surfaces
# during quit / save flows where the in-game `pbExit` chain calls
# `pbSave` which sets `Thread.critical = true`, and has historically
# crashed the engine entirely (the `NoMethodError` propagates out of
# the script-eval loop, the engine's iOS shutdown path then segfaults
# because the Ruby VM is in an exception-pending state when
# SharedState::finiInstance() runs).
#
# Restore both as no-ops on every Ruby version that's missing them.
# The 1.8 cooperative-scheduling semantics don't apply under modern
# Ruby anyway; calling code only cared that the methods existed.
unless Thread.respond_to?(:critical)
  # rubocop:disable Naming/PredicateMethod -- mocking Ruby 1.8's
  # `Thread.critical` reader, which returns a Boolean but is named
  # without `?` for backwards compatibility with the 1.8 API.
  def Thread.critical
    false
  end
  # rubocop:enable Naming/PredicateMethod

  def Thread.critical=(value)
    value
  end
end

# --- exit! / Process.exit! redirect to SystemExit ---
# Ruby's `Kernel.exit!(status)` and `Process.exit!(status)` skip
# `at_exit` handlers AND ALSO bypass the engine's SystemExit
# rescue path entirely - they call `_exit(status)` directly,
# which terminates the iOS process before mkxp-z can flush
# graphics state, save the engine log, fire the
# `mkxp_setEngineTerminated` callback, or do anything else.
#
# Pokemon Essentials' `pbExit` (and its many forks - Vanguard,
# Reborn, etc.) commonly use `exit!` so the user's quit click
# bypasses the game's "press any key to confirm" splash that
# `at_exit` handlers would normally trigger. On desktop this is
# a fine UX choice; on iOS it causes the app to vanish without
# the engine even getting a chance to know the user quit.
#
# Redirect both to `Kernel.exit(status)` so the engine's
# binding-mri.cpp script-eval loop catches the SystemExit, sets
# `mkxp_setEngineExitedCleanly()`, fires the terminated callback,
# and the iOS host shows the configured "game ended" UX. The
# desktop semantics of "skip at_exit handlers" are not preserved
# - we accept that trade because no shipping iOS PE-fork relies
# on the at_exit-skipping behaviour for anything user-visible.
module Kernel
  def exit!(status = false)
    exit(status)
  end
  module_function :exit!
end

module Process
  class << self
    alias _mkxp_orig_exit_bang exit! if respond_to?(:exit!) && !method_defined?(:_mkxp_orig_exit_bang)

    def exit!(status = false)
      Kernel.exit(status)
    end
  end
end

# Suppress Ruby's $DEBUG global. Some plugins gate verbose error
# dialogs / extra print output on `$DEBUG`; without an explicit
# `false` the engine inherits whatever Ruby's startup defaulted to,
# which on some MRI builds is a truthy state (-d on the cmdline,
# RUBYOPT=-d, etc.). JoiPlay sets this in its preload for the same
# reason. Pinned here so plugins reading it during script load see
# the expected `false`.
$DEBUG = false

# Plugin-probe constants. Old Yanfly-era plugins look at
# `Graphics::PlaneSpeedUp`; without an explicit definition our
# engine's `const_missing` returns `IOS::NullStub`, which is
# always-truthy and silently flips the plugin's optimization path
# the wrong way. Match JoiPlay's default: define the constant as
# `false` so the plugin's "no plane speedup" branch is taken.
unless defined?(Graphics::PlaneSpeedUp)
  module Graphics
    PlaneSpeedUp = false
  end
end

# Top-level no-op for `set_loop_points(intro_pos, loop_end)`. Some
# custom audio-loop plugins call this from map transitions /
# bgm_play overrides; on JoiPlay's default builds this exists as
# a Kernel-level no-op (preload.rb:119-120). Without it our
# `IOS::NullStub` const_missing path doesn't catch it (it's a
# method call, not a constant ref) and the script raises
# `NoMethodError: undefined method 'set_loop_points'`. The two-arg
# stub mirrors JoiPlay; arity is permissive via `*args` to
# accommodate plugins that pass additional metadata.
module Kernel
  def set_loop_points(*args); end
  module_function :set_loop_points
end

# --- Case-insensitive file probes ---
# Native mkxp bindings now handle the core Ruby File/Dir/require/load
# casefold retries through the PhysFS-backed path cache. Keep only the
# Ruby-side helpers still needed by higher-level script APIs.
unless defined?(MKXPCasefoldFS)
  module MKXPCasefoldFS
    # rubocop:disable Style/SymbolArray -- `%i` does not parse on Ruby 1.8.
    FILE_QUERY_METHODS = [
      :exist?, :directory?, :file?, :zero?, :size?,
      :readable?, :readable_real?, :world_readable?,
      :writable?, :writable_real?, :world_writable?,
      :executable?, :executable_real?,
      :owned?, :grpowned?,
      :blockdev?, :chardev?, :pipe?, :socket?, :symlink?,
      :setuid?, :setgid?, :sticky?
    ].freeze
    FILE_VALUE_METHODS = [
      :size, :atime, :ctime, :mtime, :birthtime,
      :stat, :lstat, :ftype, :realpath, :readlink
    ].freeze
    FILE_READ_METHODS = [:read, :binread, :readlines, :foreach].freeze
    # rubocop:enable Style/SymbolArray
    GLOB_META_RE = /[*?\[{]/.freeze

    module_function

    def exists?(path)
      File.exist?(path)
    rescue StandardError
      false
    end

    def desensitize(path)
      return nil unless path.is_a?(String)

      return System.desensitize(path) if defined?(System) && System.respond_to?(:desensitize)
      return MKXP.desensitize(path) if defined?(MKXP) && MKXP.respond_to?(:desensitize)

      nil
    rescue StandardError
      nil
    end

    def resolve(path)
      return nil unless path.is_a?(String)

      resolved = desensitize(path)
      return nil if resolved.nil? || resolved.empty?
      return resolved if resolved != path
      return resolved if exists?(resolved)

      nil
    rescue StandardError
      nil
    end

    def fallback(path)
      resolved = resolve(path)
      return false unless resolved

      yield(resolved)
    end

    def resolve_parent(path)
      return nil unless path.is_a?(String)

      dirname = File.dirname(path)
      return nil if dirname.nil? || dirname.empty? || dirname == '.'

      resolved_dir = resolve(dirname)
      return nil unless resolved_dir

      basename = File.basename(path)
      resolved_dir = resolved_dir.gsub(%r{[\\/]\z}, '')
      basename.empty? ? resolved_dir : "#{resolved_dir}/#{basename}"
    rescue StandardError
      nil
    end

    def rescue_existing_path(path)
      resolved = resolve(path) || resolve_parent(path)
      return nil unless resolved

      yield(resolved)
    end

    def resolve_bitmap(path)
      return nil unless path.is_a?(String)

      base = path.gsub(/\.(bmp|png|gif|jpg|jpeg)$/i, '')
      ['.png', '.gif'].each do |ext|
        resolved = resolve(base + ext)
        return resolved if resolved
      end

      nil
    end

    def remap_glob_pattern(pattern)
      return nil unless pattern.is_a?(String)
      return nil unless pattern =~ GLOB_META_RE

      wildcard_index = pattern.index(GLOB_META_RE)
      return nil unless wildcard_index

      prefix = pattern[0...wildcard_index]
      slash = [prefix.rindex('/'), prefix.rindex('\\')].compact.max
      return nil unless slash

      dirname = pattern[0...slash]
      suffix = pattern[(slash + 1)..-1]
      resolved_dir = resolve(dirname)
      return nil unless resolved_dir

      "#{resolved_dir.gsub(%r{[\\/]\z}, '')}/#{suffix}"
    rescue StandardError
      nil
    end

    def remap_glob_arg(arg)
      if arg.is_a?(Array)
        changed = false
        remapped = arg.map do |pattern|
          replacement = remap_glob_pattern(pattern)
          changed ||= !replacement.nil? && replacement != pattern
          replacement || pattern
        end
        changed ? remapped : nil
      else
        remap_glob_pattern(arg)
      end
    end
  end
end

unless defined?(MKXPSaveFS)
  module MKXPSaveFS
    module_function

    def root
      return nil unless defined?(System) && System.respond_to?(:data_directory)

      dir = System.data_directory.to_s
      return nil if dir.empty?

      dir.gsub(%r{[\\/]+\z}, '')
    rescue StandardError
      nil
    end

    def candidate?(path)
      return false unless path.is_a?(String)

      stripped = path.strip
      return false if stripped.empty?
      return false if stripped.start_with?('/', '~')
      return false if stripped =~ %r{\A[A-Za-z]:[\\/]}
      return false if stripped.include?('/') || stripped.include?('\\')

      lower = stripped.downcase
      return true if lower =~ /\A(?:save\d+|game)\.(?:rxdata|rvdata|rvdata2)\z/
      return true if lower.end_with?('.rxdata', '.rvdata', '.rvdata2')
      return true if lower.end_with?('.bak')

      false
    end

    def path_for(path)
      return path unless candidate?(path)

      base = root
      return path unless base

      "#{base}/#{path}"
    end

    def glob_for(pattern)
      return nil unless candidate?(pattern)

      path_for(pattern)
    end
  end
end

# Pokemon Essentials' `pbResolveBitmap` relies on `pbTryString`, which probes a
# candidate path and returns the ORIGINAL string on success. On Windows that is
# fine because later opens are also case-insensitive; on iOS we need the real
# mixed-case path for callers that keep using the returned filename.
unless Object.respond_to?(:_mkxp_casefold_orig_method_added, true)
  class << Object
    alias _mkxp_casefold_orig_method_added method_added

    # rubocop:disable Lint/MissingSuper -- this callback must invoke the aliased
    # original hook so the same code parses on Ruby 1.8.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    # rubocop:disable Naming/VariableName -- preserve upstream Pokemon method names.
    def method_added(name)
      _mkxp_casefold_orig_method_added(name)

      case name
      when :pbTryString
        return if @_mkxp_wrapping_pbTryString

        @_mkxp_wrapping_pbTryString = true
        original_method = instance_method(:pbTryString)

        define_method(:pbTryString) do |x|
          result = original_method.bind(self).call(x)
          return result unless x.is_a?(String)

          resolved = MKXPCasefoldFS.resolve(x)
          return result unless resolved

          if result.nil?
            retried = original_method.bind(self).call(resolved)
            if retried.nil?
              result
            else
              if defined?(System)
                System.puts("[platform_compat] pbTryString casefold hit: #{x} -> #{resolved}")
              end
              resolved
            end
          else
            System.puts("[platform_compat] pbTryString normalized: #{x} -> #{resolved}") if defined?(System)
            resolved
          end
        end

        private :pbTryString
      when :pbResolveBitmap
        return if @_mkxp_wrapping_pbResolveBitmap

        @_mkxp_wrapping_pbResolveBitmap = true
        original_method = instance_method(:pbResolveBitmap)

        define_method(:pbResolveBitmap) do |*args|
          result = original_method.bind(self).call(*args)
          x = args[0]
          resolved = MKXPCasefoldFS.resolve_bitmap(x)
          return result unless resolved

          if result.nil?
            if defined?(System)
              System.puts("[platform_compat] pbResolveBitmap casefold hit: #{x} -> #{resolved}")
            end
          elsif result != resolved
            if defined?(System)
              System.puts("[platform_compat] pbResolveBitmap normalized: #{x} -> #{resolved}")
            end
          end
          resolved
        end
        ruby2_keywords(:pbResolveBitmap) if respond_to?(:ruby2_keywords, true)

        private :pbResolveBitmap
      end
    ensure
      @_mkxp_wrapping_pbTryString = false if name == :pbTryString
      @_mkxp_wrapping_pbResolveBitmap = false if name == :pbResolveBitmap
    end
    # rubocop:enable Naming/VariableName
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    # rubocop:enable Lint/MissingSuper
  end

  System.puts '[platform_compat] pbTryString casefold hook armed' if defined?(System)
  System.puts '[platform_compat] pbResolveBitmap casefold hook armed' if defined?(System)
end

# --- Process spawning neutralization ---
# fork()/exec() are forbidden on iOS and cause immediate SIGKILL.
# Neutralize all process-spawning methods at the engine level.
module Kernel
  # Process-spawning methods are no-ops on iOS: fork/exec would be
  # killed by the sandbox and system("game.exe") only makes sense on
  # Windows. Return nil so games keep running; real exec() would
  # terminate the process but that's the entire iOS app here, so a
  # silent no-op is the safer default.
  def system(*_args)
    nil
  end

  def exec(*_args)
    nil
  end

  def fork(*_args)
    nil
  end

  def spawn(*_args)
    nil
  end
  module_function :system, :exec, :fork, :spawn
end

# --- Windows environment variable stubs ---
# Many RGSS games use ENV["TEMP"] / ENV["APPDATA"] for file operations,
# and some derive save paths from USERPROFILE / LOCALAPPDATA /
# COMPUTERNAME. Mirror JoiPlay's full fake-Windows environment so
# scripts constructing paths from ENV don't return nil and crash.
# Values point into the iOS sandbox (or are blank strings) so File.exist?
# returns false rather than reading unrelated system dirs.
tmp = '/tmp'
begin
  tmp = Dir.tmpdir
rescue StandardError
  # Dir.tmpdir can raise on locked-down sandboxes; fall back to /tmp.
end
save_root = nil
begin
  if defined?(System) && System.respond_to?(:data_directory)
    root = System.data_directory.to_s
    save_root = root unless root.empty?
  end
rescue StandardError
  save_root = nil
end
userdata = save_root || "#{tmp}/UserData"
ENV['TEMP'] ||= tmp
ENV['TMP']  ||= tmp
ENV['APPDATA']              ||= userdata
ENV['LOCALAPPDATA']         ||= userdata
ENV['ALLUSERSPROFILE']      ||= userdata
ENV['USERPROFILE']          ||= userdata
ENV['HOMEDRIVE']            ||= ''
ENV['HOMEPATH']             ||= userdata
ENV['SystemRoot']           ||= userdata
ENV['windir']               ||= userdata
ENV['COMPUTERNAME']         ||= 'Empo'
ENV['USERNAME']             ||= 'Empo'
ENV['USERDOMAIN']           ||= 'Empo'
ENV['SESSIONNAME']          ||= 'Empo'
ENV['OS']                   ||= 'Windows_NT'
ENV['PATH']                 ||= ''
ENV['PATHEXT']              ||= ''
ENV['Platform']             ||= ''
ENV['NUMBER_OF_PROCESSORS'] ||= '4'
ENV['PROCESSOR_ARCHITECTURE'] ||= 'x86'
ENV['PROCESSOR_IDENTIFIER'] ||= 'Intel64 Family6'
ENV['PROCESSOR_LEVEL']      ||= '6'
ENV['PROCESSOR_REVISION']   ||= '2a07'
ENV['AV_APPDATA']           ||= userdata

# --- Float bitwise-op monkey-patches ---
# RGSS scripts occasionally do `x ^ 2` when they mean `x ** 2` (a
# Game-Maker-idiom leak) or `x << n` to cheaply multiply by 2**n. On
# stock Ruby these raise NoMethodError against Float. Adding the ops
# is a zero-risk unlock for a long tail of buggy scripts.
class Float
  def ^(other)
    self**other
  end

  def <<(num)
    self * (2**num)
  end

  def >>(other)
    self / (2**other)
  end
end

# --- Input::Controller state stubs ---
# Prevents NoMethodError crashes from games that probe gamepad
# state via a pad API the iOS port doesn't expose. Cited offender
# is Sometimes Always Monsters, which calls
# `Input::Controller.first_state.thumb_left_x` (and friends) at
# startup; without these stubs the script terminates before the
# title screen. We are NOT implementing real gamepad support here
# - every method returns a zero / false / [] sentinel so probes
# succeed and the game falls through to keyboard / touch input.
#
# Guarded on `defined?(Input::Controller)` so a future engine-level
# Controller binding (or a game that ships its own) isn't clobbered.
# Source: JoiPlay mkxp/binding-mri/preload.rb:123-177.
unless defined?(Input::Controller)
  module Input
    module Controller
      class State
        def left_trigger_value
          0
        end

        def right_trigger_value
          0
        end

        def thumb_left_x
          0
        end

        def thumb_left_y
          0
        end

        def thumb_right_x
          0
        end

        def thumb_right_y
          0
        end

        def thumb_left_dir4
          0
        end

        def thumb_left_dir8
          0
        end

        def thumb_right_dir4
          0
        end

        def thumb_right_dir8
          0
        end

        def press?(_button)
          false
        end

        def trigger?(_button)
          false
        end

        def repeat?(_button)
          false
        end

        def pressed_buttons
          []
        end
      end

      def self.states
        [State.new]
      end

      def self.first_state
        State.new
      end
    end
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

  def self.desensitize(path)
    System.desensitize(path) if defined?(System)
  end
end

# --- Save-path remap into per-game UserData/ ---
class << File
  alias _mkxp_orig_open open unless method_defined?(:_mkxp_orig_open)
  alias _mkxp_orig_delete delete unless method_defined?(:_mkxp_orig_delete)
  alias _mkxp_orig_rename rename unless method_defined?(:_mkxp_orig_rename)

  def open(path, *args, &block)
    _mkxp_orig_open(MKXPSaveFS.path_for(path), *args, &block)
  end

  def delete(*paths)
    _mkxp_orig_delete(*paths.map { |path| MKXPSaveFS.path_for(path) })
  end

  def rename(from, to)
    _mkxp_orig_rename(MKXPSaveFS.path_for(from), MKXPSaveFS.path_for(to))
  end
end

module FileTest
  class << self
    alias _mkxp_orig_exist exist? unless method_defined?(:_mkxp_orig_exist)
    alias _mkxp_orig_file file? unless method_defined?(:_mkxp_orig_file)
    alias _mkxp_orig_directory directory? unless method_defined?(:_mkxp_orig_directory)

    def exist?(path)
      _mkxp_orig_exist(MKXPSaveFS.path_for(path))
    end

    def file?(path)
      _mkxp_orig_file(MKXPSaveFS.path_for(path))
    end

    def directory?(path)
      _mkxp_orig_directory(MKXPSaveFS.path_for(path))
    end
  end
end

class << Dir
  alias _mkxp_orig_glob glob unless method_defined?(:_mkxp_orig_glob)

  def glob(pattern, *args, &block)
    remapped = MKXPSaveFS.glob_for(pattern)
    result = _mkxp_orig_glob(remapped || pattern, *args, &block)
    return result unless remapped && result.respond_to?(:map)

    prefix = MKXPSaveFS.root
    return result unless prefix

    normalized_prefix = "#{prefix}/"
    result.map do |entry|
      entry.start_with?(normalized_prefix) ? entry.delete_prefix(normalized_prefix) : entry
    end
  end
end

module Kernel
  alias _mkxp_orig_load_data load_data unless method_defined?(:_mkxp_orig_load_data)
  alias _mkxp_orig_save_data save_data unless method_defined?(:_mkxp_orig_save_data)

  def load_data(path, *args)
    _mkxp_orig_load_data(MKXPSaveFS.path_for(path), *args)
  end

  def save_data(obj, path, *args)
    _mkxp_orig_save_data(obj, MKXPSaveFS.path_for(path), *args)
  end
  module_function :load_data, :save_data
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
    def self.method_missing(_name, *_args)
      self
    end

    def self.respond_to_missing?(_name, _include_private = false)
      true
    end

    def self.const_missing(_name)
      self
    end

    def self.new(*_args)
      self
    end

    # to_s/to_str return empty string so `"prefix: #{stub}"` and any implicit
    # string coercion produce clean output instead of leaking the internal
    # class name or raising TypeError on Ruby 3.x strict coercion.
    def self.to_s
      ''
    end

    def self.to_str
      ''
    end

    def self.inspect
      '#<IOS::NullStub>'
    end

    def method_missing(_name, *_args)
      nil
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  # rubocop:disable Style/MutableConstant -- const_missing populates
  # this lazily via `ErrorStubs[key] ||= ...` (line ~437) so it can't
  # be frozen.
  ErrorStubs = {}
  # rubocop:enable Style/MutableConstant
  ERROR_SUFFIX_RE = /(?:Error|Err|Exception|Failure)\z/.freeze
end

class Module
  def const_missing(name)
    return super unless Object.const_defined?(:IOS)

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

# --- Dir.chdir nil/empty-safety ---
# Pokemon Essentials and some plugin scripts pass nil or "" to
# Dir.chdir. nil crashes Ruby pre-2.0 outright; "" raises
# Errno::ENOENT on every Ruby version. Both are no-ops in spirit
# (the script wants "stay where you are") so we route them through
# the no-arg form, which is safe and well-defined (returns to home
# dir or no-op when called with a block on no-arg).
class << Dir
  alias _mkxp_orig_chdir chdir unless method_defined?(:_mkxp_orig_chdir)
  def chdir(dir = nil, &block)
    return _mkxp_orig_chdir(&block) if dir.nil? || dir.empty?

    _mkxp_orig_chdir(dir, &block)
  end
end
if defined?(System) && System.respond_to?(:puts)
  has_orig = Dir.respond_to?(:_mkxp_orig_chdir)
  System.puts "[platform_compat] Dir.chdir patch applied (orig defined? #{has_orig})"
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
    def initialize(func, type = 'i')
      @func_name = func.to_s
      @type = type
      @impl = begin
        Win32API.new('User32', @func_name, %w[l p], 'i') if defined?(Win32API)
      rescue StandardError
        nil
      end
    end

    def call(*args)
      return @impl.call(*args) if @impl

      0
    end

    def to_s
      @func_name.to_s
    end

    def to_str
      @func_name.to_s
    end
  end

  USER32_FUNCS = %w[
    GetActiveWindow GetSystemMetrics GetWindowRect SetWindowLong
    SetWindowPos FindWindow GetForegroundWindow GetCursorPos
    SetWindowText
  ].freeze

  KERNEL32_FUNCS = %w[
    GetModuleHandle GetPrivateProfileString GetCurrentThreadId
    GetCurrentProcess SetPriorityClass
  ].freeze

  def self.dlopen(lib = '')
    name = lib.to_s.downcase
    table = case name
            when /user32/   then USER32_FUNCS
            when /kernel32/ then KERNEL32_FUNCS
            else []
            end
    h = Hash.new { |_, k| k.to_s } # unknown keys echo their own name
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
# work. See TODO.md "Engine / compatibility".

module Kernel
  # Known-missing networking requires. Match by exact path or by
  # prefix so `net/http`, `net/https`, `net/http/status`, etc. are
  # all absorbed by a single `net/` entry.
  NETWORK_REQUIRE_PATHS = [
    'socket', 'resolv', 'resolv-replace',
    'openssl', 'digest',
    'uri', 'ipaddr',
    'net', 'net/',
    'httparty', 'rest-client', 'rest_client',
    'discord', 'discord-rpc', 'discordrb',
    'poke-api-v2', 'pokeapi',
    'websocket', 'websocket-client',
    'json-jwt', 'jwt'
  ].freeze

  orig_require = instance_method(:require)

  define_method(:require) do |path|
    begin
      orig_require.bind(self).call(path)
    rescue LoadError => e
      str = path.to_s
      matched = NETWORK_REQUIRE_PATHS.any? do |entry|
        entry.end_with?('/') ? str.start_with?(entry) : str == entry
      end
      raise e unless matched

      # Mark as loaded so future `require` calls short-circuit.
      feature = str.end_with?('.rb') ? str : "#{str}.rb"
      $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature)
      false
    end
  end
end

# --- Socket class stubs ---
# Removed. Pokemon Essentials forks (Insurgence, Reborn) ship
# their own Sockets script that defines TCPSocket / UDPSocket /
# BasicSocket with their own class hierarchy. Pre-defining stubs
# here causes "superclass mismatch" when the game later defines
# the same class with a different parent. Games that genuinely
# need network stubs (rare on iOS where we have no real socket
# layer anyway) should ship their own.
