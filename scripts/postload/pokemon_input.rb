# Pokemon Essentials compatibility fixes.
# Adapted from JoiPlay's pokefix.rb / pokeinput.rb
# (https://github.com/joiplay/android-mkxp/blob/master/app/src/main/assets/).
#
# Pokemon Essentials games ship with a desktop-keyboard name-entry
# scene and an Input module override that polls Win32API. Both
# break on iOS. This postload runs after the game's scripts have
# loaded (so `$PokemonSystem` exists) and before Main starts, and
# applies:
#
#   1. Top-level `USEKEYBOARDTEXTENTRY` forced to false. Stock
#      Essentials `pbEnterText` branches on this constant to pick
#      between `PokemonEntryScene` (desktop keyboard) and
#      `PokemonEntryScene2` (on-screen ABC grid). Uranium and other
#      fan games re-assign it from their Settings script after our
#      preload runs, so the override has to land in postload to win.
#   2. `PokemonEntryScene::USEKEYBOARD` forced off as a belt-and-braces
#      safety net for fan games that dispatch on the class-scoped
#      constant instead of the top-level one.
#   3. Input methods redirected to j-prefixed native implementations
#      so games overriding `Input` with Win32API polling still see
#      touch / gamepad events.

if !$PokemonSystem.nil?
  # The default soft-keyboard path (Input.text_input -> UIKit
  # UITextField -> mkxp_pushTextInput) works for IF / Reborn /
  # Insurgence name entry, so this postload doesn't force the
  # on-screen ABC grid by default. A per-game GameSettings toggle
  # ("Use on-screen keyboard") routes through the
  # `MKXP.use_on_screen_keyboard?` bridge for games whose keyboard
  # scene needs the original ABC grid (custom keys, layout, etc.) -
  # only those games get the historical force-disable, leaving the
  # majority on the polished soft-keyboard path.
  if defined?(MKXP) && MKXP.respond_to?(:use_on_screen_keyboard?) &&
     MKXP.use_on_screen_keyboard?
    # USEKEYBOARDTEXTENTRY lives at the top level in stock
    # Essentials. Some fan games re-assign it from their own
    # Settings script after our preload runs, so the override has
    # to land in postload to win the last-write race. Wrap the
    # constant assignment in `silence_warnings`-equivalent so we
    # don't spam "already initialized constant" on every launch.
    Object.send(:remove_const, :USEKEYBOARDTEXTENTRY) if defined?(USEKEYBOARDTEXTENTRY)
    USEKEYBOARDTEXTENTRY = false
    # Belt-and-braces for fan games dispatching on the class-scoped
    # constant instead of the top-level one.
    if defined?(PokemonEntryScene)
      PokemonEntryScene.send(:remove_const, :USEKEYBOARD) if PokemonEntryScene.const_defined?(:USEKEYBOARD)
      PokemonEntryScene.const_set(:USEKEYBOARD, false)
    end
  end

  module Input
    def self.update
      self.jupdate
    end

    def self.press?(button)
      return self.jpress?(button)
    end

    def self.trigger?(button)
      return self.jtrigger?(button)
    end

    def self.repeat?(button)
      return self.jrepeat?(button)
    end

    def self.dir4
      return self.jdir4
    end

    def self.dir8
      return self.jdir8
    end

    def self.pressex?(key)
      return self.jpressex?(key)
    end

    def self.triggerex?(key)
      return self.jtriggerex?(key)
    end

    def self.repeatex?(key)
      return self.jrepeatex?(key)
    end

    def self.repeatcount(key)
      return 0
    end

    def self.updateKeyState(key)
    end
  end
end
