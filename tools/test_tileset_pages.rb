#!/usr/bin/env ruby
# Regression tests for pokemon_tilemap_fix.rb: the paged tileset
# storage that replaced Pokemon Essentials' fold-into-columns wrap.
#
# The bug class under test: PE hands a tileset to a wrapper that only
# accepts images exactly 8 tiles wide, then disposes the source even
# when the wrapper gave the source straight back. Every later tile
# lookup then reads a disposed bitmap and dies with "disposed bitmap"
# (Pokemon Sandglass, jail tileset 384x12000, first map after the
# naming screen). The second failure mode is a hard size ceiling:
# a tileset too tall to fold raised "Tileset is too long!".
#
# The fakes below stand in for the C++ bindings (Bitmap, Rect, Sprite)
# and for PE's own renderer classes. Bitmap#width and #height raise on
# a disposed bitmap, exactly like the engine's guardDisposed, so a
# regression to the old ownership bug fails these tests instead of
# passing quietly.
#
# Run: ruby mkxp-z-apple-mobile/tools/test_tileset_pages.rb

require 'rbconfig'

ROOT = File.expand_path('..', __dir__)
PATCH = File.join(ROOT, 'scripts', 'postload', 'pokemon_tilemap_fix.rb')

SCENARIOS = %w[immediate deferred no_helper legacy small_gpu
                watcher_stops_legacy watcher_stops_plain real_max_size].freeze

require_relative 'assertion_count'

$failures = []

def assert(condition, label)
  asserted
  return if condition

  $failures << label
end

def assert_eq(actual, expected, label)
  asserted
  return if actual == expected

  $failures << "#{label}\n    expected: #{expected.inspect}\n    actual:   #{actual.inspect}"
end

def assert_quiet(label)
  asserted
  yield
rescue StandardError, SystemStackError => e
  $failures << "#{label}: raised #{e.class}: #{e.message}"
end

def report(scenario)
  if $failures.empty? && $assertions.positive?
    puts "  ok (#{scenario}, #{$assertions} assertions)"
    exit 0
  end
  $failures << 'the scenario ran no assertion' if $assertions.zero?
  warn "  FAILED (#{scenario}):"
  $failures.each { |f| warn "  - #{f}" }
  exit 1
end

#===============================================================================
# Engine stand-ins (C++ bindings in production)
#===============================================================================

$max_texture_size = 8192
# A game's mkxp.json may raise Bitmap.max_size above the hardware limit.
# nil means the engine build has no real_max_size accessor.
$real_texture_size = nil

class Bitmap
  LIVE = []

  attr_reader :blits

  def self.max_size
    $max_texture_size
  end

  def self.respond_to?(name, include_all = false)
    return !$real_texture_size.nil? if name == :real_max_size

    super
  end

  def self.real_max_size
    $real_texture_size
  end

  # Mega-ness follows the truth, the way the GPU does.
  def self.hardware_limit
    $real_texture_size || $max_texture_size
  end

  def initialize(width, height)
    raise 'failed to create bitmap' if width <= 0 || height <= 0

    @w = width
    @h = height
    @disposed = false
    @blits = []
    LIVE << self
  end

  # The engine raises on any operation against a disposed bitmap.
  # Reading height is what the Sandglass crash actually hit.
  def width
    guard
    @w
  end

  def height
    guard
    @h
  end

  def mega?
    guard
    @w > Bitmap.hardware_limit || @h > Bitmap.hardware_limit
  end

  def disposed?
    @disposed
  end

  def dispose
    @disposed = true
  end

  def blt(x, y, source, rect, _opacity = 255)
    guard
    source.guard
    @blits << { :x => x, :y => y, :src => source, :rect => [rect.x, rect.y, rect.width, rect.height] }
  end

  def stretch_blt(dest_rect, source, rect, _opacity = 255)
    guard
    source.guard
    @blits << { :stretch => [dest_rect.x, dest_rect.y], :src => source,
                :rect => [rect.x, rect.y, rect.width, rect.height] }
  end

  def clear; end

  def fill_rect(*_args); end

  def guard
    raise 'disposed bitmap' if @disposed
  end
end

class Rect
  attr_accessor :x, :y, :width, :height

  def initialize(x = 0, y = 0, width = 0, height = 0)
    set(x, y, width, height)
  end

  def set(x, y, width, height)
    @x = x
    @y = y
    @width = width
    @height = height
    self
  end

  def to_a
    [@x, @y, @width, @height]
  end
end

class Sprite
  attr_reader :bitmap, :src_rect
  attr_accessor :visible, :x, :y, :z, :zoom_x, :zoom_y, :tone, :color, :ox, :oy

  def initialize(_viewport = nil)
    @src_rect = Rect.new(0, 0, 0, 0)
    @visible = true
  end

  # RGSS resets src_rect to the whole bitmap on assignment. The patch
  # has to write all four rect fields after switching pages. This fake
  # is what catches it if someone reorders those two steps.
  def bitmap=(value)
    @bitmap = value
    @src_rect.set(0, 0, value ? value.width : 0, value ? value.height : 0)
  end

  def dispose; end
end

module Graphics
  FRAMES = []

  module_function

  def update
    FRAMES << :drawn
  end
end

module MKXP
  LOG = []

  module_function

  def puts(message)
    LOG << message
  end
end

$MKXP = true

def nil_or_empty?(value)
  value.nil? || value.empty?
end

$tileset_files = {}
$autotile_files = {}

def pbGetTileset(name)
  source = $tileset_files[name]
  raise "no such tileset #{name}" if !source

  source
end

def pbGetAutotile(name)
  source = $autotile_files[name]
  raise "no such autotile #{name}" if !source

  source
end

def live_pages
  Bitmap::LIVE.reject(&:disposed?)
end

def load_patch
  previous = $VERBOSE
  $VERBOSE = nil
  begin
    load PATCH
  ensure
    $VERBOSE = previous
  end
end

#===============================================================================
# Pokemon Essentials stand-ins, in their unpatched (broken) form.
#
# Kept in a string so each scenario controls WHEN the classes appear:
# games with a real Scripts.rxdata define them before the postload
# runs, games with a loose script loader define them after.
#===============================================================================

RENDERER_SOURCE = <<~'RUBY'
  class TilemapRenderer
    SOURCE_TILE_WIDTH       = 32
    SOURCE_TILE_HEIGHT      = 32
    TILESET_TILES_PER_ROW   = 8
    AUTOTILES_COUNT         = 8
    TILES_PER_AUTOTILE      = 48
    TILESET_START_ID        = AUTOTILES_COUNT * TILES_PER_AUTOTILE
    AUTOTILE_FRAME_DURATION = 5

    class TilesetBitmaps
      attr_accessor :changed
      attr_accessor :bitmaps

      def initialize
        @bitmaps      = {}
        @bitmap_wraps = {}
        @load_counts  = {}
        @changed      = true
      end

      def [](filename)
        @bitmaps[filename]
      end

      def []=(filename, bitmap)
        return if nil_or_empty?(filename)

        @bitmaps[filename] = bitmap
        @bitmap_wraps[filename] = false
        @changed = true
      end

      # The pre-fix implementation: wrapTileset gives the source back
      # for any width other than 256, and this disposes it anyway.
      def add(filename)
        return if nil_or_empty?(filename)

        if @bitmaps[filename]
          @load_counts[filename] += 1
          return
        end
        bitmap = pbGetTileset(filename)
        @bitmap_wraps[filename] = false
        if bitmap.mega?
          self[filename] = TilemapRenderer::TilesetWrapper.wrapTileset(bitmap)
          @bitmap_wraps[filename] = true
          bitmap.dispose
        else
          self[filename] = bitmap
        end
        @load_counts[filename] = 1
      end

      def remove(filename)
        return if nil_or_empty?(filename) || !@bitmaps[filename]

        if @load_counts[filename] > 1
          @load_counts[filename] -= 1
          return
        end
        @bitmaps[filename].dispose
        @bitmaps.delete(filename)
        @bitmap_wraps.delete(filename)
        @load_counts.delete(filename)
      end

      def set_src_rect(tile, tile_id)
        return if nil_or_empty?(tile.filename)
        return if !@bitmaps[tile.filename]

        start_id = TilemapRenderer::TILESET_START_ID
        per_row = TilemapRenderer::TILESET_TILES_PER_ROW
        tile.src_rect.x = ((tile_id - start_id) % per_row) * TilemapRenderer::SOURCE_TILE_WIDTH
        tile.src_rect.y = ((tile_id - start_id) / per_row) * TilemapRenderer::SOURCE_TILE_HEIGHT
        return if !@bitmap_wraps[tile.filename]

        height = @bitmaps[tile.filename].height
        col = (tile_id - start_id) * TilemapRenderer::SOURCE_TILE_HEIGHT / (per_row * height)
        tile.src_rect.x += col * per_row * TilemapRenderer::SOURCE_TILE_WIDTH
        tile.src_rect.y -= col * height
      end

      def update; end
    end

    class AutotileBitmaps < TilesetBitmaps
      attr_reader :current_frames

      def initialize
        super
        @frame_counts    = {}
        @frame_durations = {}
        @current_frames  = {}
      end

      def []=(filename, value)
        super
        return if nil_or_empty?(filename)

        frame_count(filename, true)
        set_current_frame(filename)
      end

      def add(filename)
        return if nil_or_empty?(filename)

        if @bitmaps[filename]
          @load_counts[filename] += 1
          return
        end
        orig_bitmap = pbGetAutotile(filename)
        @bitmap_wraps[filename] = false
        duration = TilemapRenderer::AUTOTILE_FRAME_DURATION
        duration = $~[1].to_i if filename[/\[\s*(\d+?)\s*\]\s*$/]
        @frame_durations[filename] = duration.to_f / 20
        bitmap = TilemapRenderer::AutotileExpander.expand(orig_bitmap)
        self[filename] = bitmap
        if bitmap.height > TilemapRenderer::SOURCE_TILE_HEIGHT &&
           bitmap.height < TilemapRenderer::TILES_PER_AUTOTILE * TilemapRenderer::SOURCE_TILE_HEIGHT
          @bitmap_wraps[filename] = true
        end
        orig_bitmap.dispose if orig_bitmap != bitmap
        @load_counts[filename] = 1
      end

      def remove(filename)
        super
        return if @load_counts[filename] && @load_counts[filename] > 0

        @frame_counts.delete(filename)
        @current_frames.delete(filename)
        @frame_durations.delete(filename)
      end

      def frame_count(filename, force_recalc = false)
        if !@frame_counts[filename] || force_recalc
          return 0 if !@bitmaps[filename]

          bitmap = @bitmaps[filename]
          @frame_counts[filename] = [bitmap.width / TilemapRenderer::SOURCE_TILE_WIDTH, 1].max
          if bitmap.height > TilemapRenderer::SOURCE_TILE_HEIGHT && @bitmap_wraps[filename]
            @frame_counts[filename] /= 2
          end
        end
        @frame_counts[filename]
      end

      def animated?(filename)
        frame_count(filename) > 1
      end

      def current_frame(filename)
        set_current_frame(filename) if !@current_frames[filename]
        @current_frames[filename]
      end

      # Production picks the frame from a clock. The tests drive it
      # directly so the assertions stay deterministic.
      def set_current_frame(filename)
        @current_frames[filename] ||= 0
      end

      def force_frame(filename, frame)
        @current_frames[filename] = frame
      end

      def set_src_rect(tile, tile_id)
        return if nil_or_empty?(tile.filename)
        return if !@bitmaps[tile.filename]

        frame = current_frame(tile.filename)
        if @bitmaps[tile.filename].height == TilemapRenderer::SOURCE_TILE_HEIGHT
          tile.src_rect.x = frame * TilemapRenderer::SOURCE_TILE_WIDTH
          tile.src_rect.y = 0
          return
        end
        wraps = @bitmap_wraps[tile.filename]
        per_autotile = TilemapRenderer::TILES_PER_AUTOTILE
        tile.src_rect.x = 0
        tile.src_rect.y = (tile_id % per_autotile) * TilemapRenderer::SOURCE_TILE_HEIGHT
        if wraps && (tile_id % per_autotile) >= per_autotile / 2
          tile.src_rect.x = TilemapRenderer::SOURCE_TILE_WIDTH
          tile.src_rect.y -= TilemapRenderer::SOURCE_TILE_HEIGHT * per_autotile / 2
        end
        tile.src_rect.x += frame * TilemapRenderer::SOURCE_TILE_WIDTH * (wraps ? 2 : 1)
      end
    end

    class TileSprite < Sprite
      attr_accessor :filename, :tile_id, :is_autotile, :animated, :priority
    end

    attr_reader :tilesets, :autotiles

    # The shipped renderer takes a viewport. The patched initialize
    # has to forward it to the original.
    def initialize(viewport = :none)
      @viewport  = viewport
      @tilesets  = TilesetBitmaps.new
      @autotiles = AutotileBitmaps.new
      @disposed  = false
    end

    attr_reader :viewport

    def disposed?
      @disposed
    end

    def dispose
      return if disposed?

      @tilesets.bitmaps.each_value { |bitmap| bitmap.dispose }
      @tilesets.bitmaps.clear
      @autotiles.bitmaps.each_value { |bitmap| bitmap.dispose }
      @autotiles.bitmaps.clear
      @disposed = true
    end
  end

  class TilemapRenderer
    module TilesetWrapper
      TILESET_WIDTH = SOURCE_TILE_WIDTH * TILESET_TILES_PER_ROW
      MAX_TEX_SIZE  = (Bitmap.max_size / 1024) * 1024

      module_function

      # Verbatim behaviour of the shipped wrapper: any width other
      # than 256 falls through and returns the source unchanged.
      def wrapTileset(originalbmp)
        width = originalbmp.width
        height = originalbmp.height
        if width == TILESET_WIDTH && originalbmp.mega?
          columns = (height / MAX_TEX_SIZE.to_f).ceil
          if columns * TILESET_WIDTH > MAX_TEX_SIZE
            raise "Tileset is too long!\\n\\nSIZE: #{height}px"
          end

          return Bitmap.new(TILESET_WIDTH * columns, MAX_TEX_SIZE)
        end
        originalbmp
      end
    end

    module AutotileExpander
      MAX_TEXTURE_SIZE = (Bitmap.max_size / 1024) * 1024
      CALLS = []

      module_function

      def expand(bitmap)
        return bitmap if bitmap.height == TilemapRenderer::SOURCE_TILE_HEIGHT

        wrap = MAX_TEXTURE_SIZE <
               TilemapRenderer::TILES_PER_AUTOTILE * TilemapRenderer::SOURCE_TILE_HEIGHT
        frames = [bitmap.width / (3 * TilemapRenderer::SOURCE_TILE_WIDTH), 1].max
        out = Bitmap.new(
          frames * (wrap ? 2 : 1) * TilemapRenderer::SOURCE_TILE_WIDTH,
          TilemapRenderer::TILES_PER_AUTOTILE * TilemapRenderer::SOURCE_TILE_HEIGHT / (wrap ? 2 : 1)
        )
        CALLS << [bitmap.width, out.width, out.height]
        out
      end
    end
  end

RUBY

LEGACY_SOURCE = <<~'RUBY'
  class CustomTilemap
    attr_reader :tileset

    def initialize
      @regularTileInfo = {}
      @tileWidth = 32
      @tileHeight = 32
      @tileSrcWidth = 32
      @tileSrcHeight = 32
      @tilesetchanged = false
    end

    def tileset=(value)
      @tileset = value
      @tilesetchanged = true
    end

    def getRegularTile(sprite, id)
      bitmap = @regularTileInfo[id]
      unless bitmap
        bitmap = Bitmap.new(@tileWidth, @tileHeight)
        rect = Rect.new(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                        @tileSrcWidth, @tileSrcHeight)
        bitmap.blt(0, 0, @tileset, rect)
        @regularTileInfo[id] = bitmap
      end
      sprite.bitmap = bitmap if sprite.bitmap != bitmap
    end
  end
RUBY

HELPER_SOURCE = <<~'RUBY'
  class TileDrawingHelper
    attr_accessor :tileset, :autotiles

    def initialize(tileset, autotiles)
      if tileset.mega?
        @tileset = TilemapRenderer::TilesetWrapper.wrapTileset(tileset)
        tileset.dispose
        @shouldWrap = true
      else
        @tileset = tileset
        @shouldWrap = false
      end
      @autotiles = autotiles
    end

    def dispose
      @tileset&.dispose
      @tileset = nil
    end

    def bltSmallRegularTile(bitmap, x, y, cx_tile, cy_tile, id)
      return if id < 384 || !@tileset || @tileset.disposed?

      rect = Rect.new(((id - 384) % 8) * 32, ((id - 384) / 8) * 32, 32, 32)
      bitmap.stretch_blt(Rect.new(x, y, cx_tile, cy_tile), @tileset, rect)
    end
  end
RUBY

def define_helper!
  eval(HELPER_SOURCE, TOPLEVEL_BINDING, __FILE__, __LINE__) # rubocop:disable Security/Eval
end

def define_renderer!
  eval(RENDERER_SOURCE, TOPLEVEL_BINDING, __FILE__, __LINE__) # rubocop:disable Security/Eval
end

def define_legacy!
  eval(LEGACY_SOURCE, TOPLEVEL_BINDING, __FILE__, __LINE__) # rubocop:disable Security/Eval
end

#===============================================================================
# Shared checks for the modern renderer, used by more than one scenario.
#===============================================================================

def new_tile(filename, autotile = false)
  tile = TilemapRenderer::TileSprite.new
  tile.filename = filename
  tile.is_autotile = autotile
  tile
end

def tile_id_for(column, row)
  TilemapRenderer::TILESET_START_ID + (row * TilemapRenderer::TILESET_TILES_PER_ROW) + column
end

def check_pager_geometry
  small = Bitmap.new(256, 4096)
  sheet = MKXPTilePages.split(small, 256, 32, 32)
  assert_eq(sheet.bitmaps.length, 1, 'pager: a tileset that already fits stays one page')
  assert_eq(sheet.copied?, false, 'pager: a tileset that already fits is not copied')
  assert_eq(sheet.first.equal?(small), true, 'pager: the single page IS the source')
  assert_eq(small.disposed?, false, 'pager: an uncopied source stays alive')

  tall = Bitmap.new(256, 25600)
  sheet = MKXPTilePages.split(tall, 256, 32, 32)
  assert_eq(sheet.bitmaps.length, 4, 'pager: 25600px over an 8192 limit needs 4 pages')
  assert_eq(sheet.copied?, true, 'pager: a split sheet reports copied')
  assert_eq(sheet.bitmaps.map(&:height), [8192, 8192, 8192, 1024], 'pager: page heights')
  assert_eq(sheet.locate(0, 0)[1, 2], [0, 0], 'pager: first pixel sits at the page origin')
  assert_eq(sheet.locate(0, 8192)[0].equal?(sheet.bitmaps[1]), true,
            'pager: the row after the first page lands on page 2')
  assert_eq(sheet.locate(0, 8192)[2], 0, 'pager: page 2 starts its own y at 0')
  assert_eq(sheet.locate(64, 25599)[0].equal?(sheet.bitmaps[3]), true,
            'pager: the last row lands on the last page')
  assert_eq(sheet.locate(0, 25600), nil, 'pager: a row past the end has no page')
  assert_eq(sheet.locate(-1, 0), nil, 'pager: a negative position has no page')

  wide = Bitmap.new(1167, 25000)
  sheet = MKXPTilePages.split(wide, 256, 32, 32)
  assert_eq(sheet.width, 256, 'pager: unreachable columns are dropped')
  assert_eq(sheet.locate(300, 0), nil, 'pager: a dropped column has no page')
  assert_eq(sheet.bitmaps.map(&:width).uniq, [256], 'pager: every page keeps the tile width')
end

def check_blit_across_pages
  source = Bitmap.new(256, 16384)
  sheet = MKXPTilePages.split(source, 256, 32, 32)
  dest = Bitmap.new(64, 64)
  sheet.blit_to(dest, 0, 0, Rect.new(0, 8180, 32, 32))
  assert_eq(dest.blits.length, 2, 'blit_to: a rect over a page seam splits into two copies')
  heights = dest.blits.map { |b| b[:rect][3] }
  assert_eq(heights.sum, 32, 'blit_to: the two copies cover the whole rect')
  assert_eq(dest.blits[0][:y], 0, 'blit_to: the first piece lands at the top')
  assert_eq(dest.blits[1][:y], heights[0], 'blit_to: the second piece lands under the first')
end

def check_wide_mega_tileset_no_longer_crashes
  renderer = TilemapRenderer.new
  source = Bitmap.new(384, 12000)
  $tileset_files['jail'] = source

  assert_quiet('add: a 384x12000 tileset loads') { renderer.tilesets.add('jail') }
  assert_eq(source.disposed?, true, 'add: the paged source is released')

  tile = new_tile('jail')
  assert_quiet('set_src_rect: the Sandglass crash case') do
    renderer.tilesets.set_src_rect(tile, tile_id_for(0, 0))
  end
  assert_eq(tile.bitmap.disposed?, false, 'set_src_rect: the tile points at a live page')
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'set_src_rect: first tile rect')

  renderer.tilesets.set_src_rect(tile, tile_id_for(3, 1))
  assert_eq(tile.src_rect.to_a, [96, 32, 32, 32], 'set_src_rect: second row rect')

  # Row 256 is the first row of page 2 (256 * 32 == 8192).
  renderer.tilesets.set_src_rect(tile, tile_id_for(0, 256))
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'set_src_rect: page 2 restarts y at 0')
  assert_eq(tile.bitmap.equal?(renderer.tilesets.mkxp_sheets['jail'].bitmaps[1]), true,
            'set_src_rect: the tile switched to page 2')

  # Straddle back to page 1 and make sure width/height are rewritten.
  # Assigning a bitmap resets src_rect to the whole page.
  renderer.tilesets.set_src_rect(tile, tile_id_for(1, 255))
  assert_eq(tile.src_rect.to_a, [32, 8160, 32, 32], 'set_src_rect: last row of page 1')

  renderer.tilesets.set_src_rect(tile, tile_id_for(0, 9999))
  assert_eq(tile.visible, false, 'set_src_rect: a tile id past the tileset is hidden')
end

def check_reference_counting_and_dispose
  renderer = TilemapRenderer.new
  $tileset_files['big'] = Bitmap.new(256, 25600)
  renderer.tilesets.add('big')
  pages = renderer.tilesets.mkxp_sheets['big'].bitmaps
  assert_eq(pages.length, 4, 'refcount: the tileset paged as expected')

  renderer.tilesets.add('big')
  renderer.tilesets.remove('big')
  assert_eq(pages.any?(&:disposed?), false, 'refcount: one release of two keeps the pages')

  renderer.tilesets.remove('big')
  assert_eq(pages.all?(&:disposed?), true, 'refcount: the last release frees every page')

  # A renderer teardown must free the pages the game never sees, not
  # just the first one it holds in @bitmaps.
  other = TilemapRenderer.new
  $tileset_files['big2'] = Bitmap.new(256, 25600)
  other.tilesets.add('big2')
  live = other.tilesets.mkxp_sheets['big2'].bitmaps
  other.dispose
  assert_eq(live.all?(&:disposed?), true, 'dispose: every page is freed with the renderer')
  assert_eq(other.disposed?, true, 'dispose: the renderer still reports disposed')
end

def check_double_install_is_safe
  # A second install must not alias dispose onto itself. That would
  # recurse forever the next time a map closes.
  MKXPTilesetPatch.install_renderer
  renderer = TilemapRenderer.new
  assert_quiet('install: calling the installer twice keeps dispose finite') { renderer.dispose }
end

def check_autotile_paging
  renderer = TilemapRenderer.new
  # 125 frames of the 3-tile-wide source layout. One page holds 85
  # frames: the expanded page and the source cut must both fit.
  $autotile_files['falls'] = Bitmap.new(125 * 96, 128)
  assert_quiet('autotile: a 12000px wide autotile loads') { renderer.autotiles.add('falls') }

  sheet = renderer.autotiles.mkxp_sheets['falls']
  assert_eq(sheet.frames, 125, 'autotile: every frame is counted')
  assert_eq(renderer.autotiles.frame_count('falls'), 125, 'autotile: frame_count agrees')
  assert_eq(renderer.autotiles.animated?('falls'), true, 'autotile: reports animated')
  assert_eq(sheet.bitmaps.length, 2, 'autotile: 125 frames need 2 pages')
  assert_eq(sheet.bitmaps.map(&:width), [85 * 32, 40 * 32], 'autotile: page widths')
  assert_eq(sheet.bitmaps.map(&:width).all? { |w| w <= Bitmap.max_size }, true,
            'autotile: no page exceeds the texture limit')
  assert_eq(TilemapRenderer::AutotileExpander::CALLS.map(&:first).all? { |w| w <= Bitmap.max_size },
            true, 'autotile: no intermediate cut exceeds the texture limit')

  tile = new_tile('falls', true)
  renderer.autotiles.force_frame('falls', 0)
  renderer.autotiles.set_src_rect(tile, 48)
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'autotile: frame 0, shape 0')
  assert_eq(tile.bitmap.equal?(sheet.bitmaps[0]), true, 'autotile: frame 0 uses page 1')

  renderer.autotiles.force_frame('falls', 84)
  renderer.autotiles.set_src_rect(tile, 48)
  assert_eq(tile.src_rect.to_a, [84 * 32, 0, 32, 32], 'autotile: last frame of page 1')

  renderer.autotiles.force_frame('falls', 85)
  renderer.autotiles.set_src_rect(tile, 48)
  assert_eq(tile.bitmap.equal?(sheet.bitmaps[1]), true, 'autotile: frame 85 moves to page 2')
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'autotile: page 2 restarts the frame count')

  renderer.autotiles.force_frame('falls', 124)
  renderer.autotiles.set_src_rect(tile, 48 + 5)
  assert_eq(tile.src_rect.to_a, [39 * 32, 5 * 32, 32, 32], 'autotile: last frame, shape 5')
end

def check_single_tile_autotile
  renderer = TilemapRenderer.new
  source = Bitmap.new(768, 32)
  $autotile_files['flowers'] = source
  renderer.autotiles.add('flowers')

  sheet = renderer.autotiles.mkxp_sheets['flowers']
  assert_eq(sheet.frames, 24, 'single autotile: 24 frames across a 768px strip')
  assert_eq(sheet.copied?, false, 'single autotile: the source is used as-is')
  assert_eq(source.disposed?, false, 'single autotile: the source is not released')

  tile = new_tile('flowers', true)
  renderer.autotiles.force_frame('flowers', 3)
  renderer.autotiles.set_src_rect(tile, 48)
  assert_eq(tile.src_rect.to_a, [96, 0, 32, 32], 'single autotile: frame 3 rect')
end

def check_frame_duration_suffix
  renderer = TilemapRenderer.new
  $autotile_files['sea [10]'] = Bitmap.new(96 * 4, 128)
  renderer.autotiles.add('sea [10]')
  durations = renderer.autotiles.instance_variable_get(:@frame_durations)
  assert_eq(durations['sea [10]'], 0.5, 'autotile: the [n] filename suffix still sets the speed')
end

def check_drawing_helper
  source = Bitmap.new(384, 12000)
  helper = TileDrawingHelper.new(source, [])
  assert_eq(source.disposed?, true, 'helper: the paged source is released')

  dest = Bitmap.new(64, 64)
  assert_quiet('helper: drawing a tile from a paged tileset') do
    helper.bltSmallRegularTile(dest, 0, 0, 4, 4, tile_id_for(0, 256))
  end
  assert_eq(dest.blits.length, 1, 'helper: one copy per tile')
  assert_eq(dest.blits[0][:rect], [0, 0, 32, 32], 'helper: page 2 rect starts at y 0')
  assert_quiet('helper: dispose frees the pages') { helper.dispose }
end

def check_alias_chaining_plugin
  # RGSS plugins extend by alias. Pokemon Nova aliases initialize and
  # dies with SystemStackError if the patch sits in a prepended module,
  # because its alias re-enters our super. The patch must compose with
  # the alias idiom instead.
  TilemapRenderer.class_eval do
    alias_method :plugin_old_initialize, :initialize
    def initialize(*args)
      plugin_old_initialize(*args)
      @plugin_ran = true
    end

    alias_method :plugin_old_dispose, :dispose
    def dispose
      @plugin_disposed = true
      plugin_old_dispose
    end
    attr_reader :plugin_ran, :plugin_disposed
  end

  TilemapRenderer::TilesetBitmaps.class_eval do
    alias_method :plugin_old_src_rect, :set_src_rect
    def set_src_rect(tile, tile_id)
      plugin_old_src_rect(tile, tile_id)
      @plugin_saw = tile_id
    end
    attr_reader :plugin_saw
  end

  renderer = nil
  assert_quiet('alias plugin: building a renderer does not recurse') do
    renderer = TilemapRenderer.new(:viewport)
  end
  return if !renderer

  assert_eq(renderer.plugin_ran, true, 'alias plugin: its initialize still ran')

  $tileset_files['aliased'] = Bitmap.new(384, 12000)
  renderer.tilesets.add('aliased')
  tile = new_tile('aliased')
  assert_quiet('alias plugin: a tile lookup does not recurse') do
    renderer.tilesets.set_src_rect(tile, tile_id_for(0, 256))
  end
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'alias plugin: paging still applies')
  assert_eq(renderer.tilesets.plugin_saw, tile_id_for(0, 256),
            'alias plugin: its own set_src_rect still ran')

  pages = renderer.tilesets.mkxp_sheets['aliased'].bitmaps
  assert_quiet('alias plugin: teardown does not recurse') { renderer.dispose }
  assert_eq(renderer.plugin_disposed, true, 'alias plugin: its dispose still ran')
  assert_eq(pages.all?(&:disposed?), true, 'alias plugin: every page is still freed')
end

def check_reports
  renderer = TilemapRenderer.new
  before = MKXP::LOG.length
  $tileset_files['wide'] = Bitmap.new(1167, 25000)
  renderer.tilesets.add('wide')
  crop = MKXP::LOG[before..-1].grep(/using 256px of 1167px/)
  assert_eq(crop.length, 1, 'report: the dropped columns are named once')

  before = MKXP::LOG.length
  tile = new_tile('wide')
  3.times { renderer.tilesets.set_src_rect(tile, tile_id_for(0, 99_999)) }
  range = MKXP::LOG[before..-1].grep(/past the tileset/)
  assert_eq(range.length, 1, 'report: an out-of-range tile is named once, not per frame')

  # A tileset that needs no paging keeps its full width, so there is
  # nothing to report.
  before = MKXP::LOG.length
  $tileset_files['small'] = Bitmap.new(320, 4096)
  renderer.tilesets.add('small')
  assert_eq(MKXP::LOG[before..-1].grep(/using /).length, 0,
            'report: nothing is said when no art is dropped')
end

def check_modern_renderer
  check_pager_geometry
  check_blit_across_pages
  check_wide_mega_tileset_no_longer_crashes
  check_reference_counting_and_dispose
  check_double_install_is_safe
  check_autotile_paging
  check_single_tile_autotile
  check_frame_duration_suffix
  check_drawing_helper
  check_reports
  check_alias_chaining_plugin
end

#===============================================================================
# Scenarios
#===============================================================================

def scenario_immediate
  # A game with a real Scripts.rxdata: every class exists before the
  # postload runs, so the patch installs straight away.
  define_renderer!
  define_helper!
  load_patch
  assert_eq(MKXPTilesetPatch.done?, true, 'install: both targets patched at load time')
  check_modern_renderer
end

def scenario_deferred
  # A game with a loose script loader (Sandglass, Reborn): the
  # postload runs first and has to wait for the classes to appear.
  load_patch
  assert_eq(MKXPTilesetPatch.done?, false, 'defer: nothing to patch yet')
  assert_eq(defined?(TilemapRenderer), nil, 'defer: the patch did not invent the class')

  define_renderer!
  define_helper!
  assert_eq(MKXPTilesetPatch.done?, true, 'defer: the watcher patched both targets')
  assert_eq(Graphics::FRAMES.empty?, true, 'defer: loading drew no frames')

  tracer = MKXPTilesetPatch.instance_variable_get(:@tracer)
  assert_eq(tracer.enabled?, false, 'defer: the watcher turns itself off once done')

  check_modern_renderer
end

def scenario_legacy
  # Essentials v17/v18 renderer.
  define_legacy!
  load_patch
  assert_eq(MKXP::LOG.any? { |m| m.include?('CustomTilemap patched') }, true,
            'legacy: the CustomTilemap patch installed')

  tilemap = CustomTilemap.new
  source = Bitmap.new(384, 12000)
  assert_quiet('legacy: a 384x12000 tileset is accepted') { tilemap.tileset = source }
  assert_eq(source.disposed?, true, 'legacy: the paged source is released')

  sprite = Sprite.new
  assert_quiet('legacy: drawing a tile from page 2') do
    tilemap.getRegularTile(sprite, 384 + (256 * 8))
  end
  assert_eq(sprite.bitmap.blits[0][:rect], [0, 0, 32, 32], 'legacy: page 2 rect starts at y 0')

  # The old wrap raised "Tileset is too long!" well before this size.
  huge = CustomTilemap.new
  assert_quiet('legacy: a 300000px tileset no longer raises') do
    huge.tileset = Bitmap.new(256, 300_000)
  end
  sheet = huge.mkxp_tileset_sheet
  assert_eq(sheet.bitmaps.length, 37, 'legacy: 300000px splits into 37 pages')
  assert_quiet('legacy: drawing from the far end of a 300000px tileset') do
    huge.getRegularTile(Sprite.new, 384 + (9000 * 8))
  end
end

def scenario_small_gpu
  # A device that only allows 1024px textures. The old fold ceiling
  # was 4096px of tileset here. Paging has no ceiling.
  $max_texture_size = 1024
  define_renderer!
  define_helper!
  load_patch

  source = Bitmap.new(256, 25600)
  $tileset_files['huge'] = source
  renderer = TilemapRenderer.new
  assert_quiet('small gpu: a 25600px tileset loads on a 1024px limit') do
    renderer.tilesets.add('huge')
  end
  sheet = renderer.tilesets.mkxp_sheets['huge']
  assert_eq(sheet.bitmaps.length, 25, 'small gpu: 25600px over 1024 needs 25 pages')
  assert_eq(sheet.bitmaps.map(&:height).uniq, [1024], 'small gpu: page heights follow the limit')

  tile = new_tile('huge')
  renderer.tilesets.set_src_rect(tile, tile_id_for(0, 32))
  assert_eq(tile.bitmap.equal?(sheet.bitmaps[1]), true, 'small gpu: row 32 lands on page 2')
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'small gpu: page 2 restarts y at 0')

  # 48 tile shapes * 32px = 1536px, taller than a 1024px texture, so
  # the expander splits each frame over two columns. The patch has to
  # carry that layout through paging.
  $autotile_files['sea'] = Bitmap.new(96 * 4, 128)
  renderer.autotiles.add('sea')
  auto_sheet = renderer.autotiles.mkxp_sheets['sea']
  assert_eq(auto_sheet.wraps?, true, 'small gpu: the expander used the two-column layout')
  assert_eq(renderer.autotiles.frame_count('sea'), 4, 'small gpu: frames counted once, not twice')

  tile = new_tile('sea', true)
  renderer.autotiles.force_frame('sea', 1)
  renderer.autotiles.set_src_rect(tile, 48 + 24)
  assert_eq(tile.src_rect.to_a, [96, 0, 32, 32], 'small gpu: the high shape uses the second column')
end

def scenario_no_helper
  # Not every fork ships a TileDrawingHelper. The watcher must still
  # stop, or it stays enabled for the whole session. The renderer is
  # NOT hooked for this: patching its initialize is what made Pokemon
  # Nova recurse, so the frame signal does the job instead.
  load_patch
  define_renderer!
  assert_eq(MKXPTilesetPatch.done?, false, 'no helper: the second target never appears')

  tracer = MKXPTilesetPatch.instance_variable_get(:@tracer)
  assert_eq(tracer.enabled?, true, 'no helper: the watcher is still waiting')

  renderer = TilemapRenderer.new(:viewport)
  assert_eq(renderer.viewport, :viewport, 'no helper: initialize is left alone')
  assert_eq(TilemapRenderer.private_method_defined?(:mkxp_original_initialize), false,
            'no helper: the patch does not wrap initialize at all')

  # One frame only records the count. The next quiet frame concludes
  # that loading is over.
  Graphics.update
  assert_eq(tracer.enabled?, true, 'no helper: one frame alone concludes nothing')
  Graphics.update
  assert_eq(tracer.enabled?, false, 'no helper: a quiet frame stops the watcher')

  # The renderer must still work with the watcher off.
  $tileset_files['jail'] = Bitmap.new(384, 12000)
  assert_quiet('no helper: the tileset patch is live') { renderer.tilesets.add('jail') }
  tile = new_tile('jail')
  renderer.tilesets.set_src_rect(tile, tile_id_for(0, 256))
  assert_eq(tile.src_rect.to_a, [0, 0, 32, 32], 'no helper: paging still works')
end

def scenario_watcher_stops_legacy
  # Essentials v17/v18 with a loose script loader: the newer renderer
  # never appears, so the watcher has to recognise the old one.
  load_patch
  tracer = MKXPTilesetPatch.instance_variable_get(:@tracer)
  assert_eq(tracer.enabled?, true, 'legacy watcher: it starts out waiting')

  define_legacy!
  assert_eq(tracer.enabled?, false, 'legacy watcher: CustomTilemap stops it')
  assert_eq(MKXPTilesetPatch.done?, false, 'legacy watcher: nothing was patched')
end

def scenario_watcher_stops_plain
  # A plain RPG Maker game: neither renderer will ever be defined. The
  # watcher cannot wait forever, so it stops at the first drawn frame
  # that brought no new class body with it.
  load_patch
  tracer = MKXPTilesetPatch.instance_variable_get(:@tracer)
  assert_eq(tracer.enabled?, true, 'plain watcher: it starts out waiting')

  # A loader that draws while it still defines classes must keep the
  # watcher alive, or a late renderer would be missed.
  2.times do
    eval('class LoaderProgress; end', TOPLEVEL_BINDING) # rubocop:disable Security/Eval
    Graphics.update
    assert_eq(tracer.enabled?, true, 'plain watcher: loading frames keep it alive')
  end

  Graphics.update
  assert_eq(tracer.enabled?, false, 'plain watcher: a quiet frame stops it')
  assert_eq(MKXPTilesetPatch.done?, false, 'plain watcher: nothing was patched')

  before = Graphics::FRAMES.length
  assert_quiet('plain watcher: the frame wrapper stays harmless') { 3.times { Graphics.update } }
  assert_eq(Graphics::FRAMES.length - before, 3, 'plain watcher: frames still reach the engine')
end

def scenario_real_max_size
  # A game raised Bitmap.max_size past the hardware limit. Pages must
  # follow the hardware, or every page comes back as a mega surface.
  $max_texture_size = 16_384
  $real_texture_size = 8192
  define_renderer!
  define_helper!
  load_patch

  assert_eq(MKXPTilePages.texture_limit, 8192, 'real limit: the truth wins over the claim')

  renderer = TilemapRenderer.new(:viewport)
  $tileset_files['claimed'] = Bitmap.new(256, 25_600)
  renderer.tilesets.add('claimed')
  sheet = renderer.tilesets.mkxp_sheets['claimed']
  assert_eq(sheet.bitmaps.map(&:height), [8192, 8192, 8192, 1024],
            'real limit: pages are cut to the hardware size')
  assert_eq(sheet.bitmaps.any?(&:mega?), false, 'real limit: no page is a mega surface')

  # Without the accessor, the patch can only trust max_size.
  $real_texture_size = nil
  assert_eq(MKXPTilePages.texture_limit, 16_384, 'real limit: falls back when unavailable')
end

#===============================================================================

def run_all
  if SCENARIOS.empty?
    warn 'no scenario registered'
    exit 1
  end

  results = SCENARIOS.map do |name|
    puts "== #{name}"
    [name, system(RbConfig.ruby, __FILE__, name)]
  end
  failed = results.reject { |_name, ok| ok }.map(&:first)
  if failed.empty?
    puts "\nall #{SCENARIOS.length} scenarios passed"
    exit 0
  end
  warn "\nfailed scenarios: #{failed.join(', ')}"
  exit 1
end

case ARGV[0]
when nil        then run_all
when 'immediate' then scenario_immediate
when 'deferred'  then scenario_deferred
when 'no_helper' then scenario_no_helper
when 'legacy'    then scenario_legacy
when 'small_gpu' then scenario_small_gpu
when 'watcher_stops_legacy' then scenario_watcher_stops_legacy
when 'watcher_stops_plain'  then scenario_watcher_stops_plain
when 'real_max_size'        then scenario_real_max_size
else
  warn "unknown scenario #{ARGV[0].inspect}"
  exit 1
end

report(ARGV[0])
