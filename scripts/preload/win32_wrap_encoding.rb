# win32_wrap_encoding.rb
#
# Ruby 1.9+ extensions to win32_wrap.rb. Adds encoding-aware
# methods to Win32API_Impl::Kernel32 and overrides the ASCII-only
# stubs in Win32API_Impl::Kernel32::MciSendString with full UTF-16
# implementations.
#
# This file uses Ruby 1.9+ APIs that 1.8's parser refuses to
# compile (kw-args via `name:` shorthand, Encoding::* constants,
# .encode/.force_encoding, byteslice/getbyte/setbyte, unpack1):
#
#   .encode(target, invalid: :replace, undef: :replace)
#   Encoding::UTF_16LE
#   String#force_encoding
#   String#unpack1
#   String#byteslice / getbyte / setbyte / bytesize
#
# Loaded only when Ruby >= 1.9 (binding-mri.cpp's preload list
# is gated on RUBY_API_VERSION_*). On the Ruby 1.8 dispatch path
# (mkxp18-merged.o, RGSS1/RGSS2 games), this file is skipped and
# Kernel32's wide-char conversion / MciSendString's encoding
# helpers are absent. Games that probe Win32API_Impl::Kernel32
# for the encoding classes will fail their `const_defined?`
# check and the script falls through to the TOLERATE_ERRORS
# branch in Win32API#call. RGSS1/2 games typically don't exercise
# UTF-16 paths anyway (they ran on Windows ANSI codepages).

module Win32API_Impl
  module Kernel32
    # Win32 codepage IDs we map directly to Ruby Encoding
    # objects. Anything not listed falls back to UTF-8 with
    # replacement, which matches what Win32 does for
    # unrepresentable characters and means the conversion
    # always returns *something* the caller can parse.
    CODEPAGE_TO_ENCODING = {
      65_001 => Encoding::UTF_8,
      20_127 => Encoding::US_ASCII,
      1252 => Encoding::Windows_1252,
      932 => Encoding::Windows_31J, # Shift_JIS / CP932
      949 => Encoding::CP949,
      936 => Encoding::GBK,
      950 => Encoding::Big5,
      28_591 => Encoding::ISO_8859_1,
      28_605 => Encoding::ISO_8859_15
    }.freeze

    def self.codepage_to_encoding(cp)
      CODEPAGE_TO_ENCODING[cp] || Encoding::UTF_8
    end

    # Take a String (assumed UTF-16LE bytes) and return either
    # a count of meaningful 16-bit code units (when the caller
    # passed -1 for `cchWideChar`, i.e. null-terminated) or the
    # explicit count, capped at the byte size.
    def self.wide_byte_slice(buf, cch)
      return '' unless buf.is_a?(String)

      if cch == -1
        # Null-terminated: scan for first 16-bit zero unit.
        idx = 0
        while idx + 1 < buf.bytesize
          break if buf.getbyte(idx).zero? && buf.getbyte(idx + 1).zero?

          idx += 2
        end
        buf.byteslice(0, idx)
      else
        cap = [cch * 2, buf.bytesize].min
        cap = 0 if cap < 0
        buf.byteslice(0, cap)
      end
    end

    # Take a String and return either its full content (when
    # `cbMultiByte == -1`, i.e. null-terminated) or the
    # requested byte slice.
    def self.byte_slice(buf, cb)
      return '' unless buf.is_a?(String)

      if cb == -1
        idx = buf.index("\0".b)
        idx ? buf.byteslice(0, idx) : buf.dup
      else
        cap = [cb, buf.bytesize].min
        cap = 0 if cap < 0
        buf.byteslice(0, cap)
      end
    end

    # Convert UTF-16LE bytes to a single-byte/multi-byte encoding
    # (typically UTF-8). Vinemon's `Zeus::Encode` round-trips
    # every MCI command and result through this. Without a real
    # conversion the round-trip yields an empty string and the
    # caller's `str.index("\0")` returns nil, raising TypeError
    # on `str[0, nil]`.
    class WideCharToMultiByte
      def call(args)
        codepage = args[0].to_i
        _flags   = args[1]
        src_buf  = args[2]
        src_cch  = args[3].to_i
        dst_buf  = args[4]
        dst_size = args[5].to_i

        wide = Win32API_Impl::Kernel32.wide_byte_slice(src_buf, src_cch)
        target = Win32API_Impl::Kernel32.codepage_to_encoding(codepage)
        converted = begin
          wide.force_encoding(Encoding::UTF_16LE)
              .encode(target, :invalid => :replace, :undef => :replace)
              .force_encoding(Encoding::ASCII_8BIT)
        rescue StandardError
          ''.b
        end

        # Length query: caller passes nil/0 for dst to ask
        # how big a buffer they need to allocate.
        return converted.bytesize if dst_buf.nil? || !dst_buf.is_a?(String) || dst_size <= 0

        n = [converted.bytesize, dst_buf.bytesize, dst_size].min
        n.times { |i| dst_buf.setbyte(i, converted.getbyte(i)) }
        n
      end
    end
    WideCharToMultiByteA = WideCharToMultiByte

    # Inverse direction. Used to convert command strings the
    # script wants to pass to MCI etc. Less critical for our
    # Vinemon path (we don't read the converted bytes), but
    # implementing it round-trips Zeus::Encode correctly so any
    # script that depends on it works.
    class MultiByteToWideChar
      # rubocop:disable Metrics/AbcSize -- mirrors Win32
      # MultiByteToWideChar's signature. The per-arg validation +
      # encode round-trip is inherent to the API.
      def call(args)
        codepage = args[0].to_i
        _flags   = args[1]
        src_buf  = args[2]
        src_cb   = args[3].to_i
        dst_buf  = args[4]
        dst_cch  = args[5].to_i

        narrow = Win32API_Impl::Kernel32.byte_slice(src_buf, src_cb)
        source = Win32API_Impl::Kernel32.codepage_to_encoding(codepage)
        converted = begin
          narrow.force_encoding(source)
                .encode(Encoding::UTF_16LE, :invalid => :replace, :undef => :replace)
                .force_encoding(Encoding::ASCII_8BIT)
        rescue StandardError
          ''.b
        end

        if dst_buf.nil? || !dst_buf.is_a?(String) || dst_cch <= 0
          # Length query: returns count of UTF-16 code
          # units, not bytes.
          return converted.bytesize / 2
        end

        wide_bytes = [converted.bytesize, dst_buf.bytesize, dst_cch * 2].min
        wide_bytes.times { |i| dst_buf.setbyte(i, converted.getbyte(i)) }
        wide_bytes / 2
      end
      # rubocop:enable Metrics/AbcSize
    end
    MultiByteToWideCharA = MultiByteToWideChar

    # Reopen MciSendString to override decode_utf16 / write_response
    # with encoding-aware versions. The 1.8-safe stubs in
    # win32_wrap.rb leave both as no-ops (returning "" / not writing
    # anything), which works for ASCII-only callers but breaks
    # games that pass UTF-16 MCI command strings.
    class MciSendString
      private

      def decode_utf16(buf)
        return '' unless buf.is_a?(String) && !buf.empty?

        bytes = buf.dup.force_encoding(Encoding::ASCII_8BIT)
        utf8 = begin
          bytes.force_encoding(Encoding::UTF_16LE)
               .encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
        rescue StandardError
          ''
        end
        utf8.split("\0", 2).first || ''
      end

      def write_response(buf, text)
        return unless buf.is_a?(String) && buf.bytesize >= 2

        utf16 = "#{text}\0".encode(Encoding::UTF_16LE)
                           .force_encoding(Encoding::ASCII_8BIT)
        limit = [utf16.bytesize, buf.bytesize].min
        limit.times { |i| buf.setbyte(i, utf16.getbyte(i)) }
        # Null-pad the remaining buffer so callers don't
        # trip over stale UTF-16 codepoints from a previous
        # response.
        (limit...buf.bytesize).each { |i| buf.setbyte(i, 0) }
      end
    end
  end
end
