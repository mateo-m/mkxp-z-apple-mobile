# pokemon_tilemap_fix.rb
# Tileset vertical wrapper for Pokemon Essentials' CustomTilemap.
#
# Original author: Zoro (inori-z fork, EssentialsCompatibility.rb)
# Source: https://github.com/joiplay/android-mkxp
# License: GPL-2.0 (same as mkxp-z)
#
# Pokemon Essentials games use a Ruby-level CustomTilemap class that
# loads the full tileset as a single Bitmap. On mobile GPUs, tilesets
# taller than GL_MAX_TEXTURE_SIZE become "mega surfaces" (CPU-only),
# causing corrupt/black tiles and severe performance loss.
#
# This script repacks oversized tilesets by wrapping excess height into
# additional columns, keeping the bitmap within the GPU texture limit.
# The effective limit is raised dramatically:
#
#   GPU limit  -> Effective tileset height
#   1024       -> 4096
#   2048       -> 16384
#   4096       -> 65536   (enough for virtually any tileset)
#   8192       -> 262144
#
# Because tile lookups need coordinate translation, there is a small
# per-tile performance cost on maps that use wrapped tilesets.

# Global flag: set to true to disable autotile animation refreshes.
# Saves CPU on low-end devices at the cost of static water/lava tiles.
$DONTREFRESHAUTOTILES = false unless defined?($DONTREFRESHAUTOTILES)

module VWrap
  MAX_TEX_SIZE         = Bitmap.max_size
  TILESET_WIDTH        = 0x100
  TILESET_HEIGHT       = MAX_TEX_SIZE - (MAX_TEX_SIZE % 32)
  MAX_TEX_SIZE_BOOSTED = (MAX_TEX_SIZE**2) / TILESET_WIDTH

  def self.clamp(val, min, max)
    val = max if val > max
    val = min if val < min
    val
  end

  def self.makeVWrappedTileset(originalbmp)
    width = originalbmp.width
    height = originalbmp.height
    if width == TILESET_WIDTH && originalbmp.mega?
      columns = (height / TILESET_HEIGHT.to_f).ceil

      if columns * TILESET_WIDTH > MAX_TEX_SIZE
        raise "Tilemap is too long!\n\n" \
              "SIZE: #{originalbmp.height}px\n" \
              "HARDWARE LIMIT: #{MAX_TEX_SIZE}px\n" \
              "BOOSTED LIMIT: #{MAX_TEX_SIZE_BOOSTED}px"
      end

      bmp = Bitmap.new(TILESET_WIDTH * columns, TILESET_HEIGHT)
      remainder = height % TILESET_HEIGHT

      columns.times do |col|
        srcrect = Rect.new(0, col * TILESET_HEIGHT, width, col + 1 == columns ? remainder : TILESET_HEIGHT)
        bmp.blt(col * TILESET_WIDTH, 0, originalbmp, srcrect)
      end
      return bmp
    end

    originalbmp
  end

  def self.blitVWrappedPixels(dest_x, dest_y, dest, src, srcrect)
    return dest.blt(dest_x, dest_y, src, srcrect) if srcrect.y + srcrect.width < TILESET_HEIGHT

    srcrect.x = clamp(srcrect.x, 0, TILESET_WIDTH)
    srcrect.width = clamp(srcrect.width, 0, TILESET_WIDTH - srcrect.x)
    col = (srcrect.y / TILESET_HEIGHT.to_f).floor
    src_x = (col * TILESET_WIDTH) + srcrect.x
    src_y = srcrect.y % TILESET_HEIGHT

    dest.blt(dest_x, dest_y, src, Rect.new(src_x, src_y, srcrect.width, srcrect.height))
  end
end

# Only patch if this is an mkxp engine AND the game defines CustomTilemap
# (i.e. Pokemon Essentials). Standard RPG Maker games use the native C++
# Tilemap which already handles mega surfaces via atlas building.
if $MKXP == true && defined?(CustomTilemap) == 'constant'
  class CustomTilemap
    def tileset=(value)
      if value.mega?
        @tileset = VWrap.makeVWrappedTileset(value)
        value.dispose
      else
        @tileset = value
      end
      @tilesetchanged = true
    end

    def getRegularTile(sprite, id)
      bitmap = @regularTileInfo[id]
      unless bitmap
        bitmap = Bitmap.new(@tileWidth, @tileHeight)
        rect = Rect.new(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                        @tileSrcWidth, @tileSrcHeight)
        VWrap.blitVWrappedPixels(0, 0, bitmap, @tileset, rect)
        @regularTileInfo[id] = bitmap
      end
      sprite.bitmap = bitmap if sprite.bitmap != bitmap
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
    # original algorithm; refactoring would deviate from the upstream
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
                temprect.set(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                             @tileSrcWidth, @tileSrcHeight)
                VWrap.blitVWrappedPixels(xpos, ypos, bitmap, @tileset, temprect)
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
                  temprect.set(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                               @tileSrcWidth, @tileSrcHeight)
                  xpos = (x * twidth) - @oxLayer0
                  ypos = (y * theight) - @oyLayer0
                  VWrap.blitVWrappedPixels(xpos, ypos, bitmap, @tileset, temprect)
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
      # are PE's CustomTilemap instance variables; we can't rename them
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
                tmprect.set(((id - 384) & 7) * @tileSrcWidth, ((id - 384) >> 3) * @tileSrcHeight,
                            @tileSrcWidth, @tileSrcHeight)
                VWrap.blitVWrappedPixels(xpos, ypos, bitmap, @tileset, tmprect)
              else
                frames = @framecount[(id / 48) - 1]
                frame = if frames <= 1
                          0
                        else
                          (Graphics.frame_count / Animated_Autotiles_Frames) % frames
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

  MKXP.puts("VWrap: Pokemon Essentials CustomTilemap patched (max tileset height: #{VWrap::MAX_TEX_SIZE_BOOSTED}px)")
end
