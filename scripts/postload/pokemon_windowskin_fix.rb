# Pokemon windowskin cross-setSkin retention fix.
#
# Root cause: Older Pokemon Essentials forks (Uranium, Reborn
# pre-19.5, etc.) have a bug in SpriteWindow_Base#setSkin where
# the previous @customskin is disposed BEFORE the new one is
# loaded:
#
#   def setSkin(skin)
#     @customskin.dispose if @customskin    # releases bitmap
#     @customskin = nil
#     resolvedName = pbResolveBitmap(skin)
#     return if !resolvedName || resolvedName == ""
#     @customskin = AnimatedBitmap.new(resolvedName)
#     __setWindowskin(@customskin.bitmap)
#     ...
#   end
#
# The window's nine child decoration sprites (corner0..3, side0..3,
# back) still hold references to the old skin's underlying Bitmap
# via their .bitmap slot at the moment the dispose fires. Under
# our engine's Ruby 3 / mkxp-z build the dispose immediately frees
# the C-level bitmap, leaving those sprites pointing at freed
# memory. The next privRefresh sees @_windowskin.disposed? = true
# and the skinformat=1 else branch hides the back sprite, dropping
# the dialog's semi-transparent background. JoiPlay masks the bug
# through looser Bitmap#dispose semantics inherited from Ruby
# 1.9/2.1. We don't.
#
# Mainline Pokemon Essentials fixed this upstream by adding a
# `RPG::Cache.retain(resolvedName)` call right after the new
# AnimatedBitmap load, which bumps the BitmapCache refcount so
# any later @customskin.dispose does not actually free memory
# until the window itself disposes. Uranium was forked before
# that upstream fix, so it still ships the broken setSkin.
#
# Fix strategy: wrap setSkin and detect AT RUNTIME whether the
# game's existing implementation already retains. If it does, we
# skip our bump - avoiding a double-retain leak. If it doesn't,
# we bump using whichever refcount API the game's cache exposes
# (RPG::Cache.retain in newer PE forks, BitmapWrapper#addRef in
# older Uranium-style caches).
#
# Detection heuristic: read the refcount on @customskin's bitmap
# AFTER the original setSkin runs:
#   - refcount == 1 -> original did NOT retain. We bump to 2
#   - refcount  > 1 -> original already retained. Skip
#   - no refcount attribute exposed -> engine is not using a
#     refcounted cache at all, no bug to fix, skip.
#
# Why this is safe for other games:
#
#   * Games without setSkin at all: Thread never finds a target
#     class, no patch applied.
#   * Games whose setSkin already retains (mainline PE v20+):
#     post-call refcount is >= 2, we skip our bump. Zero leak.
#   * Games with the old buggy setSkin (Uranium, Reborn pre-19.5):
#     post-call refcount is 1, we bump to 2, next dispose
#     decrements to 1 instead of freeing. Bug fixed.

# Synchronous version: postloads run AFTER all game scripts have
# evaluated (binding-mri.cpp triggers them at i == scriptCount-1
# right before Main), so SpriteWindow_Base / SpriteWindow_Text /
# etc. are guaranteed to be defined by the time we reach here.
# The previous version wrapped this in Thread.new + sleep 0.3 ×
# 60 to be defensive. On Ruby 1.8 native (mkxp18-merged.o) that
# Thread spawn was hanging (green-threading interaction) and
# defensive retry was unnecessary anyway. Plain inline is faster
# and works on every Ruby version we target.
begin
  candidates = %w[
    SpriteWindow_Base
    SpriteWindow
    SpriteWindow_Text
    SpriteWindow_AdvancedTextPokemon
  ]
  target = nil
  candidates.each do |name|
    begin
      klass = Object.const_get(name)
      if klass.is_a?(Class) && klass.method_defined?(:setSkin)
        target = klass
        break
      end
    rescue NameError
      # Constant disappeared between defined? and const_get. Skip.
    end
  end

  if target && !target.method_defined?(:_mkxp_orig_setSkin)
    # Two possible refcount APIs. Prefer RPG::Cache.retain(path)
    # (mainline PE), fall back to BitmapWrapper#addRef (Uranium).
    has_rpg_cache_retain = defined?(RPG::Cache) && RPG::Cache.respond_to?(:retain)
    has_wrapper_addref = defined?(BitmapWrapper) && BitmapWrapper.method_defined?(:addRef)

    if has_rpg_cache_retain || has_wrapper_addref
      target.class_eval do
        alias_method :_mkxp_orig_setSkin, :setSkin
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        # The override walks "is a customskin set?" → "is its
        # bitmap usable?" → "is the refcount already bumped?" → "what
        # cache API is in scope?" - each condition must be checked
        # independently and short-circuits cleanly.
        define_method(:setSkin) do |skin|
          _mkxp_orig_setSkin(skin)
          # No customskin loaded (e.g. empty / invalid skin path)
          # means nothing to retain.
          return unless @customskin

          bmp = begin
            @customskin.bitmap
          rescue StandardError
            nil
          end
          return unless bmp && !bmp.disposed?

          # Skip bumping if the game's own setSkin already
          # retained the new skin - avoids a double-retain leak
          # on games that have the mainline PE fix.
          current_ref = if bmp.respond_to?(:refcount)
                          begin
                            bmp.refcount
                          rescue StandardError
                            nil
                          end
                        end
          return if current_ref && current_ref > 1

          if has_rpg_cache_retain
            resolved_name = pbResolveBitmap(skin)
            return if !resolved_name || resolved_name == ''

            RPG::Cache.retain(resolved_name)
          elsif bmp.respond_to?(:addRef)
            bmp.addRef
          end
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      end
    end
  end
rescue StandardError
  # Best-effort. Failure means engine default applies.
end
