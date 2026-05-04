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
# `TypeError: superclass mismatch`); the catch leaves the game's
# own definition winning and our patch silently absent for that
# game (acceptable - it presumably handles screensize itself).
begin
  class PokemonSystem
    # `instance_methods` returns Strings on Ruby 1.8 but Symbols
    # on 1.9+, so `instance_methods.include?(:screensize)` is
    # never true on 1.8 even when the method exists. Use
    # `method_defined?` (Symbol-friendly on every version) for
    # the "is anything already defined" guard. We unconditionally
    # define both writer and reader-with-default; redefinition on
    # subsequent loads is idempotent (last-write-wins) and a
    # game's later `class PokemonSystem ... end` still overrides
    # cleanly via Ruby's open-class semantics.
    attr_accessor :screensize

    def screensize
      @screensize ||= 1.0
    end
  end
rescue TypeError
  # superclass mismatch with a fork's own definition; bow out.
end

# --- Uranium hard-reset prevention ---
# Pokemon Uranium checks $game_exists on startup and calls
# system('Uranium') + exit to relaunch itself. On iOS, system() is
# neutralized (see platform_compat.rb), but we also clear the flag so the
# hard-reset code path is never reached. The between-session reset hook
# at the bottom of this file handles subsequent sessions.
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
  # rebind them. Stored as module instance variables on Audio so
  # we can fetch them back even if the engine's
  # `resetBetweenSessions()` clears Ruby-side ivars - module
  # constants survive the reset.
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
  # snapshot is missing (engine didn't expose that method, or
  # session-reset cleared it), silently no-op so the game keeps
  # running rather than raising.
  def Audio.__mkxp_native_call(ivar, *args)
    m = instance_variable_get(ivar)
    m.call(*args) if m
  end
end

# Playback handle returned by `FmodEx.bgm_play` / etc. The actual
# native audio is fire-and-forget on the Audio module (no real
# handle), so this is mostly a duck-typed shell that satisfies the
# small set of methods game scripts call on the returned value.
# Position queries fall through to the matching native getter
# where one exists; loop-point setters are no-ops (most games
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

  def set_loop_points(*); end

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
  # to set up a software channel pool; we ignore it because the
  # underlying engine handles channel allocation itself.
  def init(*); end

  # BGM
  def bgm_play(filename, volume = 100, pitch = 100, position = 0)
    # Game scripts pass either a bare basename ("Audio/BGM/foo")
    # or a full path. mkxp-z's Audio.bgm_play accepts both. Our
    # 4-arg native form takes a position (microseconds) where
    # supported; fall back to 3-arg if the engine doesn't accept
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
#   - The alias must run only ONCE across all sessions. Re-aliasing on
#     session 2 would capture our own wrapper (from session 1) as the
#     "original", producing infinite recursion.
#   - The wrapper `define_method` must run EVERY session because
#     mriBindingInit re-registers the native C method on Sprite / Window
#     / etc. at the start of every session, overwriting our wrapper.
def _mkxp_install_disposed_safe_wrapper(klass, meth, default)
  return unless klass.method_defined?(meth)

  orig = :"_mkxp_orig_#{meth}"
  unless klass.method_defined?(orig) || klass.private_method_defined?(orig)
    klass.send(:alias_method, orig, meth)
  end
  klass.send(:define_method, meth) do
    return default if disposed?

    begin
      send(orig)
    rescue RGSSError
      default
    end
  end
end

disposed_safe_zero = %i[x y z ox oy width height
                        opacity back_opacity contents_opacity]
disposed_safe_false = [:visible]

[Sprite, Window, Viewport, Plane, Tilemap].each do |klass|
  disposed_safe_zero.each  { |m| _mkxp_install_disposed_safe_wrapper(klass, m, 0)     }
  disposed_safe_false.each { |m| _mkxp_install_disposed_safe_wrapper(klass, m, false) }
end

# --- Null mouse shim ---
# Pokemon Essentials games set $mouse = Game_Mouse.new. Between
# sessions, constant cleanup removes Game_Mouse but $mouse still
# holds an orphaned instance. MkxpNullMouse absorbs any method call,
# returning false/0/nil, and is installed on $mouse by the reset hook
# below.
class MkxpNullMouse
  # rubocop:disable Naming/PredicateMethod -- mocks Pokemon
  # Essentials' `Game_Mouse#method_missing` contract; the Ruby
  # method-missing protocol uses this exact name (no `?`).
  def method_missing(*)
    false
  end
  # rubocop:enable Naming/PredicateMethod

  def respond_to_missing?(*)
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
# Preload-defined infrastructure constants kept across between-session
# resets. Rationale documented in `platform_compat.rb`: without this
# the engine's reset step 1 removes them, and any reset-time code
# path that touches them (a hook lambda, a closure) walks into the
# `Module#const_missing` recursion described there. Per-session
# state inside FmodEx (or its handle) is reset through other means
# - here we just keep the namespace alive.
$__mkxp_preload_keep_consts ||= []
%i[MkxpNullMouse FmodEx FmodExHandle].each do |c|
  $__mkxp_preload_keep_consts << c unless $__mkxp_preload_keep_consts.include?(c)
end

$__mkxp_reset_hooks ||= []
unless $__mkxp_reset_hooks.any? { |h| h.respond_to?(:source_location) && h.source_location[0] == __FILE__ }
  $__mkxp_reset_hooks << lambda do
    # Pokemon Essentials / Pokemon fangames globals.
    #
    # Each `$Pokemon*` global commonly holds an instance whose
    # class is defined in the previous game's scripts (PokemonTemp,
    # PokemonSystem, ...). The engine's `resetBetweenSessions`
    # step 1 removes those classes from `Object` but leaves the
    # globals alone, so the next game sees a "ghost" object whose
    # class no longer exists - calls to methods the next game's
    # script expects then `NoMethodError` even when the Ruby method
    # name is sensible (concrete failure: Pokemon Z -> Vinemon
    # crashes on `$PokemonTemp.defaultBGM` because Pokemon Z's
    # `PokemonTemp` is gone but the global still points at the
    # PZ instance, which never had `defaultBGM`).
    #
    # The set below covers the globals seen in Pokemon Essentials
    # forks. Add new entries as we hit them; the cost of nil-ing
    # an undefined global is zero.
    $mouse = MkxpNullMouse.new
    $game_exists = nil # Uranium hard-reset flag
    $PokemonSystem = nil
    $PokemonTemp = nil
    $PokemonGlobal = nil
    $PokemonBag = nil
    $PokemonStorage = nil
    $Trainer = nil
  end
end
