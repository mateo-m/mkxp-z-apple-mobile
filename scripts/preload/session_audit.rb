# Session reset audit; surfaces Ruby state leaks that
# `binding-mri.cpp:resetBetweenSessions` doesn't currently scrub.
#
# Background: mkxp-z keeps the Ruby VM alive across game sessions
# (per-process iOS app, no `ruby_cleanup`). The engine's reset
# routine cleans a hardcoded list of constants/ivars/globals, but
# leaves entire categories untouched - notably methods + class
# variables on engine-baseline classes (Tone, Color, Sprite,
# Window_Base, Game_System, ...) that game scripts redefine in
# pure Ruby. Those redefinitions persist into the next game's
# session and can poison unrelated games (concrete failure: a
# chain of PE games -> RGSS3 game like BTTheManor crashes with
# `Tone#set: Can't convert Class into Tone` because
# `$game_system.window_tone` returns the wrong type).
#
# This file captures a snapshot of engine-baseline class state at
# the FIRST session's preload (clean post-mriBindingInit state)
# and saves it as `$__mkxp_audit_baseline`. Each subsequent
# session's reset hook re-snapshots and logs additions:
# methods/class-variables/instance-variables that grew since the
# baseline. The output goes to the per-game debug log via
# `mkxp_debugLog`, gated on the host's `debugLogs` setting.
#
# How to use:
#   1. Enable debug logs in Empo's app-wide settings.
#   2. Play game A, quit. Play game B, quit. Play game C.
#   3. Open game C's session log; the `[session-audit]` line
#      lists what game-A/B leaked into game-C's environment.
#   4. Each entry guides what to add to the engine's
#      `resetBetweenSessions` (or to a targeted preload-side
#      reset hook).
#
# Idempotency: the script's global-flag guard
# (`$__mkxp_session_audit_installed`) makes the body run exactly
# once across all sessions. The reset hook is registered with
# the standard `source_location` guard pattern.
#
# ---
#
# KNOWN LIMITATIONS. This audit is a tactical "clean the dishes
# after" cleanup, not a strategic isolation boundary. The
# strategic answer is process- or VM-isolation across game
# sessions; that work is paused (`MULTI_RUBY_INVESTIGATION.md`).
# Until isolation lands, the gaps below are not covered:
#
# 1. Hand-curated allow-list. Only the classes in
#    `$__MKXP_AUDIT_CLASSES` are watched. Pollution on `String`,
#    `Array`, `Hash`, `Integer`, `Class`, etc. slips through. Add
#    entries here when a real game breaks - don't pre-emptively
#    expand the list (broad coverage trades real risk for
#    speculative coverage).
#
# 2. Method *redefinition* is not detected. The diff is by symbol
#    name. If a game replaces `Marshal.load` (a baseline symbol)
#    with a Ruby version, the audit doesn't see it. Pokemon
#    Essentials' alias-then-redefine pattern leaves the alias
#    (`oldload`) visible as an addition, which acts as a
#    breadcrumb but doesn't catch the active redefinition itself.
#    Catching this requires storing baseline `Method#source_location`
#    values and diffing those - heavier, not currently done.
#
# 3. `Method#source_location` filter has edge cases. We treat
#    `nil` as "C-defined, leave alone" and non-nil as "Ruby-defined,
#    safe to remove". Methods built via `define_method` from C
#    extensions can return non-nil, and some `eval`'d code returns
#    nil. The conservative direction is "let pollution survive"
#    rather than "nuke core Ruby" - acceptable but not airtight.
#
# 4. Globals are logged but not auto-cleaned. Per-feature reset
#    hooks (`pokemon_compat.rb` etc.) own game-specific globals.
#    Auto-cleaning by denylist would risk clobbering legitimate
#    cross-session state (game saves cached at toplevel, MKXP
#    bridges, etc.). The audit logs unknown globals so we know
#    what to add to a hook; it doesn't act on them.
#
# Baseline-time pollution from engine preloads is invisible to
# the audit - anything our own preloads define becomes baseline.
# That's by design (we don't want to scrub our own infrastructure)
# but means the audit cannot catch a bug we introduce in our own
# preload scripts.

unless $__mkxp_session_audit_installed
  $__mkxp_session_audit_installed = true

  # Engine-baseline classes worth auditing. Anything game scripts
  # are likely to redefine, alias-extend, or stash class-vars on.
  # Add new entries here as we identify additional leak surfaces.
  #
  # `Marshal`, `Kernel`, `Object` are included because games often
  # monkey-patch `Marshal.load`, `Kernel#load_data`, or top-level
  # `def`s, and those patches survive into the next session unless
  # we detect+remove them. Auto-cleanup of these "core" namespaces
  # uses a `Method#source_location` safety filter (see
  # `__mkxp_audit_safe_to_remove?`): C/built-in methods return
  # `nil` from `source_location`, so we only remove pure-Ruby
  # additions. That way a baseline-snapshot timing miss can't
  # break stock Ruby.
  $__MKXP_AUDIT_CLASSES = %w[
    Tone Color Sprite Bitmap Window Window_Base Plane Tilemap
    Viewport Font Game_System Game_Map Game_Player Game_Party
    Game_Troop Game_Screen Game_Switches Game_Variables
    Marshal Kernel Object
  ].freeze

  # Classes where method removal must be gated on
  # `Method#source_location` being non-nil (i.e., the method is
  # Ruby-defined, not a C/built-in core method). Removing built-in
  # `Object#inspect` would brick Ruby; this list opts those
  # namespaces into the safety check.
  $__MKXP_AUDIT_GUARDED_CLASSES = %w[Marshal Kernel Object].freeze

  # Returns true when it's safe to remove `method_name` from
  # `klass` (instance/private/singleton). For "guarded" classes
  # like `Object`/`Kernel`/`Marshal`, only Ruby-defined methods
  # (those with a non-nil `source_location`) qualify - that
  # protects core C-defined methods from accidental removal in
  # case the baseline missed them.
  def __mkxp_audit_safe_to_remove?(klass, method_name, kind)
    return true unless $__MKXP_AUDIT_GUARDED_CLASSES.include?(klass.name)

    m =
      case kind
      when :singleton then begin
        klass.singleton_class.instance_method(method_name)
      rescue StandardError
        nil
      end
      else begin
        klass.instance_method(method_name)
      rescue StandardError
        nil
      end
      end
    return false if m.nil?

    loc = begin
      m.source_location
    rescue StandardError
      nil
    end
    !loc.nil?
  end

  # Take a structural snapshot of every audited class. We only
  # record the *names* (sorted) of each category, not the actual
  # method bodies / values. The point is to detect "did the set
  # grow", not to faithfully reconstruct state.
  #
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  # The complexity is intrinsic to Ruby-VM introspection: we walk
  # every audited class and capture five method/variable categories
  # per class. Splitting per-category would scatter the snapshot
  # into many small methods that all have to coordinate the same
  # error-tolerant fallbacks.
  def __mkxp_audit_snapshot
    state = { :__classes__ => {}, :__globals__ => {} }
    $__MKXP_AUDIT_CLASSES.each do |name|
      next unless Object.const_defined?(name)

      klass = Object.const_get(name)
      next unless klass.is_a?(Module)

      # Use rocket-style hash literals so this file parses on
      # Ruby 1.8 (where `key: value` shorthand is a syntax error).
      # `&:to_sym` Symbol-to-Proc shorthand works on 1.8.7+, but
      # we use an explicit block to stay compatible with bare 1.8
      # builds. `instance_methods` returns Strings on 1.8 and
      # Symbols on 1.9+; we normalize to Symbols for stable diffs.
      # `class_variables` / `instance_variables` are left in their
      # native type (Strings on 1.8, Symbols on 1.9+) because
      # later cleanup calls `instance_variable_set(v, nil)` which
      # on 1.8 requires the String form.
      state[:__classes__][name] = {
        :instance_methods => begin
          klass.instance_methods(false).map(&:to_sym).sort
        rescue StandardError
          []
        end,
        :private_instance_methods => (if klass.respond_to?(:private_instance_methods)
                                        begin
                                          klass.private_instance_methods(false).map(&:to_sym).sort
                                        rescue StandardError
                                          []
                                        end
                                      else
                                        []
                                      end),
        :singleton_methods => begin
          klass.singleton_methods(false).map(&:to_sym).sort
        rescue StandardError
          []
        end,
        :class_variables => begin
          klass.class_variables.sort
        rescue StandardError
          []
        end,
        :instance_variables => begin
          klass.instance_variables.sort
        rescue StandardError
          []
        end
      }
    end
    # Globals: record the *class name* of each non-nil global. A
    # leaked `$PokemonTemp` shows up as a global whose class isn't
    # in the baseline (the previous game's class object). Filter
    # out engine-baseline globals like `$~`, `$0`, `$/` etc. -
    # they're just standard Ruby/RGSS state.
    global_variables.each do |sym|
      # The audit's own bookkeeping globals would otherwise show
      # up as "leaks" because the baseline snapshot is taken
      # before the `||=` assignment that creates them. Skip the
      # whole `$__mkxp_*` namespace - it's reserved for engine/
      # preload internals (audit, reset hooks, keep-consts list,
      # session-installed flags, etc.).
      next if sym.to_s.start_with?('$__mkxp_', '$__MKXP_')

      val = begin
        # rubocop:disable Security/Eval -- audit code reads each
        # global by its symbol name; there's no fixed allowlist
        # because the point is to enumerate everything that exists.
        # Input comes from `global_variables` (Ruby builtins), not
        # user data, so this is safe.
        eval(sym.to_s)
        # rubocop:enable Security/Eval
      rescue StandardError
        nil
      end
      next if val.nil?

      class_name = begin
        val.class.name
      rescue StandardError
        '<anonymous>'
      end
      next if class_name.start_with?('Range', 'NilClass', 'TrueClass', 'FalseClass')

      state[:__globals__][sym] = class_name
    end
    state
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # For each audited class, list the names that are present in
  # `current` but NOT in `baseline`. Removed entries don't matter
  # for leak detection (they'd just be game scripts cleaning up
  # after themselves, which is fine). Globals are diffed by
  # name+class: if the same global has a different (non-nil) class
  # at session start vs baseline, treat it as a leaked instance.
  #
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  # Diff walks two parallel structures (classes-by-name and
  # globals-by-symbol); the cyclomatic depth is from the per-class
  # category loop plus per-global rescue, both inherent to the
  # operation.
  def __mkxp_audit_diff(baseline, current)
    out = {}
    classes_diff = {}
    (current[:__classes__] || {}).each do |class_name, current_state|
      baseline_state = (baseline[:__classes__] || {})[class_name] || {}
      added = {}
      current_state.each do |key, list|
        prev = baseline_state[key] || []
        new_entries = list - prev
        added[key] = new_entries unless new_entries.empty?
      end
      classes_diff[class_name] = added unless added.empty?
    end
    out[:classes] = classes_diff unless classes_diff.empty?

    leaked_globals = {}
    base_globals = baseline[:__globals__] || {}
    (current[:__globals__] || {}).each do |sym, klass_name|
      base_klass = base_globals[sym]
      # If the global existed at baseline with the same class,
      # that's expected stable state. New globals (not in baseline)
      # or globals that changed class are leaks.
      next if base_klass == klass_name

      leaked_globals[sym] = klass_name
    end
    out[:globals] = leaked_globals unless leaked_globals.empty?

    out
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Capture the baseline ONCE - on first preload of session 1, when
  # the engine has just re-installed its C methods via
  # mriBindingInit and game scripts haven't touched anything yet.
  # `||=` handles the case where another preload (or a prior
  # iteration of this one in the same process) already populated
  # the global.
  $__mkxp_audit_baseline ||= __mkxp_audit_snapshot

  # Diff at every session reset. Reset hooks fire in
  # `resetBetweenSessions` step 4, AFTER step 1-3 cleanup but
  # BEFORE step 5 GC and BEFORE the next session's preload
  # re-runs. This is the right window: state is mostly the
  # previous game's "end of session" picture, minus the already-
  # cleaned constants/ivars on the engine-managed list.
  $__mkxp_reset_hooks ||= []
  unless $__mkxp_reset_hooks.any? do |h|
    h.respond_to?(:source_location) && h.source_location && h.source_location[0] == __FILE__
  end
    # rubocop:disable Metrics/BlockLength -- the reset-hook block
    # walks the diff result by class + method category to remove
    # game-side additions; splitting it into helpers would scatter
    # related cleanup steps across many small methods.
    $__mkxp_reset_hooks << lambda do
      diff = __mkxp_audit_diff($__mkxp_audit_baseline, __mkxp_audit_snapshot)

      # Surface what we found in the per-session log so we can
      # iterate on the audit class list as new leaks are
      # identified. Cheap; only runs once per session start.
      if defined?(MKXP) && MKXP.respond_to?(:puts) && !diff.empty?
        (diff[:classes] || {}).each do |class_name, added|
          parts = added.map { |key, names| "#{key}=#{names.inspect}" }
          MKXP.puts "[session-audit] #{class_name}: #{parts.join(' ')}"
        end
        if (g = diff[:globals]) && !g.empty?
          MKXP.puts "[session-audit] leaked globals: #{g.inspect}"
        end
      end

      # CLEANUP. Remove the leaked Ruby additions on engine-baseline
      # classes so the next session sees stock state. This is the
      # piece that prevents cross-game pollution like the
      # `Tone#set: Can't convert Class into Tone` failure when a
      # PE game adds `tone=`/`tone` on the `Window` class and an
      # RGSS3 game's `Window_Base` then walks into the
      # game-defined override. Globals are NOT cleaned here -
      # individual preloads (`pokemon_compat.rb` etc.) own
      # game-specific globals via their own targeted reset hooks
      # so we don't have to maintain a denylist of "globals we own
      # vs. globals games own" in the audit itself.
      (diff[:classes] || {}).each do |class_name, added|
        next unless Object.const_defined?(class_name)

        klass = Object.const_get(class_name)
        next unless klass.is_a?(Module)

        (added[:instance_methods] || []).each do |m|
          next unless __mkxp_audit_safe_to_remove?(klass, m, :instance)

          begin
            klass.send(:remove_method, m)
          rescue StandardError
            nil
          end
        end
        (added[:private_instance_methods] || []).each do |m|
          next unless __mkxp_audit_safe_to_remove?(klass, m, :instance)

          begin
            klass.send(:remove_method, m)
          rescue StandardError
            nil
          end
        end
        (added[:singleton_methods] || []).each do |m|
          next unless __mkxp_audit_safe_to_remove?(klass, m, :singleton)

          begin
            klass.singleton_class.send(:remove_method, m)
          rescue StandardError
            nil
          end
        end
        (added[:class_variables] || []).each do |v|
          begin
            klass.send(:remove_class_variable, v)
          rescue StandardError
            nil
          end
        end
        # `Module#remove_instance_variable` exists, but only on
        # the instance side. For class-level instance vars on a
        # `Module`, set to nil; that's enough to defeat the
        # `unless @some_aliased_flag` guards game scripts use to
        # avoid double-aliasing.
        (added[:instance_variables] || []).each do |v|
          begin
            klass.instance_variable_set(v, nil)
          rescue StandardError
            nil
          end
        end
      end
    end
    # rubocop:enable Metrics/BlockLength
  end
end
