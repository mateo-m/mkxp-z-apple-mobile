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

# --- Uranium hard-reset prevention ---
# Pokemon Uranium checks $game_exists on startup and calls
# system('Uranium') + exit to relaunch itself. On iOS, system() is
# neutralized (see platform_compat.rb), but we also clear the flag so the
# hard-reset code path is never reached. The between-session reset hook
# at the bottom of this file handles subsequent sessions.
$game_exists = nil

# --- Uranium FmodEx override suppression ---
# Pokemon Uranium's "F-mod main script" redefines Audio.bgm_play /
# Audio.bgs_play / Audio.me_play to route through ::FmodEx, which on iOS
# resolves to IOS::NullStub and drops audio on the floor. The override
# block is guarded by `unless @bgm_play` on the Audio module - it only
# runs the first time the script is evaluated, so pre-setting @bgm_play
# to a truthy value defeats it.
#
# Force @bgm_play to true every preload (not just when undefined). The
# engine's resetBetweenSessions() nilifies all ivars on engine-owned
# modules between sessions, including @bgm_play. An `instance_variable_defined?`
# guard would see the ivar still exists (nil counts as defined in Ruby)
# and skip the set, leaving Uranium's `unless @bgm_play` to fire again
# on session 2+ and drop audio on the floor.
if defined?(Audio) && Audio.is_a?(Module)
  Audio.instance_variable_set(:@bgm_play, true)
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

_disposed_safe_zero = [:x, :y, :z, :ox, :oy, :width, :height,
                        :opacity, :back_opacity, :contents_opacity]
_disposed_safe_false = [:visible]

[Sprite, Window, Viewport, Plane, Tilemap].each do |klass|
  _disposed_safe_zero.each  { |m| _mkxp_install_disposed_safe_wrapper(klass, m, 0)     }
  _disposed_safe_false.each { |m| _mkxp_install_disposed_safe_wrapper(klass, m, false) }
end

# --- Null mouse shim ---
# Pokemon Essentials games set $mouse = Game_Mouse.new. Between
# sessions, constant cleanup removes Game_Mouse but $mouse still
# holds an orphaned instance. MkxpNullMouse absorbs any method call,
# returning false/0/nil, and is installed on $mouse by the reset hook
# below.
class MkxpNullMouse
  def method_missing(*) false end
  def respond_to_missing?(*) true end
  def x; 0 end
  def y; 0 end
end

# --- Between-session reset hook ---
# The C side invokes each Proc in $__mkxp_reset_hooks right before
# a new game session's scripts run. Use this to scrub Pokemon-specific
# state that would otherwise bleed from the previous session.
#
# MkxpNullMouse is added to $__mkxp_preload_keep_consts so the engine's
# constant scrubber doesn't remove it (it's not in the session-1
# baseline because it was defined after the baseline snapshot).
$__mkxp_preload_keep_consts ||= []
$__mkxp_preload_keep_consts << :MkxpNullMouse unless $__mkxp_preload_keep_consts.include?(:MkxpNullMouse)

$__mkxp_reset_hooks ||= []
unless $__mkxp_reset_hooks.any? { |h| h.respond_to?(:source_location) && h.source_location[0] == __FILE__ }
  $__mkxp_reset_hooks << lambda do
    # Pokemon Essentials / Pokemon fangames globals.
    $mouse = MkxpNullMouse.new
    $game_exists = nil      # Uranium hard-reset flag
    $PokemonSystem = nil
    $PokemonGlobal = nil
    $Trainer = nil
  end
end
