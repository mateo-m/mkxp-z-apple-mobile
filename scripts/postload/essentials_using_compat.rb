# Pokemon Essentials (v18 and older) defines a top-level
# `using(window) { ... }` that disposes the window after the block.
# UIHelper calls it from module methods, for example the quantity
# prompt when the player tosses an item. Ruby 1.8 finds Object#using
# there. Ruby 2+ finds Module#using (refinements) first, which raises
# "Module#using is not permitted in methods".
#
# This runs after the game's scripts, so the game's class bodies have
# already made any real refinement call.
if Module.private_method_defined?(:using) &&
   Object.private_method_defined?(:using)
  class Module
    def using(*args, &block)
      Object.instance_method(:using).bind(self).call(*args, &block)
    end
    private :using
  end
end
