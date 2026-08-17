# platform_compat.rb
# Engine-level platform compatibility layer.
# Auto-loaded before game scripts to ensure compatibility.
# Game-specific patches live in separate files (e.g. pokemon_compat.rb).

begin
  require 'zlib'
rescue LoadError
  # zlib is optional for some vintage games. Preload continues without it.
end

# --- JoiPlay-compat signal ---
# Several Pokemon Essentials fangames (Reborn, Rejuvenation,
# Desolation, etc.) branch on `$joiplay` to pick between JoiPlay's
# stripped-down API surface and desktop mkxp-z's extended one.
# Example: Reborn's `internal_se_play` uses `Audio.se_play` on
# JoiPlay but `Audio.se_play_position` on desktop - the latter is
# an mkxp-z extension our iOS build doesn't carry. We ship
# JoiPlay-compat shims (NilClass safe-stubs, Win32API/DL stubs,
# poke_* graphics aliases, cheats, network stubs) so the JoiPlay
# code path often works here - but `$joiplay` also triggers patches
# written against JoiPlay's old mkxp fork that misbehave on this
# engine, so the host decides per game (System.joiplay_compat?,
# wired to mkxp_setJoiplayCompat). Default off when the host
# doesn't say.
$joiplay =
  defined?(System) && System.respond_to?(:joiplay_compat?) &&
  System.joiplay_compat?

# --- Thread.critical / Thread.critical= no-op shims (Ruby 1.9+) ---
# Ruby 1.8 had `Thread.critical` and `Thread.critical=` to disable
# thread switching during a critical section. Both were removed in
# Ruby 1.9 when the GIL was replaced by per-thread locks. Vintage
# RGSS / Pokemon Essentials code commonly wraps Marshal.load and
# save-file I/O with `Thread.critical = true` ... `Thread.critical
# = false`, expecting the methods to exist.
#
# On Ruby 1.9+ those calls now raise `NoMethodError: undefined
# method 'critical' for class 'Thread'`. The error often surfaces
# during quit / save flows where the in-game `pbExit` chain calls
# `pbSave` which sets `Thread.critical = true`, and has historically
# crashed the engine entirely (the `NoMethodError` propagates out of
# the script-eval loop, the engine's iOS shutdown path then segfaults
# because the Ruby VM is in an exception-pending state when
# SharedState::finiInstance() runs).
#
# Restore both as no-ops on every Ruby version that's missing them.
# The 1.8 cooperative-scheduling semantics don't apply under modern
# Ruby anyway. Calling code only cared that the methods existed.
unless Thread.respond_to?(:critical)
  # rubocop:disable Naming/PredicateMethod -- mocking Ruby 1.8's
  # `Thread.critical` reader, which returns a Boolean but is named
  # without `?` for backwards compatibility with the 1.8 API.
  def Thread.critical
    false
  end
  # rubocop:enable Naming/PredicateMethod

  def Thread.critical=(value)
    value
  end
end

# --- exit! / Process.exit! redirect to SystemExit ---
# Ruby's `Kernel.exit!(status)` and `Process.exit!(status)` skip
# `at_exit` handlers AND ALSO bypass the engine's SystemExit
# rescue path entirely - they call `_exit(status)` directly,
# which terminates the iOS process before mkxp-z can flush
# graphics state, save the engine log, fire the
# `mkxp_setEngineTerminated` callback, or do anything else.
#
# Pokemon Essentials' `pbExit` (and its many forks - Vanguard,
# Reborn, etc.) commonly use `exit!` so the user's quit click
# bypasses the game's "press any key to confirm" splash that
# `at_exit` handlers would normally trigger. On desktop this is
# a fine UX choice. On iOS it causes the app to vanish without
# the engine even getting a chance to know the user quit.
#
# Redirect both to `Kernel.exit(status)` so the engine's
# binding-mri.cpp script-eval loop catches the SystemExit, sets
# `mkxp_setEngineExitedCleanly()`, fires the terminated callback,
# and the iOS host shows the configured "game ended" UX. The
# desktop semantics of "skip at_exit handlers" are not preserved
# - we accept that trade because no shipping iOS PE-fork relies
# on the at_exit-skipping behaviour for anything user-visible.
module Kernel
  def exit!(status = false)
    exit(status)
  end
  module_function :exit!
end

module Process
  class << self
    alias _mkxp_orig_exit_bang exit! if respond_to?(:exit!) && !method_defined?(:_mkxp_orig_exit_bang)

    def exit!(status = false)
      Kernel.exit(status)
    end
  end
end

# Suppress Ruby's $DEBUG global. Some plugins gate verbose error
# dialogs / extra print output on `$DEBUG`. Without an explicit
# `false` the engine inherits whatever Ruby's startup defaulted to,
# which on some MRI builds is a truthy state (-d on the cmdline,
# RUBYOPT=-d, etc.). JoiPlay sets this in its preload for the same
# reason. Pinned here so plugins reading it during script load see
# the expected `false`.
$DEBUG = false

# Plugin-probe constants. Old Yanfly-era plugins look at
# `Graphics::PlaneSpeedUp`. Without an explicit definition our
# engine's `const_missing` returns `IOS::NullStub`, which is
# always-truthy and silently flips the plugin's optimization path
# the wrong way. Match JoiPlay's default: define the constant as
# `false` so the plugin's "no plane speedup" branch is taken.
unless defined?(Graphics::PlaneSpeedUp)
  module Graphics
    PlaneSpeedUp = false
  end
end

# Top-level no-op for `set_loop_points(intro_pos, loop_end)`. Some
# custom audio-loop plugins call this from map transitions /
# bgm_play overrides. On JoiPlay's default builds this exists as
# a Kernel-level no-op (preload.rb:119-120). Without it our
# `IOS::NullStub` const_missing path doesn't catch it (it's a
# method call, not a constant ref) and the script raises
# `NoMethodError: undefined method 'set_loop_points'`. The two-arg
# stub mirrors JoiPlay. Arity is permissive via `*args` to
# accommodate plugins that pass additional metadata.
module Kernel
  def set_loop_points(*args); end
  module_function :set_loop_points
end

# --- Case-insensitive file probes ---
# Native mkxp bindings now handle the core Ruby File/Dir/require/load
# casefold retries through the PhysFS-backed path cache. Keep only the
# Ruby-side helpers still needed by higher-level script APIs.
unless defined?(MKXPCasefoldFS)
  module MKXPCasefoldFS
    # rubocop:disable Style/SymbolArray -- `%i` does not parse on Ruby 1.8.
    FILE_QUERY_METHODS = [
      :exist?, :directory?, :file?, :zero?, :size?,
      :readable?, :readable_real?, :world_readable?,
      :writable?, :writable_real?, :world_writable?,
      :executable?, :executable_real?,
      :owned?, :grpowned?,
      :blockdev?, :chardev?, :pipe?, :socket?, :symlink?,
      :setuid?, :setgid?, :sticky?
    ].freeze
    FILE_VALUE_METHODS = [
      :size, :atime, :ctime, :mtime, :birthtime,
      :stat, :lstat, :ftype, :realpath, :readlink
    ].freeze
    FILE_READ_METHODS = [:read, :binread, :readlines, :foreach].freeze
    # rubocop:enable Style/SymbolArray
    GLOB_META_RE = /[*?\[{]/.freeze

    module_function

    def exists?(path)
      File.exist?(path)
    rescue StandardError
      false
    end

    def desensitize(path)
      return nil unless path.is_a?(String)

      return System.desensitize(path) if defined?(System) && System.respond_to?(:desensitize)
      return MKXP.desensitize(path) if defined?(MKXP) && MKXP.respond_to?(:desensitize)

      nil
    rescue StandardError
      nil
    end

    def resolve(path)
      return nil unless path.is_a?(String)

      resolved = desensitize(path)
      return nil if resolved.nil? || resolved.empty?
      return resolved if resolved != path
      return resolved if exists?(resolved)

      nil
    rescue StandardError
      nil
    end

    def fallback(path)
      resolved = resolve(path)
      return false unless resolved

      yield(resolved)
    end

    def resolve_parent(path)
      return nil unless path.is_a?(String)

      dirname = File.dirname(path)
      return nil if dirname.nil? || dirname.empty? || dirname == '.'

      resolved_dir = resolve(dirname)
      return nil unless resolved_dir

      basename = File.basename(path)
      resolved_dir = resolved_dir.gsub(%r{[\\/]\z}, '')
      basename.empty? ? resolved_dir : "#{resolved_dir}/#{basename}"
    rescue StandardError
      nil
    end

    def rescue_existing_path(path)
      resolved = resolve(path) || resolve_parent(path)
      return nil unless resolved

      yield(resolved)
    end

    def resolve_bitmap(path)
      return nil unless path.is_a?(String)

      base = path.gsub(/\.(bmp|png|gif|jpg|jpeg)$/i, '')
      ['.png', '.gif'].each do |ext|
        resolved = resolve(base + ext)
        return resolved if resolved
      end

      nil
    end

    def remap_glob_pattern(pattern)
      return nil unless pattern.is_a?(String)
      return nil unless pattern =~ GLOB_META_RE

      wildcard_index = pattern.index(GLOB_META_RE)
      return nil unless wildcard_index

      prefix = pattern[0...wildcard_index]
      slash = [prefix.rindex('/'), prefix.rindex('\\')].compact.max
      return nil unless slash

      dirname = pattern[0...slash]
      suffix = pattern[(slash + 1)..-1]
      resolved_dir = resolve(dirname)
      return nil unless resolved_dir

      "#{resolved_dir.gsub(%r{[\\/]\z}, '')}/#{suffix}"
    rescue StandardError
      nil
    end

    def remap_glob_arg(arg)
      if arg.is_a?(Array)
        changed = false
        remapped = arg.map do |pattern|
          replacement = remap_glob_pattern(pattern)
          changed ||= !replacement.nil? && replacement != pattern
          replacement || pattern
        end
        changed ? remapped : nil
      else
        remap_glob_pattern(arg)
      end
    end
  end
end

# Windows guarantees a system font directory, and games write into
# it without a mkdir: the stock Essentials FontInstaller copies its
# font files to "<SystemRoot>\Fonts\" and reads them back on the
# next launch as its "already installed" check. The faked
# SystemRoot points at the per-game data root, so map that one
# Windows-only shape onto a real "Fonts" folder there - for reads
# and writes alike, or the installed-check never passes. Every
# other path keeps MKXPSaveFS's literal resolution.
unless defined?(MKXPWindowsFonts)
  module MKXPWindowsFonts
    module_function

    # The host-wide shared font pool when the host declares one
    # (System.shared_fonts_path). The per-game fallback otherwise.
    # The shared pool matches Windows exactly: the system font
    # folder is one store for every game, so a font one game
    # installs satisfies the next game's installed-check too.
    def pool_root(savefs)
      shared = shared_root
      return shared if shared

      base = savefs.root
      base && "#{base}/Fonts"
    end

    def shared_root
      return @shared_root if defined?(@shared_root)

      @shared_root =
        if defined?(System) && System.respond_to?(:shared_fonts_path)
          path = System.shared_fonts_path.to_s
          path.empty? ? nil : path.gsub(%r{[\\/]+\z}, '')
        end
    end

    def target(savefs, path)
      return nil unless path.is_a?(String)

      base = savefs.root
      return nil unless base
      return nil unless path[0, base.length] == base

      rest = path[base.length..-1].to_s
      match = rest.match(%r{\A[\\/]+Fonts[\\/]+([^\\/]+)\z}i)
      return nil unless match

      pool = pool_root(savefs)
      pool && "#{pool}/#{match[1]}"
    end

    # The write half of the parity: the directory always exists on
    # Windows, so it must exist here before the first copy lands.
    def ensure_dir(savefs, target)
      dir = pool_root(savefs)
      return unless dir && target.is_a?(String)
      return unless target[0, dir.length + 1] == "#{dir}/"
      return if File._mkxp_orig_directory(dir)

      Dir.mkdir(dir)
    rescue StandardError
      nil
    end
  end
end

unless defined?(MKXPSaveFS)
  # rubocop:disable Metrics/ModuleLength -- the module is the single
  # file-API front. The alias-era recovery block below pushes it
  # over the limit and leaves once no install carries stranded
  # saves.
  module MKXPSaveFS
    module_function

    # Everything inside the game folder is literal. Games create,
    # list, write, and delete their own files with no interception;
    # UserData is involved only when a game addresses it itself
    # (System.data_directory, faked env vars). The constants below
    # serve one purpose: the alias-era migration
    # (migrate_portable_saves!) that moves saves stranded by earlier
    # builds into the portable folder those games read. They gate no
    # other runtime behavior and can go once no install carries
    # stranded saves.
    PORTABLE_SAVE_DIR = 'Save Data'.freeze
    PORTABLE_PREFIX = "#{PORTABLE_SAVE_DIR}/".freeze
    ENGINE_DIR_ENTRY_RE = /\Akeybindings\.mkxp\d+\z/.freeze
    # Rooted path: "/...", "\...", or a Windows drive prefix.
    ABSOLUTE_PATH_RE = %r{\A(?:[A-Za-z]:[\\/]|[\\/])}.freeze

    def root
      return @mkxp_save_root_memo if defined?(@mkxp_save_root_memo) && @mkxp_save_root_memo

      return nil unless defined?(System) && System.respond_to?(:data_directory)

      dir = System.data_directory.to_s
      return nil if dir.empty?

      @mkxp_save_root_memo = dir.gsub(%r{[\\/]+\z}, '')
    rescue StandardError
      nil
    end

    def normalize_path(path)
      path.strip.gsub('\\', '/')
    end

    def save_filename?(name)
      return false if empo_artifact?(name)
      return false if pre_literal_artifact?(name)

      lower = name.downcase
      return true if lower =~ /\A(?:save\d+|game)\.(?:rxdata|rvdata|rvdata2)\z/
      return true if lower.end_with?('.rxdata', '.rvdata', '.rvdata2')
      return true if lower.end_with?('.bak')

      false
    end

    # Host bookkeeping files carry an ".empo-" name segment
    # (drain collision backups "*.empo-displaced*.bak", rescue
    # markers ".empo-origin.json"). They belong to the host, not to
    # the game. No recovery may move them.
    def empo_artifact?(name)
      name.include?('.empo-')
    end

    # Collision backups this migration wrote itself
    # ("*.pre-literal.bak", "*.pre-literal-2.bak"). They must never
    # count as migration candidates again: re-migrating a backup
    # chains another suffix onto it on every enumeration.
    def pre_literal_artifact?(name)
      name.include?('.pre-literal')
    end

    # True when the two paths name the same directory entry, by
    # device+inode identity. A string comparison cannot decide
    # this: on iOS the host config spells the data dir /var/...
    # while getcwd resolves the symlink to /private/var/..., and
    # File.expand_path resolves no symlinks. The old string
    # comparison stays as the fallback for paths the identity
    # check cannot stat.
    def same_directory?(a, b)
      File.identical?(a, b)
    rescue StandardError
      File.expand_path(a) == File.expand_path(b)
    end

    # Identity check for migration source/destination pairs. On
    # error, prefer "not identical": the migration then runs its
    # normal collision path, which never destroys data.
    def same_entry?(a, b)
      File.identical?(a, b)
    rescue StandardError
      false
    end

    def engine_internal_entry?(name)
      return false unless name.is_a?(String)

      name =~ ENGINE_DIR_ENTRY_RE
    end

    def filter_dir_entries(entries)
      return entries unless entries.respond_to?(:reject)

      entries.reject { |entry| engine_internal_entry?(entry) }
    end

    # Bare working-directory save filenames - the shape decade-old
    # Essentials builds use, and the only shape the legacy-save
    # recovery below reacts to.
    def candidate?(path)
      return false unless path.is_a?(String)

      stripped = normalize_path(path)
      return false if stripped.empty?
      return false if stripped.start_with?('/', '~')
      return false if stripped =~ /\A[A-Za-z]:/
      return false if stripped.include?('/')

      save_filename?(stripped)
    end

    def orig_exist?(path)
      return FileTest._mkxp_orig_exist(path) if defined?(FileTest) && FileTest.respond_to?(:_mkxp_orig_exist)
      return File._mkxp_orig_exist(path) if File.respond_to?(:_mkxp_orig_exist)

      false
    rescue StandardError
      false
    end

    # Every path resolves literally - a game's writes inside its own
    # folder land exactly where Windows would put them. This helper
    # stays as the single file-API front for two recovery side
    # effects left from the alias era:
    #  - Earlier builds redirected bare working-directory save
    #    filenames ("Game.rxdata") into UserData. The first access
    #    of such a name moves the stranded copy back into the
    #    working directory. On a collision the newer mtime keeps
    #    the canonical name and the loser stays as
    #    *.pre-literal.bak.
    #  - The same builds flattened portable "Save Data/..." paths
    #    into the UserData root. A qualifying access under the
    #    portable dir runs the one-time sweep (see the
    #    portable-save migration section below).
    # Modern games address UserData saves by absolute path, match
    # neither gate, and keep their files where they are. Delete both
    # recoveries once no install carries stranded saves.
    def path_for(path)
      maybe_recover_portable_path(path)
      recover_legacy_save(path)
      MKXPWindowsFonts.target(self, path) || path
    end

    def recover_legacy_save(path)
      return unless path.is_a?(String)

      normalized = normalize_path(path)
      return unless candidate?(normalized)

      base = recovery_base
      return unless base

      stranded = "#{base}/#{normalized}"
      return unless File._mkxp_orig_file(stranded)

      migrate_save_file(stranded, normalized)
    rescue StandardError
      nil
    end

    # The UserData root both alias-era recoveries may take files
    # FROM, or nil when no recovery may run. Two gates, shared by
    # the single-file and the glob recovery:
    #  - The redirect the recoveries undo only ever happened with
    #    the game folder as the cwd, so any other cwd skips them.
    #    Essentials' Dir.get chdirs INTO the data dir to enumerate
    #    saves. Without this gate the recovery would "migrate"
    #    those saves onto themselves.
    #  - Degenerate host config: the data dir IS the game folder.
    #    Compared by identity, not by spelling - on iOS the same
    #    directory arrives as /var/... and resolves from getcwd as
    #    /private/var/....
    def recovery_base
      base = root
      return nil unless base
      return nil unless cwd_at_game_root?
      return nil if same_directory?(base, '.')

      base
    end

    # Bare glob patterns enumerate the working directory (ancient
    # slot pickers use "Save*.rxdata"). Recover every stranded root
    # save the pattern would match before the literal glob runs, so
    # enumeration and open agree on one folder. Gated per name on the
    # save shape so a bare "*" cannot drag engine-internal UserData
    # files into the game folder.
    def recover_saves_for_glob(pattern)
      patterns = pattern.is_a?(Array) ? pattern : [pattern]
      patterns.each do |pat|
        next unless pat.is_a?(String)

        # A pattern inside the portable dir is an enumeration of it.
        maybe_recover_portable_dir(pat)

        normalized = normalize_path(pat)
        next if normalized.empty? || normalized.include?('/')

        recover_glob_matches(normalized)
      end
      nil
    rescue StandardError
      nil
    end

    def recover_glob_matches(normalized)
      base = recovery_base
      return unless base

      Dir._mkxp_orig_entries(base).each do |name|
        next unless save_filename?(name)
        next unless File.fnmatch(normalized, name)
        next unless File._mkxp_orig_file("#{base}/#{name}")

        migrate_save_file("#{base}/#{name}", name)
      end
    rescue StandardError
      nil
    end

    # iOS's filesystem is case-sensitive. Windows-authored games open
    # files with mismatched case (e.g. "Audio/BGM/TITLE_MD.ogg" for
    # title_md.ogg) and expect it to work. The engine resolves the
    # actual on-disk spelling through its case-insensitive path cache
    # (System.resolve_case_path). Returns nil when nothing matches, so
    # callers can retry raw file APIs once after Errno::ENOENT.
    def casefold_fallback(path)
      return nil unless defined?(System) && System.respond_to?(:resolve_case_path)

      candidate = path.to_s
      return nil if candidate.empty?
      return nil if candidate =~ ABSOLUTE_PATH_RE

      resolved = System.resolve_case_path(candidate)
      return nil if resolved.nil? || resolved == candidate

      resolved
    rescue StandardError
      nil
    end

    # Windows-authored games write over their own files with
    # mismatched case ("Battle Open.wav" over "Battle Open.WAV" -
    # Rejuvenation's updater extracts patches this way) and delete or
    # rename them the same way. On Windows both spellings are one
    # file. Here a raw create makes a duplicate on the device and
    # fails with Errno::EEXIST under the simulator's case-sensitivity
    # emulation, and a raw delete or rename misses the file. Resolve
    # the on-disk spelling first, so destructive file APIs hit the
    # file the game means.
    def resolve_case_target(path)
      str = path.to_s
      return path if str.empty?
      return path if raw_exist?(str)

      case_variant(str) || path
    rescue StandardError
      path
    end

    # Strict spelling probe. The engine keeps the pre-casefold
    # exist? under `_mkxp_native_orig_exist?`. The `_mkxp_orig_*`
    # aliases below capture the casefold-aware replacement, which
    # reports true for any spelling and would defeat this check.
    def raw_exist?(str)
      if File.respond_to?(:_mkxp_native_orig_exist?)
        File._mkxp_native_orig_exist?(str)
      else
        File._mkxp_orig_exist(str)
      end
    end

    # On-disk spelling for a mismatched-case path, or nil when the
    # spelling already matches or nothing resolves. Absolute paths
    # resolve when they point inside the game directory or inside
    # UserData. The engine's boot-time case cache answers first. A
    # live directory walk then covers what the cache cannot know -
    # files the game created this session (a self-updater extracts
    # files and touches them again under another spelling).
    def case_variant(str)
      prefix, rel = split_case_prefix(str)
      return nil if rel.nil?

      fixed = nil
      # The cache is game-root-relative: valid for absolute paths
      # under the game root, and for relative paths only while the
      # working directory IS the game root.
      fixed = casefold_fallback(rel) if prefix == game_root_prefix || (prefix.nil? && cwd_at_game_root?)
      if fixed.nil?
        walked = live_case_walk(rel, prefix ? prefix[0, prefix.length - 1] : '.')
        fixed = walked unless walked == rel
      end
      return nil unless fixed

      prefix ? "#{prefix}#{fixed}" : fixed
    end

    # [prefix, rel] split of a path against the known roots. prefix
    # is nil for relative paths. Both are nil when an absolute path
    # points outside every known root.
    def split_case_prefix(str)
      return [nil, str] unless str =~ ABSOLUTE_PATH_RE

      [game_root_prefix, userdata_prefix].each do |base|
        next unless base
        next unless str.length > base.length && str[0, base.length] == base

        return [base, str[base.length..-1]]
      end
      [nil, nil]
    end

    def userdata_prefix
      base = root
      base ? "#{base}/" : nil
    end

    def cwd_at_game_root?
      "#{File.expand_path('.')}/" == game_root_prefix
    rescue StandardError
      true
    end

    # Case-insensitive component walk against the live filesystem,
    # anchored at base. A component with an on-disk case variant
    # takes that spelling. A component with no match stays literal
    # (it is about to be created). Returns the input unchanged when
    # nothing differs.
    def live_case_walk(rel, base)
      current = base
      rel.split(%r{[\\/]+}).map do |part|
        spelled = live_component_spelling(current, part)
        current = "#{current}/#{spelled}"
        spelled
      end.join('/')
    end

    def live_component_spelling(dir, part)
      return part if part.empty? || part == '.' || part == '..'

      names = Dir._mkxp_orig_entries(dir)
      return part if names.include?(part)

      lower = part.downcase
      names.find { |name| name.downcase == lower } || part
    rescue StandardError
      part
    end

    # The engine starts every session in the game directory, and this
    # file loads before any game script can chdir away. The captured
    # spelling anchors absolute-path case resolution to the game root
    # even when a game changes the working directory later. The
    # capture call sits at the end of this file, outside the module
    # guard, so test harnesses that reload the file refresh it too.
    def capture_game_root!
      @mkxp_game_root_prefix = "#{File.expand_path('.')}/"
    end

    def game_root_prefix
      @mkxp_game_root_prefix
    end

    # True when an open mode creates, truncates, appends, or opens
    # for update - every case where the open must land on the
    # existing on-disk spelling instead of creating a duplicate.
    # Encoding suffixes ("r:windows-1252") stay out of the check, and
    # a keyword-style {mode: ...} hash contributes its :mode value.
    def write_mode?(mode)
      mode = mode[:mode] if mode.is_a?(Hash) && mode.key?(:mode)
      case mode
      when Integer
        (mode & (File::WRONLY | File::RDWR | File::APPEND | File::CREAT)) != 0
      when String, Symbol
        mode.to_s.split(':', 2)[0] =~ /[wa+]/ ? true : false
      else
        false
      end
    end

    def write_casefold(path, mode)
      return path unless write_mode?(mode)

      resolve_case_target(path)
    end

    # Shared File.open / File.new front: legacy-save recovery first,
    # then the write-mode case resolution.
    def open_target(path, mode)
      target = path_for(path)
      MKXPWindowsFonts.ensure_dir(self, target) if write_mode?(mode)
      write_casefold(target, mode)
    end

    # Errno::ENOENT retry target for the open wrappers. The same
    # resolution the write side uses, so absolute in-game paths and
    # session-created files resolve for reads too. A path with a
    # stray "\r" gets a second retry with those stripped: Windows
    # forbids control characters in file names, so the "\r" can only
    # come from CRLF text split with binary reads (Desolation's
    # script loader parses its CSV listing this way). Windows' own
    # text-mode reads drop the "\r" before the path is built.
    def read_fallback_target(path)
      str = path.to_s
      fixed = case_variant(str)
      return path_for(fixed) if fixed

      return nil unless str.include?("\r")

      cleaned = str.delete("\r")
      return path_for(cleaned) if raw_exist?(cleaned)

      fixed = case_variant(cleaned)
      fixed ? path_for(fixed) : nil
    rescue StandardError
      nil
    end

    # True when a resolved directory target IS the per-game UserData
    # root - the game using System.data_directory (trailing separator
    # included) or a faked env var pointing at it. Callers use this
    # to (a) filter engine-internal entries out of listings of the
    # root and (b) no-op mkdir/rmdir of the root: the host owns that
    # directory, games must never remove it, and "create my data
    # folder" is always already satisfied.
    def save_root_target?(target)
      base = root
      return false unless base && target.is_a?(String)

      target.gsub(%r{[\\/]+\z}, '') == base
    end

    # --- Portable-save migration (virtual alias -> literal) ---
    # Earlier builds virtualized the portable save dir: portable
    # games wrote "Save Data/..." and the shim flattened it into the
    # UserData root. "Save Data" is literal now, so affected
    # installs have their portable content stranded at that root.
    # The sweep below moves it back into the folder the game reads.
    #
    # The sweep is access-driven. No boot-time gate can know whether
    # a game resolves saves through the portable dir. Rejuvenation-
    # lineage builds go portable on the launcher identity alone
    # (RTP.isPortable -> mobile? -> $empo/$kirin), with no marker
    # file and no JoiPlay toggle. And a $joiplay-keyed boot sweep
    # would move root saves for games that never read the portable
    # dir. So the wrappers watch for the game itself to touch
    # portable save content. The first qualifying access runs one
    # sweep per boot:
    #  - an enumeration of the portable dir (the Reborn-lineage
    #    load screens list it), or
    #  - a file access under "Save Data/" that misses literally
    #    while the flattened counterpart exists at the root.
    # A bare probe of a missing marker never qualifies. A
    # non-portable game that only checks "Save Data/.portable"
    # keeps its root saves untouched.
    #
    # The sweep moves every stranded entry, subdirectories included
    # (the alias flattened "Save Data/Battle Logs/..." the same
    # way). Engine bookkeeping entries and host ".empo-" artifacts
    # stay at the root. On a name collision the newer mtime wins
    # the canonical name (ties go to the root copy, which the alias
    # preferred for both reads and writes). The loser is kept
    # beside it as *.pre-literal.bak.
    # Paths resolve against the engine cwd (the game folder, set by
    # main.cpp/config.cpp before the binding boots), the same base
    # the game's own "Save Data/" strings resolve against. The cwd
    # guard skips the sweep while a game has chdir'd elsewhere.
    def maybe_recover_portable_path(path)
      return if @portable_sweep_done
      return unless path.is_a?(String) && path.start_with?('Save')

      normalized = normalize_path(path)
      return unless normalized.start_with?(PORTABLE_PREFIX)

      rel = normalized[PORTABLE_PREFIX.length..-1]
      return if rel.nil? || rel.empty?
      return if orig_exist?(normalized)

      base = sweep_base
      return unless base && orig_exist?("#{base}/#{rel}")

      run_portable_sweep!
    rescue StandardError
      nil
    end

    def maybe_recover_portable_dir(path)
      return if @portable_sweep_done
      return unless path.is_a?(String) && path.start_with?('Save')

      normalized = normalize_path(path).gsub(%r{/+\z}, '')
      return unless normalized == PORTABLE_SAVE_DIR || normalized.start_with?(PORTABLE_PREFIX)

      run_portable_sweep!
    rescue StandardError
      nil
    end

    def run_portable_sweep!
      return if @portable_sweep_done
      return unless cwd_at_game_root?

      @portable_sweep_done = true
      migrate_portable_saves!
    end

    # The boot section at the end of this file re-arms the sweep on
    # every load, so test harness reloads start clean.
    def arm_portable_sweep!
      @portable_sweep_done = false
    end

    # UserData root for sweeps, or nil when the host config is
    # degenerate (no data dir, or the data dir IS the game folder -
    # a sweep there would shuffle shipped root saves into Save
    # Data).
    def sweep_base
      base = root
      return nil if base.nil? || base == '.'
      return nil if same_directory?(base, '.')

      base
    end

    def migrate_portable_saves!
      base = sweep_base
      return unless base

      names = begin
        Dir._mkxp_orig_entries(base)
      rescue StandardError
        nil
      end
      return if names.nil?

      movable = names.reject { |name| skip_portable_entry?(name) }
      return if movable.empty?

      Dir._mkxp_orig_mkdir(PORTABLE_SAVE_DIR) unless orig_exist?(PORTABLE_SAVE_DIR)
      movable.each do |name|
        migrate_save_entry("#{base}/#{name}", "#{PORTABLE_PREFIX}#{name}")
      end
    rescue StandardError
      nil
    end

    def skip_portable_entry?(name)
      return true if ['.', '..'].include?(name)
      return true if name == '.DS_Store'
      return true if engine_internal_entry?(name)

      empo_artifact?(name)
    end

    def migrate_save_entry(src, dst)
      if File._mkxp_orig_file(src)
        migrate_save_file(src, dst)
      elsif File._mkxp_orig_directory(src)
        migrate_save_tree(src, dst)
      end
    rescue StandardError
      nil
    end

    # Directory form of the migration. A whole stranded tree renames
    # over when the destination is free. Otherwise merge entry by
    # entry, recursing into shared subdirectories. Per-file
    # collisions follow the migrate_save_file mtime rule. The source
    # directory goes away only when everything inside it moved.
    def migrate_save_tree(src, dst)
      return File._mkxp_orig_rename(src, dst) unless orig_exist?(dst)
      return unless File._mkxp_orig_directory(dst)

      Dir._mkxp_orig_entries(src).each do |name|
        next if ['.', '..'].include?(name)

        migrate_save_entry("#{src}/#{name}", "#{dst}/#{name}")
      end
      Dir._mkxp_orig_rmdir(src) if Dir._mkxp_orig_entries(src).size <= 2
    rescue StandardError
      nil
    end

    def migrate_save_file(src, dst)
      # The same inode reached through two spellings must never
      # "migrate": the rename pair below would strip the file down
      # to its backup name and leave nothing at the canonical one.
      return if same_entry?(src, dst)

      unless orig_exist?(dst)
        File._mkxp_orig_rename(src, dst)
        return
      end

      backup = pre_literal_backup_name(dst)
      if migrate_source_newer?(src, dst)
        File._mkxp_orig_rename(dst, backup)
        File._mkxp_orig_rename(src, dst)
      else
        File._mkxp_orig_rename(src, backup)
      end
    rescue StandardError
      nil
    end

    # First free backup name beside dst. rename(2) replaces an
    # existing target silently, so a fixed backup name would
    # destroy the previous backup on a second collision.
    def pre_literal_backup_name(dst)
      name = "#{dst}.pre-literal.bak"
      return name unless orig_exist?(name)

      index = 2
      index += 1 while orig_exist?("#{dst}.pre-literal-#{index}.bak")
      "#{dst}.pre-literal-#{index}.bak"
    end

    # Ties go to the root (src) copy: on the first alias->literal
    # boot equal stamps mean copies of the same file, and the alias
    # treated the root as authoritative.
    def migrate_source_newer?(src, dst)
      File._mkxp_orig_mtime(src) >= File._mkxp_orig_mtime(dst)
    rescue StandardError
      true
    end
  end
  # rubocop:enable Metrics/ModuleLength
end

# Pokemon Essentials' `pbResolveBitmap` relies on `pbTryString`, which probes a
# candidate path and returns the ORIGINAL string on success. On Windows that is
# fine because later opens are also case-insensitive. On iOS we need the real
# mixed-case path for callers that keep using the returned filename.
unless Object.respond_to?(:_mkxp_casefold_orig_method_added, true)
  class << Object
    alias _mkxp_casefold_orig_method_added method_added

    # rubocop:disable Lint/MissingSuper -- this callback must invoke the aliased
    # original hook so the same code parses on Ruby 1.8.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    # rubocop:disable Naming/VariableName -- preserve upstream Pokemon method names.
    def method_added(name)
      _mkxp_casefold_orig_method_added(name)

      case name
      when :pbTryString
        return if @_mkxp_wrapping_pbTryString

        @_mkxp_wrapping_pbTryString = true
        original_method = instance_method(:pbTryString)

        define_method(:pbTryString) do |x|
          result = original_method.bind(self).call(x)
          return result unless x.is_a?(String)

          resolved = MKXPCasefoldFS.resolve(x)
          return result unless resolved

          if result.nil?
            retried = original_method.bind(self).call(resolved)
            if retried.nil?
              result
            else
              if defined?(System)
                System.puts("[platform_compat] pbTryString casefold hit: #{x} -> #{resolved}")
              end
              resolved
            end
          else
            System.puts("[platform_compat] pbTryString normalized: #{x} -> #{resolved}") if defined?(System)
            resolved
          end
        end

        private :pbTryString
      when :pbResolveBitmap
        return if @_mkxp_wrapping_pbResolveBitmap

        @_mkxp_wrapping_pbResolveBitmap = true
        original_method = instance_method(:pbResolveBitmap)

        define_method(:pbResolveBitmap) do |*args|
          result = original_method.bind(self).call(*args)
          return result if result.is_a?(Bitmap)

          x = args[0]
          resolved = MKXPCasefoldFS.resolve_bitmap(x)
          path = resolved || result
          return nil if path.nil?
          return nil if path.is_a?(String) && path.empty?

          if resolved
            if result.nil?
              if defined?(System)
                System.puts("[platform_compat] pbResolveBitmap casefold hit: #{x} -> #{resolved}")
              end
            elsif result != resolved
              if defined?(System)
                System.puts("[platform_compat] pbResolveBitmap normalized: #{x} -> #{resolved}")
              end
            end
          end
          path
        end
        ruby2_keywords(:pbResolveBitmap) if respond_to?(:ruby2_keywords, true)

        private :pbResolveBitmap
      end
    ensure
      @_mkxp_wrapping_pbTryString = false if name == :pbTryString
      @_mkxp_wrapping_pbResolveBitmap = false if name == :pbResolveBitmap
    end
    # rubocop:enable Naming/VariableName
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    # rubocop:enable Lint/MissingSuper
  end

  System.puts '[platform_compat] pbTryString casefold hook armed' if defined?(System)
  System.puts '[platform_compat] pbResolveBitmap casefold hook armed' if defined?(System)
end

# --- Process spawning neutralization ---
# fork()/exec() are forbidden on iOS and cause immediate SIGKILL.
# Neutralize all process-spawning methods at the engine level.
module Kernel
  # Process-spawning methods are no-ops on iOS: fork/exec would be
  # killed by the sandbox and system("game.exe") only makes sense on
  # Windows. Return nil so games keep running. Real exec() would
  # terminate the process but that's the entire iOS app here, so a
  # silent no-op is the safer default.
  def system(*_args)
    nil
  end

  def exec(*_args)
    nil
  end

  def fork(*_args)
    nil
  end

  def spawn(*_args)
    nil
  end
  module_function :system, :exec, :fork, :spawn
end

# --- Windows environment variable stubs ---
# Many RGSS games use ENV["TEMP"] / ENV["APPDATA"] for file operations,
# and some derive save paths from USERPROFILE / LOCALAPPDATA /
# COMPUTERNAME. Mirror JoiPlay's full fake-Windows environment so
# scripts constructing paths from ENV don't return nil and crash.
# Values point into the iOS sandbox (or are blank strings) so File.exist?
# returns false rather than reading unrelated system dirs.
tmp = '/tmp'
begin
  tmp = Dir.tmpdir
rescue StandardError
  # Dir.tmpdir can raise on locked-down sandboxes. Fall back to /tmp.
end

# SDL_GetPrefPath contract: directory paths used for string-concat
# save joins must end with '/'. iOS normalize strips trailing slashes.
# The C++ System.data_directory binding re-adds one. Shared by the
# Ruby mirror (stale-merged.o safety) and ENV setup below.
module MkxpPath
  module_function

  def ensure_trailing_dir_sep(path)
    p = path.to_s
    return './' if p.empty? || p == '.'

    p.end_with?('/', '\\') ? p : "#{p}/"
  end
end

if defined?(System) && System.respond_to?(:data_directory) && !System.respond_to?(:_mkxp_orig_data_directory)
  class << System
    alias _mkxp_orig_data_directory data_directory

    def data_directory(*args)
      MkxpPath.ensure_trailing_dir_sep(_mkxp_orig_data_directory(*args))
    end
  end
end

save_root = nil
begin
  if defined?(System) && System.respond_to?(:data_directory)
    root = System.data_directory.to_s
    save_root = root unless root.empty?
  end
rescue StandardError
  save_root = nil
end
# Fake Windows env vars → per-game save root (trailing slash required
# for `ENV['APPDATA'] + "Game.rxdata"`-style concat).
# Machine/user identity for the fake Windows env below: prefer the
# launcher identity the host declared ($userAgent), fall back to the
# engine's own name so nothing here is tied to a specific host app.
host_identity = defined?($userAgent) && $userAgent ? $userAgent.to_s : 'mkxp'
userdata = MkxpPath.ensure_trailing_dir_sep(save_root || "#{tmp}/UserData")
ENV['TEMP'] ||= tmp
ENV['TMP']  ||= tmp
ENV['APPDATA']              ||= userdata
ENV['LOCALAPPDATA']         ||= userdata
ENV['ALLUSERSPROFILE']      ||= userdata
ENV['USERPROFILE']          ||= userdata
ENV['HOMEDRIVE']            ||= ''
ENV['HOMEPATH']             ||= userdata
ENV['SystemRoot']           ||= userdata
ENV['windir']               ||= userdata
ENV['COMPUTERNAME']         ||= host_identity
ENV['USERNAME']             ||= host_identity
ENV['USERDOMAIN']           ||= host_identity
ENV['SESSIONNAME']          ||= host_identity
ENV['OS']                   ||= 'Windows_NT'
ENV['PATH']                 ||= ''
ENV['PATHEXT']              ||= ''
ENV['Platform']             ||= ''
ENV['NUMBER_OF_PROCESSORS'] ||= '4'
ENV['PROCESSOR_ARCHITECTURE'] ||= 'x86'
ENV['PROCESSOR_IDENTIFIER'] ||= 'Intel64 Family6'
ENV['PROCESSOR_LEVEL']      ||= '6'
ENV['PROCESSOR_REVISION']   ||= '2a07'
ENV['AV_APPDATA']           ||= userdata

# --- Float bitwise-op monkey-patches ---
# RGSS scripts occasionally do `x ^ 2` when they mean `x ** 2` (a
# Game-Maker-idiom leak) or `x << n` to cheaply multiply by 2**n. On
# stock Ruby these raise NoMethodError against Float. Adding the ops
# is a zero-risk unlock for a long tail of buggy scripts.
class Float
  def ^(other)
    self**other
  end

  def <<(num)
    self * (2**num)
  end

  def >>(other)
    self / (2**other)
  end
end

# --- Input::Controller state stubs ---
# Prevents NoMethodError crashes from games that probe gamepad
# state via a pad API the iOS port doesn't expose. Cited offender
# is Sometimes Always Monsters, which calls
# `Input::Controller.first_state.thumb_left_x` (and friends) at
# startup. Without these stubs the script terminates before the
# title screen. We are NOT implementing real gamepad support here
# - every method returns a zero / false / [] sentinel so probes
# succeed and the game falls through to keyboard / touch input.
#
# Guarded on `defined?(Input::Controller)` so a future engine-level
# Controller binding (or a game that ships its own) isn't clobbered.
# Source: JoiPlay mkxp/binding-mri/preload.rb:123-177.
unless defined?(Input::Controller)
  module Input
    module Controller
      class State
        def left_trigger_value
          0
        end

        def right_trigger_value
          0
        end

        def thumb_left_x
          0
        end

        def thumb_left_y
          0
        end

        def thumb_right_x
          0
        end

        def thumb_right_y
          0
        end

        def thumb_left_dir4
          0
        end

        def thumb_left_dir8
          0
        end

        def thumb_right_dir4
          0
        end

        def thumb_right_dir8
          0
        end

        def press?(_button)
          false
        end

        def trigger?(_button)
          false
        end

        def repeat?(_button)
          false
        end

        def pressed_buttons
          []
        end
      end

      def self.states
        [State.new]
      end

      def self.first_state
        State.new
      end
    end
  end
end

# --- Audio.se_play_position shim ---
# Pokemon Reborn's custom desktop mkxp-z fork extends Audio with
# spatially-positioned sound effects:
# `se_play_position(name, volume, pitch, x, y, z)`. Reborn's
# `internal_se_play` calls it on every SE when `$joiplay` is false,
# so without a shim the first message-confirm sound raises
# NoMethodError and soft-locks the scene. Our engine's SE path has
# no spatial support. Drop the coordinates and play the SE plain -
# identical to the game's own JoiPlay branch
# (`Audio.se_play(name, volume, pitch)`).
#
# Guarded so a future engine-native implementation (or a game's own
# monkey-patch loaded later via preload) wins over the shim.
if defined?(Audio) && Audio.respond_to?(:se_play) && !Audio.respond_to?(:se_play_position)
  module Audio
    def self.se_play_position(filename, volume = 100, pitch = 100, *_position)
      se_play(filename, volume, pitch)
    end
  end
end

# --- MKXP module shim ---
# Some game preload scripts expect the MKXP module from Ancurio's
# original mkxp. mkxp-z uses "System" module instead.
module MKXP
  def self.zinflate(string)
    Zlib::Inflate.inflate(string)
  end

  def self.zdeflate(string, level = Zlib::DEFAULT_COMPRESSION)
    Zlib::Deflate.deflate(string, level)
  end

  def self.data_directory(*args)
    System.data_directory(*args) if defined?(System)
  end

  def self.puts(*args)
    if defined?(System)
      System.puts(*args)
    else
      Kernel.puts(*args)
    end
  end

  def self.desensitize(path)
    System.desensitize(path) if defined?(System)
  end
end

# --- Windows text-mode read emulation ---
# Windows Ruby opens files in text mode by default and folds CRLF to
# LF on read. Games depend on that: Desolation's script loader splits
# its CSV listing on "\n" and derives file paths and control flow
# from the fields, and a kept "\r" breaks both. Pokemon Pathways ships
# the RGSS Script Editor loader, which splits a CRLF load_order.txt on
# "\n" and then rejects every entry because File.extname sees ".rb\r".
# Fold the same way for plain read-mode opens on the modern VM. Binary
# opens ('b' flag, integer flags), update modes, write modes, and calls
# with explicit extra arguments stay raw.
unless defined?(MKXPTextMode)
  module MKXPTextMode
    module_function

    # File.read and its friends take no mode argument, so Windows
    # applies text mode to every one of these calls. Fold the bare
    # form only: a call that gives a length, a separator, or its own
    # options keeps the arguments it was given.
    def whole_file_args(args)
      opts = universal_newline_opts
      return args unless opts && args.empty?

      [opts]
    end

    def read_args(args)
      opts = universal_newline_opts
      return args unless opts
      return ['r', opts] if args.empty?
      return args unless args.length == 1

      mode = args[0]
      return args unless mode.is_a?(String)

      flags = mode.split(':', 2)[0]
      return args unless %w[r rt].include?(flags)

      [mode, opts]
    end

    # The option hash carries the ruby2_keywords flag so the splat
    # in the File wrappers passes it as keywords.
    def universal_newline_opts
      return @universal_newline_opts if defined?(@universal_newline_opts)

      capable = defined?(System) && System.respond_to?(:ruby_version) &&
                System.ruby_version.to_f >= 3.1 &&
                Hash.respond_to?(:ruby2_keywords_hash)
      @universal_newline_opts =
        capable ? Hash.ruby2_keywords_hash({ :newline => :universal }) : nil
    end
  end
end

# --- File API front: legacy-save recovery + case resolution ---
# Paths resolve literally. path_for only performs the one-time
# legacy-save recovery side effect. The case helpers keep destructive
# operations on the on-disk spelling. IO.read is not hooked. No
# observed game reads saves through it.
class << File
  alias _mkxp_orig_open open unless method_defined?(:_mkxp_orig_open)
  alias _mkxp_orig_delete delete unless method_defined?(:_mkxp_orig_delete)
  alias _mkxp_orig_rename rename unless method_defined?(:_mkxp_orig_rename)
  alias _mkxp_orig_new new unless method_defined?(:_mkxp_orig_new)
  alias _mkxp_orig_exist exist? unless method_defined?(:_mkxp_orig_exist)
  alias _mkxp_orig_exists exists? unless method_defined?(:_mkxp_orig_exists)
  alias _mkxp_orig_file file? unless method_defined?(:_mkxp_orig_file)
  alias _mkxp_orig_directory directory? unless method_defined?(:_mkxp_orig_directory)
  alias _mkxp_orig_size size unless method_defined?(:_mkxp_orig_size)
  alias _mkxp_orig_size? size? unless method_defined?(:_mkxp_orig_size?)
  alias _mkxp_orig_zero? zero? unless method_defined?(:_mkxp_orig_zero?)
  alias _mkxp_orig_mtime mtime unless method_defined?(:_mkxp_orig_mtime)

  def open(path, *args, &block)
    args = MKXPTextMode.read_args(args)
    _mkxp_orig_open(MKXPSaveFS.open_target(path, args[0]), *args, &block)
  rescue Errno::ENOENT
    fixed = MKXPSaveFS.read_fallback_target(path)
    raise unless fixed

    _mkxp_orig_open(fixed, *args, &block)
  end

  def new(path, *args)
    args = MKXPTextMode.read_args(args)
    _mkxp_orig_new(MKXPSaveFS.open_target(path, args[0]), *args)
  rescue Errno::ENOENT
    fixed = MKXPSaveFS.read_fallback_target(path)
    raise unless fixed

    _mkxp_orig_new(fixed, *args)
  end

  def delete(*paths)
    _mkxp_orig_delete(*paths.map { |path| MKXPSaveFS.resolve_case_target(MKXPSaveFS.path_for(path)) })
  end
  # File.unlink is a distinct singleton method. Without this alias it
  # would bypass the legacy-save recovery and the case resolution.
  alias unlink delete

  def rename(from, to)
    _mkxp_orig_rename(
      MKXPSaveFS.resolve_case_target(MKXPSaveFS.path_for(from)),
      MKXPSaveFS.resolve_case_target(MKXPSaveFS.path_for(to))
    )
  end

  def exist?(path)
    _mkxp_orig_exist(MKXPSaveFS.path_for(path))
  end

  def exists?(path)
    _mkxp_orig_exists(MKXPSaveFS.path_for(path))
  end

  def file?(path)
    _mkxp_orig_file(MKXPSaveFS.path_for(path))
  end

  def directory?(path)
    _mkxp_orig_directory(MKXPSaveFS.path_for(path))
  end

  def size(path)
    _mkxp_orig_size(MKXPSaveFS.path_for(path))
  end

  def size?(path)
    _mkxp_orig_size?(MKXPSaveFS.path_for(path))
  end

  def zero?(path)
    _mkxp_orig_zero?(MKXPSaveFS.path_for(path))
  end

  def mtime(path)
    _mkxp_orig_mtime(MKXPSaveFS.path_for(path))
  end

  # Whole-file read/write helpers must resolve bare save names the
  # same way File.open does, or a game's File.read of a save sees a
  # different copy than its File.open (guard/act disagreement).
  # binread/binwrite/write are guarded: absent on Ruby 1.8.
  alias _mkxp_orig_read read unless method_defined?(:_mkxp_orig_read)

  def read(path, *args)
    _mkxp_orig_read(MKXPSaveFS.path_for(path), *MKXPTextMode.whole_file_args(args))
  end

  alias _mkxp_orig_readlines readlines unless method_defined?(:_mkxp_orig_readlines)

  def readlines(path, *args)
    _mkxp_orig_readlines(MKXPSaveFS.path_for(path), *MKXPTextMode.whole_file_args(args))
  end

  alias _mkxp_orig_foreach foreach unless method_defined?(:_mkxp_orig_foreach)

  def foreach(path, *args, &block)
    _mkxp_orig_foreach(MKXPSaveFS.path_for(path), *MKXPTextMode.whole_file_args(args), &block)
  end

  if (method_defined?(:binread) || private_method_defined?(:binread)) && !method_defined?(:_mkxp_orig_binread)
    alias _mkxp_orig_binread binread

    def binread(path, *args)
      _mkxp_orig_binread(MKXPSaveFS.path_for(path), *args)
    end
  end

  if (method_defined?(:write) || private_method_defined?(:write)) && !method_defined?(:_mkxp_orig_write)
    alias _mkxp_orig_write write

    def write(path, *args)
      _mkxp_orig_write(MKXPSaveFS.resolve_case_target(MKXPSaveFS.path_for(path)), *args)
    end
  end

  if (method_defined?(:binwrite) || private_method_defined?(:binwrite)) &&
     !method_defined?(:_mkxp_orig_binwrite)
    alias _mkxp_orig_binwrite binwrite

    def binwrite(path, *args)
      _mkxp_orig_binwrite(MKXPSaveFS.resolve_case_target(MKXPSaveFS.path_for(path)), *args)
    end
  end

  # Ruby 3 separates keyword args from positionals. Without the
  # ruby2_keywords flag these *args wrappers would collapse
  # `File.open(path, mode: 'rb')`-style kwargs into a positional
  # Hash and the original method raises TypeError. No-op relevant
  # on 1.8/1.9 (hash-positional is the native semantic there).
  if respond_to?(:ruby2_keywords, true)
    ruby2_keywords :open
    ruby2_keywords :new
    ruby2_keywords :read
    ruby2_keywords :readlines
    ruby2_keywords :foreach
    ruby2_keywords :binread if method_defined?(:_mkxp_orig_binread)
    ruby2_keywords :write if method_defined?(:_mkxp_orig_write)
    ruby2_keywords :binwrite if method_defined?(:_mkxp_orig_binwrite)
  end
end

module FileTest
  class << self
    alias _mkxp_orig_exist exist? unless method_defined?(:_mkxp_orig_exist)
    alias _mkxp_orig_file file? unless method_defined?(:_mkxp_orig_file)
    alias _mkxp_orig_directory directory? unless method_defined?(:_mkxp_orig_directory)

    def exist?(path)
      _mkxp_orig_exist(MKXPSaveFS.path_for(path))
    end

    if (method_defined?(:exists?) || private_method_defined?(:exists?)) &&
       !method_defined?(:_mkxp_orig_exists)
      alias _mkxp_orig_exists exists?

      def exists?(path)
        _mkxp_orig_exists(MKXPSaveFS.path_for(path))
      end
    end

    def file?(path)
      _mkxp_orig_file(MKXPSaveFS.path_for(path))
    end

    def directory?(path)
      _mkxp_orig_directory(MKXPSaveFS.path_for(path))
    end

    # Size probes need the same ENOENT casefold retry File.open has.
    # Daybreak's AudioUtilities scans MP3 frames through an already
    # casefolded File.open, then calls FileTest.size with the
    # game's own mismatched spelling ("Audio/BGM/TITLE.mp3" for
    # Title.mp3) and dies at the title screen without the retry.
    if (method_defined?(:size) || private_method_defined?(:size)) && !method_defined?(:_mkxp_orig_size)
      alias _mkxp_orig_size size

      def size(path)
        _mkxp_orig_size(MKXPSaveFS.path_for(path))
      rescue Errno::ENOENT
        fixed = MKXPSaveFS.read_fallback_target(path)
        raise unless fixed

        _mkxp_orig_size(fixed)
      end
    end

    if (method_defined?(:size?) || private_method_defined?(:size?)) && !method_defined?(:_mkxp_orig_size?)
      alias _mkxp_orig_size? size?

      # size? answers nil for a missing file instead of raising, so
      # the casefold retry keys on that rather than on ENOENT.
      # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
      # -- nil-for-missing is FileTest.size?'s documented contract.
      def size?(path)
        found = _mkxp_orig_size?(MKXPSaveFS.path_for(path))
        return found unless found.nil?

        fixed = MKXPSaveFS.read_fallback_target(path)
        fixed ? _mkxp_orig_size?(fixed) : nil
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition
    end
  end
end

class << Dir
  alias _mkxp_orig_glob glob unless method_defined?(:_mkxp_orig_glob)
  alias _mkxp_orig_brackets [] unless method_defined?(:_mkxp_orig_brackets)
  alias _mkxp_orig_new new unless method_defined?(:_mkxp_orig_new)
  alias _mkxp_orig_open open unless method_defined?(:_mkxp_orig_open)
  alias _mkxp_orig_entries entries unless method_defined?(:_mkxp_orig_entries)
  alias _mkxp_orig_foreach foreach unless method_defined?(:_mkxp_orig_foreach)
  if (method_defined?(:exist?) || private_method_defined?(:exist?)) && !method_defined?(:_mkxp_orig_exist)
    alias _mkxp_orig_exist exist?
  end
  alias _mkxp_orig_mkdir mkdir unless method_defined?(:_mkxp_orig_mkdir)

  # Globs are literal. The one side effect: a bare save-file pattern
  # first recovers any legacy saves stranded at the UserData root
  # into the working directory (see recover_saves_for_glob), so slot
  # enumeration and the open that follows see the same folder.
  def glob(pattern, *args, &block)
    MKXPSaveFS.recover_saves_for_glob(pattern)
    _mkxp_orig_glob(pattern, *args, &block)
  end
  # Keep Ruby 3 kwargs (`Dir.glob(pat, base: dir)` - rubygems uses
  # this) flowing through the *args wrapper. See the File note above.
  ruby2_keywords :glob if respond_to?(:ruby2_keywords, true)

  # Dir[] shares glob's recovery. Ancient slot pickers use both.
  def [](*patterns)
    MKXPSaveFS.recover_saves_for_glob(patterns)
    _mkxp_orig_brackets(*patterns)
  end
  ruby2_keywords :[] if respond_to?(:ruby2_keywords, true)

  # Dir.new / Dir.open enumerate too - the Reborn-lineage load
  # screens list saves through Dir.new(getSaveFolder). Give both
  # the portable recovery trigger. Paths stay literal.
  def new(path, *args)
    MKXPSaveFS.maybe_recover_portable_dir(path)
    _mkxp_orig_new(path, *args)
  end
  ruby2_keywords :new if respond_to?(:ruby2_keywords, true)

  def open(path, *args, &block)
    MKXPSaveFS.maybe_recover_portable_dir(path)
    _mkxp_orig_open(path, *args, &block)
  end
  ruby2_keywords :open if respond_to?(:ruby2_keywords, true)

  def entries(path = '.', *args)
    # Listings are literal. A listing of the portable save dir first
    # recovers alias-era stranded content (maybe_recover_portable_dir).
    # Listings of the UserData root (System.data_directory, faked
    # env var spellings) hide engine-internal entries. Everything
    # else passes through.
    MKXPSaveFS.maybe_recover_portable_dir(path)
    target = MKXPSaveFS.path_for(path)
    result = _mkxp_orig_entries(target, *args)
    return MKXPSaveFS.filter_dir_entries(result) if MKXPSaveFS.save_root_target?(target)

    result
  end
  ruby2_keywords :entries if respond_to?(:ruby2_keywords, true)

  def foreach(path = '.', *args, &block)
    MKXPSaveFS.maybe_recover_portable_dir(path)
    target = MKXPSaveFS.path_for(path)
    unless block
      if MKXPSaveFS.save_root_target?(target)
        return MKXPSaveFS.filter_dir_entries(_mkxp_orig_entries(target, *args)).each
      end

      return _mkxp_orig_foreach(target, *args)
    end

    if MKXPSaveFS.save_root_target?(target)
      MKXPSaveFS.filter_dir_entries(_mkxp_orig_entries(target, *args)).each(&block)
    else
      _mkxp_orig_foreach(target, *args, &block)
    end
  end
  ruby2_keywords :foreach if respond_to?(:ruby2_keywords, true)

  # Ruby 2.5+/2.6+ additions. Pokemon Rejuvenation's New Game Plus
  # code lists the save folder via Dir.each_child.
  if method_defined?(:children) || private_method_defined?(:children)
    alias _mkxp_orig_children children unless method_defined?(:_mkxp_orig_children)

    def children(path, *args)
      MKXPSaveFS.maybe_recover_portable_dir(path)
      target = MKXPSaveFS.path_for(path)
      result = _mkxp_orig_children(target, *args)
      return MKXPSaveFS.filter_dir_entries(result) if MKXPSaveFS.save_root_target?(target)

      result
    end
    ruby2_keywords :children if respond_to?(:ruby2_keywords, true)
  end

  if method_defined?(:each_child) || private_method_defined?(:each_child)
    alias _mkxp_orig_each_child each_child unless method_defined?(:_mkxp_orig_each_child)

    def each_child(path, *args, &block)
      MKXPSaveFS.maybe_recover_portable_dir(path)
      target = MKXPSaveFS.path_for(path)
      unless block
        if MKXPSaveFS.save_root_target?(target)
          return MKXPSaveFS.filter_dir_entries(_mkxp_orig_children(target, *args)).each
        end

        return _mkxp_orig_each_child(target, *args)
      end

      if MKXPSaveFS.save_root_target?(target)
        MKXPSaveFS.filter_dir_entries(_mkxp_orig_children(target, *args)).each(&block)
      else
        _mkxp_orig_each_child(target, *args, &block)
      end
    end
    ruby2_keywords :each_child if respond_to?(:ruby2_keywords, true)
  end

  if method_defined?(:exist?) || private_method_defined?(:exist?)
    def exist?(path)
      _mkxp_orig_exist(MKXPSaveFS.path_for(path))
    end
  end

  if (method_defined?(:exists?) || private_method_defined?(:exists?)) && !method_defined?(:_mkxp_orig_exists)
    alias _mkxp_orig_exists exists?

    def exists?(path)
      _mkxp_orig_exists(MKXPSaveFS.path_for(path))
    end
  end

  # The portable save dir is LITERAL: Pokemon Rejuvenation's
  # portable mode (isPortable -> getSaveFolder == "Save Data/")
  # creates it with
  #   Dir.mkdir("Save Data/") unless File.exists?("Save Data/")
  # and then runs
  #   Dir.mkdir(RTP.getSaveFolder + "Battle Debug Logs/")
  # at the start of every battle, unrescued. Both resolve relative
  # to the game folder and must really create the directories there,
  # exactly as on Windows/JoiPlay - an earlier alias scheme answered
  # the first mkdir with a virtual success, which left the second
  # one without a parent and black-screened the battle transition
  # with Errno::ENOENT.
  # The wrappers exist for one reason: the UserData root itself is
  # host-owned - "create it" reports success instead of
  # Errno::EEXIST, and "remove it" must never actually happen.
  def mkdir(path, *args)
    target = MKXPSaveFS.path_for(path)
    return 0 if MKXPSaveFS.save_root_target?(target)

    # Case-resolve so FileUtils.mkdir_p of "audio/bgs" extends the
    # on-disk "Audio/BGS" tree instead of creating a duplicate one.
    _mkxp_orig_mkdir(MKXPSaveFS.resolve_case_target(target), *args)
  end

  alias _mkxp_orig_rmdir rmdir unless method_defined?(:_mkxp_orig_rmdir)

  def rmdir(path)
    target = MKXPSaveFS.path_for(path)
    return 0 if MKXPSaveFS.save_root_target?(target)

    _mkxp_orig_rmdir(MKXPSaveFS.resolve_case_target(target))
  end
  alias delete rmdir
  alias unlink rmdir
end

module Kernel
  alias _mkxp_orig_load_data load_data unless method_defined?(:_mkxp_orig_load_data)
  alias _mkxp_orig_save_data save_data unless method_defined?(:_mkxp_orig_save_data)

  def load_data(path, *args)
    _mkxp_orig_load_data(MKXPSaveFS.path_for(path), *args)
  end

  def save_data(obj, path, *args)
    _mkxp_orig_save_data(obj, MKXPSaveFS.path_for(path), *args)
  end
  module_function :load_data, :save_data
end

# --- Win32 library null-stub via const_missing ---
# Win32-only library scripts (RGSS Linker, FMODEX, network loaders, etc.)
# reference constants that never get defined on iOS because DLL loading is a
# no-op (see win32_wrap.rb). Instead of adding per-library stubs, hook
# Module#const_missing so any undefined constant - top-level OR nested
# inside a partially-defined module like Berka::NetErrorErr - resolves to
# a safe stub rather than raising NameError.
#
# Two kinds of stubs are returned:
#
# 1. Constants whose name ends in Error, Err, Exception, or Failure become
#    real StandardError subclasses. This matters because games commonly
#    write `raise Berka::NetErrorErr, "msg"`. The raised exception must
#    inherit from Exception or Ruby rejects it, and if it is NullStub the
#    alert ends up showing "IOS::NullStub" as the error message.
#
# 2. Everything else becomes IOS::NullStub, which silently absorbs any
#    method call and any nested constant lookup. This covers library
#    namespaces like FmodEx, FmodEx::System, etc.
#
# NullStub is also raisable. Games sometimes raise a typo'd nested
# constant that only resolves on iOS (Daybreak's downloader does
# `raise Berka::NetErrorErr::ConIn`. `ConIn` has no error suffix, so
# it resolves to NullStub). What `raise <stub>` does depends on the
# VM:
#
# - Ruby 1.9+ coerces the argument through `to_str` first, so the
#   stub raises as a RuntimeError with an empty message. Ugly, but
#   not fatal.
# - Ruby 1.8 accepts only real Strings, then requires the argument
#   to respond to `exception`. method_missing does not satisfy that
#   check, so the script's own raise dies with a fatal
#   "exception class/object expected" TypeError.
# - The two-argument form `raise <stub>, msg` requires `exception`
#   on every VM.
#
# The explicit `exception` hook below makes the 1.8 and two-argument
# paths produce a plain StandardError with a readable message.
module IOS
  class NullStub
    # Raise protocol hook: `raise NullStub` calls exception() and
    # `raise NullStub, msg` calls exception(msg) on every VM we
    # target (1.8 / 1.9 / 3.x).
    def self.exception(message = nil)
      StandardError.new(message || 'a Win32-only feature is unavailable on this platform')
    end

    def self.method_missing(_name, *_args)
      self
    end

    def self.respond_to_missing?(_name, _include_private = false)
      true
    end

    def self.const_missing(_name)
      self
    end

    def self.new(*_args)
      self
    end

    # to_s/to_str return empty string so `"prefix: #{stub}"` and any implicit
    # string coercion produce clean output instead of leaking the internal
    # class name or raising TypeError on Ruby 3.x strict coercion.
    def self.to_s
      ''
    end

    def self.to_str
      ''
    end

    def self.inspect
      '#<IOS::NullStub>'
    end

    # Instance-level twin of the raise protocol hook. NullStub.new
    # returns the class, so instances are rare - but a game can still
    # obtain one (e.g. via allocate) and raise it.
    def exception(message = nil)
      self.class.exception(message)
    end

    def method_missing(_name, *_args)
      nil
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  # rubocop:disable Style/MutableConstant -- const_missing populates
  # this lazily via `ErrorStubs[key] ||= ...` (line ~437) so it can't
  # be frozen.
  ErrorStubs = {}
  # rubocop:enable Style/MutableConstant
  ERROR_SUFFIX_RE = /(?:Error|Err|Exception|Failure)\z/.freeze
  PB_DATA_TABLE_RE = /\APB[A-Z]/.freeze
end

class Module
  # `super` does not work in a redefined Module#const_missing (there
  # is no superclass implementation), so keep the original around for
  # the passthrough paths. It raises the stock NameError.
  alias _mkxp_orig_const_missing const_missing unless method_defined?(:_mkxp_orig_const_missing)

  def const_missing(name)
    return _mkxp_orig_const_missing(name) unless Object.const_defined?(:IOS)

    # Pokemon Essentials keeps its data tables in PB* classes
    # (PBItems, PBSpecies, PBMoves, ...). Games probe these tables
    # for optional entries with `const_get(...) rescue nil` and treat
    # the NameError as the "entry is absent" signal. A stub does not
    # raise, so the probe would hand a Class to game code that
    # expects an Integer id. Empyrean does exactly this for optional
    # *_CARD items and then crashes on `card < 2000`. No Win32
    # library lives in a PB* namespace, so let these lookups raise
    # as they do on Windows.
    return _mkxp_orig_const_missing(name) if self.name.to_s =~ ::IOS::PB_DATA_TABLE_RE

    if name.to_s =~ ::IOS::ERROR_SUFFIX_RE
      key = [self, name]
      ::IOS::ErrorStubs[key] ||= begin
        klass = Class.new(StandardError)
        const_set(name, klass)
        klass
      end
    else
      ::IOS::NullStub
    end
  end
end

# --- Dir.chdir nil/empty-safety ---
# Pokemon Essentials and some plugin scripts pass nil or "" to
# Dir.chdir. nil crashes Ruby pre-2.0 outright. "" raises
# Errno::ENOENT on every Ruby version. Both are no-ops in spirit
# (the script wants "stay where you are") so we route them through
# the no-arg form, which is safe and well-defined (returns to home
# dir or no-op when called with a block on no-arg).
class << Dir
  alias _mkxp_orig_chdir chdir unless method_defined?(:_mkxp_orig_chdir)
  def chdir(dir = nil, &block)
    return _mkxp_orig_chdir(&block) if dir.nil? || dir.empty?

    _mkxp_orig_chdir(dir, &block)
  end
end
if defined?(System) && System.respond_to?(:puts)
  has_orig = Dir.respond_to?(:_mkxp_orig_chdir)
  System.puts "[platform_compat] Dir.chdir patch applied (orig defined? #{has_orig})"
end

# --- DL / DL::CFunc legacy fake module ---
# Older Pokemon Essentials forks and a few community plugins use
# Ruby 1.8's `require 'dl'` + `DL::CFunc` to call user32 / kernel32
# functions directly (pre-dating Win32API). On Ruby 3 the stdlib
# `dl` gem doesn't exist and our `const_missing` hook only returns
# `IOS::NullStub`, which is not hash-indexable. Scripts doing
# `dll = DL.dlopen('user32'); dll['GetSystemMetrics']` therefore
# fail on `Hash#[]` even though the constant itself resolves.
#
# Ported from JoiPlay's preload.rb. `dlopen` returns a populated
# hash so the lookup succeeds. `CFunc.new` stores the function
# name and delegates `call` to Win32API (which our win32_wrap
# already routes to noop / safe-default returns on iOS).
module DL
  class CFunc
    def initialize(func, type = 'i')
      @func_name = func.to_s
      @type = type
      @impl = begin
        Win32API.new('User32', @func_name, %w[l p], 'i') if defined?(Win32API)
      rescue StandardError
        nil
      end
    end

    def call(*args)
      return @impl.call(*args) if @impl

      0
    end

    def to_s
      @func_name.to_s
    end

    def to_str
      @func_name.to_s
    end
  end

  USER32_FUNCS = %w[
    GetActiveWindow GetSystemMetrics GetWindowRect SetWindowLong
    SetWindowPos FindWindow GetForegroundWindow GetCursorPos
    SetWindowText
  ].freeze

  KERNEL32_FUNCS = %w[
    GetModuleHandle GetPrivateProfileString GetCurrentThreadId
    GetCurrentProcess SetPriorityClass
  ].freeze

  def self.dlopen(lib = '')
    name = lib.to_s.downcase
    table = case name
            when /user32/   then USER32_FUNCS
            when /kernel32/ then KERNEL32_FUNCS
            else []
            end
    h = Hash.new { |_, k| k.to_s } # unknown keys echo their own name
    table.each { |fn| h[fn] = fn }
    h
  end
end

# --- Socket / network stubs ---
# Our embedded Ruby doesn't compile the network stdlib (socket,
# net/http, net/https, openssl, uri) and games can't install user
# gems (discord-rpc, poke-api-v2, rest-client). Without help a
# single `require 'socket'` at the top of a bootstrap script
# raises LoadError and terminates the whole eval, so Reborn and
# similar games don't even reach the title screen. We solve this
# in two layers:
#
# 1. Provide minimal no-op classes for socket primitives (below)
#    so scripts that do `TCPSocket.open(...)` don't NameError
#    later on.
# 2. Intercept Kernel#require with an allowlist of known-missing
#    network stdlib + gems. If the require matches the allowlist
#    and the original require raises LoadError, we swallow it and
#    return false (mimicking "already loaded") so the calling
#    script continues. Non-network requires still propagate.
#
# TODO: compile Ruby with network stdlib so online features
# work. See TODO.md "Engine / compatibility".

# --- rbconfig fallback ---
# Our embedded Ruby doesn't ship `rbconfig` (it's generated per-arch
# at Ruby build time, so it never lands in the static ext set).
# Desktop-targeting games hit it indirectly - e.g. Pokemon Reborn's
# bundled rubyzip does `require 'rbconfig'` on the non-JoiPlay path
# and reads CONFIG['host_os'] to pick Windows vs POSIX path
# handling. Reborn ships its own stdlib copies of rbconfig.rb but
# only pushes the arch subdir (stdlib/x64-mingw32 etc.) onto the
# load path for platforms it knows about, so on iOS the require
# fails and the whole script eval aborts.
#
# When `require 'rbconfig'` raises LoadError, install a minimal
# darwin-flavored RbConfig instead - iOS is closest to macOS (POSIX
# paths, case-insensitive FS), so callers branch away from the
# Windows-specific path handling that would corrupt our paths.
# Installing a real module matters: merely swallowing the require
# would leave `RbConfig::CONFIG['host_os']` to the const_missing
# NullStub, whose method_missing chain is always-truthy and would
# match ANY `=~ /mswin|mingw/` probe as Windows.
#
# Lazy (hooked into the require rescue below, not pre-defined) so a
# game that gets a real rbconfig.rb onto the load path still loads
# the genuine article without constant-redefinition noise.
module MKXPRbConfigFallback
  module_function

  # Unknown keys resolve to '' (not nil) so string ops on unprobed
  # CONFIG entries don't raise.
  def config_values
    parts = RUBY_VERSION.split('.')
    config = Hash.new { |_hash, _key| '' }
    config.update(
      'MAJOR' => parts[0],
      'MINOR' => parts[1],
      'TEENY' => parts[2],
      'ruby_version' => "#{parts[0]}.#{parts[1]}.0",
      'RUBY_PROGRAM_VERSION' => RUBY_VERSION,
      'host_os' => 'darwin',
      'target_os' => 'darwin',
      'host_cpu' => 'arm64',
      'target_cpu' => 'arm64',
      'arch' => 'arm64-darwin',
      'sitearch' => 'arm64-darwin',
      'host' => 'arm64-apple-darwin',
      'ruby_install_name' => 'ruby',
      'RUBY_INSTALL_NAME' => 'ruby',
      'RUBY_SO_NAME' => 'ruby',
      'EXEEXT' => '',
      'DLEXT' => 'bundle',
      'SOEXT' => 'dylib',
      'PATH_SEPARATOR' => ':'
    )
  end

  def install
    return if Object.const_defined?(:RbConfig)

    config = config_values
    mod = Module.new
    mod.const_set(:CONFIG, config)
    mod.const_set(:MAKEFILE_CONFIG, config)
    mod.const_set(:TOPDIR, nil)
    mod.const_set(:DESTDIR, '')
    def mod.ruby
      'ruby'
    end

    def mod.expand(val, _config = nil)
      val
    end
    Object.const_set(:RbConfig, mod)
    System.puts '[platform_compat] rbconfig fallback installed' if defined?(System)
    nil
  end
end

module Kernel
  # Network stdlib. When the host enables network access these
  # requires resolve for real: on modern Rubies against the bundled
  # pure-Ruby stdlib + static socket/openssl exts, on 1.8/1.9 partly
  # via the Net::HTTP facade in `net_http_compat.rb`. A require that
  # still fails (a stdlib piece we didn't ship) is absorbed exactly
  # like in offline mode - games historically survive the resulting
  # NameError through their own rescues, and a shipping gap must not
  # crash a game that used to boot - but it is logged loudly so the
  # gap can be reported and closed.
  #
  # Match by exact path or by prefix so `net/http`, `net/https`,
  # `net/http/status`, etc. are all absorbed by a single `net/`
  # entry.
  NETWORK_STDLIB_PATHS = [
    'socket', 'resolv', 'resolv-replace',
    'openssl', 'digest',
    'uri', 'ipaddr', 'open-uri',
    'net', 'net/'
  ].freeze

  # Gems that desktop games bundle but that can't exist here (no
  # user gems, no dlopen). Genuinely absent regardless of the
  # network toggle, so always absorbed.
  MISSING_GEM_PATHS = %w[
    httparty rest-client rest_client
    discord discord-rpc discordrb
    poke-api-v2 pokeapi
    websocket websocket-client
    json-jwt jwt
  ].freeze

  # Back-compat: older patches/scripts referenced the combined list.
  NETWORK_REQUIRE_PATHS = (NETWORK_STDLIB_PATHS + MISSING_GEM_PATHS).freeze

  orig_require = instance_method(:require)

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  # -- the interceptor enumerates the historical absorb rules in one place
  define_method(:require) do |path|
    begin
      orig_require.bind(self).call(path)
    rescue LoadError => e
      str = path.to_s

      # rbconfig gets a real fallback module (see
      # MKXPRbConfigFallback above), not a swallow: callers read
      # RbConfig::CONFIG values right after requiring.
      if ['rbconfig', 'rbconfig.rb'].include?(str)
        MKXPRbConfigFallback.install
        feature = 'rbconfig.rb'
        $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature)
        next true
      end

      match = lambda do |list|
        list.any? do |entry|
          entry.end_with?('/') ? str.start_with?(entry) : str == entry
        end
      end

      matched_stdlib = match.call(NETWORK_STDLIB_PATHS)
      raise e unless matched_stdlib || match.call(MISSING_GEM_PATHS)

      # With networking enabled these requires should have resolved
      # against the bundled stdlib/shims. Absorbing one means we
      # failed to ship something the game wants. Keep the game alive
      # (as in offline mode) but say so loudly.
      if matched_stdlib &&
         defined?(System) && System.respond_to?(:network_enabled?) &&
         System.network_enabled? && defined?(MKXP) && MKXP.respond_to?(:puts)
        MKXP.puts("[platform_compat] network stdlib require '#{str}' failed " \
                  "despite networking being enabled: #{e.message}")
      end

      # Mark as loaded so future `require` calls short-circuit.
      feature = str.end_with?('.rb') ? str : "#{str}.rb"
      $LOADED_FEATURES << feature unless $LOADED_FEATURES.include?(feature)
      false
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end

# --- Socket class stubs ---
# Removed. Pokemon Essentials forks (Insurgence, Reborn) ship
# their own Sockets script that defines TCPSocket / UDPSocket /
# BasicSocket with their own class hierarchy.
#
# A stub here never survives those scripts, and the way it fails
# depends on the Ruby version. On 1.9 and 3.1 the game's definition
# raises "superclass mismatch", and the script loop skips the rest
# of that section. On 1.8 nothing raises at all, because
# ruby18/rgss-superclass-override.patch restores the RGSS1 rule
# that the last definition wins. The stub is then replaced in
# silence. A stub helps in neither case.
#
# Games that need network stubs must ship their own. With
# networking enabled the real socket classes come from the
# statically-linked ext instead (gated in extinit so offline mode
# still matches this old behavior). Games that call Winsock
# through Win32API reach the network through Win32API_Impl::Ws2_32
# in win32_wrap.rb.

# --- Eager static extension load ---
# The socket and openssl extensions are statically linked into the
# Ruby 3.1 VM. They initialize lazily, on the first `require`. Some
# games replace `Kernel#require` with a loader that searches the load
# path for plain .rb files and evals them (Rejuvenation's
# ScriptLoader does this). Such a loader cannot start a static
# extension: `require 'socket.so'` finds no file and returns false.
# The stdlib wrapper then evals into hollow classes, and the C-only
# constants (IPSocket, the OpenSSL internals) never exist. The first
# stdlib file that touches one crashes. Example: ipaddr.rb sees no
# Socket::AF_INET6, takes its no-IPv6 branch, and its
# `class << IPSocket` block raises a NameError inside the game's
# update flow.
#
# Load both extensions here, through the real `require`, before any
# game code runs. The real `require` records the absolute stdlib
# paths in $LOADED_FEATURES. Replacement loaders honor that list, so
# they skip these files and the real classes stay in place. The
# eager load does not conflict with the stub-removal note above: the
# 1.8/1.9 VMs do not link the extensions, and the version gate skips
# them, so no class appears there. The gate reads System.ruby_version
# (the C API version), not RUBY_VERSION, because the syntax-transform
# layer can mimic an old RUBY_VERSION on the 3.1 VM. When networking
# is off, the airplane-mode section below still patches the connect
# surface.
if defined?(System) && System.respond_to?(:ruby_version) &&
   System.ruby_version.to_f >= 3.1
  begin
    require 'socket'
    require 'openssl'
  rescue StandardError
    nil
  end
end

# --- TLS trust store protection ---
# Desktop-targeting games routinely do
#   ENV['SSL_CERT_FILE'] = 'cacert.pem'
# pointing at a bundle shipped next to Game.exe (Rejuvenation's
# ScriptLoader does exactly this). The host already exports a
# working SSL_CERT_FILE for Ruby's openssl. Letting a game point it
# at a file that doesn't exist in the iOS import silently breaks
# every TLS handshake with "unable to get local issuer
# certificate". Honor the game's assignment when the file is really
# there (game-relative paths resolve against the game dir, our
# cwd), otherwise keep the host trust store.
class << ENV
  unless method_defined?(:__mkxp_orig_env_set)
    alias __mkxp_orig_env_set []=

    def []=(key, value)
      if %w[SSL_CERT_FILE SSL_CERT_DIR].include?(key.to_s) &&
         value && !File.exist?(value.to_s)
        if defined?(MKXP) && MKXP.respond_to?(:puts)
          MKXP.puts("[platform_compat] ignoring ENV['#{key}'] = " \
                    "#{value.inspect}: file missing; keeping host trust store")
        end
        return
      end
      __mkxp_orig_env_set(key, value)
    end

    alias store []=
  end
end

# --- Airplane-mode socket blocking ---
# With network access toggled off the game must see the equivalent
# of airplane mode: libraries load, classes exist, connections fail.
# The native HTTP client refuses on its own, but Ruby 3.1's real
# socket classes are statically compiled in and would happily reach
# the network. Patch the connection-making surface to raise
# ENETDOWN - the exact errno airplane mode produces - so raw-socket
# code takes the same rescue paths it takes on a device with no
# connectivity. Local binds/listens are left alone (they work in
# airplane mode too). On the 1.8/1.9 VMs the socket classes aren't
# registered while offline, so these guards simply never match.
network_off = defined?(System) &&
              System.respond_to?(:network_enabled?) &&
              !System.network_enabled?
if network_off
  # The eager static extension load above already initialized the
  # socket classes on the VMs that carry them. On the 1.8/1.9 VMs
  # the classes stay absent and the guards below are no-ops.
  if defined?(TCPSocket)
    class << TCPSocket
      def open(*_args)
        raise Errno::ENETDOWN
      end
      alias new open
    end
  end

  if defined?(Socket)
    class Socket
      def connect(*_args)
        raise Errno::ENETDOWN
      end

      def connect_nonblock(*_args)
        raise Errno::ENETDOWN
      end
    end

    class << Socket
      def tcp(*_args)
        raise Errno::ENETDOWN
      end
    end
  end

  if defined?(UDPSocket)
    class UDPSocket
      def send(*_args)
        raise Errno::ENETDOWN
      end

      def connect(*_args)
        raise Errno::ENETDOWN
      end
    end
  end

  # Datagram and DNS surfaces that skip `connect`. A bare
  # `Socket.new(:INET, :DGRAM)` can emit via `send`/`sendmsg` with
  # an explicit destination, and resolver calls reach the network
  # on their own - all of it must go dark with the toggle too.
  # `BasicSocket#send` stays usable for connected sockets (two
  # args, no destination): those already got ENETDOWN at connect.
  if defined?(BasicSocket)
    class BasicSocket
      # Alias, never `super`: a replaced #send falling through to
      # the superclass lands on Object#send - Ruby MESSAGE
      # dispatch - which would treat the payload as a method name.
      alias _mkxp_orig_socket_send send

      def send(*args)
        raise Errno::ENETDOWN if args.length >= 3

        _mkxp_orig_socket_send(*args)
      end

      def sendmsg(*_args)
        raise Errno::ENETDOWN
      end

      def sendmsg_nonblock(*_args)
        raise Errno::ENETDOWN
      end
    end
  end

  if defined?(Socket)
    class << Socket
      def udp_server_sockets(*_args)
        raise Errno::ENETDOWN
      end

      def getaddrinfo(*_args)
        raise Errno::ENETDOWN
      end
    end
  end

  if defined?(Addrinfo)
    class << Addrinfo
      def getaddrinfo(*_args)
        raise Errno::ENETDOWN
      end
    end
  end

  if defined?(IPSocket)
    class << IPSocket
      def getaddress(*_args)
        raise Errno::ENETDOWN
      end
    end
  end
end

# --- Portable-save migration arming ---
# The sweep is access-driven (see the portable-save migration
# section in MKXPSaveFS): the wrappers above watch for the game to
# touch portable "Save Data" content, and the first qualifying
# access runs one sweep per boot through the _mkxp_orig_* aliases.
# No boot-time gate: launcher-identity portable modes
# (Rejuvenation's RTP.isPortable -> mobile? -> $empo) are invisible
# before game scripts run, and a $joiplay-keyed boot sweep would
# move root saves for games that never read the portable dir.
MKXPSaveFS.capture_game_root!
MKXPSaveFS.arm_portable_sweep!
