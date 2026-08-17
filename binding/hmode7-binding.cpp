/*
** hmode7-binding.cpp
**
** Ruby module binding that exposes the ported MGC H-Mode7 renderer
** (see //hmode7-apple-mobile) to RGSS scripts as `HM7::Native`.
**
** The original Windows plugin shipped as `MGC_Hmode7.dll` and was
** called by Insurgence's scripts via Win32API with raw `__id__`
** integers pointing at RGSS1 objects. That ABI is not portable:
**   - `Win32API.new(...)` can't load a Windows PE on iOS.
**   - `__id__ << 1` does not equal a pointer in Ruby 3.1.
**   - RGSS1's Bitmap/Table struct layouts differ from mkxp-z's.
**
** So instead of wire-compatible emulation, this binding exposes the
** ported C++ functions as a plain Ruby module that takes the actual
** `Bitmap`/`Table`/`Array`/`Hash` Ruby objects. A postload shim
** (`scripts/postload/hmode7_shim.rb`) redefines the `HM7.self.xxx`
** methods in Insurgence's scripts to call this module, bypassing
** the Win32API layer entirely.
**
** Per-call argument shapes are documented next to each RB_METHOD
** below. All are derived from the H-Mode7 Ruby script
** (`210-HM7_NEW_CLASSES.rb`) call sites + data construction,
** cross-referenced against the original plugin's C reads
** (`ptr[i] >> 1`).
*/

#include "binding-util.h"
#include "bitmap.h"

#include <cstring>
#include "table.h"

#include <SDL_surface.h>
#include <cstdint>
#include <cstdio>

// Mkxp-z's file-based debug log. Unlike `Debug() <<` (which goes to
// std::cerr and is invisible on iOS), this routes into the per-game
// Logs/ file.
extern "C" void mkxp_debugLog(const char *tag, const char *source,
                              const char *message);

// Public C++ headers from //hmode7-apple-mobile. Expected on the
// include path via the xcodegen integration (see project.yml).
#include "hm7_apply_opacity.h"
#include "hm7_apply_zoom.h"
#include "hm7_apply_lighting.h"
#include "hm7_compute_m7.h"
#include "hm7_draw_heightmap.h"
#include "hm7_draw_textureset.h"
#include "hm7_draw_map_tileset.h"
#include "hm7_render.h"

namespace {

// ----------------------------------------------------------------
//  Map layer count
// ----------------------------------------------------------------

// Tile layers per map cell. RPG Maker XP map data is a Table whose
// third dimension is always 3, so this is a property of the editor
// format and not of any one game. Hmode7 is an RMXP-era plugin, so
// every game that reaches this binding packs 3 layers.
constexpr int kMapLayers = 3;

// Hmode7's Ruby side packs its tilemap Table as one run of
// `kMapLayers + 1` entries per cell: the 3 layer tiles, then the
// bush-start index. The renderers stride by that number, so a table
// whose width is not a multiple of it would be read at the wrong
// offsets and draw garbage without ever failing.
//
// The binding cannot see the map's cell width, so divisibility is
// the only check available. It still catches the case that matters,
// which is a fork that repacked the table with a different stride.
constexpr int kPackedStride = kMapLayers + 1;

// True when a packed tilemap width can hold whole cells. Warns once
// per process on the way out, because a stride mismatch is a
// property of the game and repeats every frame.
bool packed_tilemap_is_sane(int tilemap_xsize, const char *caller) {
    if (tilemap_xsize > 0 && tilemap_xsize % kPackedStride == 0) return true;

    static int strideWarned = 0;
    if (!strideWarned) {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
            "%s: tilemap width=%d is not a multiple of %d. This game packs "
            "its Hmode7 tile table differently, so the map is not drawn.",
            caller, tilemap_xsize, kPackedStride);
        mkxp_debugLog("HM7-WARN", "hmode7-binding.cpp [C++]", buf);
        strideWarned = 1;
    }
    return false;
}

// ----------------------------------------------------------------
//  Low-level unwrappers
// ----------------------------------------------------------------

// Unwrap a Ruby Bitmap VALUE into a writable CPU-side SDL_Surface*.
// Returns nullptr on nil / Fixnum / disposed / non-Bitmap inputs so
// callers can early-return. Forces lazy GPU->CPU sync via `getPixel`.
//
// mkxp-z has TWO CPU-side surface paths:
//   1. Regular Bitmap  - `p->surface` is the shadow, allocated on
//      first `getPixel` call, backed by a GL texture (up to the
//      max texture size).
//   2. "Mega surface" Bitmap - when the bitmap is larger than the
//      GL max texture size (Insurgence's @textureset lands here
//      for big maps: 160 x (tileCount*32) easily exceeds 4096px
//      tall). These live entirely on the CPU in `p->megaSurface`;
//      `p->surface` stays null.
//
// Insurgence's Ruby code passes `0` (Fixnum) as a placeholder in
// some Array slots (see `auto_tilesets.push(0)` in
// 210-HM7_NEW_CLASSES.rb:800). We reject those without trying to
// dereference a tagged Fixnum as T_DATA (undefined behavior).
SDL_Surface *bitmap_surface(VALUE v) {
    if (NIL_P(v)) return nullptr;
    if (!RB_TYPE_P(v, T_DATA)) return nullptr;
    Bitmap *b = getPrivateDataNoRaise<Bitmap>(v);
    if (!b || b->isDisposed()) return nullptr;
    // Check for the mega-surface path first so we don't trigger a
    // full-bitmap GL read-back on a gigantic texture just to find
    // out `p->surface` is null.
    if (SDL_Surface *mega = b->megaSurface()) {
        return mega;
    }
    // Regular path: trigger lazy allocation of the shadow surface
    // + GL->CPU sync on first access.
    b->getPixel(0, 0);
    return b->surface();
}

// Push the Bitmap's shadow surface back to the GPU texture. Uses
// the full-bitmap sub-rect path so the shadow survives the commit
// and the next frame's paint can mutate it in place WITHOUT the
// engine first re-allocating + re-filling it via a full-texture
// glReadPixels round-trip. That round-trip is a GPU pipeline stall
// on tile-based mobile GPUs (Apple A-series) and was the dominant
// cost of the original whole-bitmap replaceRaw path used here.
//
// Note: we upload the full (width x height) rect rather than a
// dirty-rect intersection because the HM7 kernels touch nearly
// every pixel of their output surfaces every frame, so narrowing
// is not worth the accounting overhead. If a future kernel is
// added that only updates a small band, uploadCPURect supports
// partial rects directly.
void commit_bitmap(VALUE v) {
    if (NIL_P(v)) return;
    if (!RB_TYPE_P(v, T_DATA)) return;
    Bitmap *b = getPrivateDataNoRaise<Bitmap>(v);
    if (!b || b->isDisposed()) return;
    SDL_Surface *surf = b->surface();
    if (!surf) return;
    b->uploadCPURect(0, 0, surf->w, surf->h);
}

// Unwrap a Ruby Table into a raw int16_t* + dims. The Table stores
// its `std::vector<int16_t>` internally. `&t->at(0,0,0)` returns
// a pointer into that contiguous backing buffer. Returns nullptr
// for non-Table / zero-size inputs.
std::int16_t *table_data(VALUE v, int *xs, int *ys, int *zs) {
    if (NIL_P(v)) return nullptr;
    if (!RB_TYPE_P(v, T_DATA)) return nullptr;
    Table *t = getPrivateDataNoRaise<Table>(v);
    if (!t) return nullptr;
    int x = t->xSize(), y = t->ySize(), z = t->zSize();
    if (x == 0 || y == 0 || z == 0) return nullptr;
    if (xs) *xs = x;
    if (ys) *ys = y;
    if (zs) *zs = z;
    return &t->at(0, 0, 0);
}

// Array accessors with NUM2INT coercion + sane defaults on nil/OOB.
VALUE aref_or_nil(VALUE arr, long i) {
    if (NIL_P(arr) || !RB_TYPE_P(arr, T_ARRAY)) return Qnil;
    if (i < 0 || i >= RARRAY_LEN(arr)) return Qnil;
    return RARRAY_AREF(arr, i);
}

int aref_int(VALUE arr, long i, int fallback = 0) {
    VALUE v = aref_or_nil(arr, i);
    if (FIXNUM_P(v)) return FIX2INT(v);
    if (v == Qtrue) return 1;
    if (v == Qfalse || v == Qnil) return fallback;
    return NUM2INT(v);
}

// Like `aref_int` but returns `(n << 1) | 1` - the raw tagged-
// Fixnum bit pattern RGSS1 used in memory. The original plugin
// read these slots without the `>> 1` untag (see
// MGC_Hmode7_1_4_4.cpp lines 154-162 and 863-864 for the six
// trig/slope fields and the two display-offset fields that skip
// the untag). Doubling preserves the scaling the plugin's integer
// math assumed. Without this, projection formulas land at ~half
// scale, sampling off-map and producing all-transparent pixels.
int aref_int_raw_tagged(VALUE arr, long i, int fallback = 0) {
    VALUE v = aref_or_nil(arr, i);
    int n;
    if (FIXNUM_P(v)) {
        n = FIX2INT(v);
    } else if (v == Qtrue) {
        n = 1;
    } else if (v == Qfalse || v == Qnil) {
        n = fallback;
    } else {
        n = NUM2INT(v);
    }
    // Mirror Ruby's `(n << 1) | 1` in-memory Fixnum layout.
    return (n << 1) | 1;
}

// ----------------------------------------------------------------
//  HM7::Native.apply_opacity(bitmap, opacity) -> nil
//
// Ruby: `HM7.apply_opacity(bitmap, opacity)` from
//   210-HM7_NEW_CLASSES.rb:99. `bitmap` is a Bitmap, `opacity` is
//   an Integer 0..255.
// ----------------------------------------------------------------

RB_METHOD(hm7NativeApplyOpacity) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 2);
    VALUE bitmap_v = argv[0];
    int opacity = NUM2INT(argv[1]);

    SDL_Surface *surf = bitmap_surface(bitmap_v);
    if (!surf) return Qnil;

    hm7::apply_opacity(surf, opacity);
    commit_bitmap(bitmap_v);
    return Qnil;
}

// ----------------------------------------------------------------
//  HM7::Native.apply_zoom(dst, src, lissage) -> nil
//
// Not called by Insurgence but wired for completeness. `lissage`
// is a bool-ish (0/1 or true/false) selecting bilinear vs nearest.
// ----------------------------------------------------------------

RB_METHOD(hm7NativeApplyZoom) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    VALUE dst_v = argv[0];
    VALUE src_v = argv[1];
    int lissage = RTEST(argv[2]) ? 1 : 0;

    SDL_Surface *dst = bitmap_surface(dst_v);
    SDL_Surface *src = bitmap_surface(src_v);
    if (!dst || !src) return Qnil;

    hm7::apply_zoom(dst, src, lissage);
    commit_bitmap(dst_v);
    return Qnil;
}

// ----------------------------------------------------------------
//  HM7::Native.apply_lighting(heightmap) -> nil
//
// Ruby: `HM7.apply_lighting(heightmap)` from
//   210-HM7_NEW_CLASSES.rb:73. `heightmap` is a Table (size
//   `(width*2) x (height + height/2)` of int16_t). The port
//   reads ground-region rows and writes shadow/highlight deltas
//   into plane 1.
// ----------------------------------------------------------------

RB_METHOD(hm7NativeApplyLighting) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 1);
    VALUE heightmap_v = argv[0];

    int raw_xs = 0, raw_ys = 0, raw_zs = 0;
    std::int16_t *data = table_data(heightmap_v, &raw_xs, &raw_ys, &raw_zs);
    if (!data) return Qnil;

    hm7::apply_lighting(data, raw_xs, raw_ys);
    // Tables live on the CPU side. No commit needed.
    return Qnil;
}

// ----------------------------------------------------------------
//  HM7::Native.compute_m7(datatable, lightline, params) -> nil
//
// Ruby: `HM7.compute_m7(datatable, lightline, params)` from
//   210-HM7_NEW_CLASSES.rb:79. `params` is the 12-or-more Fixnum
//   array built at line 565 of the same file:
//     [0]  cos_alpha       [6]  hm7_height_limit
//     [1]  sin_alpha       [7]  cos_theta
//     [2]  distance_h      [8]  sin_theta
//     [3]  pivot_map       [9]  distance_p
//     [4]  slope_value_map [10] zoom_map
//     [5]  corrective_map  [11] (pass-through slot)
//
// `datatable` is a 3D Table (xsize, ysize, 2) storing projected
// (xr, yr) source-map coordinates. `lightline` is a 3-row Bitmap
// used for per-row lighting + per-column scratch.
// ----------------------------------------------------------------

RB_METHOD(hm7NativeComputeM7) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    VALUE datatable_v = argv[0];
    VALUE lightline_v = argv[1];
    VALUE params_v = argv[2];

    int data_xs = 0, data_ys = 0, data_zs = 0;
    std::int16_t *data = table_data(datatable_v, &data_xs, &data_ys, &data_zs);
    if (!data) return INT2FIX(0);

    SDL_Surface *lightline = bitmap_surface(lightline_v);
    if (!lightline) return INT2FIX(0);

    hm7::ComputeM7Params cp = {};
    // Trig + slope + correction params: the Windows plugin read
    // these as the raw tagged Fixnum bit pattern (no `>> 1`), so
    // their effective value in the pixel math was ~2n. We mirror
    // that by passing `(n << 1) | 1` for these 6 fields.
    cp.cosAngle = aref_int_raw_tagged(params_v, 0);
    cp.sinAngle = aref_int_raw_tagged(params_v, 1);
    cp.altitude = aref_int(params_v, 2);
    cp.pivot = aref_int(params_v, 3);
    cp.slope = aref_int_raw_tagged(params_v, 4);
    cp.correction = aref_int_raw_tagged(params_v, 5);
    cp.heightLimit = aref_int(params_v, 6);
    cp.cosTheta = aref_int_raw_tagged(params_v, 7);
    cp.sinTheta = aref_int_raw_tagged(params_v, 8);
    cp.distProj = aref_int(params_v, 9);
    cp.zoom = aref_int(params_v, 10);
    // xMin/xMax/yMin/yMax/lessCut are not passed by Insurgence's
    // Ruby code. Default to full-lightline-width / full-data-height
    // (matches the clipless behaviour the Windows DLL fell into by
    // reading uninitialized stack memory as ~zero).
    cp.xMin = 0;
    cp.xMax = lightline->w;
    cp.yMin = 0;
    cp.yMax = data_ys;
    cp.lessCut = 0;

    hm7::compute_m7(data, data_xs, data_ys, lightline, cp);
    commit_bitmap(lightline_v);
    return INT2FIX(0);
}

// ----------------------------------------------------------------
//  HM7::Native.draw_heightmap(heightmap, heightpattern,
//                             map_tileset, tilemap_data) -> nil
//
// Ruby: `HM7.draw_heightmap(heightmap, heightpattern, map_tileset,
//        tilemap_data)` from 210-HM7_NEW_CLASSES.rb:66.
// `heightmap`, `tilemap_data` are Tables. `heightpattern`,
// `map_tileset` are Bitmaps.
// ----------------------------------------------------------------

RB_METHOD(hm7NativeDrawHeightmap) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 4);
    VALUE heightmap_v = argv[0];
    VALUE pattern_v = argv[1];
    VALUE map_tileset_v = argv[2];
    VALUE tilemap_v = argv[3];

    int hm_xs = 0, hm_ys_unused = 0, hm_zs_unused = 0;
    std::int16_t *heightmap = table_data(heightmap_v, &hm_xs, &hm_ys_unused, &hm_zs_unused);
    (void)hm_ys_unused; (void)hm_zs_unused;
    if (!heightmap) return INT2FIX(0);

    int tm_xs = 0, tm_ys = 0, tm_zs_unused = 0;
    std::int16_t *tilemap = table_data(tilemap_v, &tm_xs, &tm_ys, &tm_zs_unused);
    (void)tm_zs_unused;
    if (!tilemap) return INT2FIX(0);

    SDL_Surface *map_tileset = bitmap_surface(map_tileset_v);
    SDL_Surface *pattern = bitmap_surface(pattern_v);
    if (!map_tileset || !pattern) return INT2FIX(0);

    if (!packed_tilemap_is_sane(tm_xs, "draw_heightmap")) return INT2FIX(0);

    hm7::draw_heightmap(heightmap, hm_xs, tilemap, tm_xs, tm_ys,
                        map_tileset, pattern, kMapLayers);
    return INT2FIX(0);
}

// ----------------------------------------------------------------
//  HM7::Native.draw_textureset(texture_hash, colormap, texture_auto)
//    -> nil
//
// Ruby: `HM7.draw_textureset(textures, colormap, texture_auto)`
//   from 210-HM7_NEW_CLASSES.rb:60.
// `texture_hash` is `Hash<Fixnum tile_num, Array value>` where
// `value = [tile_value, texture_bitmap]` (Insurgence's shape) or
// `value = [tile_value, texture_bitmap, anim_nbr, anim_index]`
// (original plugin shape, animated textures). The binding reads
// all 4 slots. Missing entries default to 0.
// `colormap` is the destination Bitmap (the wall-strip atlas).
// `texture_auto` is a single Bitmap (the autotile wall source,
// used when tile_value < 384).
// ----------------------------------------------------------------

namespace {
struct DrawTexturesetCtx {
    SDL_Surface *colormap;
    SDL_Surface *texture_auto;
};

int hm7_draw_textureset_iter(VALUE key, VALUE val, VALUE ctx_val) {
    DrawTexturesetCtx *ctx = reinterpret_cast<DrawTexturesetCtx *>(ctx_val);
    if (!FIXNUM_P(key)) return ST_CONTINUE;
    if (NIL_P(val) || !RB_TYPE_P(val, T_ARRAY)) return ST_CONTINUE;

    int tile_num = FIX2INT(key);
    int tile_value = aref_int(val, 0);
    SDL_Surface *texture = bitmap_surface(aref_or_nil(val, 1));
    int anim_nbr = aref_int(val, 2, 1);    // default 1 = no animation
    int anim_index = aref_int(val, 3, 0);
    if (anim_nbr <= 0) anim_nbr = 1;

    hm7::draw_textureset_entry(ctx->colormap, tile_num, tile_value,
                               texture, ctx->texture_auto,
                               anim_nbr, anim_index);
    return ST_CONTINUE;
}
}  // anonymous namespace

RB_METHOD(hm7NativeDrawTextureset) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    VALUE texture_hash_v = argv[0];
    VALUE colormap_v = argv[1];
    VALUE texture_auto_v = argv[2];

    SDL_Surface *colormap = bitmap_surface(colormap_v);
    if (!colormap) return INT2FIX(0);
    SDL_Surface *texture_auto = bitmap_surface(texture_auto_v);
    // texture_auto can be nil if no autotile textures. That's fine,
    // the per-entry function handles null.

    if (!NIL_P(texture_hash_v) && RB_TYPE_P(texture_hash_v, T_HASH)) {
        DrawTexturesetCtx ctx = { colormap, texture_auto };
        rb_hash_foreach(texture_hash_v, (int (*)(ANYARGS))hm7_draw_textureset_iter,
                        reinterpret_cast<VALUE>(&ctx));
    }

    commit_bitmap(colormap_v);
    return INT2FIX(0);
}

// ----------------------------------------------------------------
//  HM7::Native.draw_map_tileset(map_tileset, tileset, heightset,
//                               tilemap_hash, auto_tilesets) -> nil
//
// Ruby: from 210-HM7_NEW_CLASSES.rb:53 and 974.
// `tilemap_hash` is `Hash<Fixnum tile_num, Array>` where
// `Array = [layer0, layer1, layer2, bush_start]`. 4 ints.
// `auto_tilesets` is a 14-entry Array of Bitmaps/0:
//   [0..6]  autotile tileset graphics (nil-or-Bitmap each)
//   [7..13] autotile heightset graphics
// A missing / `0` slot skips that autotile group.
// ----------------------------------------------------------------

namespace {
// Extracts up to 7 Bitmap* entries from a Ruby Array slice
// `[offset, offset+7)`, filling `nullptr` for non-Bitmap slots.
void unwrap_autotile_bitmaps(VALUE arr, long offset,
                             SDL_Surface *out[7]) {
    for (int i = 0; i < 7; ++i) out[i] = nullptr;
    if (NIL_P(arr) || !RB_TYPE_P(arr, T_ARRAY)) return;
    long len = RARRAY_LEN(arr);
    for (int i = 0; i < 7; ++i) {
        long idx = offset + i;
        if (idx < 0 || idx >= len) continue;
        VALUE v = RARRAY_AREF(arr, idx);
        out[i] = bitmap_surface(v);
    }
}

struct DrawMapCtx {
    SDL_Surface *map_tileset;
    SDL_Surface *tileset;
    SDL_Surface *heightset;
    SDL_Surface *auto_tilesets[7];
    SDL_Surface *auto_heightsets[7];
};

int hm7_draw_map_iter(VALUE key, VALUE val, VALUE ctx_val) {
    DrawMapCtx *ctx = reinterpret_cast<DrawMapCtx *>(ctx_val);
    if (!FIXNUM_P(key)) return ST_CONTINUE;
    if (NIL_P(val) || !RB_TYPE_P(val, T_ARRAY)) return ST_CONTINUE;

    hm7::TileEntry entry = {};
    entry.tile_num = FIX2INT(key);
    // [layer0, layer1, layer2, bush_start]
    entry.layer_tile_values[0] = aref_int(val, 0);
    entry.layer_tile_values[1] = aref_int(val, 1);
    entry.layer_tile_values[2] = aref_int(val, 2);
    entry.layer_tile_values[3] = aref_int(val, 3);  // bush

    hm7::draw_map_tileset_entry(ctx->map_tileset, ctx->tileset,
                                ctx->heightset, entry,
                                ctx->auto_tilesets, 7,
                                ctx->auto_heightsets, 7,
                                kMapLayers);
    return ST_CONTINUE;
}

int hm7_refresh_map_iter(VALUE key, VALUE val, VALUE ctx_val) {
    DrawMapCtx *ctx = reinterpret_cast<DrawMapCtx *>(ctx_val);
    if (!FIXNUM_P(key)) return ST_CONTINUE;
    if (NIL_P(val) || !RB_TYPE_P(val, T_ARRAY)) return ST_CONTINUE;

    hm7::TileEntry entry = {};
    entry.tile_num = FIX2INT(key);
    entry.layer_tile_values[0] = aref_int(val, 0);
    entry.layer_tile_values[1] = aref_int(val, 1);
    entry.layer_tile_values[2] = aref_int(val, 2);
    entry.layer_tile_values[3] = aref_int(val, 3);

    hm7::refresh_map_tileset_entry(ctx->map_tileset, ctx->tileset, entry,
                                   ctx->auto_tilesets, 7, kMapLayers);
    return ST_CONTINUE;
}
}  // anonymous namespace

RB_METHOD(hm7NativeDrawMapTileset) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 5);
    VALUE map_tileset_v = argv[0];
    VALUE tileset_v = argv[1];
    VALUE heightset_v = argv[2];
    VALUE tilemap_hash_v = argv[3];
    VALUE auto_tilesets_v = argv[4];

    DrawMapCtx ctx = {};
    ctx.map_tileset = bitmap_surface(map_tileset_v);
    ctx.tileset = bitmap_surface(tileset_v);
    ctx.heightset = bitmap_surface(heightset_v);
    if (!ctx.map_tileset || !ctx.tileset || !ctx.heightset) return INT2FIX(0);

    unwrap_autotile_bitmaps(auto_tilesets_v, 0, ctx.auto_tilesets);
    unwrap_autotile_bitmaps(auto_tilesets_v, 7, ctx.auto_heightsets);

    if (!NIL_P(tilemap_hash_v) && RB_TYPE_P(tilemap_hash_v, T_HASH)) {
        rb_hash_foreach(tilemap_hash_v, (int (*)(ANYARGS))hm7_draw_map_iter,
                        reinterpret_cast<VALUE>(&ctx));
    }

    commit_bitmap(map_tileset_v);
    return INT2FIX(0);
}

// ----------------------------------------------------------------
//  HM7::Native.refresh_map_tileset(map_tileset, tileset,
//                                  tilemap_hash, auto_tilesets) -> nil
//
// Ruby: 210-HM7_NEW_CLASSES.rb:91. Same shapes as draw_map_tileset
// minus the heightset. Only updates color bytes, preserves height
// and bush metadata (for animated-autotile frame refresh).
// ----------------------------------------------------------------

RB_METHOD(hm7NativeRefreshMapTileset) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 4);
    VALUE map_tileset_v = argv[0];
    VALUE tileset_v = argv[1];
    VALUE tilemap_hash_v = argv[2];
    VALUE auto_tilesets_v = argv[3];

    DrawMapCtx ctx = {};
    ctx.map_tileset = bitmap_surface(map_tileset_v);
    ctx.tileset = bitmap_surface(tileset_v);
    if (!ctx.map_tileset || !ctx.tileset) return INT2FIX(0);

    unwrap_autotile_bitmaps(auto_tilesets_v, 0, ctx.auto_tilesets);
    // heightsets unused by refresh path

    if (!NIL_P(tilemap_hash_v) && RB_TYPE_P(tilemap_hash_v, T_HASH)) {
        rb_hash_foreach(tilemap_hash_v, (int (*)(ANYARGS))hm7_refresh_map_iter,
                        reinterpret_cast<VALUE>(&ctx));
    }

    commit_bitmap(map_tileset_v);
    return INT2FIX(0);
}

// ----------------------------------------------------------------
//  HM7::Native.render_hm7(params, vars, surfaces) -> int
//
// Ruby: `HM7.render_hm7(params, vars, surfaces)` from
//   210-HM7_NEW_CLASSES.rb:85. Returns the new camera Y offset
//   (`oCamera`) used by the Ruby side to auto-track height.
//
// `params` array shape (Insurgence's 13-entry flavour, missing
// entries fall back to defaults in the binding):
//   [0]  render (screen Bitmap)
//   [1]  computetable (Table, projection LUT)
//   [2]  rowsdata (lightline Bitmap)
//   [3]  heightmap (Table)
//   [4]  map_tileset (Bitmap)
//   [5]  tiletable (tilemap_data Table)
//   [6]  textureset (colormap Bitmap)
//   [7]  loop_x
//   [8]  loop_y
//   [9]  camera_mode
//   [10] s_screen_bitmap (scratch Bitmap)
//   [11] less_cut
//   [12] no_black_cut
//   [13..16] (not present in Insurgence, x_min/x_max/y_min/y_max)
//
// `vars` array: [height_limit, display_x, display_y, filter, o_scr_y]
// `surfaces` array: list of 11-Fixnum sub-arrays (see design doc section 2.4)
// ----------------------------------------------------------------

RB_METHOD(hm7NativeRenderHM7) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    VALUE params_v = argv[0];
    VALUE vars_v = argv[1];
    VALUE surfaces_v = argv[2];

    hm7::RenderParams rp = {};

    rp.screen_bitmap = bitmap_surface(aref_or_nil(params_v, 0));

    int data_zs_unused = 0;
    rp.data_table = table_data(aref_or_nil(params_v, 1),
                               &rp.data_xsize, &rp.data_ysize_real,
                               &data_zs_unused);
    (void)data_zs_unused;

    rp.lightline = bitmap_surface(aref_or_nil(params_v, 2));

    int hm_ys_unused = 0, hm_zs_unused = 0;
    rp.heightmap = table_data(aref_or_nil(params_v, 3),
                              &rp.heightmap_xsize, &hm_ys_unused,
                              &hm_zs_unused);
    (void)hm_ys_unused; (void)hm_zs_unused;

    rp.map_tileset = bitmap_surface(aref_or_nil(params_v, 4));

    int tm_zs_unused = 0;
    rp.tilemap_data = table_data(aref_or_nil(params_v, 5),
                                 &rp.tilemap_xsize, &rp.tilemap_ysize,
                                 &tm_zs_unused);
    (void)tm_zs_unused;

    rp.colormap = bitmap_surface(aref_or_nil(params_v, 6));
    rp.loop_x = aref_int(params_v, 7);
    rp.loop_y = aref_int(params_v, 8);
    rp.cam = aref_int(params_v, 9);
    rp.s_screen_bitmap = bitmap_surface(aref_or_nil(params_v, 10));
    rp.less_cut = aref_int(params_v, 11);
    rp.no_black = aref_int(params_v, 12);

    // Insurgence's @params doesn't include entries 13..16. Use sane
    // defaults so the full screen renders. The original Windows DLL
    // effectively did the same via uninitialized stack reads.
    const int screen_w = rp.screen_bitmap ? rp.screen_bitmap->w : 0;
    const int screen_h = rp.screen_bitmap ? rp.screen_bitmap->h : 0;
    rp.x_min = aref_int(params_v, 13, 0);
    rp.x_max = aref_int(params_v, 14, screen_w);
    rp.y_min = aref_int(params_v, 15, 0);
    rp.y_max_draw = aref_int(params_v, 16, screen_h);
    if (rp.x_max <= 0) rp.x_max = screen_w;
    if (rp.y_max_draw <= 0) rp.y_max_draw = screen_h;

    hm7::RenderVars rv = {};
    rv.height_limit = aref_int(vars_v, 0);
    // `display_x` / `display_y` are the 6-bit fractional-pixel
    // sub-tile offsets. The Windows plugin reads them as raw
    // tagged Fixnums (no `>> 1`, see MGC_Hmode7_1_4_4.cpp:863-
    // 864) and adds the result directly to xs/ys. The effective
    // value used in the pixel math is ~2n. Pre-double here so
    // the port's sampling lands at the same place.
    rv.display_x = aref_int_raw_tagged(vars_v, 1);
    rv.display_y = aref_int_raw_tagged(vars_v, 2);
    rv.filter = aref_int(vars_v, 3);
    rv.o_scr_y = aref_int(vars_v, 4);

    // Unpack surfaces. Cap at 256 sprites. Anything past that is
    // pathological for the game and would also overflow the stack
    // buffer we use below.
    constexpr int MAX_SURFACES = 256;
    hm7::RenderSurface surfaces[MAX_SURFACES];
    int surface_count = 0;
    if (!NIL_P(surfaces_v) && RB_TYPE_P(surfaces_v, T_ARRAY)) {
        long len = RARRAY_LEN(surfaces_v);
        if (len > MAX_SURFACES) len = MAX_SURFACES;
        for (long i = 0; i < len; ++i) {
            VALUE s = RARRAY_AREF(surfaces_v, i);
            if (NIL_P(s) || !RB_TYPE_P(s, T_ARRAY)) continue;
            // Defensive: reject anything that doesn't carry the
            // full v1.4.4 11-element layout. The shim's nil-bitmap
            // fallback returns nil (hit by NIL_P above), but an
            // older HM7 engine or a differently-patched fork might
            // push a 6-element v1.2.1 array here. Reading index
            // [5] as `inverse` in that case would pick up
            // `blend_type`, which would mirror the sprite
            // horizontally when non-zero. Skip rather than risk it.
            if (RARRAY_LEN(s) < 11) continue;
            hm7::RenderSurface &rs = surfaces[surface_count];
            // Slot [0] is the surface type. The renderer draws every
            // sprite as a billboard, so it does not take that field.
            rs.screen_x1 = aref_int(s, 1);
            rs.screen_y1 = aref_int(s, 2);
            rs.screen_x2 = aref_int(s, 3);
            rs.screen_y2 = aref_int(s, 4);
            rs.inverse = aref_int(s, 5);
            rs.bitmap = bitmap_surface(aref_or_nil(s, 6));
            rs.dh = aref_int(s, 7);
            rs.blend = aref_int(s, 8);
            rs.disp_width = aref_int(s, 9);
            rs.disp_offset = aref_int(s, 10);
            ++surface_count;
        }
    }

    // Assert: s_screen_bitmap must be 2x render width because the
    // renderer packs 8 bytes per column slot (flag, blend, hbase hi/
    // lo, r, g, b, a) and a regular Bitmap's pitch is only 4 bytes
    // per pixel. The postload shim reallocates @params[10] in
    // `HM7::Tilemap#initialize` to accomplish this. If the shim
    // failed to run (e.g. Ruby visibility / `method_defined?` quirk
    // on `initialize`), sprite writes at `sXt >= render_w / 2`
    // would wrap into adjacent rows and render sprites at bogus
    // positions near the left edge. Log once and loudly if we
    // detect the mismatch so the bug doesn't silently re-appear.
    if (rp.s_screen_bitmap && rp.screen_bitmap) {
        static int widthWarned = 0;
        const int expected = rp.screen_bitmap->w * 2;
        if (!widthWarned && rp.s_screen_bitmap->w != expected) {
            char buf[128];
            std::snprintf(buf, sizeof(buf),
                "s_screen width=%d expected=%d (shim failed to "
                "reallocate; sprites will render at wrong positions)",
                rp.s_screen_bitmap->w, expected);
            mkxp_debugLog("HM7-WARN", "hmode7-binding.cpp [C++]", buf);
            widthWarned = 1;
        }
    }

    // Clear the sprite-compositing scratch buffer at frame start.
    // The renderer writes 8-byte-per-column records into
    // `s_screen_bitmap` and expects them to be zero outside the
    // regions it touches in the current frame. Prior writes normally
    // get cleared by the wall loop / final overdraw passes as they
    // move through each column, so within a single frame we should
    // always end with a clean buffer. But *between* frames, any
    // cells that the renderer wrote during frame N and did not
    // read-and-clear (e.g. because the current `(yt, xt)` coverage
    // didn't reach them, which can happen near the screen edges in
    // extreme camera poses) would leak stale sprite data into
    // frame N+1's ground-compose path, manifesting as phantom
    // sprite pixels at positions the current frame's surfaces
    // don't occupy.
    //
    // Cost: ~2.5 MiB memset for a 1280 x 480 bitmap, or <1 ms on
    // modern ARM. Negligible compared to the render itself and
    // eliminates a whole class of cross-frame correctness bugs.
    if (rp.s_screen_bitmap) {
        std::memset(rp.s_screen_bitmap->pixels, 0,
                    static_cast<std::size_t>(rp.s_screen_bitmap->pitch) *
                    rp.s_screen_bitmap->h);
    }

    // Wall-layer-selection mode. Looked up on the module each call
    // (cheap - module constant is a hash probe) so a
    // game's postload shim can set it before or even during play.
    // Defaults to `:top_cumulative` if unset or invalid. See
    // `WallLayerMode` in hm7_render.h for rationale.
    hm7::WallLayerMode wall_mode = hm7::WallLayerMode::TopCumulative;
    {
        VALUE hm7_module = rb_const_get(rb_cObject, rb_intern("HM7"));
        VALUE native_module = rb_const_get(hm7_module, rb_intern("Native"));
        ID id_mode = rb_intern("WALL_LAYER_MODE");
        if (rb_const_defined(native_module, id_mode)) {
            VALUE v = rb_const_get(native_module, id_mode);
            if (SYMBOL_P(v)) {
                ID sym = SYM2ID(v);
                if (sym == rb_intern("bottom_cumulative") ||
                    sym == rb_intern("v1_4") ||
                    sym == rb_intern("reference")) {
                    wall_mode = hm7::WallLayerMode::BottomCumulative;
                }
            }
        }
    }

    if (!packed_tilemap_is_sane(rp.tilemap_xsize, "render_hm7")) {
        return INT2FIX(0);
    }

    int o_camera = hm7::render_hm7(rp, rv, surfaces, surface_count,
                                   kMapLayers, wall_mode);

    // Commit all bitmaps the renderer wrote to.
    commit_bitmap(aref_or_nil(params_v, 0));   // screen_bitmap
    commit_bitmap(aref_or_nil(params_v, 2));   // lightline (scratch)
    commit_bitmap(aref_or_nil(params_v, 10));  // s_screen_bitmap (scratch)

    return INT2FIX(o_camera);
}

}  // anonymous namespace

void hmode7BindingInit() {
    VALUE mHM7 = rb_define_module("HM7");
    VALUE mNative = rb_define_module_under(mHM7, "Native");

    _rb_define_module_function(mNative, "apply_opacity",
                               hm7NativeApplyOpacity);
    _rb_define_module_function(mNative, "apply_zoom",
                               hm7NativeApplyZoom);
    _rb_define_module_function(mNative, "apply_lighting",
                               hm7NativeApplyLighting);
    _rb_define_module_function(mNative, "compute_m7",
                               hm7NativeComputeM7);
    _rb_define_module_function(mNative, "draw_heightmap",
                               hm7NativeDrawHeightmap);
    _rb_define_module_function(mNative, "draw_textureset",
                               hm7NativeDrawTextureset);
    _rb_define_module_function(mNative, "draw_map_tileset",
                               hm7NativeDrawMapTileset);
    _rb_define_module_function(mNative, "refresh_map_tileset",
                               hm7NativeRefreshMapTileset);
    _rb_define_module_function(mNative, "render_hm7",
                               hm7NativeRenderHM7);

    // Sentinel constant the postload shim checks: if present, it
    // replaces the Win32API-based HM7.self.xxx methods with wrappers
    // that call this module.
    rb_define_const(mNative, "AVAILABLE", Qtrue);

    // `HM7::Native::WALL_LAYER_MODE` is intentionally NOT defined
    // here. The postload shim auto-detects the HM7 script's era
    // (pre-V1.3 vs V1.3+/V1.4+) and assigns the constant based on
    // that detection. If no shim runs at all, the binding falls
    // back to `TopCumulative` at render time (the pre-V1.3
    // behaviour that works for every currently-known caller -
    // see WALL_LAYER_MODE.md).
}
