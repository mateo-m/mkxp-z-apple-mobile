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
# ones we override need new entries here; the rest fall through
# to the (no-op) Win32API stubs. That's intentional - new methods
# can be added incrementally as we port them.

return unless defined?(HM7)
return unless defined?(HM7::Native)
return unless HM7::Native.const_defined?(:AVAILABLE) && HM7::Native::AVAILABLE

begin
  HM7.module_eval do
    # Idempotency: if this shim runs twice (e.g. mriBindingReset
    # between sessions), skip the second install.
    next if respond_to?(:_mkxp_hm7_shim_installed)

    def self._mkxp_hm7_shim_installed
      true
    end

    # ------------------------------------------------------------
    #  Overrides. Each corresponds to a `def self.xxx` in
    #  Insurgence's 210-HM7_NEW_CLASSES.rb around lines 53-101.
    #  Argument order matches the upstream Ruby signature exactly;
    #  we pass objects directly to HM7::Native (which unwraps them
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
  # needs the Bitmap to actually *be* that large. Reallocate at
  # 2x width after initialize runs. See design doc caveat §10.5
  # in //hmode7-apple-mobile/docs/HMODE7_PORT_DESIGN.md.
  #
  # Guarded so older HM7 layouts (if anyone forks with a different
  # @params structure) don't get silently corrupted.
  # ----------------------------------------------------------------
  if defined?(HM7::Tilemap) && HM7::Tilemap.method_defined?(:initialize)
    HM7::Tilemap.class_eval do
      unless method_defined?(:_mkxp_hm7_orig_initialize)
        alias_method :_mkxp_hm7_orig_initialize, :initialize
        def initialize(*args, &blk)
          _mkxp_hm7_orig_initialize(*args, &blk)
          # @params might not be set on all forks / map types.
          return unless @params.is_a?(Array) && @params.length > 10
          s = @params[10]
          return unless s.is_a?(Bitmap) && !s.disposed?
          # Already 2x? (Idempotency: if this shim reruns, or if a
          # future HM7 version ships the fix, don't double it.)
          return if s.width >= @render.width * 2
          fixed = Bitmap.new(@render.width * 2, @render.height)
          @params[10] = fixed
          s.dispose
        end
      end
    end
  end

  # Optional: expose a global flag so game scripts / debug overlays
  # can detect whether the native renderer is active. No Insurgence
  # code checks this today, but forks might.
  $mkxp_hm7_native = true
rescue => e
  # Best-effort install. If anything goes wrong (missing method,
  # unexpected HM7 internals in a different Essentials fork) leave
  # the Win32API stubs in place so at least the game doesn't crash;
  # the player will see the pre-fix "no world map" rendering bug.
  warn "hmode7_shim: native install failed: #{e.class}: #{e.message}"
end
