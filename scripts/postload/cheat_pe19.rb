# Cheat menu for Pokemon Essentials (v17+ and v19+).
#
# Ported from JoiPlay's cheat_pe19.rb. Loaded by cheat_dispatch.rb
# when the game is detected as Pokemon Essentials (PBItems or
# GameData::Item constant is defined). The menu is triggered
# in-game by pressing Input::HOME while $CHEATS is true.
#
# Features: heal party, get items (reuses PokemonMart screen with a
# zero-price adapter), walk-through-walls toggle ($wtw).
#
# Design notes: we keep the original class / method names so that
# games defining their own Window_CommandPokemon / PokemonMartScreen
# variants plug in unchanged. The engine-injected HOME keypress
# from the iOS toolbar flows through the same Input.trigger?(HOME)
# gate the JoiPlay build uses.

if Object.const_defined?("GameData") || Object.const_defined?("PBItems")
  MKXP.puts("[cheats] loading Pokemon Essentials cheat menu")

  def getPEVersion
    return "19" unless Object.const_defined?("Essentials")
    return Essentials::VERSION
  end

  ENABLE_GET_ITEM = Object.const_defined?("PokemonMartScreen")

  if ENABLE_GET_ITEM
    class CheatItemsAdapter < PokemonMartAdapter
      def getPrice(item, selling = false)
        return 0
      end
    end

    if Object.const_defined?("PokemonMart_Scene")
      class SceneCheat_Items < PokemonMart_Scene
      end
    elsif Object.const_defined?("PokemonMartScene")
      class SceneCheat_Items < PokemonMartScene
      end
    end

    class ScreenCheat_Items < PokemonMartScreen
      def initialize(scene, stock)
        @scene = scene
        @stock = stock
        @adapter = CheatItemsAdapter.new
      end
    end
  end

  class Scene_Cheat
    def main
      @wtwString = $wtw ? "Disable WTW" : "Enable WTW"
      @cviewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @cviewport.z = 99999
      @cheat_window = Window_CommandPokemon.new(
        ["Get Items", "Heal Party", @wtwString, "Cancel"], 160)
      @cheat_window.active = true
      @cheat_window.visible = true
      @cheat_window.viewport = @cviewport

      @partyArray = []
      $Trainer.party.each { |pokemon| @partyArray.push(pokemon.name) } if $Trainer && $Trainer.party
      @partyArray.push("Cancel")
      Graphics.transition
      loop do
        Graphics.update
        Input.update
        pbUpdateSceneMap
        break if update == -1
      end
      @cheat_window.dispose
      @cviewport.dispose
    end

    def update
      @cheat_window.update
      return update_cheat if @cheat_window.active
    end

    def update_cheat
      return -1 if Input.trigger?(Input::B)
      if Input.trigger?(Input::C)
        case @cheat_window.index
        when 0
          if ENABLE_GET_ITEM
            @cheat_window.active = false
            @cheat_window.visible = false
            scene = SceneCheat_Items.new
            array = []
            if Object.const_defined?("GameData")
              GameData::Item.each do |i|
                array.push(i) unless i.name.empty?
              end
            else
              (0..PBItems.maxValue).each do |i|
                array.push(i) unless PBItems.getName(i).empty?
              end
            end
            screen = ScreenCheat_Items.new(scene, array)
            screen.pbBuyScreen
            pbScrollMap(-6, -5, -5)
          end
          return -1
        when 1
          $Trainer.party.each { |pokemon| pokemon.heal } if $Trainer && $Trainer.party
          @cheat_window.active = false
          @cheat_window.visible = false
          return -1
        when 2
          $wtw = !$wtw
          return -1
        when 3
          return -1
        end
        return
      end
    end

    def return_scene
      @cviewport.dispose
    end

    def cheat_cancel
      @cheat_window.close
    end
  end

  class Scene_Map
    alias cheatUpdateMaps updateMaps unless self.method_defined?(:cheatUpdateMaps)
    def updateMaps
      if Input.trigger?(Input::HOME) && $CHEATS
        $game_temp.menu_calling = false if $game_temp
        $game_temp.in_menu = true if $game_temp
        $game_player.straighten if $game_player
        $game_map.update if $game_map
        Scene_Cheat.new.main
        $game_temp.in_menu = false if $game_temp
      end
      cheatUpdateMaps
    end
  end

  class Game_Player
    alias cheatPassable? passable? unless self.method_defined?(:cheatPassable?)
    def passable?(x, y, d, strict = false)
      if $wtw
        new_x = x + (d == 6 ? 1 : d == 4 ? -1 : 0)
        new_y = y + (d == 2 ? 1 : d == 8 ? -1 : 0)
        return $game_map.valid?(new_x, new_y)
      else
        begin
          cheatPassable?(x, y, d, strict)
        rescue
          cheatPassable?(x, y, d)
        end
      end
    end
  end

  MKXP.puts("[cheats] Pokemon Essentials cheat menu ready")
end
