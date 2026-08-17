# pokemon_tilemap_fix.rb
# Removes the tileset size limit in Pokemon Essentials map renderers.
#
# Parts of the CustomTilemap patch come from Zoro (inori-z fork,
# EssentialsCompatibility.rb).
# Source: https://github.com/joiplay/android-mkxp
# License: GPL-2.0 (same as mkxp-z)
#
# A GPU can only hold a texture up to GL_MAX_TEXTURE_SIZE on a side
# (8192 on many iOS devices and on the simulator, 16384 on newer
# ones). A tileset that is taller than that becomes a "mega surface":
# a CPU-only bitmap that no sprite can show and that every blit reads
# through system memory. Pokemon Essentials games ship tilesets of
# 25000px and more, so this is a common failure.
#
# Both Essentials renderers try to solve this with the same trick:
# they wrap the excess height into more columns. The trick has two
# hard limits. It only accepts tilesets that are exactly 8 tiles
# wide, and the wrapped result must still fit in one texture. Above
# that, the renderers either raise or (worse) keep a disposed bitmap
# and crash later with "disposed bitmap".
#
# This file replaces the wrap with paging. The tileset is cut into a
# grid of pages, and each page is a texture of a size the GPU accepts.
# A tile lookup gives the page plus the position in that page, so a
# tileset of any width and any height works on any device. Animated
# autotiles are paged the same way, by frame.
#
# Pixels beyond the eighth tile column are dropped, because RMXP tile
# ids cannot address them. That keeps the memory cost proportional to
# the part of the tileset the game can actually show.

# Global flag: set to true to disable autotile animation refreshes.
# Saves CPU on low-end devices at the cost of static water/lava tiles.
$DONTREFRESHAUTOTILES = false unless defined?($DONTREFRESHAUTOTILES)

#===============================================================================
# Sheets: one oversized bitmap, stored as a grid of GPU-sized pages.
#===============================================================================
module MKXPTilePages
  # Size a page may reach. `Bitmap.max_size` is not always the hardware
  # limit: a game's mkxp.json can raise it, because the engine allows
  # oversized work buffers there. A texture built at the raised size
  # then draws as black. `Bitmap.real_max_size` reports what the GPU
  # truly accepts. Older engine builds do not have it.
  def self.texture_limit
    return Bitmap.real_max_size if Bitmap.respond_to?(:real_max_size)

    Bitmap.max_size
  end

  # Largest page edge that still holds a whole number of tiles. A page
  # boundary must fall on a tile boundary, or a tile would be split
  # over two pages and no single blit could draw it.
  def self.page_limit(unit)
    limit = texture_limit
    limit -= limit % unit if unit > 0
    limit = unit if limit < unit
    limit
  end

  # Report a condition once per subject. Called from tile lookups, so
  # it must stay cheap when it has nothing to say.
  def self.warn_once(key, message)
    @warned ||= {}
    return if @warned[key]

    @warned[key] = true
    MKXP.puts(message)
  end

  # An image addressed as one big surface, stored as several textures.
  # `size` and `page_size` are [width, height] pairs.
  class Sheet
    attr_reader :bitmaps, :width, :height, :page_width, :page_height, :columns

    def initialize(bitmaps, size, page_size, copied)
      @bitmaps = bitmaps
      @width = size[0]
      @height = size[1]
      @page_width = page_size[0]
      @page_height = page_size[1]
      @columns = ((@width - 1) / @page_width) + 1
      @copied = copied
    end

    # True if the pages are new bitmaps. The source is then free, and
    # the caller must dispose it. False means this sheet IS the source,
    # so the caller must keep it.
    def copied?
      @copied
    end

    def first
      @bitmaps[0]
    end

    def disposed?
      @bitmaps.empty? || !@bitmaps[0] || @bitmaps[0].disposed?
    end

    # Give the page that holds a pixel, and the position in that page.
    def locate(x, y)
      return nil if x < 0 || y < 0 || x >= @width || y >= @height

      bitmap = @bitmaps[((y / @page_height) * @columns) + (x / @page_width)]
      return nil if !bitmap || bitmap.disposed?

      [bitmap, x % @page_width, y % @page_height]
    end

    # Draw a source rectangle into `dest`. The rectangle can cross page
    # borders, so the copy runs one page piece at a time.
    def blit_to(dest, dest_x, dest_y, rect)
      right = rect.x + rect.width
      x = rect.x
      while x < right
        step_x = blit_column(dest, dest_x, dest_y, rect, x)
        return if step_x <= 0

        x += step_x
      end
    end

    def dispose
      @bitmaps.each { |bitmap| bitmap.dispose if bitmap && !bitmap.disposed? }
      @bitmaps = []
    end

    private

    # Copy the part of the rectangle that starts at column `x`. Gives
    # the width copied, or 0 if nothing could be found.
    def blit_column(dest, dest_x, dest_y, rect, x)
      bottom = rect.y + rect.height
      step_x = 0
      y = rect.y
      while y < bottom
        spot = locate(x, y)
        return 0 unless spot

        step_x = [@page_width - spot[1], rect.x + rect.width - x].min
        step_y = [@page_height - spot[2], bottom - y].min
        dest.blt(dest_x + x - rect.x, dest_y + y - rect.y, spot[0],
                 Rect.new(spot[1], spot[2], step_x, step_y))
        y += step_y
      end
      step_x
    end
  end

  # Cut `source` into pages. `keep_width` drops the columns that tile
  # ids cannot reach. Pass nil to keep the full width. `unit_w` and
  # `unit_h` are the tile size the cuts must align to.
  #
  # A bitmap that already fits becomes a one-page sheet over the source
  # itself, so the common case costs no memory and no copy.
  def self.split(source, keep_width, unit_w, unit_h)
    width = source.width
    width = keep_width if keep_width && keep_width < width
    size = [width, source.height]
    page_size = [page_limit(unit_w), page_limit(unit_h)]
    if !source.mega? && width <= page_size[0] && size[1] <= page_size[1]
      return Sheet.new([source], size, page_size, false)
    end

    Sheet.new(cut_pages(source, size, page_size), size, page_size, true)
  end

  def self.cut_pages(source, size, page_size)
    columns = ((size[0] - 1) / page_size[0]) + 1
    rows = ((size[1] - 1) / page_size[1]) + 1
    bitmaps = []
    rows.times do |row|
      columns.times { |column| bitmaps.push(cut_page(source, size, page_size, [column, row])) }
    end
    bitmaps
  end

  # Copy one page out of the source. `cell` is the [column, row] of the
  # page in the grid.
  def self.cut_page(source, size, page_size, cell)
    x = cell[0] * page_size[0]
    y = cell[1] * page_size[1]
    width = [page_size[0], size[0] - x].min
    height = [page_size[1], size[1] - y].min
    page = Bitmap.new(width, height)
    page.blt(0, 0, source, Rect.new(x, y, width, height))
    page
  end

  # An expanded autotile, stored as several textures. Autotiles grow
  # sideways (one column of 48 tile shapes per animation frame), so
  # they are paged by frame.
  class AutotileSheet
    attr_reader :bitmaps, :frames

    def initialize(bitmaps, frames, frames_per_page, copied, wraps)
      @bitmaps = bitmaps
      @frames = frames
      @frames_per_page = frames_per_page
      @copied = copied
      @wraps = wraps
    end

    def copied?
      @copied
    end

    # True if each frame takes two columns because a full 48-tile
    # column does not fit in one texture.
    def wraps?
      @wraps
    end

    def first
      @bitmaps[0]
    end

    def disposed?
      @bitmaps.empty? || !@bitmaps[0] || @bitmaps[0].disposed?
    end

    # Give the page that holds a frame, and the frame number in it.
    def frame_page(frame)
      return nil if frame < 0 || frame >= @frames

      bitmap = @bitmaps[frame / @frames_per_page]
      return nil if !bitmap || bitmap.disposed?

      [bitmap, frame % @frames_per_page]
    end

    def dispose
      @bitmaps.each { |bitmap| bitmap.dispose if bitmap && !bitmap.disposed? }
      @bitmaps = []
    end
  end
end

#===============================================================================
# Where a tile sits: the geometry the modern renderer patch works from.
#===============================================================================
module MKXPTileLayout
  # Width a tile id can reach: 8 tile columns for a stock renderer.
  def self.tileset_width
    TilemapRenderer::SOURCE_TILE_WIDTH * TilemapRenderer::TILESET_TILES_PER_ROW
  end

  def self.split_tileset(source)
    MKXPTilePages.split(source, tileset_width,
                        TilemapRenderer::SOURCE_TILE_WIDTH,
                        TilemapRenderer::SOURCE_TILE_HEIGHT)
  end

  # Expand an autotile into pages of animation frames.
  #
  # The expansion itself stays with the game: AutotileExpander turns
  # the 3-tile-wide source layout into the 48 tile shapes the renderer
  # reads, and forks change that layout. So each page is built by
  # cutting a run of frames out of the source and giving that run to
  # the game's own expander.
  def self.expand_autotile(source)
    expander = autotile_expander
    tile_width = TilemapRenderer::SOURCE_TILE_WIDTH
    # A 32px tall autotile is a single tile with its frames side by
    # side. Anything taller uses the 3-tile-wide source layout.
    single = (source.height == TilemapRenderer::SOURCE_TILE_HEIGHT)
    frame_width = single ? tile_width : tile_width * 3
    frames = source.width / frame_width
    frames = 1 if frames < 1
    per_page = frames_per_page(frame_width, single)
    if !expander || frames <= per_page
      page = expander ? expander.expand(source) : source
      return MKXPTilePages::AutotileSheet.new([page], frames, [per_page, frames].max,
                                              !page.equal?(source), wraps?(page))
    end

    pages = expand_in_runs(source, expander, frame_width, [frames, per_page])
    MKXPTilePages::AutotileSheet.new(pages, frames, per_page, true, wraps?(pages[0]))
  end

  # Expand the autotile a run of frames at a time. `counts` is the
  # [total frames, frames per page] pair.
  def self.expand_in_runs(source, expander, frame_width, counts)
    pages = []
    index = 0
    while index < counts[0]
      count = [counts[1], counts[0] - index].min
      chunk = Bitmap.new(count * frame_width, source.height)
      chunk.blt(0, 0, source, Rect.new(index * frame_width, 0,
                                       count * frame_width, source.height))
      page = expander.expand(chunk)
      chunk.dispose unless page.equal?(chunk)
      pages.push(page)
      index += count
    end
    pages
  end

  # AutotileExpander lives in a later script file than the renderer, so
  # it can be missing while the patch installs. It is only needed when
  # an autotile loads, which happens much later.
  def self.autotile_expander
    return nil unless TilemapRenderer.const_defined?(:AutotileExpander)

    TilemapRenderer::AutotileExpander
  end

  # Frames per page. Both the source cut and the expanded page must
  # stay inside one texture, so the smaller of the two rules wins.
  def self.frames_per_page(frame_width, single)
    tile_width = TilemapRenderer::SOURCE_TILE_WIDTH
    expanded_width = tile_width
    expanded_width *= 2 if !single && wrapped_layout?
    limit = MKXPTilePages.texture_limit
    [[limit / expanded_width, limit / frame_width].min, 1].max
  end

  # AutotileExpander splits each frame over two columns when a full
  # 48-tile column is taller than one texture.
  def self.wrapped_layout?
    expander = autotile_expander
    limit = if expander && expander.const_defined?(:MAX_TEXTURE_SIZE)
              expander::MAX_TEXTURE_SIZE
            else
              (Bitmap.max_size / 1024) * 1024
            end
    limit < TilemapRenderer::TILES_PER_AUTOTILE * TilemapRenderer::SOURCE_TILE_HEIGHT
  end

  def self.wraps?(page)
    return false unless page

    page.height > TilemapRenderer::SOURCE_TILE_HEIGHT &&
      page.height < TilemapRenderer::TILES_PER_AUTOTILE * TilemapRenderer::SOURCE_TILE_HEIGHT
  end

  # Where a tile id sits in the tileset image.
  def self.tile_position(tile_id)
    index = tile_id - TilemapRenderer::TILESET_START_ID
    per_row = TilemapRenderer::TILESET_TILES_PER_ROW
    [(index % per_row) * TilemapRenderer::SOURCE_TILE_WIDTH,
     (index / per_row) * TilemapRenderer::SOURCE_TILE_HEIGHT]
  end

  # Art past the addressable columns is unreachable through tile ids,
  # so paging drops it. Say so once: a game author looking for missing
  # decoration has no other way to find out.
  def self.report_crop(filename, source, sheet)
    return if !sheet.copied? || source.width <= sheet.width

    MKXPTilePages.warn_once(
      "crop:#{filename}",
      "[tile-pages] #{filename}: using #{sheet.width}px of #{source.width}px " \
      "(tile ids reach #{TilemapRenderer::TILESET_TILES_PER_ROW} columns)"
    )
  end

  # Where a tile sits in a bitmap that was never paged.
  def self.unpaged_spot(bitmap, tile_id)
    return nil unless bitmap

    [bitmap] + tile_position(tile_id)
  end

  # A blank tile is otherwise indistinguishable from map art, so say
  # once that the map asked for a tile the tileset does not have.
  def self.report_out_of_range(filename, tile_id)
    MKXPTilePages.warn_once(
      "range:#{filename}",
      "[tile-pages] #{filename}: tile id #{tile_id} is past the tileset, hidden"
    )
  end

  # The page that holds a tile id, and the position in that page.
  def self.tile_spot(sheet, tile_id)
    return nil unless sheet

    spot = tile_position(tile_id)
    sheet.locate(spot[0], spot[1])
  end

  # Point the tile at one of the 48 shapes in the frame `spot` holds.
  def self.set_autotile_rect(tile, tile_id, spot, wraps)
    page = spot[0]
    frame = spot[1]
    tile_width = TilemapRenderer::SOURCE_TILE_WIDTH
    tile_height = TilemapRenderer::SOURCE_TILE_HEIGHT
    per_autotile = TilemapRenderer::TILES_PER_AUTOTILE
    x = 0
    y = 0
    if page.height == tile_height
      # Single tile autotile: the frames sit side by side.
      x = frame * tile_width
    else
      y = (tile_id % per_autotile) * tile_height
      if wraps && (tile_id % per_autotile) >= per_autotile / 2
        x = tile_width
        y -= tile_height * per_autotile / 2
      end
      x += frame * tile_width * (wraps ? 2 : 1)
    end
    tile.src_rect.set(x, y, tile_width, tile_height)
  end
end

#===============================================================================
# Modern renderer (Essentials v19 and later): TilemapRenderer.
#
# TilesetBitmaps and AutotileBitmaps hand a bitmap plus a source
# rectangle to one sprite per tile. Paging fits that model directly:
# the tile sprite points at the page that holds its tile.
#===============================================================================
module MKXPTilesetPatch
  @renderer_done = false
  @helper_done = false
  @tracer = nil

  def self.done?
    @renderer_done && @helper_done
  end

  def self.renderer_ready?
    return false if defined?(TilemapRenderer) != 'constant'
    return false unless TilemapRenderer.const_defined?(:TilesetBitmaps)
    return false unless TilemapRenderer.const_defined?(:AutotileBitmaps)

    # `dispose` comes last in the class body, so this also tells us
    # that both nested classes are complete.
    TilemapRenderer.method_defined?(:dispose)
  end

  # The helper patch reads TilemapRenderer's constants, and older
  # Essentials ships a different TileDrawingHelper, so wait for the
  # renderer as well.
  def self.helper_ready?
    return false unless renderer_ready?
    return false if defined?(TileDrawingHelper) != 'constant'

    TileDrawingHelper.method_defined?(:bltSmallRegularTile)
  end

  def self.install
    install_renderer if !@renderer_done && renderer_ready?
    install_helper if !@helper_done && helper_ready?
  end

  # Essentials v17/v18 ships CustomTilemap instead. Once it appears,
  # the newer renderer will never come, so there is nothing to wait for.
  def self.legacy_renderer?
    defined?(CustomTilemap) == 'constant'
  end

  # The renderer classes may not exist yet. Games with a loose script
  # loader (their Scripts.rxdata only reads .rb files from disk) define
  # every class after this postload runs. Watch for the end of a class
  # body and patch as soon as the renderer is complete.
  def self.install_deferred
    return if defined?(TracePoint) != 'constant'
    return if legacy_renderer?

    @seen = 0
    @seen_at_frame = -1
    @tracer = TracePoint.new(:end) do |_event|
      begin
        @seen += 1
        install
        stop_watching if done? || legacy_renderer?
      rescue StandardError => e
        stop_watching
        MKXP.puts("[tile-pages] deferred patch failed: #{e.class}: #{e.message}")
      end
    end
    @tracer.enable
    watch_frames
  end

  # Most games never define the newer renderer, and the watcher cannot
  # tell "not yet" from "never" on its own. Loading is a tight eval
  # loop that draws nothing, so the first frame that arrives with no
  # new class body means the game has finished loading its scripts.
  # This wrapper only exists for games that made us wait.
  def self.watch_frames
    singleton = (class << Graphics; self; end)
    return if singleton.method_defined?(:mkxp_tile_pages_update)

    singleton.send(:alias_method, :mkxp_tile_pages_update, :update)
    singleton.send(:define_method, :update) do
      MKXPTilesetPatch.frame_tick
      mkxp_tile_pages_update
    end
  end

  # Runs once per drawn frame while the watcher waits, then goes inert.
  def self.frame_tick
    return if !@tracer || !@tracer.enabled?

    stop_watching if @seen == @seen_at_frame
    @seen_at_frame = @seen
  end

  # Most games never define the newer renderer, so the watcher has to
  # stop on its own. Leaving a TracePoint enabled for a whole session
  # keeps the VM on its tracing path and would grow into a real cost
  # if a game builds classes inside its frame loop.
  def self.stop_watching
    @tracer.disable if @tracer && @tracer.enabled?
  end

  def self.install_renderer
    @renderer_done = true
    patch_tileset_bitmaps(TilemapRenderer::TilesetBitmaps)
    patch_autotile_bitmaps(TilemapRenderer::AutotileBitmaps)
    patch_renderer_dispose(TilemapRenderer)
    MKXP.puts('[tile-pages] TilemapRenderer patched: tileset size is unlimited')
  end

  # `define_method` bodies are method bodies, not iterator blocks, so
  # `return` here exits the patched method. Rubocop cannot tell the two
  # apart.
  # rubocop:disable Lint/NonLocalExitFromIterator
  # These replace the class's own methods and keep the original under an
  # alias. Module#prepend would read better, but RGSS plugins extend by
  # `alias`: a plugin that aliases a prepended method and then calls
  # that alias re-enters our `super` and recurses forever. Pokemon Nova
  # dies on its first map that way. Alias chaining is the idiom this
  # ecosystem composes with, so the patch uses it too.
  def self.patch_tileset_bitmaps(klass)
    patch_sheet_store(klass)
    patch_tileset_add(klass)
    patch_tileset_remove(klass)
    patch_tileset_src_rect(klass)
  end

  def self.patch_sheet_store(klass)
    klass.send(:define_method, :mkxp_sheets) do
      @mkxp_sheets ||= {}
    end

    klass.send(:define_method, :mkxp_dispose_sheets) do
      mkxp_sheets.each_value(&:dispose)
      mkxp_sheets.clear
    end
  end

  def self.patch_tileset_add(klass)
    klass.send(:define_method, :add) do |filename|
      return if nil_or_empty?(filename)

      if @bitmaps[filename]
        @load_counts[filename] += 1
        return
      end
      source = pbGetTileset(filename)
      sheet = MKXPTileLayout.split_tileset(source)
      MKXPTileLayout.report_crop(filename, source, sheet)
      source.dispose if sheet.copied?
      mkxp_sheets[filename] = sheet
      self[filename] = sheet.first
      @load_counts[filename] = 1
    end
  end

  def self.patch_tileset_remove(klass)
    klass.send(:define_method, :remove) do |filename|
      return if nil_or_empty?(filename) || !@bitmaps[filename]

      if @load_counts[filename] > 1
        @load_counts[filename] -= 1
        return
      end
      sheet = mkxp_sheets.delete(filename)
      sheet.dispose if sheet
      @bitmaps[filename].dispose unless @bitmaps[filename].disposed?
      @bitmaps.delete(filename)
      @bitmap_wraps.delete(filename)
      @load_counts.delete(filename)
    end
  end

  def self.patch_tileset_src_rect(klass)
    klass.send(:define_method, :set_src_rect) do |tile, tile_id|
      return if nil_or_empty?(tile.filename)

      sheet = mkxp_sheets[tile.filename]
      spot = MKXPTileLayout.tile_spot(sheet, tile_id)
      # A bitmap put in directly, without `add`, has no sheet. It came
      # from the game, so it fits in one texture already.
      spot ||= MKXPTileLayout.unpaged_spot(@bitmaps[tile.filename], tile_id) unless sheet
      # The map asks for a tile the tileset does not have. Show
      # nothing rather than a piece of another tile.
      unless spot
        MKXPTileLayout.report_out_of_range(tile.filename, tile_id) if sheet
        tile.visible = false
        return
      end
      # Setting the bitmap resets src_rect to the whole page, so all
      # four values go in after it.
      tile.bitmap = spot[0] if tile.bitmap != spot[0]
      tile.src_rect.set(spot[1], spot[2], TilemapRenderer::SOURCE_TILE_WIDTH,
                        TilemapRenderer::SOURCE_TILE_HEIGHT)
    end
  end

  def self.patch_autotile_bitmaps(klass)
    patch_autotile_add(klass)
    patch_autotile_frame_count(klass)
    patch_autotile_src_rect(klass)
  end

  def self.patch_autotile_add(klass)
    klass.send(:define_method, :add) do |filename|
      return if nil_or_empty?(filename)

      if @bitmaps[filename]
        @load_counts[filename] += 1
        return
      end
      source = pbGetAutotile(filename)
      duration = TilemapRenderer::AUTOTILE_FRAME_DURATION
      duration = Regexp.last_match(1).to_i if filename[/\[\s*(\d+?)\s*\]\s*$/]
      @frame_durations[filename] = duration.to_f / 20
      sheet = MKXPTileLayout.expand_autotile(source)
      source.dispose if sheet.copied?
      mkxp_sheets[filename] = sheet
      # `[]=` recounts the frames, so the sheet goes in first.
      self[filename] = sheet.first
      @bitmap_wraps[filename] = sheet.wraps?
      @load_counts[filename] = 1
    end
  end

  def self.patch_autotile_frame_count(klass)
    # Optional arguments are not allowed in a block on Ruby 1.8, so the
    # (filename, force_recalc) pair arrives as a list.
    klass.send(:define_method, :frame_count) do |*args|
      filename = args[0]
      sheet = mkxp_sheets[filename]
      return sheet.frames if sheet
      return @frame_counts[filename] if @frame_counts[filename] && !args[1]
      return 0 unless @bitmaps[filename]

      bitmap = @bitmaps[filename]
      count = [bitmap.width / TilemapRenderer::SOURCE_TILE_WIDTH, 1].max
      count /= 2 if bitmap.height > TilemapRenderer::SOURCE_TILE_HEIGHT && @bitmap_wraps[filename]
      @frame_counts[filename] = count
    end
  end

  def self.patch_autotile_src_rect(klass)
    klass.send(:define_method, :set_src_rect) do |tile, tile_id|
      return if nil_or_empty?(tile.filename)

      sheet = mkxp_sheets[tile.filename]
      # A bitmap put in directly, without `add`, is already expanded
      # and fits in one texture.
      spot = if sheet
               sheet.frame_page(current_frame(tile.filename))
             else
               [@bitmaps[tile.filename], current_frame(tile.filename)]
             end
      return if !spot || !spot[0]

      tile.bitmap = spot[0] if tile.bitmap != spot[0]
      wraps = sheet ? sheet.wraps? : @bitmap_wraps[tile.filename]
      MKXPTileLayout.set_autotile_rect(tile, tile_id, spot, wraps)
    end
  end

  # The renderer only disposes the bitmaps it knows about, which is one
  # page per tileset. Free the rest with them.
  def self.patch_renderer_dispose(klass)
    return if klass.method_defined?(:mkxp_original_dispose)

    klass.send(:alias_method, :mkxp_original_dispose, :dispose)
    klass.send(:define_method, :dispose) do
      return if disposed?

      @tilesets.mkxp_dispose_sheets if @tilesets.respond_to?(:mkxp_dispose_sheets)
      @autotiles.mkxp_dispose_sheets if @autotiles.respond_to?(:mkxp_dispose_sheets)
      mkxp_original_dispose
    end
  end

  # TileDrawingHelper draws the town map and the minimap. It reads the
  # tileset through blits instead of sprites, but it hits the same size
  # limit, and it also disposes a tileset it did not copy.
  def self.install_helper
    @helper_done = true
    patch_helper_initialize(TileDrawingHelper)
    patch_helper_blit(TileDrawingHelper)
    patch_helper_dispose(TileDrawingHelper)
    MKXP.puts('[tile-pages] TileDrawingHelper patched')
  end

  def self.patch_helper_initialize(klass)
    klass.send(:define_method, :initialize) do |tileset, autotiles|
      @mkxp_sheet = MKXPTileLayout.split_tileset(tileset)
      tileset.dispose if @mkxp_sheet.copied?
      @tileset = @mkxp_sheet.first
      @autotiles = autotiles
    end
  end

  def self.patch_helper_blit(klass)
    # rubocop:disable Metrics/ParameterLists -- PE's own signature
    klass.send(:define_method, :bltSmallRegularTile) do |bitmap, x, y, cx_tile, cy_tile, id|
      return if id < TilemapRenderer::TILESET_START_ID
      return if !@mkxp_sheet || @mkxp_sheet.disposed?

      spot = MKXPTileLayout.tile_spot(@mkxp_sheet, id)
      return unless spot

      bitmap.stretch_blt(Rect.new(x, y, cx_tile, cy_tile), spot[0],
                         Rect.new(spot[1], spot[2],
                                  TilemapRenderer::SOURCE_TILE_WIDTH,
                                  TilemapRenderer::SOURCE_TILE_HEIGHT))
    end
    # rubocop:enable Metrics/ParameterLists
  end

  def self.patch_helper_dispose(klass)
    klass.send(:define_method, :dispose) do
      @mkxp_sheet.dispose if @mkxp_sheet
      @mkxp_sheet = nil
      @tileset = nil
      @autotiles.each_with_index do |autotile, i|
        autotile.dispose if autotile && !autotile.disposed?
        @autotiles[i] = nil
      end
    end
  end
  # rubocop:enable Lint/NonLocalExitFromIterator
end

#===============================================================================
# Legacy renderer (Essentials v17 and v18): CustomTilemap.
#
# This renderer draws the ground layer by blitting tiles into one big
# bitmap, so it only needs the paged sheet as a blit source.
#===============================================================================
module VWrap
  TILESET_WIDTH = 0x100
  TILE_UNIT     = 32
end

# A game can also ship this wrap technique inside its own CustomTilemap
# (Fire Ash bundles a TileWrap module that reads Bitmap.max_size). Such a
# tilemap is already mobile-safe, and it diverges from stock Essentials
# in more than the wrap math. An override from this file would drop the
# game-side changes, so skip the patch for these games.
# Match two module functions, not one. The pair is a fingerprint of
# that known wrap script. A single name could collide with an
# unrelated game module.
game_wraps_own_tilesets = $MKXP == true &&
                          defined?(TileWrap) == 'constant' &&
                          TileWrap.respond_to?(:wrapTileset) &&
                          TileWrap.respond_to?(:blitWrappedPixels)
MKXP.puts('VWrap: skipped, this game wraps its own tilesets') if game_wraps_own_tilesets

# Only patch if this is an mkxp engine AND the game defines CustomTilemap
# (i.e. Pokemon Essentials). Standard RPG Maker games use the native C++
# Tilemap which already handles mega surfaces via atlas building.
if $MKXP == true && defined?(CustomTilemap) == 'constant' && !game_wraps_own_tilesets
  # rubocop:disable Metrics/ClassLength -- this reopens PE's own class,
  # and the length comes from PE's refreshLayer0, which is copied here
  # so that the tileset reads can go through the paged sheet.
  class CustomTilemap
    def tileset=(value)
      sheet = MKXPTilePages.split(value, VWrap::TILESET_WIDTH, VWrap::TILE_UNIT, VWrap::TILE_UNIT)
      value.dispose if sheet.copied?
      @mkxp_sheet = sheet
      @mkxp_sheet_source = sheet.first
      @tileset = sheet.first
      @tilesetchanged = true
    end

    # The game can also assign @tileset on its own. Page whatever is
    # there now, and rebuild if it changed behind our back.
    def mkxp_tileset_sheet
      return nil if !@tileset || @tileset.disposed?

      if !@mkxp_sheet || @mkxp_sheet.disposed? || !@mkxp_sheet_source.equal?(@tileset)
        @mkxp_sheet = MKXPTilePages.split(@tileset, VWrap::TILESET_WIDTH,
                                          VWrap::TILE_UNIT, VWrap::TILE_UNIT)
        @mkxp_sheet_source = @tileset
      end
      @mkxp_sheet
    end

    def getRegularTile(sprite, id)
      bitmap = @regularTileInfo[id]
      unless bitmap
        sheet = mkxp_tileset_sheet
        return unless sheet

        bitmap = Bitmap.new(@tileWidth, @tileHeight)
        rect = Rect.new(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                        @tileSrcWidth, @tileSrcHeight)
        sheet.blit_to(bitmap, 0, 0, rect)
        @regularTileInfo[id] = bitmap
      end
      sprite.bitmap = bitmap if sprite.bitmap != bitmap
    end

    # Stock Essentials sets the Animated_Autotiles_Frames constant. Some
    # games replace it with an instance method (Fire Ash defines
    # animated_Autotiles_Frames). Read whichever form exists. Without
    # this fallback, the bare constant resolves to IOS::NullStub through
    # const_missing, and the integer division raises a coerce TypeError.
    def autotileFrameInterval
      return animated_Autotiles_Frames if respond_to?(:animated_Autotiles_Frames)
      return Animated_Autotiles_Frames if defined?(Animated_Autotiles_Frames)

      15
    end

    def repaintAutotiles
      return if $DONTREFRESHAUTOTILES

      (0...@autotileInfo.length).each do |i|
        next unless @autotileInfo[i]

        frame = autotileFrame(i)
        @autotileInfo[i].clear
        bltAutotile(@autotileInfo[i], 0, 0, i, frame)
      end
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockNesting, Naming/PredicateMethod
    # PE's tile-rendering loop. The complexity is intrinsic to the
    # original algorithm. Refactoring would deviate from the upstream
    # CustomTilemap behaviour PE games rely on.
    def refreshLayer0(autotiles = false)
      return true if autotiles && !shown?

      pt_x = @ox - @oxLayer0
      pt_y = @oy - @oyLayer0
      if !autotiles && !@firsttime && !@usedsprites &&
         pt_x >= 0 && pt_x + @viewport.rect.width <= @layer0.bitmap.width &&
         pt_y >= 0 && pt_y + @viewport.rect.height <= @layer0.bitmap.height
        if @layer0clip && @viewport.ox.zero? && @viewport.oy.zero?
          @layer0.ox = 0
          @layer0.oy = 0
          @layer0.src_rect.set(pt_x.round, pt_y.round,
                               @viewport.rect.width, @viewport.rect.height)
        else
          @layer0.ox = pt_x.round
          @layer0.oy = pt_y.round
          @layer0.src_rect.set(0, 0, @layer0.bitmap.width, @layer0.bitmap.height)
        end
        return true
      end
      width = @layer0.bitmap.width
      height = @layer0.bitmap.height
      bitmap = @layer0.bitmap
      sheet = mkxp_tileset_sheet
      ysize = @map_data.ysize
      xsize = @map_data.xsize
      zsize = @map_data.zsize
      twidth = @tileWidth
      theight = @tileHeight
      mapdata = @map_data
      if autotiles
        return true if $DONTREFRESHAUTOTILES
        return true if @fullyrefreshedautos && @prioautotiles.empty?

        x_start = (@oxLayer0 / twidth)
        x_start = 0 if x_start < 0
        y_start = (@oyLayer0 / theight)
        y_start = 0 if y_start < 0
        x_end = x_start + (width / twidth) + 1
        y_end = y_start + (height / theight) + 1
        x_end = xsize if x_end > xsize
        y_end = ysize if y_end > ysize
        return true if x_start >= x_end || y_start >= y_end

        trans = Color.new(0, 0, 0, 0)
        temprect = Rect.new(0, 0, 0, 0)
        tilerect = Rect.new(0, 0, twidth, theight)
        zrange = 0...zsize
        overallcount = 0
        count = 0
        if @fullyrefreshedautos
          if !@priorect || !@priorectautos || @priorect[0] != x_start ||
             @priorect[1] != y_start ||
             @priorect[2] != x_end ||
             @priorect[3] != y_end
            # `@prioautotiles` shape varies across PE forks:
            #   * Older PE: Array of [x, y, z] (or [x, y]) triples;
            #     `find_all` yields each element as `tile`,
            #     `tile[0]/tile[1]` are coordinates.
            #   * Newer / modified PE (Pokemon Solar Eclipse): Hash
            #     keyed by `[x, y]` arrays with truthy values;
            #     `find_all` yields `[key, value]` pairs, so
            #     `tile[0]` becomes the `[x, y]` array - and
            #     `x < x_start` raises NoMethodError `<` on Array.
            # Branch on the actual type so the postload survives both.
            @priorectautos = if @prioautotiles.is_a?(Hash)
                               @prioautotiles.keys.find_all do |key|
                                 x = key[0]
                                 y = key[1]
                                 next !(x < x_start || x > x_end || y < y_start || y > y_end)
                               end
                             else
                               @prioautotiles.find_all do |tile|
                                 x = tile[0]
                                 y = tile[1]
                                 next !(x < x_start || x > x_end || y < y_start || y > y_end)
                               end
                             end
            @priorect = [x_start, y_start, x_end, y_end]
          end
          @priorectautos.each do |tile|
            x = tile[0]
            y = tile[1]
            overallcount += 1
            xpos = (x * twidth) - @oxLayer0
            ypos = (y * theight) - @oyLayer0
            bitmap.fill_rect(xpos, ypos, twidth, theight, trans)
            z = 0
            while z < zsize
              id = mapdata[x, y, z]
              z += 1
              next if !id || id < 48

              prioid = @priorities[id]
              next if prioid != 0 || !prioid

              if id >= 384
                next unless sheet

                temprect.set(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                             @tileSrcWidth, @tileSrcHeight)
                sheet.blit_to(bitmap, xpos, ypos, temprect)
              else
                tilebitmap = @autotileInfo[id]
                unless tilebitmap
                  anim = autotileFrame(id)
                  next if anim < 0

                  tilebitmap = Bitmap.new(twidth, theight)
                  bltAutotile(tilebitmap, 0, 0, id, anim)
                  @autotileInfo[id] = tilebitmap
                end
                bitmap.blt(xpos, ypos, tilebitmap, tilerect)
              end
            end
          end
          Graphics.frame_reset if overallcount > 500
        else
          (y_start..y_end).each do |y|
            (x_start..x_end).each do |x|
              haveautotile = false
              zrange.each do |z|
                id = mapdata[x, y, z]
                next if !id || id < 48 || id >= 384

                prioid = @priorities[id]
                next if prioid != 0 || !prioid

                fcount = @framecount[(id / 48) - 1]
                next if !fcount || fcount < 2

                unless haveautotile
                  haveautotile = true
                  overallcount += 1
                  xpos = (x * twidth) - @oxLayer0
                  ypos = (y * theight) - @oyLayer0
                  bitmap.fill_rect(xpos, ypos, twidth, theight, trans) if overallcount <= 2000
                  break
                end
                id = mapdata[x, y, z]
                next if !id || id < 48

                prioid = @priorities[id]
                next if prioid != 0 || !prioid

                if overallcount > 2000
                  xpos = (x * twidth) - @oxLayer0
                  ypos = (y * theight) - @oyLayer0
                  count = addTile(@autosprites, count, xpos, ypos, id)
                  next
                elsif id >= 384
                  next unless sheet

                  temprect.set(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                               @tileSrcWidth, @tileSrcHeight)
                  xpos = (x * twidth) - @oxLayer0
                  ypos = (y * theight) - @oyLayer0
                  sheet.blit_to(bitmap, xpos, ypos, temprect)
                else
                  tilebitmap = @autotileInfo[id]
                  unless tilebitmap
                    anim = autotileFrame(id)
                    next if anim < 0

                    tilebitmap = Bitmap.new(twidth, theight)
                    bltAutotile(tilebitmap, 0, 0, id, anim)
                    @autotileInfo[id] = tilebitmap
                  end
                  xpos = (x * twidth) - @oxLayer0
                  ypos = (y * theight) - @oyLayer0
                  bitmap.blt(xpos, ypos, tilebitmap, tilerect)
                end
              end
            end
          end
          Graphics.frame_reset
        end
        @usedsprites = false
        return true
      end
      return false if @usedsprites

      @firsttime = false
      # rubocop:disable Naming/VariableName -- @oxLayer0 / @oyLayer0
      # are PE's CustomTilemap instance variables. We can't rename them
      # without diverging from PE's own code that reads them.
      @oxLayer0 = @ox - (width >> 2)
      @oyLayer0 = @oy - (height >> 2)
      if @layer0clip
        @layer0.ox = 0
        @layer0.oy = 0
        @layer0.src_rect.set(width >> 2, height >> 2,
                             @viewport.rect.width, @viewport.rect.height)
      else
        @layer0.ox = (width >> 2)
        @layer0.oy = (height >> 2)
      end
      @layer0.bitmap.clear
      @oxLayer0 = @oxLayer0.floor
      @oyLayer0 = @oyLayer0.floor
      # rubocop:enable Naming/VariableName
      x_start = (@oxLayer0 / twidth)
      x_start = 0 if x_start < 0
      y_start = (@oyLayer0 / theight)
      y_start = 0 if y_start < 0
      x_end = x_start + (width / twidth) + 1
      y_end = y_start + (height / theight) + 1
      x_end = xsize if x_end >= xsize
      y_end = ysize if y_end >= ysize
      if x_start < x_end && y_start < y_end
        tmprect = Rect.new(0, 0, 0, 0)
        yrange = y_start...y_end
        xrange = x_start...x_end
        (0...zsize).each do |z|
          yrange.each do |y|
            ypos = (y * theight) - @oyLayer0
            xrange.each do |x|
              xpos = (x * twidth) - @oxLayer0
              id = mapdata[x, y, z]
              next if id.zero? || @priorities[id] != 0 || !@priorities[id]

              if id >= 384
                next unless sheet

                tmprect.set(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                            @tileSrcWidth, @tileSrcHeight)
                sheet.blit_to(bitmap, xpos, ypos, tmprect)
              else
                frames = @framecount[(id / 48) - 1]
                frame = if frames <= 1
                          0
                        else
                          (Graphics.frame_count / autotileFrameInterval) % frames
                        end
                bltAutotile(bitmap, xpos, ypos, id, frame)
              end
            end
          end
        end
        Graphics.frame_reset
      end
      true
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockNesting, Naming/PredicateMethod
  end
  # rubocop:enable Metrics/ClassLength

  MKXP.puts('VWrap: Pokemon Essentials CustomTilemap patched: tileset size is unlimited')
end

if $MKXP == true
  MKXPTilesetPatch.install
  MKXPTilesetPatch.install_deferred unless MKXPTilesetPatch.done?
end
