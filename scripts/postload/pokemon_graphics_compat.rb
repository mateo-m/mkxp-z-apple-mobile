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
