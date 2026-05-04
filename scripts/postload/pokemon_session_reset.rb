# pokemon_session_reset.rb
#
# Neutralizes the "already running" guards Pokemon Reborn and
# Infinite Fusion (and similar PE fangames) use to skip
# resize-screen re-init on session 2+.
#
# Background: our engine reuses the Ruby VM across game sessions
# (Ruby 3's ruby_init/cleanup doesn't cycle cleanly), so any
# global the game's first session defines lingers into the
# second session's script-eval phase. The two PE patterns we
# have to defeat:
#
# 1. Reborn's `pbSetUpSystem` only calls `pbSetResizeFactor`
#    when `defined?($game_system)` is nil. We reset the VALUE
#    to nil between sessions but Ruby's symbol table still
#    knows the global by name, so `defined?` returns
#    "global-variable" (truthy) and Reborn takes the
#    "already up" branch.
#
# 2. Infinite Fusion's `pbSetResizeFactor` itself wraps the
#    `Graphics.resize_screen(SCREEN_WIDTH, SCREEN_HEIGHT)` call
#    in `if !$ResizeInitialized then ... ; $ResizeInitialized
#    = true ; end`. The flag survives session reset, so on
#    session 2 the inner `Graphics.resize_screen(512, 384)`
#    is skipped. Engine stays at the default 640x480 while
#    the game places sprites for 512x384, producing the
#    classic "viewport at 80% of available space" symptom
#    (512/640 = 0.8) with mixed layer sizes (Plane-based
#    layers tile across the engine's 640x480 while Bitmap-
#    based layers stay at 512x384).
#
# Fix:
# - Clear `$ResizeInitialized` at postload time so IF's
#   guard fails and the inner resize runs.
# - Spawn a one-shot Thread that waits for the game's
#   pbSetResizeFactor + $Settings to be defined, then calls
#   `pbSetResizeFactor($Settings.screensize)` unconditionally.
#   On session 1 this is a no-op because the game already
#   called it; on session 2 it forces the resize that the
#   game-side guard skipped.
#
# A Thread is used instead of a Graphics.update hook because
# Reborn's System.rb re-aliases Graphics.update, and on session
# 2 its `unless method_defined?(:__turbo_update)` guard skips
# the re-alias and orphans any hook we installed in the postload.

# Step 1: pre-emptive flag clears for known per-game guards.
# These run at postload time, BEFORE the game's scripts re-eval,
# so by the time the game's pbSetResizeFactor body runs the
# guard fails and the resize_screen call inside fires.
$ResizeInitialized = nil if defined?($ResizeInitialized)

# Step 2: belt-and-braces deferred re-call (handles guards we
# don't know about by forcing a re-init regardless).
Thread.new do
  begin
    10.times do
      sleep 0.3
      defined_resize = Object.private_method_defined?(:pbSetResizeFactor) ||
                       Object.method_defined?(:pbSetResizeFactor)
      next unless defined_resize
      next unless defined?($Settings) && $Settings
      next unless $Settings.respond_to?(:screensize)

      ss = begin
        $Settings.screensize
      rescue StandardError
        nil
      end
      next unless ss

      TOPLEVEL_BINDING.receiver.send(:pbSetResizeFactor, ss)
      break
    end
  rescue StandardError
    # Silently no-op on any error. Games that don't define
    # pbSetResizeFactor shouldn't care, and worst case the
    # original engine behavior applies.
  end
end
