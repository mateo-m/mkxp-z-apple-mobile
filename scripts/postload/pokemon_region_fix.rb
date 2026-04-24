# Pokemon Insurgence `getRegion` / `pbGetLanguage` fix.
#
# Latent bug in Insurgence's `186-Deuks_Region.rb:21`:
#
#   x = z.to_s.split('').map   # .map WITHOUT a block
#   y = x[0]                   # [] on the Enumerator
#
# On Ruby 1.8 (RMXP's original runtime) `.map` without a block
# returned the array itself, so `x[0]` worked. On Ruby 1.9+ (and
# therefore mkxp-z's Ruby 3.1) `.map` without a block returns an
# `Enumerator`, which has no `[]` method, crashing with
# `NoMethodError: undefined method '[]' for #<Enumerator: [...]:map>`.
#
# The function is additionally useless on iOS because its only
# real work is a `MiniRegistry.get(HKEY_CURRENT_USER, ...)` read
# of a Windows country code from the registry - meaningless off
# Windows. On non-Windows platforms `getCountryCode` returns nil
# and `z.to_i` is 0, so even if the Enumerator bug were fixed
# the function would return 0 for every iOS user anyway.
#
# Error surface: `pbTrainerName` -> `PokeBattle_Trainer#initialize`
# -> `pbGetLanguage` -> `getRegion` on first name-input confirm.
# Hits every iOS user of Insurgence. Regression since the bug is
# entirely in the game script (not in our port), but needs a
# port-side compat shim because we can't modify game scripts.
#
# Fix: override `getRegion` to return 2 (English), which is the
# fallback value the game's own code comments document as the
# intended default ("# Use 'English' by default" in
# 157-PokemonUtilities.rb:125). No visible behaviour change vs.
# what the game would do on a Windows install with a
# non-French/German/etc. locale.

if !$PokemonSystem.nil? && defined?(getRegion)
  # Top-level def overrides the original top-level def (Ruby
  # treats both as private instance methods on Object).
  def getRegion
    # 2 = English. Matches the `return 2 # Use 'English' by
    # default` comment in pbGetLanguage's commented-out Windows
    # locale-detection block.
    2
  end
end
