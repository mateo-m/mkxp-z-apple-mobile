# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Repairs broken sound names before a game writes a save, and tells the
# host when a game loads a save.
#
# Before #81 the Ruby 1.8 sweep freed the name of the sound clone that
# Pokemon Essentials keeps across a battle. The name then held a Float,
# an Array or another object, the game saved it, and the load crashed.
#
# The VM outlives a game, and each game loads this file again. The
# wrappers must go on only once, because platform_compat.rb wraps
# Marshal.dump again, and only once.
unless defined?(MKXPSaveRepair)
  module MKXPSaveRepair
    module_function

    # Essentials writes a save with one Marshal.dump for each part. The
    # repair runs once for each open file.
    def before_dump(port)
      return unless File === port # rubocop:disable Style/CaseEquality -- a BasicObject has no is_a?.
      return if port.instance_variable_get(:@mkxp_save_repaired)

      port.instance_variable_set(:@mkxp_save_repaired, true)
      repair_all(File.basename(port.path.to_s))
    rescue StandardError
      nil
    end

    # Reads @name, because games define the getter again.
    def repair_all(file_name)
      klass = audio_file_class
      return unless klass

      ObjectSpace.each_object(klass) do |audio|
        name = audio.instance_variable_get(:@name)
        next if name.nil? || name.is_a?(String) || audio.frozen?

        audio.instance_variable_set(:@name, '')
        report(:report_save_repaired, "#{file_name}: #{fault(audio, name)}")
      end
    end

    # audio_file_name_repair.rb calls this when the getter repairs a name.
    def repaired_on_read(audio, name)
      file_name = @last_save || 'unknown file'
      report(:report_save_repaired, "#{file_name}: #{fault(audio, name)} when the game read it")
    rescue StandardError
      nil
    end

    def fault(audio, name)
      "the @name of #{with_article(audio.class.name.to_s)} was #{with_article(name.class.name.to_s)}"
    end

    def with_article(name)
      name =~ /\A(?:[AEIOU]|RPG)/ ? "an #{name}" : "a #{name}"
    end

    def audio_file_class
      RPG::AudioFile if defined?(RPG::AudioFile) && RPG::AudioFile.is_a?(Class)
    end

    # A save holds the Game_System, alone or in the Hash or the Array of
    # the save. Pokemon Essentials reads the first parts of Game.rxdata at
    # start and on the title screen, so a file counts only when the game
    # reads it to the end.
    def after_load(source, value)
      return unless File === source # rubocop:disable Style/CaseEquality -- a BasicObject has no is_a?.
      return if source.instance_variable_get(:@mkxp_save_loaded)

      source.instance_variable_set(:@mkxp_game_system, true) if holds_game_system?(value)
      return unless source.instance_variable_get(:@mkxp_game_system) && source.eof?

      source.instance_variable_set(:@mkxp_save_loaded, true)
      loaded(source.path.to_s)
    rescue StandardError
      nil
    end

    # load_data reads the file in C, and gives Marshal.load a String.
    # windows_fs.rb defines load_data again for each game, so its
    # load_data calls this.
    def after_load_data(path, value)
      loaded(path.to_s) if holds_game_system?(value)
    rescue StandardError
      nil
    end

    def loaded(path)
      @last_save = File.basename(path)
      report(:report_save_load, @last_save)
    end

    def holds_game_system?(value)
      return false unless defined?(::Game_System) && ::Game_System.is_a?(Class)
      # rubocop:disable Style/CaseEquality -- a BasicObject has no is_a?.
      return true if ::Game_System === value

      list = if ::Hash === value
               value.values
             elsif ::Array === value
               value
             else
               []
             end
      list.any? { |item| ::Game_System === item }
      # rubocop:enable Style/CaseEquality
    end

    def report(name, detail)
      System.send(name, detail) if defined?(System) && System.respond_to?(name)
    end
  end

  class << Marshal
    alias _mkxp_repair_dump dump
    alias _mkxp_repair_load load

    def dump(obj, *args)
      MKXPSaveRepair.before_dump(args[0])
      _mkxp_repair_dump(obj, *args)
    end

    def load(source, *args)
      value = _mkxp_repair_load(source, *args)
      MKXPSaveRepair.after_load(source, value)
      value
    end
  end
end
