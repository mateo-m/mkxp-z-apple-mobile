# Pokemon Essentials Graphics + movie-plugin compatibility aliases.
#
# JoiPlay bound `Graphics.poke_*` as distinct C++ entry points and
# then defined the regular `Graphics.width` / `resize_screen` etc.
# in Ruby as thin wrappers around them. Our engine already ships
# the regular names natively, so every fangame that calls the
# `poke_*` flavor (Uranium, Reborn, Rejuvenation, Insurgence,
# Infinite Fusion and most PE19-based games) crashes on iOS with
# `NoMethodError: undefined method poke_snap_to_bitmap`.
#
# Port the aliases in reverse: define `poke_*` as delegates to the
# real methods. Same for `mkxp_snap_to_bitmap` which a handful of
# older plugins hit, and for `zeus_play_movie` which wraps
# `Graphics.play_movie` for games that expect the Zeus video
# plugin API. Gate each on `respond_to?` + `method_defined?` so
# re-running this script (reload during development) or games
# that already define these names keep working.

module Graphics
  class << self
    define_method(:poke_width) { Graphics.width } unless respond_to?(:poke_width)

    define_method(:poke_height) { Graphics.height } unless respond_to?(:poke_height)

    define_method(:poke_snap_to_bitmap) { Graphics.snap_to_bitmap } unless respond_to?(:poke_snap_to_bitmap)

    define_method(:mkxp_snap_to_bitmap) { Graphics.snap_to_bitmap } unless respond_to?(:mkxp_snap_to_bitmap)

    unless respond_to?(:poke_resize_screen)
      define_method(:poke_resize_screen) do |w, h|
        Graphics.resize_screen(w, h)
      end
    end

    # Legacy PE feature probe. Always true on mkxp-z; some games
    # branch on this to decide whether to call resize_screen.
    define_method(:haveresizescreen) { true } unless respond_to?(:haveresizescreen)

    # Zeus video plugin ships as a separate DLL on Windows and
    # some fangames call it directly. Delegate to our native
    # play_movie, ignoring the extra cancellable/fit args which
    # we don't expose distinctly.
    unless respond_to?(:zeus_play_movie)
      define_method(:zeus_play_movie) do |filename, *_rest|
        Graphics.play_movie(filename)
      end
    end
  end
end

# Some fangame plugins (e.g. Pokemon Void Character Select) assign
# a resolved filename string directly to Sprite#bitmap= and call
# .width / .height on the same path string. Coerce at the setter;
# Graphics/ path strings expose bitmap dimensions on demand.
module MkxpGraphicsPathString
  GRAPHICS_RE = %r{\AGraphics/}.freeze

  def width
    raise NoMethodError, "undefined method `width' for #{inspect}" unless self =~ GRAPHICS_RE

    Bitmap.new(self).width
  end

  def height
    raise NoMethodError, "undefined method `height' for #{inspect}" unless self =~ GRAPHICS_RE

    Bitmap.new(self).height
  end
end

if String.respond_to?(:prepend, true)
  String.prepend MkxpGraphicsPathString unless String.ancestors.include?(MkxpGraphicsPathString)
else
  # Module#prepend is Ruby 2.0+. width/height are new methods on
  # String, so include is equivalent on 1.8/1.9 VX/VX Ace games.
  String.include MkxpGraphicsPathString unless String.ancestors.include?(MkxpGraphicsPathString)
end

module MkxpBitmapPathCoercion
  def bitmap=(value)
    super(MkxpBitmapPathCoercion.coerce(value))
  end

  module_function

  def coerce(value)
    return nil if value.nil?
    return value unless value.is_a?(String)
    return nil if value.empty?

    Bitmap.new(value)
  end

  def patch(klass)
    return unless defined?(klass) && klass.is_a?(Class)

    if klass.respond_to?(:prepend, true)
      return if klass.ancestors.include?(MkxpBitmapPathCoercion)

      klass.prepend(MkxpBitmapPathCoercion)
    else
      marker = :__mkxp_coerced_bitmap_set
      return if klass.method_defined?(marker)

      klass.class_eval do
        alias_method marker, :bitmap=
        define_method(:bitmap=) do |value|
          send(marker, MkxpBitmapPathCoercion.coerce(value))
        end
      end
    end
  end
end

MkxpBitmapPathCoercion.patch(Sprite) if defined?(Sprite)
MkxpBitmapPathCoercion.patch(Plane) if defined?(Plane)

module MkxpPokemonGraphicsCompat
  def self.patch_ball_animation_mixin
    return unless defined?(PokeBattle_BallAnimationMixin)
    return unless PokeBattle_BallAnimationMixin.method_defined?(:ballTracksHand)

    PokeBattle_BallAnimationMixin.module_eval do
      unless method_defined?(:__mkxp_ball_tracks_hand_with_bitmap)
        alias_method :__mkxp_ball_tracks_hand_with_bitmap, :ballTracksHand
      end

      # rubocop:disable Naming/MethodParameterName, Naming/VariableName -- PE mixin API
      def ballTracksHand(ball, traSprite, safariThrow = false)
        bitmap = traSprite.bitmap if traSprite
        return [-6, 202] if bitmap.nil?

        __mkxp_ball_tracks_hand_with_bitmap(ball, traSprite, safariThrow)
      end
      # rubocop:enable Naming/MethodParameterName, Naming/VariableName
    end
  end
end

MkxpPokemonGraphicsCompat.patch_ball_animation_mixin

class Module
  unless method_defined?(:__mkxp_graphics_compat_include)
    alias __mkxp_graphics_compat_include include

    def include(*mods)
      ret = __mkxp_graphics_compat_include(*mods)
      if defined?(PokeBattle_BallAnimationMixin) && mods.include?(PokeBattle_BallAnimationMixin)
        MkxpPokemonGraphicsCompat.patch_ball_animation_mixin
      end
      ret
    end
  end
end

if defined?(GameData::TrainerType) && GameData::TrainerType.respond_to?(:check_file)
  module GameData
    class TrainerType
      class << self
        unless method_defined?(:__mkxp_case_sensitive_check_file)
          alias __mkxp_case_sensitive_check_file check_file
        end

        # rubocop:disable Metrics/AbcSize -- candidate path fan-out for case-insensitive trainer sprites
        def check_file(tr_type, path, optional_suffix = '', suffix = '')
          ret = __mkxp_case_sensitive_check_file(tr_type, path, optional_suffix, suffix)
          return ret if ret

          tr_type_data = try_get(tr_type)
          return nil if tr_type_data.nil?

          candidates = []
          if optional_suffix && !optional_suffix.empty?
            candidates << (path + tr_type_data.id.to_s + optional_suffix + suffix)
            if tr_type_data.respond_to?(:id_number)
              candidates << (path + format('%03d', tr_type_data.id_number) + optional_suffix + suffix)
            end
          end
          candidates << (path + tr_type_data.id.to_s + suffix)
          if tr_type_data.respond_to?(:id_number)
            candidates << (path + format('%03d', tr_type_data.id_number) + suffix)
          end

          candidates.each do |candidate|
            resolved = __mkxp_case_insensitive_bitmap(candidate)
            return resolved if resolved
          end
          nil
        end
        # rubocop:enable Metrics/AbcSize

        def __mkxp_case_insensitive_bitmap(candidate)
          dir = File.dirname(candidate)
          base = File.basename(candidate).downcase

          Dir.foreach(dir) do |entry|
            next if ['.', '..'].include?(entry)

            name = File.basename(entry, File.extname(entry)).downcase
            ext = File.extname(entry).downcase
            if name == base && ['.png', '.gif'].include?(ext)
              return File.join(dir, File.basename(entry, File.extname(entry)))
            end
          end
          nil
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
