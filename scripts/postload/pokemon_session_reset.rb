# pokemon_session_reset.rb
#
# Neutralizes the "already running" guard Pokemon Reborn (and
# similar PE fangames) use to skip re-init on session 2+.
#
# Reborn's `pbSetUpSystem` only calls `pbSetResizeFactor` when
# `defined?($game_system)` is nil. Our engine reuses the Ruby
# VM across game sessions (Ruby 3's ruby_init/cleanup doesn't
# cycle cleanly), so on session 2+ the global's name remains in
# Ruby's symbol table even after we reset the VALUE to nil, and
# `defined?` returns "global-variable" (truthy). Reborn then
# takes the "already up" branch, skips pbSetResizeFactor, and
# the engine stays at its 640x480 default while the game's
# sprites are positioned for 512x384. Visible as a shrunken
# viewport with black bars.
#
# Fix: defer a one-shot Thread that waits for the game's script
# evaluation to define pbSetResizeFactor + $Settings, then calls
# pbSetResizeFactor($Settings.screensize) unconditionally. On
# session 1 this is a no-op because the game already called it;
# on session 2 it performs the re-init the guard skipped.
#
# A Thread is used instead of a Graphics.update hook because
# Reborn's System.rb re-aliases Graphics.update, and on session
# 2 its `unless method_defined?(:__turbo_update)` guard skips
# the re-alias and orphans any hook we installed in the postload.

Thread.new do
  begin
    10.times do
      sleep 0.3
      defined_resize = Object.private_method_defined?(:pbSetResizeFactor) ||
                       Object.method_defined?(:pbSetResizeFactor)
      next unless defined_resize
      next unless defined?($Settings) && $Settings
      next unless $Settings.respond_to?(:screensize)
      ss = $Settings.screensize rescue nil
      next unless ss
      TOPLEVEL_BINDING.receiver.send(:pbSetResizeFactor, ss)
      break
    end
  rescue
    # Silently no-op on any error. Games that don't define
    # pbSetResizeFactor shouldn't care, and worst case the
    # original engine behavior applies.
  end
end
