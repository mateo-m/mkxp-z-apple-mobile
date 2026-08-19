# Mega-surface regression suite.
#
# Adapted from tests/mega-bitmap/mega-bitmap-test.rb in upstream
# mkxp-z (Copyright 2023-2026 Splendide Imaginarius, GPLv2+). The
# upstream suite dumps PNG files for a person to look at, and it
# builds 16383-pixel-wide bitmaps to get past the hardware texture
# limit. This version keeps the operation coverage but asserts the
# result, and it forces mega surfaces through the "maxTextureSize"
# key in mkxp.json instead, so every bitmap here stays small enough
# to run on a phone in a few seconds.
#
# A mega surface is a bitmap too large for one GPU texture. The
# engine keeps it in main memory as an SDL surface, so every drawing
# operation needs a second, CPU-side implementation. Each check
# below therefore runs twice. On an ordinary bitmap it must always
# pass. On a mega surface it reports PEND until the engine implements
# that operation.
#
# Run it with tools/run-engine-tests.sh in the Empo repository, or
# point any mkxp-z build at this directory (see README.md).

# The engine runs the scripts named by "preloadScript" only for games
# that boot from Scripts.rxdata, so a customScript suite loads the
# harness itself. __FILE__ is the path from the "customScript" key,
# which makes this work whatever directory the config points at.
unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

RED = Color.new(255, 0, 0, 255)
GREEN = Color.new(0, 255, 0, 255)
BLUE = Color.new(0, 0, 255, 255)
WHITE = Color.new(255, 255, 255, 255)
BLACK = Color.new(0, 0, 0, 255)
CYAN_PIXEL = [0, 255, 255, 255].freeze

RED_PIXEL = [255, 0, 0, 255].freeze
GREEN_PIXEL = [0, 255, 0, 255].freeze
BLUE_PIXEL = [0, 0, 255, 255].freeze
CLEAR_PIXEL = [0, 0, 0, 0].freeze

# The two kinds of bitmap every check runs against. A bitmap wider
# than the texture limit becomes a mega surface, and one pixel past
# the limit costs about as much memory as the small case.
Kind = Struct.new(:label, :width, :height, :mega)

KINDS = [
  Kind.new('small', 64, 32, false),
  Kind.new('mega', Bitmap.max_size + 1, 32, true)
].freeze

# Each check registers itself here and then runs once per kind, so
# adding one is a single call and nothing else.
# rubocop:disable Style/MutableConstant -- the checks register into it.
CASES = []
# rubocop:enable Style/MutableConstant

def check(name, &body)
  CASES << [name, body]
end

def last_point(kind)
  [kind.width - 1, kind.height - 1]
end

check('a new bitmap has the size it was asked for') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    EngineTest.assert_equal(kind.width, bitmap.width, 'width')
    EngineTest.assert_equal(kind.height, bitmap.height, 'height')
  end
end

# This check guards the rest. If the engine ignored "maxTextureSize",
# the mega half of the run would be a second small run in disguise.
check('the mega flag matches the size') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    EngineTest.assert_equal(kind.mega, bitmap.mega?, 'mega?')
  end
end

check('a new bitmap starts out transparent') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    EngineTest.assert_pixel(bitmap, [0, 0], CLEAR_PIXEL, 'first pixel')
    EngineTest.assert_pixel(bitmap, last_point(kind), CLEAR_PIXEL, 'last pixel')
  end
end

check('fill_rect paints the given rect and nothing else') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    bitmap.fill_rect(8, 8, 16, 16, BLUE)
    EngineTest.assert_pixel(bitmap, [8, 8], BLUE_PIXEL, 'first pixel of the rect')
    EngineTest.assert_pixel(bitmap, [23, 23], BLUE_PIXEL, 'last pixel of the rect')
    EngineTest.assert_pixel(bitmap, [7, 7], RED_PIXEL, 'before the rect')
    EngineTest.assert_pixel(bitmap, [24, 24], RED_PIXEL, 'past the rect')
  end
end

check('clear empties the whole bitmap') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    bitmap.clear
    EngineTest.assert_pixel(bitmap, [0, 0], CLEAR_PIXEL, 'first pixel')
    EngineTest.assert_pixel(bitmap, last_point(kind), CLEAR_PIXEL, 'last pixel')
  end
end

check('clear_rect empties the given rect and nothing else') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    bitmap.clear_rect(8, 8, 16, 16)
    EngineTest.assert_pixel(bitmap, [8, 8], CLEAR_PIXEL, 'inside the cleared rect')
    EngineTest.assert_pixel(bitmap, [7, 7], RED_PIXEL, 'outside the cleared rect')
  end
end

check('gradient_fill_rect runs left to right') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    bitmap.gradient_fill_rect(0, 0, kind.width, kind.height, RED, BLUE)
    EngineTest.assert_pixel_near(bitmap, [0, 0], RED_PIXEL, 4, 'left end')
    EngineTest.assert_pixel_near(bitmap, [kind.width - 1, 0], BLUE_PIXEL, 4, 'right end')
  end
end

check('gradient_fill_rect runs top to bottom when asked') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    bitmap.gradient_fill_rect(0, 0, kind.width, kind.height, RED, BLUE, true)
    EngineTest.assert_pixel_near(bitmap, [0, 0], RED_PIXEL, 4, 'top end')
    EngineTest.assert_pixel_near(bitmap, [0, kind.height - 1], BLUE_PIXEL, 4, 'bottom end')
  end
end

check('set_pixel and get_pixel agree') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    point = [kind.width - 2, kind.height - 2]
    bitmap.set_pixel(point[0], point[1], GREEN)
    EngineTest.assert_pixel(bitmap, point, GREEN_PIXEL, 'the pixel that was set')
    EngineTest.assert_pixel(bitmap, [point[0] - 1, point[1]], RED_PIXEL, 'its neighbour')
  end
end

check('raw_data has four bytes per pixel') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    expected = kind.width * kind.height * 4
    EngineTest.assert_equal(expected, bitmap.raw_data.size, 'raw_data size')
  end
end

check('raw_data= replaces every pixel') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    EngineTest.bitmap(kind.width, kind.height, GREEN) { |source| bitmap.raw_data = source.raw_data }
    EngineTest.assert_pixel(bitmap, [0, 0], GREEN_PIXEL, 'first pixel')
    EngineTest.assert_pixel(bitmap, last_point(kind), GREEN_PIXEL, 'last pixel')
  end
end

check('blt copies a source rect into place') do |kind|
  EngineTest.bitmap(kind.width, kind.height, GREEN) do |bitmap|
    EngineTest.bitmap(16, 16, RED) { |source| bitmap.blt(4, 4, source, source.rect) }
    EngineTest.assert_pixel(bitmap, [4, 4], RED_PIXEL, 'first copied pixel')
    EngineTest.assert_pixel(bitmap, [19, 19], RED_PIXEL, 'last copied pixel')
    EngineTest.assert_pixel(bitmap, [3, 3], GREEN_PIXEL, 'outside the copy')
  end
end

check('stretch_blt scales a source over the whole bitmap') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    EngineTest.bitmap(2, 1) do |source|
      source.set_pixel(0, 0, RED)
      source.set_pixel(1, 0, BLUE)
      bitmap.stretch_blt(bitmap.rect, source, source.rect)
    end
    EngineTest.assert_pixel_near(bitmap, [0, 0], RED_PIXEL, 8, 'left end')
    EngineTest.assert_pixel_near(bitmap, last_point(kind), BLUE_PIXEL, 8, 'right end')
  end
end

check('clone copies the pixels and the mega flag') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    bitmap.fill_rect(0, 0, 4, 4, BLUE)
    EngineTest.owning(bitmap.clone) do |copy|
      EngineTest.assert_equal(bitmap.mega?, copy.mega?, 'mega?')
      EngineTest.assert_pixel(copy, [0, 0], BLUE_PIXEL, 'copied corner')
      EngineTest.assert_pixel(copy, last_point(kind), RED_PIXEL, 'copied far pixel')
    end
  end
end

check('hue_change moves the colours') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    bitmap.hue_change(180)
    # Half a turn from red is cyan. Asserting only that the colour
    # moved would pass for a hue_change that scrambled the pixels.
    EngineTest.assert_pixel_near(bitmap, [0, 0], CYAN_PIXEL, 24, 'half a turn from red')
  end
end

check('blur softens an edge') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    half = kind.width / 2
    middle = kind.height / 2
    bitmap.fill_rect(half, 0, kind.width - half, kind.height, BLUE)
    bitmap.blur
    # Blur must carry colour across the edge, not just disturb it.
    left = EngineTest.pixel(bitmap, [half - 1, middle])
    right = EngineTest.pixel(bitmap, [half, middle])
    EngineTest.assert(left[2] > 0, "blue never reached the red side: #{left.inspect}")
    EngineTest.assert(right[0] > 0, "red never reached the blue side: #{right.inspect}")
    # The far corners stay their own colour, so blur is not a wash.
    EngineTest.assert_pixel(bitmap, [0, middle], RED_PIXEL, 'far left')
    EngineTest.assert_pixel(bitmap, [kind.width - 1, middle], BLUE_PIXEL, 'far right')
  end
end

check('radial_blur changes the pixels') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    bitmap.fill_rect(0, 0, 8, 8, BLUE)
    before = bitmap.raw_data
    bitmap.radial_blur(30, 8)
    EngineTest.refute_equal(before, bitmap.raw_data, 'pixels after radial_blur')
  end
end

check('text_size reports a box for the text') do |kind|
  EngineTest.bitmap(kind.width, kind.height) do |bitmap|
    size = bitmap.text_size('Test')
    EngineTest.assert(size.width > 0, "text_size width was #{size.width}")
    EngineTest.assert(size.height > 0, "text_size height was #{size.height}")
    # A box that does not grow with the text is a stub, not a measure.
    one = bitmap.text_size('T')
    EngineTest.assert(size.width > one.width,
                      "'Test' measured #{size.width}, 'T' measured #{one.width}")
    EngineTest.assert_equal(one.height, size.height, 'height of one line')
  end
end

check('draw_text changes the bitmap') do |kind|
  EngineTest.bitmap(kind.width, kind.height, WHITE) do |bitmap|
    before = bitmap.raw_data
    bitmap.font.color = BLACK
    bitmap.draw_text(0, 0, kind.width, kind.height, 'Test', 1)
    after = bitmap.raw_data
    EngineTest.refute_equal(before, after, 'pixels after draw_text')
    # Black text on white must leave dark bytes behind. Without this
    # the check passes on any change at all, including a stray pixel.
    dark = after.unpack('C*').any? { |byte| byte < 128 }
    EngineTest.assert(dark, 'draw_text left no dark pixel')
  end
end

# Sprite, Plane, and Window each decide for themselves whether they
# accept a mega surface, so a bitmap the engine can draw into is not
# automatically a bitmap the engine can show.
check('a Sprite accepts the bitmap') do |kind|
  EngineTest.bitmap(kind.width, kind.height, RED) do |bitmap|
    EngineTest.owning(Sprite.new) do |sprite|
      sprite.bitmap = bitmap
      Graphics.update
      EngineTest.assert_equal(kind.width, sprite.bitmap.width, 'the width the sprite kept')
      EngineTest.assert(!sprite.disposed?, 'the sprite survived the frame')
      EngineTest.assert(!bitmap.disposed?, 'the bitmap survived the frame')
    end
  end
end

check('a Plane accepts the bitmap') do |kind|
  EngineTest.bitmap(kind.width, kind.height, GREEN) do |bitmap|
    EngineTest.owning(Plane.new) do |plane|
      plane.bitmap = bitmap
      Graphics.update
      EngineTest.assert_equal(kind.width, plane.bitmap.width, 'the width the plane kept')
      EngineTest.assert(!plane.disposed?, 'the plane survived the frame')
      EngineTest.assert(!bitmap.disposed?, 'the bitmap survived the frame')
    end
  end
end

# No Graphics.update for the Window. One with no windowskin has
# nothing to draw, and the check is whether it takes the contents.
check('a Window accepts the bitmap as contents') do |kind|
  EngineTest.bitmap(kind.width, kind.height, BLUE) do |bitmap|
    EngineTest.owning(Window.new) do |window|
      window.width = 200
      window.height = 100
      window.contents = bitmap
      EngineTest.assert_equal(kind.width, window.contents.width, 'the width the window kept')
      EngineTest.assert(!bitmap.disposed?, 'the bitmap survived the assignment')
    end
  end
end

EngineTest.suite('mega-bitmap', KINDS.size * CASES.size)

KINDS.each do |kind|
  EngineTest.info("#{kind.label}_size", "#{kind.width}x#{kind.height}")
  # An ordinary bitmap must support every operation here, so a "not
  # supported" error on that kind is a defect and reports FAIL. Only
  # the mega surface is allowed to report PEND.
  EngineTest.pending_allowed = kind.mega
  CASES.each do |name, body|
    EngineTest.test("#{kind.label}: #{name}") { body.call(kind) }
  end
end

EngineTest.finish
exit
