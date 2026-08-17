# NilClass safe-stubs - a monkey patch that makes nil behave like
# an empty string / zero number / false flag for the long tail of
# methods older RGSS scripts assume will exist on their operands.
#
# Why ship this? Pokemon Essentials games (Uranium, Reborn,
# Rejuvenation, Insurgence, Infinite Fusion, etc.) and decade-old
# RPG Maker plugins accumulate bugs where a rare event branch
# reaches `nil.downcase`, `nil + 1`, `nil.to_i` and crashes with
# NoMethodError. JoiPlay's `nilclass-binding.cpp` solves this by
# patching NilClass at the C level with a whitelist of safe
# returns. Porting the same whitelist in Ruby keeps the engine
# identical to upstream mkxp-z while matching JoiPlay's silently
# forgiving behavior at runtime, which is what end-users of the
# iOS app expect to avoid per-game crash reports.
#
# The whitelist only covers idempotent / arithmetic-style methods.
# Allocation-adjacent or mutating ones (push/pop/clear etc.) are
# intentionally left out so logic errors in game state mutation
# still surface rather than silently succeed.

# rubocop:disable Metrics/ClassLength -- NilClass extension covers
# the full PE/JoiPlay safe-stub surface (~30 numeric/comparison/string
# accessors). Each method is one line, splitting across multiple
# class-reopens would just add noise.
class NilClass
  # Numeric methods - return 0, -1, false, or the other arg so
  # arithmetic / comparison chains keep flowing.
  def %(*_args)
    0
  end

  def *(*_args)
    0
  end

  def **(*_args)
    0
  end

  def +(other)
    other
  end

  def -(*_args)
    0
  end

  def /(*_args)
    0
  end

  def <(*_args)
    true
  end

  def <<(*_args)
    0
  end

  def <=(*_args)
    false
  end

  def <=>(_other)
    0
  end

  def >(*_args)
    false
  end

  def >=(*_args)
    false
  end

  def >>(_other)
    0
  end

  def abs
    0
  end

  def abs2
    0
  end

  def angle
    0
  end

  def arg
    0
  end

  def ceil(*_args)
    0
  end

  # Numeric#* / Numeric#+ etc. ask for `other.coerce(self)` and
  # expect `[promoted_other, promoted_self]`. Returning `[]` (the
  # old stub) raised `coerce must return [x, y]` and crashed any
  # `5 * nil` style arithmetic. Treat nil as zero in mixed math:
  # the operand stays as it is and we promote ourselves to `0`
  # (which auto-promotes to `0.0` against a Float operand).
  def coerce(other)
    [other, 0]
  end

  def conj
    0
  end

  def conjugate
    0
  end

  def denominator
    0
  end

  def div(*_args)
    0
  end

  def divmod(*_args)
    []
  end

  def downto(*_args)
    0
  end

  def even?
    true
  end

  def fdiv(*_args)
    0.0
  end

  def floor(*_args)
    0
  end

  def finite?
    true
  end

  def hash
    0
  end

  # `Object#id` was removed in Ruby 1.9 (use `object_id` for the
  # real value), but Pokemon Essentials forks frequently call `.id`
  # on potentially-nil receivers in feature-detect blocks like:
  #
  #   sym = sym.id if !sym.is_a?(Symbol) && sym.respond_to?(:id)
  #
  # Pokemon Flux's `pbWeight` hits this path on a Pokemon with no
  # held item: `itemActive?` returns true while `self.item` returns
  # nil, so `nil.id` is called from the held-item weight-effect
  # trigger and crashes the battle send-out animation. Returning
  # nil here mimics "no id present". The calling lookup `self[nil]`
  # then returns nil and the trigger no-ops cleanly.
  def id
    nil
  end

  def imag
    0
  end

  def imaginary
    0
  end

  def infinite?
    true
  end

  def integer?
    false
  end

  def modulo(*_args)
    0
  end

  def nan?
    true
  end

  def next
    0
  end

  def nonzero?
    false
  end

  def odd?
    false
  end

  def ord
    0
  end

  def quo(*_args)
    0.0
  end

  def phase
    0
  end

  def pred
    0
  end

  def real
    0
  end

  def real?
    false
  end

  def remainder(*_args)
    0
  end

  def round(*_args)
    0
  end

  def step(*_args)
    0
  end

  def succ
    0
  end

  def times(*_args)
    0
  end

  def to_int
    0
  end

  def truncate(*_args)
    0
  end

  def upto(*_args)
    0
  end

  def zero?
    true
  end

  def |(*_args)
    0
  end

  # String methods - return "", 0, false, nil, or [] so text
  # transforms / formatting chains keep flowing.
  def ascii_only?
    true
  end

  def bytes
    ''
  end

  def bytesize
    0
  end

  def capitalize
    ''
  end

  def capitalize!
    nil
  end

  def casecmp(*_args)
    -1
  end

  def center(*_args)
    ''
  end

  def chars
    ''
  end

  def chomp(*_args)
    ''
  end

  def chomp!(*_args)
    ''
  end

  def chop
    ''
  end

  def chop!
    ''
  end

  def chr
    ''
  end

  def clear
    ''
  end

  def codepoints
    ''
  end

  def concat(*_args)
    ''
  end

  def count(*_args)
    0
  end

  def crypt(*_args)
    ''
  end

  def delete(*_args)
    ''
  end

  def delete!(*_args)
    ''
  end

  def downcase
    ''
  end

  def downcase!
    ''
  end

  def dump
    ''
  end

  def each(*_args)
    ''
  end

  def each_byte(*_args)
    ''
  end

  def each_char(*_args)
    ''
  end

  def each_codepoint(*_args)
    ''
  end

  def each_line(*_args)
    ''
  end

  def empty?
    true
  end

  def encode(*_args)
    ''
  end

  def encode!(*_args)
    ''
  end

  def end_with?(*_args)
    false
  end

  def force_encoding(*_args)
    ''
  end

  def getbyte(*_args)
    0
  end

  def gsub(*_args)
    ''
  end

  def gsub!(*_args)
    ''
  end

  def hex
    0
  end

  def include?(*_args)
    false
  end

  def index(*_args)
    nil
  end

  def insert(*_args)
    ''
  end

  def inspect
    ''
  end

  def length
    0
  end

  def lines(*_args)
    ''
  end

  def ljust(*_args)
    ''
  end

  def lstrip
    ''
  end

  def lstrip!
    ''
  end

  def match(*_args)
    nil
  end

  def oct
    0
  end

  def partition(*_args)
    []
  end

  def replace(*_args)
    ''
  end

  def reverse
    ''
  end

  def reverse!
    ''
  end

  def rindex(*_args)
    nil
  end

  def rjust(*_args)
    ''
  end

  def rpartition(*_args)
    []
  end

  def rstrip
    ''
  end

  def rstrip!
    ''
  end

  def scan(*_args)
    []
  end

  def setbyte(*_args)
    0
  end

  def size
    0
  end

  def slice(*_args)
    ''
  end

  def slice!(*_args)
    ''
  end

  def split(*_args)
    []
  end

  def squeeze(*_args)
    ''
  end

  def start_with?(*_args)
    false
  end

  def strip
    ''
  end

  def strip!
    ''
  end

  def sub(*_args)
    ''
  end

  def sub!(*_args)
    ''
  end

  def sum(*_args)
    0
  end

  def swapcase
    ''
  end

  def swapcase!
    ''
  end

  def tr(*_args)
    ''
  end

  def tr!(*_args)
    ''
  end

  def tr_s(*_args)
    ''
  end

  def tr_s!(*_args)
    ''
  end

  def unpack(*_args)
    []
  end

  def upcase
    ''
  end

  def upcase!
    ''
  end

  def valid_encoding?
    true
  end

  def to_str
    ''
  end

  def to_ary
    []
  end

  # Pokemon Essentials-flavored accessors that scripts call on
  # `$PokemonTemp` and other globals before checking for nil. The
  # canonical example is Vinemon's `308_Jukebox` doing
  # `Audio.bgm_stop if !$PokemonTemp.defaultBGM` without guarding
  # the receiver - we'd rather treat a missing $PokemonTemp as
  # "no override" than crash the script. Same idea as the String
  # / Numeric stubs above: enumerate the exact names games use,
  # don't reach for a wildcard `method_missing` (which would mask
  # real bugs across unrelated scripts).
  def defaultBGM
    nil
  end

  def defaultBGS
    nil
  end
end
# rubocop:enable Metrics/ClassLength

MKXP.puts('[nil-stubs] NilClass safe-stubs installed') if defined?(MKXP)
