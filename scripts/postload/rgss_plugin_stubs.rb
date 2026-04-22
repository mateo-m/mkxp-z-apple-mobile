# Stubs / neutralizers for common third-party RGSS plugin scripts.
#
# Many RPG Maker games ship community plugins that write PNG save
# previews to disk, probe Win32 window metrics, or shell out to
# native DLLs. On iOS those calls either fail silently (sandbox
# write) or crash (missing DLL / NoMethodError). This postload
# replaces the problematic entry points with safe no-ops and
# provides inert module / class shells so downstream code paths
# can still resolve their constants.
#
# Ports a curated subset of JoiPlay's `postload.rb`. Omitted items:
# Zeus video player shim (we have our own movie dispatcher),
# MGQP::make_thumbnail (touches Dir.mkdir on the game folder -
# iOS sandbox unfriendly), HN_Light / Sprite_Dark reskins (too
# game-specific), CSV parser override, string encoding helper -
# none of them have been reported as blockers.

# --- MapSaver (TH::Map_Saver) neutralization ---
# Some games bind a hotkey to snapshot the current map or screen
# to a PNG on disk. Define the class with no-op methods so the
# hotkey is inert and the constants used to name it never raise.
class Map_Saver
  def initialize(map_id = 0, x = 0, y = 0); end
  def set_scale(scale); end
  def mapshot; end
  def screenshot; end
end

module TH
  module Map_Saver
    Mapshot_Button    = 3452345
    Screenshot_Button = 3452345
  end
end

# --- Save-preview bitmap stubs ---
# Fleeting Iris, Vitamin Plus (Wora_NSS) and similar save menus
# expect Cache.bitmap_save_ss / savefile_picture to return a
# drawable Bitmap they can blit into the load screen. Our stubs
# return a plain gradient / blank so the UI renders without the
# actual screenshot.
module Cache
  def self.bitmap_save_ss(hash, index)
    sp = Bitmap.new(205, 150)
    sp.gradient_fill_rect(sp.rect, Color.new(80, 80, 80), Color.new(20, 20, 20), true)
    sp.draw_text(sp.rect, "Save File", 1)
    sp
  end

  def self.savefile_picture(filename)
    Bitmap.new(160, 120)
  end
end

# Bitmap#exportBitmap is called by several plugins to dump a
# screenshot PNG; route through engine Graphics.screenshot which
# knows how to write to the sandboxed cache dir.
class Bitmap
  def exportBitmap(fn, type, back = nil)
    Graphics.screenshot(fn) if Graphics.respond_to?(:screenshot)
  end
end

# Vitamin Plus save-screen screenshot toggles. Turning both off
# makes the plugin skip its screenshot path entirely.
module Wora_NSS
  SCREENSHOT_IMAGE = false
  PREMADE_IMAGE    = false
end

# --- tktk_bitmap no-op ---
# HN_Light and a few other plugins require tktk_bitmap's
# blend_blt. The real implementation does per-pixel blending via
# a Win32 DLL; no-op is safer than crashing.
module TKTK_Bitmap
  def blend_blt(dest_bmp, x, y, src_bmp, rect, blend_type = 0, opacity = 255)
  end
end

# --- MOG Anti Lag fix ---
# MOG's anti-lag plugin uses native window-client-area queries to
# build its event-update range. On mkxp we have Graphics.width /
# height instead. Rewrite the initial-setup method if the plugin
# is loaded so events near the map edges keep ticking.
begin
  if defined?(Game_Event) && Game_Event.method_defined?(:anti_lag_initial_setup)
    class Game_Event < Game_Character
      def anti_lag_initial_setup
        @can_update = true
        rg = [(Graphics.width / 32) - 1, (Graphics.height / 32) - 1]
        @loop_map = ($game_map.loop_horizontal? || $game_map.loop_vertical?) ? true : false
        out_screen = defined?(MOG_ANTI_LAG::UPDATE_OUT_SCREEN_RANGE) ?
          MOG_ANTI_LAG::UPDATE_OUT_SCREEN_RANGE : 0
        @antilag_range = [-out_screen, rg[0] + out_screen, rg[1] + out_screen]
      end
    end
  end
rescue StandardError
end

# --- YSE Patch System quit_fake suppression ---
# YSE's patch system forces a quit-confirm dialog that misbehaves
# on mobile (can't close, steals input). Flip its configured flag
# to false if the plugin is loaded.
begin
  if defined?(YSE::PATCH_SYSTEM::LOAD_CONFIGURATION)
    YSE::PATCH_SYSTEM::LOAD_CONFIGURATION[:quit_fake] = false
  end
rescue StandardError
end

# --- KGC BitmapExtension default ---
# Declare the default-mode constant so games referencing it at
# load time don't hit const_missing (which would return a NullStub
# and break `DEFAULT_MODE == 0` comparisons).
module KGC
  module BitmapExtension
    DEFAULT_MODE = 0 unless const_defined?(:DEFAULT_MODE)
  end
end

# --- MessageEnhance no-ops ---
# Suppress a commonly-included message-window enhancer's option
# flags so its extra rendering layers are skipped.
module MessageEnhance
  OK1 = false
  OB1 = false
  OK2 = false
  OB2 = false
  OK3 = false
  OB3 = false
  OB4 = false

  def self.invisible
    false
  end
end

# --- ZiifSaveLayoutA inert defaults ---
# This save-layout plugin loads background bitmaps from disk at
# boot. Provide neutral defaults and tiny placeholder bitmaps so
# the load screen builds without the native assets.
module ZiifSaveLayoutA
  File_column = 2
  File_row    = 5
  D_Area      = false
  D_Story     = false

  def self.save_background_bitmap; Bitmap.new(48, 48) end
  def self.load_background_bitmap; Bitmap.new(48, 48) end
end

begin
  class Window_ZiifSaveFile
    def draw_save_bitmap; end
  end
rescue StandardError
end

# --- InputMouse module stub ---
# Community-written mouse-input module distinct from Pokemon
# Essentials' $mouse. Touch devices have no mouse - return
# neutral values for every documented query so games probing
# for mouse activity always see "nothing pressed".
module InputMouse
  @@x = 0
  @@y = 0

  def self.x;  @@x end
  def self.y;  @@y end
  def self.set_pos(x, y);   false end
  def self.press?(index);   false end
  def self.trigger?(index); false end
  def self.repeat?(index);  false end
  def self.input_time(index); -1 end
  def self.input?;          false end
  def self.wheel_delta;     0 end
  def self.update;          end
  def self.fullscreen?;     true end
end
