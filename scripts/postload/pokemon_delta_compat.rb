# Graphics.delta unit compatibility for modern Pokemon Essentials.
#
# Upstream mkxp-z changed Graphics.delta from microseconds to seconds
# between v2.4.1 and v2.4.2 (upstream 0072c193, "Time is now measured
# in fractions of a second"). Our engine keeps the legacy microsecond
# unit because most fangames were built against pre-2.4.2 engines and
# convert with their own `Graphics.delta / 1_000_000` wrappers
# (Essentials v20's MKXP_Compatibility defines Graphics.delta_s that
# way, and standalone plugins do the same).
#
# Essentials v21+ games consume Graphics.delta directly as seconds:
# the Unreal Time plugin advances its in-game clock by it, weather
# fades scale by it, phone-call timers count down by it. Feeding them
# microseconds runs every delta-timed effect about a million times
# too fast. The visible symptom is day/night overlays and tints
# strobing every few frames on outdoor maps.
#
# v21 games declare the engine they were built against in
# Essentials::MKXPZ_VERSION (e.g. "2.4.2/c9378cf"). v20 and older
# don't define the constant at all. Convert to seconds exactly when
# the declared target is >= 2.4.2, so pre-2.4.2 games keep the
# microsecond unit their own wrappers require.
module MkxpPokemonDeltaCompat
  SECONDS_UNIT_SINCE = [2, 4, 2].freeze

  module_function

  def declared_mkxpz_version
    return nil unless defined?(Essentials)
    return nil unless Essentials.const_defined?(:MKXPZ_VERSION)

    Essentials::MKXPZ_VERSION.to_s
  end

  def seconds_unit?(version)
    return false if version.nil?

    digits = version[/\d+(?:\.\d+)*/]
    return false if digits.nil?

    # rubocop:disable Style/SymbolProc -- Ruby 1.8 can't parse `&:to_i`.
    parts = digits.split('.').map { |part| part.to_i }
    # rubocop:enable Style/SymbolProc
    (parts <=> SECONDS_UNIT_SINCE) >= 0
  end

  def apply
    return unless seconds_unit?(declared_mkxpz_version)
    return if Graphics.respond_to?(:__mkxp_delta_microseconds)

    Graphics.singleton_class.class_eval do
      alias_method :__mkxp_delta_microseconds, :delta

      define_method(:delta) do
        __mkxp_delta_microseconds / 1_000_000.0
      end
    end
  end
end

MkxpPokemonDeltaCompat.apply
