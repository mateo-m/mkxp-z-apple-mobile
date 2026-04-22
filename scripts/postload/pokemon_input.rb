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
  # Force the top-level constant off regardless of whatever the
  # game's scripts set it to - see header comment. Must use the
  # Object.const_set dance (rather than `USEKEYBOARDTEXTENTRY = false`)
  # because a plain assignment at this scope raises "already
  # initialized constant" warnings when the game has already defined
  # it, and we want the silent override.
  if Object.const_defined?(:USEKEYBOARDTEXTENTRY, false)
    Object.send(:remove_const, :USEKEYBOARDTEXTENTRY)
  end
  Object.const_set(:USEKEYBOARDTEXTENTRY, false)

  if defined?(PokemonEntryScene)
    class PokemonEntryScene
      remove_const(:USEKEYBOARD) if const_defined?(:USEKEYBOARD, false)
      USEKEYBOARD = false
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
