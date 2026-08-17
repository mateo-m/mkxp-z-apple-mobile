# MGC H-Mode7 native shim.
#
# Root cause: Pokemon Insurgence's opening cinematic (Map689 Event 3
# "pelipper" in the new-game Yes/Yes sequence) renders a rotating-
# perspective flyover of the world map using the MGC H-Mode7 plugin
# (MGC_Hmode7_1_4_4.cpp, x86 Windows PE). The plugin exposes nine C
# functions that Insurgence calls through RGSS1 Win32API:
#
#   scripts/210-HM7_NEW_CLASSES.rb, lines 41-49:
#     Draw_Map_Tileset    = Win32API.new("MGC_Hmode7", "drawMapTileset", ...)
#     Draw_Textureset     = Win32API.new("MGC_Hmode7", "drawTextureset", ...)
#     Draw_Heightmap      = Win32API.new("MGC_Hmode7", "drawHeightmap", ...)
#     Apply_Lighting      = Win32API.new("MGC_Hmode7", "applyLighting", ...)
#     Compute_M7          = Win32API.new("MGC_Hmode7", "computeM7", ...)
#     Render_HM7          = Win32API.new("MGC_Hmode7", "renderHM7", ...)
#     Refresh_Map_Tileset = Win32API.new("MGC_Hmode7", "refreshMapTileset", ...)
#     Apply_Opacity       = Win32API.new("MGC_Hmode7", "applyOpacity", ...)
#
# Each call passes object `__id__` integers and expects the DLL to
# reach into RGSS1 struct layouts via pointer math. Our Win32API
# stub always returns 0 (because we cannot load an x86 Windows PE on
# iOS, and the RGSS1 ABI differs from Ruby 3.1 / mkxp-z in any case),
# so every HM7 call was a no-op and the intro showed only the fog
# overlay texture with no world map underneath.
#
# Fix strategy: the hmode7-apple-mobile port (//hmode7-apple-mobile)
# reimplements the nine plugin functions in portable C++. The
# binding layer (binding/hmode7-binding.cpp) registers them as
# Ruby module functions under `HM7::Native` that take the real
# Bitmap/Table/Array/Hash objects (no `__id__` indirection).
#
# This postload shim runs after Insurgence's scripts have defined
# `module HM7`. It redefines `HM7.self.xxx` to bypass the Win32API
# constants and call `HM7::Native.xxx` directly, with the full Ruby
# objects. The `Win32API.new(...)` calls at the module top level
# still happen (returning our no-op stubs) but those constants are
# never reached because the wrappers no longer use them.
#
# This preserves the upstream HM7 code unmodified: if Insurgence
# ships a newer `HM7` module version with more methods, only the
# ones we override need new entries here. The rest fall through
# to the (no-op) Win32API stubs. That's intentional - new methods
# can be added incrementally as we port them.

return unless defined?(HM7)
return unless defined?(HM7::Native)
return unless HM7::Native.const_defined?(:AVAILABLE) && HM7::Native::AVAILABLE

# ----------------------------------------------------------------
#  Auto-detect the HM7 DLL era so the native renderer can pick the
#  correct wall-layer-selection algorithm.
#
#  The critical split is V1.4: its changelog reads *"can now handle
#  n layers (but the more layers, the more lag)"*. That is when the
#  layer-handling code was rewritten from a hardcoded 3-layer loop
#  (pre-V1.4 top-cumulative) to a generalised n-layer loop that
#  ended up with the bottom-cumulative threshold in the public
#  V1.4.4 source. See hmode7/docs/WALL_LAYER_MODE.md.
#
#  V1.3's changelog also mentions *"the DLL part is entirely
#  rewritten"*, but that rewrite was for wall EVENTS (sprite walls
#  attached to events via HM7::Surface) - a completely separate
#  system from the tile-layer wall extrusion. So despite V1.3
#  being a big rewrite, wall-layer selection most likely stayed
#  pre-V1.4 style through V1.3.x. We prefer to err conservative:
#  only flip to bottom-cumulative when we see V1.4-specific
#  markers.
#
#  V1.4 markers the HM7 Ruby scripts expose:
#    1. `HM7.apply_zoom` - a Ruby wrapper around the 9th DLL
#       export `applyZoom`, added in V1.4. Most definitive signal
#       because the underlying export only exists in V1.4+ DLLs.
#    2. Anything else V1.4-specific the script might expose. We
#       don't know of a second signal today, so we rely on (1).
#
#  Anything without these markers is treated as pre-V1.4
#  (top-cumulative) - confirmed correct for Pokemon Insurgence
#  1.2.7, assumed safe for V1.3.x as discussed above.
# ----------------------------------------------------------------
def self._mkxp_hm7_v14_or_newer?
  # V1.4's applyZoom Ruby wrapper. Most reliable signal.
  return true if HM7.respond_to?(:apply_zoom)

  false
end

detected_mode = _mkxp_hm7_v14_or_newer? ? :bottom_cumulative : :top_cumulative

unless HM7::Native.const_defined?(:WALL_LAYER_MODE)
  HM7::Native.const_set(:WALL_LAYER_MODE, detected_mode)
  v14_marker = if detected_mode == :bottom_cumulative
                 'HM7.apply_zoom present = V1.4+'
               else
                 'HM7.apply_zoom absent = pre-V1.4'
               end
  MKXP.puts "[hm7-shim] WALL_LAYER_MODE autodetected: #{detected_mode} (#{v14_marker})"
end

begin
  # Insurgence's game scripts (210-HM7_NEW_CLASSES.rb) define
  # `def self.xxx` on `HM7` AFTER `hmode7BindingInit` registers the
  # native module, so our overrides have to land last. The postload
  # runs after game scripts.
  HM7.module_eval do
    # ------------------------------------------------------------
    #  Overrides. Each corresponds to a `def self.xxx` in
    #  Insurgence's 210-HM7_NEW_CLASSES.rb around lines 53-101.
    #  Argument order matches the upstream Ruby signature exactly.
    #  We pass objects directly to HM7::Native (which unwraps them
    #  into SDL_Surface*/int16_t* in C++).
    # ------------------------------------------------------------

    def self.draw_map_tileset(map_tileset, tileset, heightset,
                              tilemap_hash, auto_tilesets)
      HM7::Native.draw_map_tileset(map_tileset, tileset, heightset,
                                   tilemap_hash, auto_tilesets)
    end

    def self.draw_textureset(textures, colormap, texture_auto)
      HM7::Native.draw_textureset(textures, colormap, texture_auto)
    end

    def self.draw_heightmap(heightmap, heightpattern, map_tileset,
                            tilemap_data)
      HM7::Native.draw_heightmap(heightmap, heightpattern,
                                 map_tileset, tilemap_data)
    end

    def self.apply_lighting(heightmap)
      HM7::Native.apply_lighting(heightmap)
    end

    def self.compute_m7(datatable, lightline, params)
      HM7::Native.compute_m7(datatable, lightline, params)
    end

    def self.render_hm7(params, vars, surfaces)
      HM7::Native.render_hm7(params, vars, surfaces)
    end

    def self.refresh_map_tileset(map_tileset, tileset, tilemap_hash,
                                 auto_tilesets)
      HM7::Native.refresh_map_tileset(map_tileset, tileset,
                                      tilemap_hash, auto_tilesets)
    end

    def self.apply_opacity(bitmap, opacity)
      HM7::Native.apply_opacity(bitmap, opacity)
    end
  end

  # ----------------------------------------------------------------
  #  HM7::Surface#get_data v1.2.1 -> v1.4.4 adapter.
  #
  # Insurgence ships H-Mode7 v1.2.1 (2011-05-15, see
  # 208-----_MGC___H-Mode7_----.rb). Its `Surface#get_data` returns
  # a 6-element Array:
  #
  #   [type, screen_x, screen_y, bitmap, altitude, blend_type]
  #
  # Our port is based on v1.4.4, whose renderHM7 reads an 11-element
  # Array:
  #
  #   [type, screenX1, screenY1, screenX2, screenY2, inverse,
  #    bitmap, dh, blend, dispWidth, dispOffset]
  #
  # On Windows the v1.2.1 hash is still passed to the v1.4.4-expecting
  # DLL, and the DLL reads past the end into heap garbage - which is
  # what the reports describe as "works on Windows, mostly". On our
  # port that over-read would be a crash or a TypeError inside the
  # binding's NUM2INT, which is exactly what we hit first (Bitmap
  # at [3] being coerced to Integer for screenX2).
  #
  # Fix: override Surface#get_data to return the 11-element v1.4.4
  # form, synthesized from the v1.2.1 fields plus the sprite's
  # bitmap geometry:
  #   - screenX1 / screenX2 = screen_x +/- bitmap.width / 2
  #   - screenY1 / screenY2 = screen_y - bitmap.height .. screen_y
  #   - inverse    = 0   (no mirror, characters update their own sx/sy)
  #   - dh         = altitude
  #   - blend      = blend_type
  #   - dispWidth  = bitmap.width
  #   - dispOffset = 0
  # This corresponds to the "centered-bottom-anchored sprite" that
  # the HM7 character tooling builds.
  # ----------------------------------------------------------------
  if defined?(HM7::Surface) && HM7::Surface.method_defined?(:get_data)
    HM7::Surface.class_eval do
      # Refresh the alias on every install so `_mkxp_hm7_orig_get_data`
      # points at the CURRENT session's original (the game scripts
      # re-evaluate `def get_data` each session, so session 1's alias
      # captured an outdated method instance). `alias_method` with an
      # existing target name just replaces the alias - no chaining.
      alias_method :_mkxp_hm7_orig_get_data, :get_data
      # rubocop:disable Naming/AccessorMethodName -- HM7::Surface's
      # native binding calls this exact method name. Can't rename
      # without losing the override.
      def get_data
        # rubocop:enable Naming/AccessorMethodName
        # Fallback handling. If we lack a usable bitmap, returning
        # the original v1.2.1 6-element form would leak values
        # into the native binding's 11-element positional slots
        # (specifically `blend_type` at original[5] gets read as
        # `inverse` in v1.4.4 layout, causing a horizontal mirror).
        # Return `nil` instead. The native binding skips nil
        # entries defensively in its surface unpacking loop.
        return nil if bitmap.nil? || bitmap.disposed?

        half_w = bitmap.width >> 1
        bitmap.height

        # v1.4.4 plugin convention: `(screenX1, screenY1)` and
        # `(screenX2, screenY2)` are two ANCHOR POINTS defining a
        # tilt-line along which the sprite is drawn. They are
        # NOT a bounding box:
        #   - `sDx = screenX2 - screenX1` is the horizontal span.
        #   - `sDy = screenY1 - screenY2` is the vertical slant.
        #   - `sSlope = (sDy << 7) / sDx` is the skew factor.
        #
        # For a standard axis-aligned billboard sprite (the only
        # kind Insurgence's v1.2.1 Surface produces), sDy must
        # be 0 so the sprite renders vertically straight. That
        # means screenY1 == screenY2, both set to the sprite's
        # foot-y anchor.
        #
        # Sprite HEIGHT is not derived from (Y1, Y2). The plugin
        # reads `sHeight` directly from the bitmap header and
        # scales via `sFYt` based on mode-7 depth.
        sx1 = screen_x - half_w
        sx2 = screen_x + half_w
        anchor_y = screen_y # sprite's foot = anchor line

        [
          type,             # [0]
          sx1,              # [1] screenX1 (left anchor x)
          anchor_y,         # [2] screenY1 (anchor y, bottom/foot)
          sx2,              # [3] screenX2 (right anchor x)
          anchor_y,         # [4] screenY2 (same - no slant)
          0,                # [5] inverse (no mirror)
          bitmap,           # [6]
          altitude,         # [7] dh
          blend_type,       # [8] blend
          bitmap.width,     # [9] dispWidth
          0                 # [10] dispOffset
        ]
      end
    end
  end

  # ----------------------------------------------------------------
  #  sScreenBitmap 2x-width fix.
  #
  # Insurgence's `HM7::Tilemap#initialize` (210-HM7_NEW_CLASSES.rb
  # line 515) allocates `@params[10] = Bitmap.new(@render.width,
  # @render.height)` - single-width. The original Windows plugin's
  # `renderHM7` treats this buffer as 8 bytes per pixel (packed
  # composition state: flag, blend, hbase_hi, hbase_lo, r, g, b, a)
  # and reads up to `(xt << 3)` per column. With a 1x-width Bitmap
  # that's an overread of 4 bytes/pixel, which on Windows happens
  # to land inside the next heap block and produces garbage or SIGSEGV.
  #
  # Our port respects the 8-bytes-per-pixel assumption, but it also
  # needs the Bitmap to be that large. Reallocate at 2x width after
  # initialize runs.
  #
  # Guarded so older HM7 layouts (if anyone forks with a different
  # @params structure) don't get silently corrupted.
  # ----------------------------------------------------------------
  # Important Ruby gotcha: `#initialize` is implicitly PRIVATE on every
  # class, so `Class#method_defined?(:initialize)` returns false even
  # when the class has one. Use `private_method_defined?`
  # (which does NOT check public+private simultaneously the way a naive
  # reader might expect from the name) OR the more robust
  # `instance_method(:initialize)` lookup which throws NameError when
  # the method doesn't exist, regardless of visibility.
  tilemap_has_init =
    defined?(HM7::Tilemap) &&
    (HM7::Tilemap.method_defined?(:initialize) ||
     HM7::Tilemap.private_method_defined?(:initialize))

  if tilemap_has_init
    HM7::Tilemap.class_eval do
      # Refresh the alias on every install. Same rationale as
      # HM7::Surface#get_data above: the game scripts re-evaluate
      # `def initialize` each session, so `_mkxp_hm7_orig_initialize`
      # needs to be re-pointed at the current session's original or
      # we'd call into a stale method object captured at session 1.
      alias_method :_mkxp_hm7_orig_initialize, :initialize
      def initialize(*args, &blk)
        _mkxp_hm7_orig_initialize(*args, &blk)
        return unless @params.is_a?(Array) && @params.length > 10

        s = @params[10]
        return unless s.is_a?(Bitmap) && !s.disposed?
        return if s.width >= @render.width * 2

        fixed = Bitmap.new(@render.width * 2, @render.height)
        @params[10] = fixed
        s.dispose
      end
    end
  else
    MKXP.puts '[hm7-shim] WARNING: HM7::Tilemap#initialize patch skipped: ' \
              "HM7::Tilemap defined?=#{defined?(HM7::Tilemap).inspect}"
  end

  # Optional: expose a global flag so game scripts / debug overlays
  # can detect whether the native renderer is active. No Insurgence
  # code checks this today, but forks might.
  $mkxp_hm7_native = true
rescue StandardError => e
  # Best-effort install. If anything goes wrong (missing method,
  # unexpected HM7 internals in a different Essentials fork) leave
  # the Win32API stubs in place so at least the game doesn't crash.
  # The player will see the pre-fix "no world map" rendering bug.
  warn "hmode7_shim: native install failed: #{e.class}: #{e.message}"
end
