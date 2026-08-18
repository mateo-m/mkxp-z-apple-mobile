# pokemon_compat.rb
# Compatibility patches for Pokemon Essentials / Pokemon fangames.
# Separated from platform_compat.rb to keep engine-generic code clean.

# --- Pokemon Essentials text-entry path ---
# JoiPlay sets this top-level constant so Pokemon Essentials fan
# games consulting it (older Essentials builds, Uranium, Reborn,
# others) pick the on-screen character grid instead of the
# physical-keyboard variant. Stock Essentials doesn't reference it -
# JoiPlay-aware games do - but it's the cheapest nudge into the
# touch-friendly scene that doesn't require modifying the game's
# `PokemonEntryScene` itself.
#
# Set here at preload so class bodies evaluating `USEKEYBOARD =
# USEKEYBOARDTEXTENTRY` during script load see `false`. Some fan
# games (Uranium) re-assign the constant from their own Settings
# script, so pokemon_input.rb re-applies the override in postload
# to win that race before `pbEnterText` ever runs.
USEKEYBOARDTEXTENTRY = false unless defined?(USEKEYBOARDTEXTENTRY)

# --- PokemonSystem#screensize backstop ---
# Pre-define the class with a default `screensize` accessor so older
# PE forks (Reborn pre-19, Insurgence pre-1.2, several mod packs)
# that probe `$PokemonSystem.screensize` before the actual setter
# has run get 1.0 instead of `NoMethodError`. Ruby's open-class
# semantics mean the game's later `class PokemonSystem ... end`
# block reopens this class without losing the accessor.
#
# `begin/rescue` defends against game forks that redefine
# `PokemonSystem` with an explicit superclass (which would raise
# `TypeError: superclass mismatch`). The catch leaves the game's
# own definition winning and our patch silently absent for that
# game (acceptable - it presumably handles screensize itself).
begin
  class PokemonSystem
    # `instance_methods` returns Strings on Ruby 1.8 but Symbols
    # on 1.9+, so `instance_methods.include?(:screensize)` is
    # never true on 1.8 even when the method exists. Use
    # `method_defined?` (Symbol-friendly on every version) for
    # the "is anything already defined" guard. We unconditionally
    # define both writer and reader-with-default. Redefinition on
    # subsequent loads is idempotent (last-write-wins) and a
    # game's later `class PokemonSystem ... end` still overrides
    # cleanly via Ruby's open-class semantics.
    attr_accessor :screensize

    def screensize
      @screensize ||= 1.0
    end
  end
rescue TypeError
  # superclass mismatch with a fork's own definition. Bow out.
end

# --- Uranium hard-reset prevention ---
# Pokemon Uranium checks $game_exists on startup and calls
# system('Uranium') + exit to relaunch itself. On iOS, system() is
# neutralized (see platform_compat.rb), but we also clear the flag so the
# hard-reset code path is never reached.
$game_exists = nil

# --- FmodEx routing to native Audio ---
# Pokemon fan games (Uranium, Vinemon Sauce Edition, others) ship
# scripts that load `RGSS FmodEx.dll` and redefine `Audio.bgm_play`
# / `Audio.bgs_play` / `Audio.me_play` to dispatch through
# `::FmodEx`. On iOS the DLL can't be loaded, so without
# intervention `::FmodEx` resolves to `IOS::NullStub` (via our
# `const_missing` hook) and every audio call lands in
# `method_missing` and drops the sound on the floor.
#
# Strategy: define a real `::FmodEx` module here that satisfies the
# game scripts' API surface (init / bgm_play / bgs_play / me_play /
# se_play / fade / stop, plus the playback handle's
# `set_position` / `get_position` / `set_loop_points`) by
# forwarding to the engine's native `Audio` module. Snapshotting
# the native methods now (preload runs before any game script
# touches `Audio`) means later script overrides that route
# through `::FmodEx` end up calling back into the engine's native
# OpenAL-Soft path - audio plays.
#
# Replaces the older Uranium-specific `@bgm_play = true` hack
# (which short-circuited Uranium's `unless @bgm_play` block but
# didn't help games like Vinemon whose audio override has no
# similar guard). One mechanism, fewer game-specific scopes.
if defined?(Audio) && Audio.is_a?(Module)
  # Snapshot native Audio methods before any game script can
  # rebind them. Stored as module instance variables on Audio.
  Audio.instance_eval do
    @__mkxp_native_bgm_play  = method(:bgm_play)  if respond_to?(:bgm_play)
    @__mkxp_native_bgm_fade  = method(:bgm_fade)  if respond_to?(:bgm_fade)
    @__mkxp_native_bgm_stop  = method(:bgm_stop)  if respond_to?(:bgm_stop)
    @__mkxp_native_bgs_play  = method(:bgs_play)  if respond_to?(:bgs_play)
    @__mkxp_native_bgs_fade  = method(:bgs_fade)  if respond_to?(:bgs_fade)
    @__mkxp_native_bgs_stop  = method(:bgs_stop)  if respond_to?(:bgs_stop)
    @__mkxp_native_me_play   = method(:me_play)   if respond_to?(:me_play)
    @__mkxp_native_me_fade   = method(:me_fade)   if respond_to?(:me_fade)
    @__mkxp_native_me_stop   = method(:me_stop)   if respond_to?(:me_stop)
    @__mkxp_native_se_play   = method(:se_play)   if respond_to?(:se_play)
    @__mkxp_native_se_stop   = method(:se_stop)   if respond_to?(:se_stop)
  end

  # Helper: best-effort call of the saved native method. If the
  # snapshot is missing (engine didn't expose that method) silently
  # no-op so the game keeps running rather than raising.
  def Audio.__mkxp_native_call(ivar, *args)
    m = instance_variable_get(ivar)
    m.call(*args) if m
  end
end

# Snapshot native Graphics methods the same way. Daybreak's "MKXP
# Compatbility Fix" script replaces Graphics.snap_to_bitmap with a
# delegate to Graphics.mkxp_snap_to_bitmap, and JoiPlay-targeting
# games ship equivalent Ruby wrappers over the poke_* names. The
# postload delegates (pokemon_graphics_compat.rb) must reach the
# native methods, not the game's replacements - late binding there
# makes the two wrappers call each other until the stack dies.
if defined?(Graphics) && Graphics.is_a?(Module)
  Graphics.instance_eval do
    @__mkxp_native_snap_to_bitmap = method(:snap_to_bitmap) if respond_to?(:snap_to_bitmap)
    @__mkxp_native_width          = method(:width)          if respond_to?(:width)
    @__mkxp_native_height         = method(:height)         if respond_to?(:height)
    @__mkxp_native_resize_screen  = method(:resize_screen)  if respond_to?(:resize_screen)
    @__mkxp_native_play_movie     = method(:play_movie)     if respond_to?(:play_movie)
  end
end

# Playback handle returned by `FmodEx.bgm_play` / etc. The actual
# native audio is fire-and-forget on the Audio module (no real
# handle), so this is mostly a duck-typed shell that satisfies the
# small set of methods game scripts call on the returned value.
# Position queries fall through to the matching native getter
# where one exists. Loop-point setters are no-ops (most games
# don't depend on Ruby-level loop tables - mkxp-z honors Ogg
# `LOOPSTART`/`LOOPLENGTH` tags via its native loader).
class FmodExHandle
  def initialize(kind)
    @kind = kind
  end

  # rubocop:disable Naming/AccessorMethodName -- mirrors FmodEx
  # playback-handle API (`set_position` / `get_position`) that
  # game scripts call by exact name.
  def set_position(_pos); end

  def get_position
    if Audio.respond_to?(:bgm_position)
      begin
        Audio.bgm_position
      rescue StandardError
        0
      end
    else
      0
    end
  end
  # rubocop:enable Naming/AccessorMethodName

  def set_loop_points(*_args); end

  def stop
    case @kind
    when :bgm then Audio.__mkxp_native_call(:@__mkxp_native_bgm_stop)
    when :bgs then Audio.__mkxp_native_call(:@__mkxp_native_bgs_stop)
    when :me  then Audio.__mkxp_native_call(:@__mkxp_native_me_stop)
    when :se  then Audio.__mkxp_native_call(:@__mkxp_native_se_stop)
    end
  end
end

module FmodEx
  module_function

  # No-op init handshake. Some scripts call `FmodEx.init(channels)`
  # to set up a software channel pool. We ignore it because the
  # underlying engine handles channel allocation itself.
  def init(*_args); end

  # BGM
  def bgm_play(filename, volume = 100, pitch = 100, position = 0)
    # Game scripts pass either a bare basename ("Audio/BGM/foo")
    # or a full path. mkxp-z's Audio.bgm_play accepts both. Our
    # 4-arg native form takes a position (microseconds) where
    # supported. Fall back to 3-arg if the engine doesn't accept
    # it (older RGSS1 builds).
    begin
      Audio.__mkxp_native_call(:@__mkxp_native_bgm_play, filename, volume, pitch, position)
    rescue StandardError
      Audio.__mkxp_native_call(
        :@__mkxp_native_bgm_play, filename, volume, pitch
      )
    end
    FmodExHandle.new(:bgm)
  end

  def bgm_fade(ms)
    Audio.__mkxp_native_call(:@__mkxp_native_bgm_fade, ms)
  end

  def bgm_stop
    Audio.__mkxp_native_call(:@__mkxp_native_bgm_stop)
  end

  # BGS
  def bgs_play(filename, volume = 100, pitch = 100)
    Audio.__mkxp_native_call(:@__mkxp_native_bgs_play, filename, volume, pitch)
    FmodExHandle.new(:bgs)
  end

  def bgs_fade(ms)
    Audio.__mkxp_native_call(:@__mkxp_native_bgs_fade, ms)
  end

  def bgs_stop
    Audio.__mkxp_native_call(:@__mkxp_native_bgs_stop)
  end

  # ME (music effect - one-shot, plays over BGM)
  def me_play(filename, volume = 100, pitch = 100)
    Audio.__mkxp_native_call(:@__mkxp_native_me_play, filename, volume, pitch)
    FmodExHandle.new(:me)
  end

  def me_fade(ms)
    Audio.__mkxp_native_call(:@__mkxp_native_me_fade, ms)
  end

  def me_stop
    Audio.__mkxp_native_call(:@__mkxp_native_me_stop)
  end

  # SE
  def se_play(filename, volume = 100, pitch = 100)
    Audio.__mkxp_native_call(:@__mkxp_native_se_play, filename, volume, pitch)
    FmodExHandle.new(:se)
  end

  def se_stop
    Audio.__mkxp_native_call(:@__mkxp_native_se_stop)
  end
end

# --- Disposed RGSS object safety patches ---
# Pokemon Essentials scripts (e.g. Mouse Input, pokemonLoadPanel)
# access properties on disposed Sprites/Windows/Viewports between
# frames. Some custom classes report disposed?=false but their
# internal native C++ object is already freed, raising RGSSError.
#
# We wrap property accessors to return safe defaults instead of
# crashing. Two constraints:
#   - The alias is idempotent (only captures the original method
#     if no `_mkxp_orig_<meth>` already exists), guarding against
#     repeated invocations.
#   - The wrapper `define_method` runs after the engine's binding
#     init, which would otherwise overwrite our wrapper with the
#     native C method.
def _mkxp_install_disposed_safe_wrapper(klass, meth, default)
  return unless klass.method_defined?(meth)
  return unless klass.method_defined?(:disposed?)

  orig = :"_mkxp_orig_#{meth}"
  unless klass.method_defined?(orig) || klass.private_method_defined?(orig)
    klass.send(:alias_method, orig, meth)
  end
  # Keep a private alias of the native disposed?. The wrapper must
  # not call the public disposed?: game scripts redefine it, and
  # some route it back through a wrapped getter. VXAce_FP fix [01]
  # probes `self.visible` inside disposed?, so the public call
  # recurses without bound (found in BLACK SOULS II).
  unless klass.method_defined?(:_mkxp_orig_disposed?) ||
         klass.private_method_defined?(:_mkxp_orig_disposed?)
    klass.send(:alias_method, :_mkxp_orig_disposed?, :disposed?)
  end
  klass.send(:define_method, meth) do
    return default if _mkxp_orig_disposed?

    begin
      send(orig)
    rescue RGSSError
      default
    end
  end
end

# rubocop:disable Style/SymbolArray -- `%i` does not parse on Ruby 1.8.
disposed_safe_zero = [:x, :y, :z, :ox, :oy, :width, :height,
                      :opacity, :back_opacity, :contents_opacity]
disposed_safe_false = [:visible]
# rubocop:enable Style/SymbolArray

# Install the wrappers only for RGSS1 games. Pokemon Essentials is
# always XP-based, and the wrappers exist for Essentials scripts
# alone. Later engines must keep the stock raise-on-disposed
# semantics: VX Ace games probe those raises on purpose (VXAce_FP
# redefines disposed? to rescue the RGSSError from `visible`), and
# a getter that returns a default instead breaks that probe.
if System.rpg_version == 1
  [Sprite, Window, Viewport, Plane, Tilemap].each do |klass|
    disposed_safe_zero.each  { |m| _mkxp_install_disposed_safe_wrapper(klass, m, 0)     }
    disposed_safe_false.each { |m| _mkxp_install_disposed_safe_wrapper(klass, m, false) }
  end
end

# --- Null mouse shim ---
# Pokemon Essentials games set $mouse = Game_Mouse.new. The MkxpNullMouse
# class absorbs any method call, returning false/0/nil. Some PE forks
# poll $mouse before they instantiate Game_Mouse, so a non-nil default
# avoids NoMethodError on the very first frame.
class MkxpNullMouse
  # rubocop:disable Naming/PredicateMethod -- mocks Pokemon
  # Essentials' `Game_Mouse#method_missing` contract. The Ruby
  # method-missing protocol uses this exact name (no `?`).
  def method_missing(*_args)
    false
  end
  # rubocop:enable Naming/PredicateMethod

  def respond_to_missing?(*_args)
    true
  end

  def x
    0
  end

  def y
    0
  end
end

# --- Between-session reset hook ---
# The C side invokes each Proc in $__mkxp_reset_hooks right before
# a new game session's scripts run. Use this to scrub Pokemon-specific
# state that would otherwise bleed from the previous session.
#
# Default $mouse to a null shim so PE forks that poll the global
# before Game_Mouse.new runs don't NoMethodError on the first frame.
$mouse = MkxpNullMouse.new

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

# Pokemon Essentials' `pbResolveBitmap` relies on `pbTryString`, which probes a
# candidate path and returns the ORIGINAL string on success. On Windows that is
# fine because later opens are also case-insensitive. On iOS we need the real
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
                System.puts("[pokemon_compat] pbTryString casefold hit: #{x} -> #{resolved}")
              end
              resolved
            end
          else
            System.puts("[pokemon_compat] pbTryString normalized: #{x} -> #{resolved}") if defined?(System)
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
          return result if result.is_a?(Bitmap)

          x = args[0]
          resolved = MKXPCasefoldFS.resolve_bitmap(x)
          path = resolved || result
          return nil if path.nil?
          return nil if path.is_a?(String) && path.empty?

          if resolved
            if result.nil?
              if defined?(System)
                System.puts("[pokemon_compat] pbResolveBitmap casefold hit: #{x} -> #{resolved}")
              end
            elsif result != resolved
              if defined?(System)
                System.puts("[pokemon_compat] pbResolveBitmap normalized: #{x} -> #{resolved}")
              end
            end
          end
          path
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

  System.puts '[pokemon_compat] pbTryString casefold hook armed' if defined?(System)
  System.puts '[pokemon_compat] pbResolveBitmap casefold hook armed' if defined?(System)
end
