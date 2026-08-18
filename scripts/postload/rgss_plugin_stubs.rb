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
# CSV parser override and CConv::s2u8 string-encoding helper
# (very game-specific, no current reports), Game_Temp /
# Scene_Map save-preview rewrites (the games we've tested take
# the default path fine).

# PE 20+ routes boot/version notices through Game.msgbox (Win32
# API on desktop). mkxp-z only binds Kernel.msgbox under RGSS3;
# PE20 titles that still ship Scripts.rxdata (RGSS1 detection)
# need a portable shim. Fall back to Kernel.p (native dialog on
# RGSS1/2) or debug-log via System.puts as last resort.
if defined?(Game) && !Game.respond_to?(:msgbox)
  class << Game
    def msgbox(*args)
      if Kernel.respond_to?(:msgbox)
        Kernel.msgbox(*args)
      elsif Kernel.respond_to?(:p)
        Kernel.p(*args)
      elsif defined?(System) && System.respond_to?(:puts)
        System.puts(args.join)
      end
    end
  end
end

# --- MapSaver (TH::Map_Saver) neutralization ---
# Some games bind a hotkey to snapshot the current map or screen
# to a PNG on disk. Define the class with no-op methods so the
# hotkey is inert and the constants used to name it never raise.
class Map_Saver
  def initialize(map_id = 0, x = 0, y = 0); end

  # rubocop:disable Naming/AccessorMethodName -- mirrors the
  # upstream Map_Saver plugin API (`map_saver.set_scale(2)`).
  def set_scale(scale); end
  # rubocop:enable Naming/AccessorMethodName

  def mapshot; end
  def screenshot; end
end

module TH
  module Map_Saver
    Mapshot_Button    = 3_452_345
    Screenshot_Button = 3_452_345
  end
end

# --- Save-preview bitmap stubs ---
# Fleeting Iris, Vitamin Plus (Wora_NSS) and similar save menus
# expect Cache.bitmap_save_ss / savefile_picture to return a
# drawable Bitmap they can blit into the load screen. Our stubs
# return a plain gradient / blank so the UI renders without the
# actual screenshot.
module Cache
  def self.bitmap_save_ss(_hash, _index)
    sp = Bitmap.new(205, 150)
    sp.gradient_fill_rect(sp.rect, Color.new(80, 80, 80), Color.new(20, 20, 20), true)
    sp.draw_text(sp.rect, 'Save File', 1)
    sp
  end

  def self.savefile_picture(_filename)
    Bitmap.new(160, 120)
  end
end

# --- MGQP DataManager.make_thumbnail no-op ---
# Monster Girl Quest Paradox and games sharing its save plugin
# call DataManager.make_thumbnail at boot. The stock body does
# Dir.mkdir("Save") and scans Save/*.png for thumbnails, both of
# which are unfriendly inside the iOS sandbox (write-permission
# errors, hangs on large folders). Replace with a no-op that
# initialises the @thumbnails / @current_thumbnail / @dummy_thumbnail
# instance vars to harmless placeholders so the rest of the
# save-screen pipeline keeps working. Gated on RGSS3 (rpg_version
# 3) since that's where the plugin lives.
if defined?(MKXP) && MKXP.respond_to?(:rpg_version) && MKXP.rpg_version > 2
  module DataManager
    def self.make_thumbnail
      @thumbnails        = {}
      @current_thumbnail = Bitmap.new(1, 1)
      @dummy_thumbnail   = Bitmap.new(1, 1)
    end
  end
end

# Bitmap#exportBitmap is called by several plugins to dump a
# screenshot PNG. Route through engine Graphics.screenshot which
# knows how to write to the sandboxed cache dir.
class Bitmap
  def exportBitmap(fn, _type, _back = nil)
    Graphics.screenshot(fn) if Graphics.respond_to?(:screenshot)
  end
end

# Bitmap#draw_text / text_size aliases for plugins that wrap text
# rendering by aliasing the original under `_draw_text` / `_text_size`
# names (Insurgence's font-replacer, Hime's text-pre-process scripts,
# others). Without the alias their bypass falls through to a
# `NoMethodError`, which they typically rescue silently and end up
# rendering nothing. JoiPlay sets these aliases in postload.rb:
# match the convention so the bypass paths survive.
#
# Idempotent: skip if the alias already exists (some games install
# their own `_draw_text` either before or after our postload, and
# re-aliasing would capture our wrapper as the "original").
class Bitmap
  alias _draw_text draw_text unless method_defined?(:_draw_text) || private_method_defined?(:_draw_text)
  alias _text_size text_size unless method_defined?(:_text_size) || private_method_defined?(:_text_size)
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
# a Win32 DLL. No-op is safer than crashing.
module TKTK_Bitmap
  # rubocop:disable Metrics/ParameterLists -- matches the upstream
  # tktk_bitmap signature game scripts call.
  def blend_blt(dest_bmp, x, y, src_bmp, rect, blend_type = 0, opacity = 255); end
  # rubocop:enable Metrics/ParameterLists
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
        @loop_map = $game_map.loop_horizontal? || $game_map.loop_vertical?
        out_screen = if defined?(MOG_ANTI_LAG::UPDATE_OUT_SCREEN_RANGE)
                       MOG_ANTI_LAG::UPDATE_OUT_SCREEN_RANGE
                     else
                       0
                     end
        @antilag_range = [-out_screen, rg[0] + out_screen, rg[1] + out_screen]
      end
    end
  end
rescue StandardError
  # MOG plugin not loaded. Nothing to patch.
end

# --- YSE Patch System quit_fake suppression ---
# YSE's patch system forces a quit-confirm dialog that misbehaves
# on mobile (can't close, steals input). Flip its configured flag
# to false if the plugin is loaded.
begin
  YSE::PATCH_SYSTEM::LOAD_CONFIGURATION[:quit_fake] = false if defined?(YSE::PATCH_SYSTEM::LOAD_CONFIGURATION)
rescue StandardError
  # YSE patch system not loaded. Nothing to disable.
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

  # rubocop:disable Naming/PredicateMethod -- mirrors upstream
  # MessageEnhance.invisible accessor (named without `?` in the
  # plugin and called as `MessageEnhance.invisible` by games).
  def self.invisible
    false
  end
  # rubocop:enable Naming/PredicateMethod
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

  def self.save_background_bitmap
    Bitmap.new(48, 48)
  end

  def self.load_background_bitmap
    Bitmap.new(48, 48)
  end
end

begin
  class Window_ZiifSaveFile
    def draw_save_bitmap; end
  end
rescue StandardError
  # ZiifSaveLayoutA plugin not loaded. Nothing to patch.
end

# --- HN_Light / Sprite_Dark inert shells ---
# Hime's HN_Light dynamic-lighting plugin builds per-pixel light
# textures via tktk_bitmap's native blend_blt, which we already
# no-op above. Provide an empty Light class so any `HN_Light::Light.new`
# call returns a harmless object with the attr_readers the plugin
# expects, and stub Sprite_Dark with a real Sprite subclass so
# `<<` / refresh / dispose calls forwarded by map scenes don't
# explode. The result is "no lighting effect" rather than a crash.
module HN_Light
  class Light
    attr_reader :bitmap, :cells, :width, :height, :ox, :oy

    def initialize(light_type, s_zoom = 1); end
    def dispose; end
  end
end

begin
  class Sprite_Dark < Sprite
    def initialize(viewport = nil)
      super
      @width  = Graphics.width
      @height = Graphics.height
      @light_cache = {}
    end

    def add_light(character); end
    def refresh; end
  end
rescue StandardError
  # HN_Light Sprite_Dark not in scope. Nothing to stub.
end

# --- InputMouse module stub ---
# Community-written mouse-input module distinct from Pokemon
# Essentials' $mouse. Touch devices have no mouse - return
# neutral values for every documented query so games probing
# for mouse activity always see "nothing pressed".
module InputMouse
  @@x = 0
  @@y = 0

  def self.x
    @@x
  end

  def self.y
    @@y
  end

  # rubocop:disable Naming/PredicateMethod
  # `set_pos` mirrors the upstream InputMouse plugin API. Returns
  # false to mean "not supported on this platform".
  def self.set_pos(_x, _y)
    false
  end
  # rubocop:enable Naming/PredicateMethod

  def self.press?(_index)
    false
  end

  def self.trigger?(_index)
    false
  end

  def self.repeat?(_index)
    false
  end

  def self.input_time(_index)
    -1
  end

  def self.input?
    false
  end

  def self.wheel_delta
    0
  end

  def self.update; end

  def self.fullscreen?
    true
  end
end
