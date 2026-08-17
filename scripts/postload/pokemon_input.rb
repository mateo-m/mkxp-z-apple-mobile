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

unless $PokemonSystem.nil?
  # Persist a "this is PE" marker in the host-managed state dir.
  # The host-side static detector (GameSettings.detectPokemonEssentials)
  # can't see PE signatures inside rgssad-protected archives, so
  # without this, GameSettings UI would default the In-game keyboard
  # toggle OFF on every launch even though the game IS PE. The
  # marker tips off the next launch's UI so the toggle defaults ON.
  begin
    if defined?(MKXP) && MKXP.respond_to?(:managed_config_dir)
      managed = MKXP.managed_config_dir.to_s
      unless managed.empty?
        marker = "#{managed}/.pokemon_essentials_detected"
        File.write(marker, '') unless File.exist?(marker)
      end
    end
  rescue StandardError => e
    begin
      MKXP.puts("[pokemon_input] failed to write PE marker: #{e}")
    rescue StandardError
      nil
    end
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
  # directly. This preempt covers the older versions and is
  # redundant-but-safe on PE 21.
  if defined?(Window_TextEntry_Keyboard)
    class Window_TextEntry_Keyboard
      unless method_defined?(:_mkxp_pre_backspace_orig_update)
        alias _mkxp_pre_backspace_orig_update update
        def update
          if @helper && @helper.cursor > 0 &&
             begin
               Input.triggerex?(:BACKSPACE)
             rescue StandardError
               false
             end
            # Delegate to the parent class's `delete` (defined on
            # Window_TextEntry) which trims the helper's text and
            # refreshes the rendered window. Skip the rest of
            # PE's update for this frame so the GetKeyboardState
            # poll doesn't immediately re-process the same key.
            delete
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
  use_in_game = defined?(MKXP) && MKXP.respond_to?(:use_in_game_keyboard?) &&
                MKXP.use_in_game_keyboard?
  if use_in_game
    # PE v18 and earlier: top-level constant. PE v19+ moved most
    # settings into a `Settings` module so the original constant
    # name is `Settings::USEKEYBOARDTEXTENTRY`. Fan games sometimes
    # also define a class-scoped `PokemonEntryScene::USEKEYBOARD`
    # that takes precedence over the top-level name. Belt-and-
    # braces all three: the right one for the game wins, the
    # others are no-ops.
    [
      [Object, :USEKEYBOARDTEXTENTRY],
      [Object.const_defined?(:Settings) ? Settings : nil, :USEKEYBOARDTEXTENTRY],
      [defined?(PokemonEntryScene) ? PokemonEntryScene : nil, :USEKEYBOARD]
    ].each do |scope, name|
      next unless scope

      # `const_defined?(name, false)` 2-arg form (skip-inheritance)
      # is Ruby 1.9+. On 1.8 the 1-arg form already only checks
      # the receiver's own constant table, so we just always pass
      # the inherit flag on 1.9+ and omit it on 1.8.
      already = if RUBY_VERSION >= '1.9'
                  scope.const_defined?(name, false)
                else
                  scope.const_defined?(name)
                end
      scope.send(:remove_const, name) if already
      scope.const_set(name, false)
    end
  end

  module Input
    # Newer Pokemon Essentials fangames add button codes of their own.
    # Pokemon Empyrean defines ESC = 35, MENU = 36 and
    # KEY_ITEM_1..5 = 37..41. The engine knows the RGSS codes only, so
    # `jtrigger?` answers false for every extended code and the button
    # is dead. In Empyrean that left no way to open the pause menu.
    #
    # The same games ship `Input.buttonToKey`, which gives the Win32
    # virtual-key codes a button listens on. `jtriggerex?` accepts a
    # virtual-key code, so route extended buttons through that table.
    #
    # Standard RGSS codes stay on the native path. It reads the
    # player's key bindings and also covers the on-screen controls and
    # gamepads, which raw key state alone would miss.
    MKXP_RGSS_BUTTON_CODES = [2, 4, 6, 8,
                              11, 12, 13, 14, 15, 16, 17, 18,
                              21, 22, 23,
                              25, 26, 27, 28, 29].freeze

    def self.mkxp_extended_vkeys(button)
      return nil if MKXP_RGSS_BUTTON_CODES.include?(button)
      return nil unless respond_to?(:buttonToKey)

      vkeys = begin
        buttonToKey(button)
      rescue StandardError
        nil
      end
      return nil unless vkeys.is_a?(Array) && !vkeys.empty?

      vkeys
    end

    # Pokemon Essentials calls `Input.update` from hundreds of places,
    # some of them in the middle of a frame. Pokemon Empyrean's
    # `Game_Player#update` calls it, then reads `Input.trigger?` about
    # ninety lines further down the same method.
    #
    # The engine advances the trigger edge on every `Input.update`, so
    # that second call throws the press away before anything reads it.
    # On Windows the games get away with this: their Input module polls
    # GetAsyncKeyState and advances a key only when that key is READ,
    # so extra updates cost nothing.
    #
    # On iOS the result looked like broken input. The pause menu never
    # opened, and talking to an NPC or reading a sign worked only when
    # a keypress happened to land between the mid-frame update and the
    # read.
    #
    # So track the trigger edge here under the same read-driven rule:
    # a button advances on its first read after each `Input.update`,
    # and repeat reads in between give the same answer. `press?` needs
    # no such care, because a pressed state has no edge to lose.
    def self.mkxp_button_down?(button)
      vkeys = mkxp_extended_vkeys(button)
      return vkeys.any? { |vkey| jpressex?(vkey) } if vkeys

      jpress?(button)
    end

    def self.update
      @mkxp_read = nil
      @mkxp_release_read = nil
      jupdate
    end

    def self.press?(button)
      mkxp_button_down?(button)
    end

    def self.trigger?(button)
      @mkxp_read ||= {}
      return @mkxp_read[button] if @mkxp_read.key?(button)

      @mkxp_counts ||= {}
      held = @mkxp_counts[button] || 0
      down = mkxp_button_down?(button)
      @mkxp_counts[button] = down ? held + 1 : 0
      @mkxp_read[button] = down && held.zero?
    end

    def self.repeat?(button)
      vkeys = mkxp_extended_vkeys(button)
      return vkeys.any? { |vkey| jrepeatex?(vkey) } if vkeys

      jrepeat?(button)
    end

    def self.dir4
      jdir4
    end

    def self.dir8
      jdir8
    end

    def self.pressex?(key)
      jpressex?(key)
    end

    def self.triggerex?(key)
      jtriggerex?(key)
    end

    def self.repeatex?(key)
      jrepeatex?(key)
    end

    # The engine has a native `releaseex?`, but the game's own Input
    # module replaces it before this postload runs, and the binding
    # gives no j-prefixed alias to fall back on. So derive the release
    # edge from the native pressed state.
    #
    # The rule is the read-driven one that `trigger?` uses above: a key
    # advances on its first read after each `Input.update`, and repeat
    # reads in the same frame give the same answer. A key that nothing
    # reads keeps its last sampled state, which is what the Win32
    # `GetAsyncKeyState` polling these games expect also does.
    #
    # Pokemon Essentials mouse scenes gate their actions on this. In
    # Pokemon Insurgence the DexNav highlights a button on touch, which
    # uses `pressex?`, but runs the action on `releaseex?`. With
    # `releaseex?` always false the scene drew and highlighted but no
    # button did anything, and the player could only leave it with the
    # cancel button.
    def self.releaseex?(key)
      @mkxp_release_read ||= {}
      return @mkxp_release_read[key] if @mkxp_release_read.key?(key)

      @mkxp_ex_held ||= {}
      held = @mkxp_ex_held[key] ? true : false
      down = jpressex?(key)
      @mkxp_ex_held[key] = down
      @mkxp_release_read[key] = held && !down
    end

    def self.repeatcount(_key)
      0
    end

    def self.updateKeyState(key); end
  end
end
