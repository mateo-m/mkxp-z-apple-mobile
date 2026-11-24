# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The engine keeps the texts of draw_text on the CPU and sends them to
# the texture before the next use of a bitmap. A game must not see
# this: each text is in the bitmap for the next call, in the order of
# the calls. Many texts on drawn pixels in one frame must not make the
# frame wait for the GPU.
#
#   tools/run-engine-tests.sh --suite text_draw.rb
#
# This file must parse on Ruby 1.8, 1.9, and 3.x.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('text-draw', 14)

BACK = Color.new(40, 90, 200, 255)
THIN = Color.new(200, 60, 30, 128)
INK = Color.new(255, 230, 40, 200)
WIDTH = 240
HEIGHT = 96
LINE = 28

def drawn_bitmap
  bitmap = Bitmap.new(WIDTH, HEIGHT)
  bitmap.fill_rect(0, 0, WIDTH / 2, HEIGHT, BACK)
  bitmap.fill_rect(WIDTH / 2, 0, WIDTH / 2, HEIGHT, THIN)
  bitmap.font.size = 22
  bitmap.font.color = INK
  bitmap
end

def with_bitmaps(*bitmaps)
  yield(*bitmaps)
ensure
  bitmaps.each { |bitmap| bitmap.dispose unless bitmap.disposed? }
end

def largest_difference(one, other)
  a = one.unpack('C*')
  b = other.unpack('C*')
  largest = 0
  a.each_index do |i|
    difference = (a[i] - b[i]).abs
    largest = difference if difference > largest
  end
  largest
end

def text_pixels(bitmap, back)
  count = 0
  bitmap.raw_data.unpack('C*').each_slice(4) { |pixel| count += 1 unless pixel == back }
  count
end

def assert_same_pixels(expected, actual, label)
  EngineTest.assert(expected == actual, "#{label}: the pixels differ")
end

def assert_other_pixels(unexpected, actual, label)
  EngineTest.assert(unexpected != actual, "#{label}: the pixels are the same")
end

# The picture draw of a text from a cleared bitmap is the same blend
# as the text draw. The two differ only in the rounding of a channel.
def assert_same_picture(expected, actual, label)
  EngineTest.assert_equal(expected.raw_data.size, actual.raw_data.size, "#{label}, size")
  difference = largest_difference(expected.raw_data, actual.raw_data)
  EngineTest.assert(difference <= 2, "#{label}: a channel differs by #{difference}")
end

def draw_as_picture(bitmap, x, y, width, text)
  with_bitmaps(Bitmap.new(width, LINE)) do |part|
    part.font.size = bitmap.font.size
    part.font.color = bitmap.font.color
    part.draw_text(0, 0, width, LINE, text)
    bitmap.blt(x, y, part, part.rect)
  end
end

BACK_PIXEL = [40, 90, 200, 255].freeze

# All the texts go to the first bitmap before the first picture draw,
# because a call on one more bitmap sends the texts to the texture.
def compare_with_pictures(texts, pictures, lines, label)
  lines.each { |x, y, width, text| texts.draw_text(x, y, width, LINE, text) }
  lines.each { |x, y, width, text| draw_as_picture(pictures, x, y, width, text) } # rubocop:disable Style/CombinableLoops
  assert_same_picture(pictures, texts, label)
end

def half_drawn_bitmap
  bitmap = Bitmap.new(WIDTH, HEIGHT)
  bitmap.fill_rect(0, 0, WIDTH / 2, HEIGHT, BACK)
  bitmap.font.size = 22
  bitmap.font.color = INK
  bitmap
end

def cleared_bitmap
  bitmap = Bitmap.new(WIDTH, HEIGHT)
  bitmap.font.size = 22
  bitmap.font.color = INK
  bitmap
end

def edge_lines(bitmap)
  lines = [[-20, 2, 'Left edge gjpqy'], [WIDTH - 60, 30, 'Right edge gjpqy'],
           [70, HEIGHT - 12, 'Bottom edge gjpqy'], [130, -10, 'Top edge']]
  lines.map { |x, y, text| [x, y, bitmap.text_size(text).width + 2, text] }
end

EngineTest.test('texts that overlap on drawn pixels are the picture draws of the same texts') do
  with_bitmaps(drawn_bitmap, drawn_bitmap) do |texts, pictures|
    lines = [[4, 2, 'Earthquake gjpqy'], [30, 14, 'Swords Dance'], [60, 26, 'Stone Edge gjpqy'],
             [100, 60, 'Protect']]
    lines = lines.map { |x, y, text| [x, y, texts.text_size(text).width + 2, text] }
    compare_with_pictures(texts, pictures, lines, 'four texts')
    on_back = text_pixels(texts, BACK_PIXEL) - (WIDTH * HEIGHT / 2)
    EngineTest.assert(on_back > 200, "the texts changed #{on_back} pixels of the left half")
  end
end

EngineTest.test('a narrow text between two texts keeps its place in the order') do
  with_bitmaps(drawn_bitmap, drawn_bitmap) do |texts, pictures|
    full = texts.text_size('Dragon Dance gjpqy').width + 2
    lines = [[4, 20, full], [20, 26, full * 2 / 3], [36, 32, full]]
    lines = lines.map { |x, y, width| [x, y, width, 'Dragon Dance gjpqy'] }
    compare_with_pictures(texts, pictures, lines, 'three texts')
  end
end

EngineTest.test('texts on cleared pixels and across the edges are the picture draws') do
  with_bitmaps(cleared_bitmap, cleared_bitmap) do |texts, pictures|
    compare_with_pictures(texts, pictures, edge_lines(texts), 'four texts')
    EngineTest.assert(text_pixels(texts, [0, 0, 0, 0]) > 200, 'the texts left no pixels')
  end
end

EngineTest.test('texts on drawn and on cleared pixels in one frame are the picture draws') do
  with_bitmaps(half_drawn_bitmap, half_drawn_bitmap) do |texts, pictures|
    compare_with_pictures(texts, pictures, edge_lines(texts), 'four texts')
  end
end

# A blur moves pixels into places that the engine does not record as
# drawn. The pixel between the two texts is one of them.
EngineTest.test('two texts keep the blurred pixels between them') do
  with_bitmaps(cleared_bitmap) do |bitmap|
    bitmap.fill_rect(40, 12, 40, 30, BACK)
    bitmap.blur
    between = [60, 11]
    blurred = EngineTest.pixel(bitmap, between)
    EngineTest.assert(blurred[3] > 0, "the blur left no pixel at #{between.inspect}")
    bitmap.draw_text(0, 0, 30, 12, 'a')
    bitmap.draw_text(100, 0, 30, 12, 'b')
    EngineTest.assert_equal(blurred, EngineTest.pixel(bitmap, between), 'the pixel between the texts')
  end
end

# The first read makes a copy of the pixels on the CPU. The second
# read must not use that copy.
EngineTest.test('a text is in the bitmap for the next read of a pixel') do
  with_bitmaps(drawn_bitmap) do |bitmap|
    EngineTest.assert_equal(BACK_PIXEL, EngineTest.pixel(bitmap, [4, 44]), 'the pixel before the text')
    bitmap.draw_text(4, 30, 110, LINE, 'MMMMMM')
    changed = (4...100).reject { |x| EngineTest.pixel(bitmap, [x, 44]) == BACK_PIXEL }
    EngineTest.assert(!changed.empty?, 'get_pixel found no pixel of the text')
  end
end

EngineTest.test('a fill after a text covers the text') do
  with_bitmaps(drawn_bitmap, Bitmap.new(WIDTH, HEIGHT)) do |bitmap, filled|
    bitmap.draw_text(4, 30, 200, LINE, 'Under the fill')
    bitmap.fill_rect(0, 0, WIDTH, HEIGHT, BACK)
    filled.fill_rect(0, 0, WIDTH, HEIGHT, BACK)
    assert_same_pixels(filled.raw_data, bitmap.raw_data, 'after the fill')
  end
end

EngineTest.test('a clear after a text removes the text, and a later text stays') do
  with_bitmaps(drawn_bitmap) do |bitmap|
    bitmap.draw_text(4, 30, 200, LINE, 'Before the clear')
    bitmap.clear
    EngineTest.assert_equal(0, text_pixels(bitmap, [0, 0, 0, 0]), 'pixels after the clear')
    bitmap.draw_text(4, 30, 200, LINE, 'After the clear')
    EngineTest.assert(text_pixels(bitmap, [0, 0, 0, 0]) > 100, 'the later text left no pixels')
  end
end

EngineTest.test('each of two bitmaps gets its own texts') do
  with_bitmaps(drawn_bitmap, drawn_bitmap, drawn_bitmap) do |top, bottom, plain|
    3.times do |i|
      top.draw_text(4 + (i * 30), 4, 100, LINE, 'Top')
      bottom.draw_text(4 + (i * 30), 60, 100, LINE, 'Bottom')
    end
    half = WIDTH * (HEIGHT / 2) * 4
    plain_data = plain.raw_data
    top_data = top.raw_data
    bottom_data = bottom.raw_data
    assert_same_pixels(plain_data[half, half], top_data[half, half], 'lower half of the first bitmap')
    assert_same_pixels(plain_data[0, half], bottom_data[0, half], 'upper half of the second bitmap')
    assert_other_pixels(plain_data[0, half], top_data[0, half], 'upper half of the first bitmap')
    assert_other_pixels(plain_data[half, half], bottom_data[half, half], 'lower half of the second bitmap')
  end
end

EngineTest.test('a copy of a bitmap has its text') do
  with_bitmaps(drawn_bitmap, drawn_bitmap) do |bitmap, plain|
    bitmap.draw_text(4, 30, 200, LINE, 'Source gjpqy')
    with_bitmaps(bitmap.dup) do |copy|
      assert_other_pixels(plain.raw_data, copy.raw_data, 'the copy and a bitmap without text')
      assert_same_pixels(bitmap.raw_data, copy.raw_data, 'the copy')
    end
  end
end

EngineTest.test('a picture draw from a bitmap has its text') do
  with_bitmaps(drawn_bitmap, drawn_bitmap, Bitmap.new(WIDTH, HEIGHT)) do |bitmap, plain, target|
    bitmap.draw_text(4, 30, 200, LINE, 'Source gjpqy')
    target.blt(0, 0, bitmap, bitmap.rect)
    assert_other_pixels(plain.raw_data, target.raw_data, 'the picture draw and a bitmap without text')
    assert_same_pixels(bitmap.raw_data, target.raw_data, 'the picture draw')
  end
end

EngineTest.test('a disposed bitmap does not give its text to the next bitmap') do
  bitmap = drawn_bitmap
  bitmap.draw_text(4, 30, 200, LINE, 'Gone gjpqy')
  bitmap.dispose
  with_bitmaps(Bitmap.new(WIDTH, HEIGHT)) do |later|
    EngineTest.assert_equal(0, text_pixels(later, [0, 0, 0, 0]), 'pixels of the next bitmap')
  end
end

EngineTest.test('the screen shows a text without one more call on the bitmap') do
  viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
  viewport.z = 99_999
  sprite = Sprite.new(viewport)
  sprite.bitmap = Bitmap.new(WIDTH, HEIGHT)
  sprite.bitmap.fill_rect(0, 0, WIDTH, HEIGHT, BACK)
  sprite.bitmap.font.size = 22
  begin
    Graphics.update
    with_bitmaps(Graphics.snap_to_bitmap) do |before|
      sprite.bitmap.draw_text(4, 30, 200, LINE, 'MMMMMM')
      with_bitmaps(Graphics.snap_to_bitmap) do |after|
        assert_other_pixels(before.raw_data, after.raw_data, 'the screen after the text')
      end
    end
  ensure
    sprite.bitmap.dispose
    sprite.dispose
    viewport.dispose
  end
end

TEXTS = 248

def texts_ms(bitmap, width)
  start = Time.now
  TEXTS.times { |i| bitmap.draw_text((i % 16) * width, (i / 16) * 16, width, 16, 'Earthquake') }
  bitmap.get_pixel(0, 0)
  (Time.now - start) * 1000
end

# A battle menu of Pokemon Essentials draws 248 texts on drawn pixels
# in one frame. The time is not the same on each computer, so the
# test compares it with the time of the same texts on cleared pixels.
# On an iPhone 13 Pro, the texts on drawn pixels took 15 times that
# with one GPU draw for each text.
EngineTest.test('many texts on drawn pixels take the time of the texts on cleared pixels') do
  with_bitmaps(Bitmap.new(8, 8)) do |probe|
    probe.font.size = 12
    width = probe.text_size('Earthquake').width + 2
    with_bitmaps(Bitmap.new(width * 16, 256), Bitmap.new(width * 16, 256)) do |drawn, cleared|
      [drawn, cleared].each { |bitmap| bitmap.font.size = 12 }
      drawn_ms = []
      cleared_ms = []
      5.times do
        drawn.fill_rect(0, 0, drawn.width, drawn.height, BACK)
        drawn.get_pixel(0, 0)
        drawn_ms << texts_ms(drawn, width)
        cleared.clear
        cleared.get_pixel(0, 0)
        cleared_ms << texts_ms(cleared, width)
      end
      on_drawn = format('%.1f', drawn_ms.min)
      on_cleared = format('%.1f', cleared_ms.min)
      EngineTest.info('drawn_ms', on_drawn)
      EngineTest.info('cleared_ms', on_cleared)
      EngineTest.assert(drawn_ms.min < cleared_ms.min * 4,
                        "#{on_drawn} ms on drawn pixels, and #{on_cleared} ms on cleared pixels")
    end
  end
end

EngineTest.finish
exit
