# Bool-coercion compat - native RGSS treats any truthy value as ON
# when assigning a bool-typed property (`font.shadow = 20` simply
# turns the shadow on), but mkxp-z's rb_bool_arg accepts only
# true / false / nil and raises "TypeError: Argument 0: Expected
# bool" for everything else. Decade-old scripts lean on the
# forgiving Windows behavior: Galv's Event Pop Ups line 152 does
# `self.bitmap.font.shadow = 20` and crashes Hello Charlotte EP1 on
# the first event pop-up. Wrap the strict setters (the DEF_PROP_B /
# DEF_GFX_PROP_B surface in binding/) so values are coerced with
# Ruby truthiness before reaching the C binding, matching native
# RGSS at runtime while keeping the engine identical to upstream
# mkxp-z - same posture as nilclass_safe_stubs.rb.
#
# Postload scripts re-run on every F12 soft reset (the script loop
# in binding-mri.cpp restarts from the top), so each wrapper is
# guarded by the presence of its `empo_bool_orig_*` alias:
# re-aliasing on reset would point the saved original at the
# wrapper and recurse forever.
#
# VX/Ace variants bind under the same Ruby names (WindowVX ->
# Window, TilemapVX -> Tilemap). Setters a variant lacks (e.g.
# Window#stretch on VX) are skipped by the method_defined? guard.
{
  'Font' => %w[bold italic shadow outline],
  'Sprite' => %w[mirror pattern_tile invert],
  'Window' => %w[stretch active pause arrows_visible],
  'Tilemap' => %w[visible]
}.each do |klass_name, props|
  next unless Object.const_defined?(klass_name)

  klass = Object.const_get(klass_name)
  props.each do |prop|
    setter = "#{prop}="
    orig = "empo_bool_orig_#{prop}="
    next unless klass.method_defined?(setter)
    next if klass.method_defined?(orig)

    klass.class_eval do
      alias_method orig, setter
      define_method(setter) { |value| send(orig, value ? true : false) }
    end
  end
end

MKXP.puts('[bool-coerce] strict bool setters wrapped') if defined?(MKXP)
