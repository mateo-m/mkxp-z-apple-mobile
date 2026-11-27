// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

// The hm7_* functions of the H-Mode7 library that a game can ship
// (hmode7.dll, libhmode7.so). The game calls them through Win32API,
// and scripts/preload/win32_wrap.rb sends each call to HM7::Native.
//
// A negative return makes the game raise HM7::Error with the text of
// hm7_last_error.

#include "binding-util.h"

#include <cstddef>

#include "hm7_library.h"

namespace {

struct Bytes {
    char *ptr;
    std::size_t len;
};

// The game packs its buffers in Strings. Any other value has no bytes,
// and the library rejects it.
Bytes string_bytes(VALUE v) {
    if (!RB_TYPE_P(v, T_STRING)) return {nullptr, 0};
    return {RSTRING_PTR(v), static_cast<std::size_t>(RSTRING_LEN(v))};
}

RB_METHOD(hm7AbiVersion) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 0);
    return rb_int2inum(hm7::library::abi_version());
}

RB_METHOD(hm7LastError) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 0);
    return rb_str_new2(hm7::library::last_error());
}

RB_METHOD(hm7Stats) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 0);
    return rb_int2inum(hm7::library::stats());
}

RB_METHOD(hm7ImageCreate) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    const Bytes pixels = string_bytes(argv[0]);
    return rb_int2inum(hm7::library::image_create(pixels.ptr, pixels.len, NUM2INT(argv[1]), NUM2INT(argv[2])));
}

RB_METHOD(hm7ImageUpdate) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 5);
    const Bytes pixels = string_bytes(argv[1]);
    return rb_int2inum(hm7::library::image_update(NUM2INT(argv[0]), pixels.ptr, pixels.len, NUM2INT(argv[2]),
                                                  NUM2INT(argv[3]), NUM2INT(argv[4])));
}

RB_METHOD(hm7ImageFree) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 1);
    return rb_int2inum(hm7::library::image_free(NUM2INT(argv[0])));
}

RB_METHOD(hm7CtxCreate) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 9);
    return rb_int2inum(hm7::library::ctx_create(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2]),
                                                NUM2INT(argv[3]), NUM2INT(argv[4]), NUM2INT(argv[5]),
                                                NUM2INT(argv[6]), NUM2INT(argv[7]), NUM2INT(argv[8])));
}

RB_METHOD(hm7CtxDestroy) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 1);
    return rb_int2inum(hm7::library::ctx_destroy(NUM2INT(argv[0])));
}

RB_METHOD(hm7SetOption) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    return rb_int2inum(hm7::library::set_option(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2])));
}

RB_METHOD(hm7MapSetTileset) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    return rb_int2inum(hm7::library::map_set_tileset(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2])));
}

RB_METHOD(hm7MapSetAutotile) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 5);
    return rb_int2inum(hm7::library::map_set_autotile(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2]),
                                                      NUM2INT(argv[3]), NUM2INT(argv[4])));
}

RB_METHOD(hm7MapSetTiletable) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 4);
    const Bytes cells = string_bytes(argv[1]);
    return rb_int2inum(hm7::library::map_set_tiletable(NUM2INT(argv[0]), cells.ptr, cells.len, NUM2INT(argv[2]),
                                                       NUM2INT(argv[3])));
}

RB_METHOD(hm7MapSetCombos) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    const Bytes records = string_bytes(argv[1]);
    return rb_int2inum(
        hm7::library::map_set_combos(NUM2INT(argv[0]), records.ptr, records.len, NUM2INT(argv[2])));
}

RB_METHOD(hm7MapSetAnimated) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    const Bytes keys = string_bytes(argv[1]);
    return rb_int2inum(hm7::library::map_set_animated(NUM2INT(argv[0]), keys.ptr, keys.len, NUM2INT(argv[2])));
}

RB_METHOD(hm7MapAddTexture) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 4);
    return rb_int2inum(hm7::library::map_add_texture(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2]),
                                                     NUM2INT(argv[3])));
}

RB_METHOD(hm7MapSetTextureAuto) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 2);
    return rb_int2inum(hm7::library::map_set_texture_auto(NUM2INT(argv[0]), NUM2INT(argv[1])));
}

RB_METHOD(hm7MapBuild) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 5);
    return rb_int2inum(hm7::library::map_build(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2]),
                                               NUM2INT(argv[3]), NUM2INT(argv[4])));
}

RB_METHOD(hm7MapAnimate) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 2);
    const Bytes frames = string_bytes(argv[1]);
    return rb_int2inum(hm7::library::map_animate(NUM2INT(argv[0]), frames.ptr, frames.len));
}

RB_METHOD(hm7Compute) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 6);
    const Bytes params = string_bytes(argv[1]);
    return rb_int2inum(hm7::library::compute(NUM2INT(argv[0]), params.ptr, params.len, NUM2INT(argv[2]),
                                             NUM2INT(argv[3]), NUM2INT(argv[4]), NUM2INT(argv[5])));
}

RB_METHOD(hm7Render) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 10);
    // The library draws into the game's String, so it must own its bytes.
    if (RB_TYPE_P(argv[1], T_STRING)) rb_str_modify(argv[1]);
    const Bytes screen = string_bytes(argv[1]);
    const Bytes surfaces = string_bytes(argv[8]);
    return rb_int2inum(hm7::library::render(NUM2INT(argv[0]), screen.ptr, screen.len, NUM2LONG(argv[2]),
                                            NUM2INT(argv[3]), NUM2INT(argv[4]), NUM2INT(argv[5]),
                                            NUM2INT(argv[6]), NUM2INT(argv[7]), surfaces.ptr, surfaces.len,
                                            NUM2INT(argv[9])));
}

RB_METHOD(hm7RowZoom) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 2);
    return rb_int2inum(hm7::library::row_zoom(NUM2INT(argv[0]), NUM2INT(argv[1])));
}

RB_METHOD(hm7HeightmapGet) {
    RB_UNUSED_PARAM;
    rb_check_argc(argc, 3);
    return rb_int2inum(hm7::library::heightmap_get(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2])));
}

}  // namespace

void hmode7FlatBindingInit() {
    VALUE native = rb_define_module_under(rb_define_module("HM7"), "Native");
    _rb_define_module_function(native, "hm7_abi_version", hm7AbiVersion);
    _rb_define_module_function(native, "hm7_last_error", hm7LastError);
    _rb_define_module_function(native, "hm7_stats", hm7Stats);
    _rb_define_module_function(native, "hm7_image_create", hm7ImageCreate);
    _rb_define_module_function(native, "hm7_image_update", hm7ImageUpdate);
    _rb_define_module_function(native, "hm7_image_free", hm7ImageFree);
    _rb_define_module_function(native, "hm7_ctx_create", hm7CtxCreate);
    _rb_define_module_function(native, "hm7_ctx_destroy", hm7CtxDestroy);
    _rb_define_module_function(native, "hm7_set_option", hm7SetOption);
    _rb_define_module_function(native, "hm7_map_set_tileset", hm7MapSetTileset);
    _rb_define_module_function(native, "hm7_map_set_autotile", hm7MapSetAutotile);
    _rb_define_module_function(native, "hm7_map_set_tiletable", hm7MapSetTiletable);
    _rb_define_module_function(native, "hm7_map_set_combos", hm7MapSetCombos);
    _rb_define_module_function(native, "hm7_map_set_animated", hm7MapSetAnimated);
    _rb_define_module_function(native, "hm7_map_add_texture", hm7MapAddTexture);
    _rb_define_module_function(native, "hm7_map_set_texture_auto", hm7MapSetTextureAuto);
    _rb_define_module_function(native, "hm7_map_build", hm7MapBuild);
    _rb_define_module_function(native, "hm7_map_animate", hm7MapAnimate);
    _rb_define_module_function(native, "hm7_compute", hm7Compute);
    _rb_define_module_function(native, "hm7_render", hm7Render);
    _rb_define_module_function(native, "hm7_row_zoom", hm7RowZoom);
    _rb_define_module_function(native, "hm7_heightmap_get", hm7HeightmapGet);
}
