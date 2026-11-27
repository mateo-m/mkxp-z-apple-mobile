# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The hm7_* library that a game can ship (hmode7/src/
# hm7_library.cpp), called through Win32API with the arguments that
# the game's HM7 scripts give.
#
#   tools/run-engine-tests.sh --suite hmode7_flat.rb --ruby 31

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('hmode7-flat', 7)
EngineTest.load_preloads(%w[windows_fs platform_compat pokemon_compat win32_wrap])

module FlatHM7
  LIB = './libhmode7.so'.freeze
  MAP_W = 20
  MAP_H = 15
  SCREEN_W = 640
  SCREEN_H = 480
  RED = [255, 0, 0, 255].freeze
  BLUE = [0, 0, 255, 255].freeze

  module_function

  def call(name, imports, *args)
    Win32API.new(LIB, name, imports, name == 'hm7_last_error' ? 'p' : 'l').call(*args)
  end

  def image(width, height, rgba = nil)
    pixels = rgba ? rgba.pack('C*') * (width * height) : "\0" * (width * height * 4)
    call('hm7_image_create', 'pll', pixels, width, height)
  end

  DISTANCE_H = 480
  PIVOT = 240

  # The values of HM7::Tilemap#refresh_alpha with the defaults of
  # Game_System#hm7_reset, at 100 % zoom.
  def parameters(alpha)
    rad = Math::PI * alpha / 180
    cos_alpha = (2048 * Math.cos(rad)).to_i
    sin_alpha = (2048 * Math.sin(rad)).to_i
    slope, corrective = slope_and_corrective(cos_alpha, sin_alpha)
    [cos_alpha, sin_alpha, DISTANCE_H, PIVOT, (131_072 * slope).to_i, (131_072 * corrective).to_i,
     [height_limit(cos_alpha, sin_alpha), 0].max, 2048, 0, 0, 4096, 0]
  end

  def slope_and_corrective(cos_alpha, sin_alpha)
    depth = DISTANCE_H << 11
    h0 = ((-DISTANCE_H * PIVOT * cos_alpha) / (depth + (PIVOT * sin_alpha))) + PIVOT
    z0 = depth.to_f / (depth + (PIVOT * sin_alpha))
    slope = (1.0 - z0) / (PIVOT - h0)
    [slope, 1.0 - (PIVOT * slope)]
  end

  def height_limit(cos_alpha, sin_alpha)
    last_line = -PIVOT - 960
    ((DISTANCE_H * last_line * cos_alpha) / ((DISTANCE_H << 11) - (last_line * sin_alpha))) + PIVOT
  end

  # A map of tileset tile 384 on every cell: one tiles combination, flat.
  def build_map(loop_y = 0)
    ctx = call('hm7_ctx_create', 'lllllllll', MAP_W, MAP_H, SCREEN_W, SCREEN_H, 0, loop_y, 0, 0, 0)
    tileset = image(256, 32, RED)
    heightset = image(256, 32)
    call('hm7_map_set_tileset', 'lll', ctx, tileset, heightset)
    [tileset, heightset].each { |id| call('hm7_image_free', 'l', id) }
    table = Array.new(MAP_W * MAP_H) { [0, 0, 0, 0] }.flatten
    call('hm7_map_set_tiletable', 'lpll', ctx, table.pack('s<*'), MAP_W << 2, MAP_H)
    call('hm7_map_set_combos', 'lpl', ctx, [0, 384, 0, 0, 1].pack('l<*'), 1)
    call('hm7_map_set_animated', 'lpl', ctx, '', 0)
    texture_auto = image(256, 192)
    call('hm7_map_set_texture_auto', 'll', ctx, texture_auto)
    call('hm7_image_free', 'l', texture_auto)
    call('hm7_map_build', 'lllll', ctx, 1, 1, 0, 0)
    ctx
  end

  def compute(ctx, alpha)
    call('hm7_compute', 'lpllll', ctx, parameters(alpha).pack('l<*'), 0, 0, 255, 1)
  end

  def render(ctx, alpha, surfaces = [])
    buf = "\0" * (SCREEN_W * SCREEN_H * 4)
    vars = [parameters(alpha)[6], 0, 0, 0, 0]
    ret = call('hm7_render', 'lpllllllpl', ctx, buf, buf.bytesize, *vars,
               surfaces.flatten.pack('l<*'), surfaces.length)
    [ret, buf]
  end

  def pixel(buf, x, y)
    buf.unpack("@#{(x + (y * SCREEN_W)) * 4}C4")
  end

  # The horizon fade of the game is additive blue (Color.new(0, 0, 255,
  # 1)). Seen from above, compute_m7 makes it 255 * (pivot - y) / 960 on
  # each row over the pivot.
  def faded(y)
    [255, 0, 255 * (PIVOT - y) / 960, 255]
  end

  # compute_m7 packs the zoom of each row as (a << 12) / xp0, with
  # xp0 = zoom * ((a << 18) / (slope * y + corrective)) >> 12, and the
  # slope and corrective values in the doubled scale of the DLL.
  def expected_row_zoom(alpha, y)
    p = parameters(alpha)
    a = SCREEN_W >> 1
    slope = (p[4] << 1) | 1
    corrective = (p[5] << 1) | 1
    xp0 = (p[10] * ((a << 18) / ((slope * y) + corrective))) >> 12
    (a << 12) / xp0
  end
end

EngineTest.test('the library answers its ABI version') do
  EngineTest.assert_equal(1, FlatHM7.call('hm7_abi_version', ''), 'hm7_abi_version')
end

EngineTest.test('a flat map draws its tile color, with the horizon fade over the pivot') do
  ctx = FlatHM7.build_map
  EngineTest.assert(ctx.positive?, "hm7_ctx_create returned #{ctx}")
  EngineTest.assert_equal(0, FlatHM7.compute(ctx, 0), 'hm7_compute')
  ret, buf = FlatHM7.render(ctx, 0)
  EngineTest.assert(ret >= 0, "hm7_render returned #{ret}: #{FlatHM7.call('hm7_last_error', '')}")
  # The zoom of 4108 / 4096 puts the last row and column just past the map.
  [[320, 240], [320, 300], [638, 478]].each do |x, y|
    EngineTest.assert_equal(FlatHM7::RED, FlatHM7.pixel(buf, x, y), "screen pixel #{x},#{y}")
  end
  [0, 100, 239].each do |y|
    EngineTest.assert_equal(FlatHM7.faded(y), FlatHM7.pixel(buf, 320, y), "faded screen pixel 320,#{y}")
  end
  FlatHM7.call('hm7_ctx_destroy', 'l', ctx)
end

EngineTest.test('a slanted map draws the ground at the bottom and the fade at the top') do
  # At 60 degrees the bottom screen row looks past a 15-tile map, so the
  # map loops vertically.
  ctx = FlatHM7.build_map(1)
  FlatHM7.compute(ctx, 60)
  _ret, buf = FlatHM7.render(ctx, 60)
  EngineTest.assert_equal(FlatHM7::RED, FlatHM7.pixel(buf, 320, 479), 'ground under the camera')
  EngineTest.refute_equal(FlatHM7::RED, FlatHM7.pixel(buf, 320, 0), 'the top row')
  FlatHM7.call('hm7_ctx_destroy', 'l', ctx)
end

EngineTest.test('the row zoom of a flat map follows the integer math of compute_m7') do
  ctx = FlatHM7.build_map
  FlatHM7.compute(ctx, 0)
  zoom = FlatHM7.call('hm7_row_zoom', 'll', ctx, 240)
  EngineTest.assert_equal(FlatHM7.expected_row_zoom(0, 240), zoom, 'hm7_row_zoom')
  EngineTest.assert(zoom > 4096 && zoom < 4096 * 101 / 100, "hm7_row_zoom near 4096: #{zoom}")
  FlatHM7.call('hm7_ctx_destroy', 'l', ctx)
end

EngineTest.test('a character sprite draws over the map') do
  ctx = FlatHM7.build_map
  FlatHM7.compute(ctx, 0)
  sprite = FlatHM7.image(32, 48, FlatHM7::BLUE)
  _ret, buf = FlatHM7.render(ctx, 0, [[0, 320, 300, sprite, 0, 0]])
  EngineTest.assert_equal(FlatHM7::BLUE, FlatHM7.pixel(buf, 320, 290), 'pixel in the sprite')
  EngineTest.assert_equal(FlatHM7::RED, FlatHM7.pixel(buf, 100, 400), 'pixel away from the sprite')
  FlatHM7.call('hm7_image_free', 'l', sprite)
  FlatHM7.call('hm7_ctx_destroy', 'l', ctx)
end

EngineTest.test('a call with an unknown context fails with a reason') do
  EngineTest.assert_equal(-1, FlatHM7.call('hm7_row_zoom', 'll', 9999, 0), 'hm7_row_zoom')
  EngineTest.assert_equal('row_zoom: unknown context', FlatHM7.call('hm7_last_error', ''), 'hm7_last_error')
end

EngineTest.test('a surface with an unknown image fails with a reason') do
  ctx = FlatHM7.build_map
  FlatHM7.compute(ctx, 0)
  ret, _buf = FlatHM7.render(ctx, 0, [[0, 320, 300, 9999, 0, 0]])
  EngineTest.assert_equal(-1, ret, 'hm7_render')
  EngineTest.assert_equal('render: surface references an unknown image',
                          FlatHM7.call('hm7_last_error', ''), 'hm7_last_error')
  FlatHM7.call('hm7_ctx_destroy', 'l', ctx)
end

EngineTest.finish
exit
