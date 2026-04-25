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
#      `PokemonEntryScene2` (the game's in-game keyboard scene).
#      Uranium and other fan games re-assign it from their
#      Settings script after our preload runs, so the override has
#      to land in postload to win.
#   2. `PokemonEntryScene::USEKEYBOARD` forced off as a belt-and-braces
#      safety net for fan games that dispatch on the class-scoped
#      constant instead of the top-level one.
#   3. Input methods redirected to j-prefixed native implementations
#      so games overriding `Input` with Win32API polling still see
#      touch / gamepad events.

if !$PokemonSystem.nil?
  # Persist a "this is PE" marker in the host-managed state dir.
  # The host-side static detector (GameSettings.detectPokemonEssentials)
  # can't see PE signatures inside rgssad-protected archives, so
  # without this, GameSettings UI would default the In-game keyboard
  # toggle OFF on every launch even though the game IS PE. The
  # marker tips off the next launch's UI so the toggle defaults ON.
  begin
    if defined?(MKXP) && MKXP.respond_to?(:managed_config_dir)
      managed = MKXP.managed_config_dir.to_s
      if !managed.empty?
        marker = "#{managed}/.pokemon_essentials_detected"
        File.write(marker, "") unless File.exist?(marker)
      end
    end
  rescue => e
    MKXP.puts("[pokemon_input] failed to write PE marker: #{e}") rescue nil
  end


  # Backspace shim for Pokemon Essentials' keyboard text-entry
  # scene. Older PE versions (Uranium / Insurgence era - PE 16-18)
  # implement `Window_TextEntry_Keyboard.update` around
  # `Win32API.GetKeyboardState` polling tuned for hold-to-repeat
  # hardware keyboards, and never call `self.delete` or
  # `@helper.delete` on a single tap. With our iOS soft-keyboard
  # bridge each backspace is a single 50ms scancode injection -
  # `Input.triggerex?(:BACKSPACE)` correctly reports true on the
  # right frame but PE's update flow doesn't act on it, so the
  # name field never shrinks. PE 21 wired the trigger path
  # directly; this preempt covers the older versions and is
  # redundant-but-safe on PE 21.
  if defined?(Window_TextEntry_Keyboard)
    class Window_TextEntry_Keyboard
      unless method_defined?(:_mkxp_pre_backspace_orig_update)
        alias_method :_mkxp_pre_backspace_orig_update, :update
        def update
          if @helper && @helper.cursor > 0 &&
             (Input.triggerex?(:BACKSPACE) rescue false)
            # Delegate to the parent class's `delete` (defined on
            # Window_TextEntry) which trims the helper's text and
            # refreshes the rendered window. Skip the rest of
            # PE's update for this frame so the GetKeyboardState
            # poll doesn't immediately re-process the same key.
            self.delete
            return
          end
          _mkxp_pre_backspace_orig_update
        end
      end
    end
  end

  # The default soft-keyboard path (Input.text_input -> UIKit
  # UITextField -> mkxp_pushTextInput) works for IF / Reborn /
  # Insurgence name entry, so this postload doesn't force the
  # in-game keyboard scene by default. A per-game GameSettings
  # toggle ("In-game keyboard") routes through the
  # `MKXP.use_in_game_keyboard?` bridge for games whose keyboard
  # scene needs custom keys / layout - only those games get the
  # historical force-disable, leaving the majority on the polished
  # soft-keyboard path.
  #
  # NOTE: this check happens once at postload time, so flipping
  # the GameSettings toggle requires a game relaunch to take
  # effect. The bridge value is set by AppState.selectGame BEFORE
  # the engine starts running scripts, so once postload finishes
  # `USEKEYBOARDTEXTENTRY` is locked for the session.
  use_in_game = (defined?(MKXP) && MKXP.respond_to?(:use_in_game_keyboard?) &&
                 MKXP.use_in_game_keyboard?)
  if use_in_game
    # PE v18 and earlier: top-level constant. PE v19+ moved most
    # settings into a `Settings` module so the original constant
    # name is `Settings::USEKEYBOARDTEXTENTRY`. Fan games sometimes
    # also define a class-scoped `PokemonEntryScene::USEKEYBOARD`
    # that takes precedence over the top-level name. Belt-and-
    # braces all three: the right one for the game wins, the
    # others are no-ops.
    [
      [Object,           :USEKEYBOARDTEXTENTRY],
      [Object.const_defined?(:Settings) ? Settings : nil, :USEKEYBOARDTEXTENTRY],
      [defined?(PokemonEntryScene) ? PokemonEntryScene : nil, :USEKEYBOARD],
    ].each do |scope, name|
      next unless scope
      scope.send(:remove_const, name) if scope.const_defined?(name, false)
      scope.const_set(name, false)
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
