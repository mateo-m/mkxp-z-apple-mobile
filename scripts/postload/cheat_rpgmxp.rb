# Cheat menu for RPG Maker XP (RGSS1) generic projects.
#
# Ported from the non-Pokemon branch of JoiPlay's cheat_rpgmxp.rb.
# Loaded by cheat_dispatch.rb when the RGSS version is 1 and the
# project is not a Pokemon Essentials game. Menu is triggered
# in-game by pressing Input::HOME while $CHEATS is true.
#
# Features: level up actor[0] (x1, x5, x10, x100), gain gold,
# add items/weapons/armors via a custom Window_GetItem.

MKXP.puts("[cheats] loading RPG Maker XP cheat menu")

if defined?(Window_Selectable).nil? && defined?(Window_DrawableCommand)
  class Window_Selectable < Window_DrawableCommand
  end
end

class Window_GetItem < Window_Selectable
  def initialize
    super(0, 128, 368, 352)
    @shop_goods = []
    @shop_goods += $data_items   if defined?($data_items)   && $data_items
    @shop_goods += $data_weapons if defined?($data_weapons) && $data_weapons
    @shop_goods += $data_armors  if defined?($data_armors)  && $data_armors
    refresh
    self.index = 0
  end

  def item
    return @data[self.index]
  end

  def refresh
    if self.contents != nil
      self.contents.dispose
      self.contents = nil
    end
    @data = []
    for item in @shop_goods
      @data.push(item) if item != nil && item.name != ""
    end
    @item_max = @data.size
    if @item_max > 0
      self.contents = Bitmap.new(width - 32, row_max * 32)
      for i in 0...@item_max
        draw_item(i)
      end
    end
  end

  def draw_item(index)
    item = @data[index]
    number = case item
             when RPG::Item   then $game_party.item_number(item.id)
             when RPG::Weapon then $game_party.weapon_number(item.id)
             when RPG::Armor  then $game_party.armor_number(item.id)
             else 0
             end
    self.contents.font.color = number < 99 ? normal_color : disabled_color
    x = 4
    y = index * 32
    rect = Rect.new(x, y, self.width - 32, 32)
    self.contents.fill_rect(rect, Color.new(0, 0, 0, 0))
    begin
      bitmap = RPG::Cache.icon(item.icon_name)
      opacity = self.contents.font.color == normal_color ? 255 : 128
      self.contents.blt(x, y + 4, bitmap, Rect.new(0, 0, 24, 24), opacity)
    rescue
    end
    self.contents.draw_text(x + 28, y, 212, 32, item.name, 0)
    self.contents.draw_text(x + 240, y, 88, 32, item.price.to_s, 2)
  end
end

class Scene_Cheat
  def main
    @cheat_window = Window_Command.new(160, ["Level Up", "Gain Gold", "Get Items", "Cancel"])
    @cheat_window.active = true
    @cheat_window.visible = true

    @level_window = Window_Command.new(160, ["1 Level", "5 Level", "10 Level", "100 Level", "Cancel"])
    @level_window.active = false
    @level_window.visible = false

    @gold_window = Window_Command.new(160, ["100 G", "1K G", "10K G", "100K G", "1M G", "Cancel"])
    @gold_window.active = false
    @gold_window.visible = false

    @item_window = Window_GetItem.new
    @item_window.active = false
    @item_window.visible = false

    @number_window = Window_ShopNumber.new
    @number_window.active = false
    @number_window.visible = false

    Graphics.transition
    loop do
      Graphics.update
      Input.update
      update
      break if $scene != self
    end
    Graphics.freeze
    @cheat_window.dispose
    @level_window.dispose
    @gold_window.dispose
    @item_window.dispose
    @number_window.dispose
  end

  def update
    @cheat_window.update
    @level_window.update
    @gold_window.update
    @item_window.update
    @number_window.update
    return update_cheat  if @cheat_window.active
    return update_level  if @level_window.active
    return update_gold   if @gold_window.active
    return update_item   if @item_window.active
    return update_number if @number_window.active
  end

  def update_cheat
    if Input.trigger?(Input::B)
      $scene = Scene_Map.new
      return
    end
    if Input.trigger?(Input::C)
      case @cheat_window.index
      when 0
        @cheat_window.active = false
        @cheat_window.visible = false
        @level_window.active = true
        @level_window.visible = true
        @level_window.refresh
      when 1
        @cheat_window.active = false
        @cheat_window.visible = false
        @gold_window.active = true
        @gold_window.visible = true
        @gold_window.refresh
      when 2
        @cheat_window.active = false
        @cheat_window.visible = false
        @item_window.active = true
        @item_window.visible = true
        @item_window.refresh
      when 3
        $scene = Scene_Map.new
      end
    end
  end

  def update_level
    if Input.trigger?(Input::B)
      $scene = Scene_Map.new
      return
    end
    if Input.trigger?(Input::C)
      case @level_window.index
      when 0 then cheat_level_up1
      when 1 then cheat_level_up5
      when 2 then cheat_level_up10
      when 3 then cheat_level_up100
      end
      $scene = Scene_Map.new
    end
  end

  def update_gold
    if Input.trigger?(Input::B)
      $scene = Scene_Map.new
      return
    end
    if Input.trigger?(Input::C)
      case @gold_window.index
      when 0 then cheat_add_gold(100)
      when 1 then cheat_add_gold(1_000)
      when 2 then cheat_add_gold(10_000)
      when 3 then cheat_add_gold(100_000)
      when 4 then cheat_add_gold(1_000_000)
      end
      $scene = Scene_Map.new
    end
  end

  def update_item
    if Input.trigger?(Input::B)
      $scene = Scene_Map.new
      return
    end
    if Input.trigger?(Input::C)
      @item = @item_window.item
      return if @item.nil?
      number = case @item
               when RPG::Item   then $game_party.item_number(@item.id)
               when RPG::Weapon then $game_party.weapon_number(@item.id)
               when RPG::Armor  then $game_party.armor_number(@item.id)
               else 0
               end
      return if number == 99
      max = [99, 99 - number].min
      @item_window.active = false
      @item_window.visible = false
      @number_window.set(@item, max, @item.price)
      @number_window.active = true
      @number_window.visible = true
    end
  end

  def update_number
    if Input.trigger?(Input::B)
      @number_window.active = false
      @number_window.visible = false
      @item_window.active = true
      @item_window.visible = true
      return
    end
    if Input.trigger?(Input::C)
      @number_window.active = false
      @number_window.visible = false
      case @item
      when RPG::Item   then $game_party.gain_item(@item.id, @number_window.number)
      when RPG::Weapon then $game_party.gain_weapon(@item.id, @number_window.number)
      when RPG::Armor  then $game_party.gain_armor(@item.id, @number_window.number)
      end
      @item_window.refresh
      @item_window.active = true
      @item_window.visible = true
    end
  end

  def cheat_level_up
    $game_party.actors[0].level = $game_party.actors[0].level + 1 if $game_party && $game_party.actors && $game_party.actors[0]
  end

  def cheat_level_up1;    cheat_level_up;                  end
  def cheat_level_up5;    5.times   { cheat_level_up }; end
  def cheat_level_up10;   10.times  { cheat_level_up }; end
  def cheat_level_up100;  100.times { cheat_level_up }; end

  def cheat_add_gold(amount)
    cap = 9_999_999
    if ($game_party.gold + amount) >= cap
      $game_party.gain_gold(cap - $game_party.gold)
    else
      $game_party.gain_gold(amount)
    end
  end
end

class Game_Player
  alias :cheat_update :update unless self.method_defined?(:cheat_update)
  def update
    cheat_update
    if Input.trigger?(Input::HOME) && $CHEATS
      $scene = Scene_Cheat.new
    end
  end
end

MKXP.puts("[cheats] RPG Maker XP cheat menu ready")
