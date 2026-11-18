# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Repairs the sounds in saves from before #81. On Ruby 1.8 the engine
# freed the name of the sound clone that Pokemon Essentials keeps
# across a battle. The slot then held a Float, an Array, a Color or
# another object, and the game saved it. On load,
# `File.basename(bgs.name)` raises TypeError. An empty name is the RGSS
# value for "no sound", so the repair sets it, and the next save keeps
# the repaired name.
#
# It runs after the game's scripts, because games define
# RPG::AudioFile#name again (GS Vitro does in RGSS2Compatibility).

if defined?(RPG::AudioFile) && !RPG::AudioFile.method_defined?(:empo_unrepaired_name)
  module RPG
    class AudioFile
      alias empo_unrepaired_name name

      def name
        name = empo_unrepaired_name
        return name if name.nil? || name.is_a?(String)

        @name = ''
      end
    end
  end
end
