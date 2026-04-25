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
  # Note: previously this postload force-disabled the Pokemon
  # Essentials text-entry "use keyboard" path by setting
  # `USEKEYBOARDTEXTENTRY = false` and
  # `PokemonEntryScene::USEKEYBOARD = false`, on the grounds that
  # iOS had no soft-keyboard bridge so the keyboard scene would
  # accept no input and stall the game. With the
  # `Input.text_input = true` -> SDL_StartTextInput -> UIKit
  # UITextField -> `mkxp_pushTextInput` bridge wired up
  # (app_bridge.cpp + KeyboardFieldRepresentable.swift), the soft
  # keyboard now appears automatically and types characters into
  # the in-game field via `Input.gets`. The default PE keyboard
  # path therefore works correctly on iOS - we no longer need to
  # force the on-screen ABC grid as a workaround.
  #
  # If a specific game's keyboard layout proves unworkable on iOS
  # (e.g. requires keys not present on the iOS soft keyboard), we
  # can re-add a per-game gate via mkxp.json or AppSettings rather
  # than a global override.

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
