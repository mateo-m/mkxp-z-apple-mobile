# Zeus81 "Bitmap Export" compatibility.
#
# Many fangames ship Zeus81's Bitmap Export script. It adds
# `Bitmap#export`, `Bitmap#save`, `Bitmap#get_data`, Marshal support
# for Bitmap, and a `Graphics.snap_to_bitmap` replacement. The script
# reads and writes pixels through the Win32 call `RtlMoveMemory`. It
# walks the RGSS object header (`__id__*2+16`) to find the pixel
# buffer of a bitmap.
#
# That layout only exists in the Windows RGSS DLLs. Our engine keeps
# pixels in a GPU texture, so there is no such buffer. `RtlMoveMemory`
# is a no-op stub here (win32_wrap.rb), so the script silently reads
# zero bytes. Every export writes a fully transparent image, and the
# Win32 `snap_to_bitmap` returns an empty bitmap.
#
# Games that build sprites at run time break in a way that is hard to
# read: no error, no crash, only invisible graphics. Pokemon Empyrean
# composes the player character from clothing layers, saves the result
# to `Graphics/Characters`, then loads it back. The player and the
# gender-selection trainers were invisible. Menus that snapshot the
# screen for their background were invisible too.
#
# Our engine already exposes the same operations natively:
#   Bitmap#raw_data / #raw_data=  - RGBA pixels, top row first
#   Bitmap#to_file                - PNG, JPG or BMP by file extension
#   Graphics.snap_to_bitmap       - real screen capture
#
# Rebuild the Zeus methods on top of those. `get_data` and `set_data`
# keep the Windows pixel layout (BGRA, bottom row first) because game
# scripts that touch pixels expect it. `export` and `save` skip the
# pure-Ruby PNG encoder and call the native writer.
#
# The engine restores `Graphics.snap_to_bitmap` only when Zeus took it
# over. `Graphics::GetDIBits` exists only in the Win32 branch of the
# script, so it is a safe signal. Games that legitimately wrap
# `snap_to_bitmap` (Daybreak, Reborn) keep their own version.

if defined?(Bitmap) &&
   Bitmap.method_defined?(:raw_data) &&
   Bitmap.method_defined?(:to_file) &&
   Bitmap.method_defined?(:last_row_address)

  class Bitmap
    # Windows keeps bitmap pixels as BGRA with the bottom row first.
    # Our engine returns RGBA with the top row first. Convert both
    # ways so scripts see the layout they were written against.
    def __mkxp_swap_layout(data, row_bytes)
      rows = []
      y = (data.size / row_bytes) - 1
      while y >= 0
        rows << data[y * row_bytes, row_bytes]
        y -= 1
      end
      out = rows.join
      i = 0
      len = out.size
      while i < len
        out[i, 3] = out[i, 3].reverse
        i += 4
      end
      out
    end
    private :__mkxp_swap_layout

    # rubocop:disable Naming/AccessorMethodName -- names come from the Zeus81 API
    def get_data
      __mkxp_swap_layout(raw_data, width * 4)
    end

    def set_data(data)
      self.raw_data = __mkxp_swap_layout(data, width * 4)
      data
    end

    # Zeus hands out a fake String that points straight at the RGSS
    # pixel buffer, then frees the pointer. We give a plain copy and
    # a `free` that does nothing.
    def get_data_ptr
      data = get_data
      def data.free; end

      return data unless block_given?

      begin
        yield data
      ensure
        data.free
      end
    end
    # rubocop:enable Naming/AccessorMethodName

    # The address is meaningless here. Return 0 so any leftover
    # RtlMoveMemory call stays harmless.
    def last_row_address
      0
    end

    def export(filename, &on_finish)
      format = File.extname(filename).downcase
      case format
      when '.png', '.bmp', '.jpg', '.jpeg'
        to_file(filename)
      when ''
        filename = "#{filename}.png"
        to_file(filename)
      else
        print("Export format '#{format}' not supported.")
        return nil
      end
      on_finish.call if on_finish
      filename
    end

    def save(filename, &on_finish)
      export(filename, &on_finish)
    end

    def export_png(filename, &on_finish)
      to_file(filename)
      on_finish.call if on_finish
      filename
    end

    def export_bmp(filename)
      to_file(filename)
      filename
    end
  end

  module Graphics
    class << self
      native_snap = Graphics.instance_variable_get(:@__mkxp_native_snap_to_bitmap)
      if native_snap && Graphics.const_defined?(:GetDIBits)
        define_method(:snap_to_bitmap) { native_snap.call }
      end

      if method_defined?(:export)
        def export(filename = nil)
          filename ||= Time.now.strftime("snapshot %Y-%m-%d %Hh%Mm%Ss #{frame_count}")
          bitmap = snap_to_bitmap
          return nil if bitmap.nil?

          begin
            bitmap.export(filename)
          ensure
            bitmap.dispose
          end
        end

        alias save export
        alias snapshot export
      end
    end
  end

  MKXP.puts('[bitmap-export] Zeus81 Bitmap Export rebuilt on native pixel access') if defined?(MKXP)
end
