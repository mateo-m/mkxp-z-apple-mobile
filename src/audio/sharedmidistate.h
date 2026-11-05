/*
** sharedmidistate.h
**
** This file is part of mkxp.
**
** Copyright (C) 2014 - 2021 Amaryllis Kulla <ancurio@mapleshrine.eu>
**
** mkxp is free software: you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation, either version 2 of the License, or
** (at your option) any later version.
**
** mkxp is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with mkxp.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef SHAREDMIDISTATE_H
#define SHAREDMIDISTATE_H

#include "config.h"
#include "debugwriter.h"
#include "exception.h"
#include "filesystem/filesystemImpl.h"

#include <fluidsynth.h>

#include <assert.h>
#include <vector>
#include <string>

#define SYNTH_SAMPLERATE 44100

struct Synth
{
	fluid_synth_t *synth;
	bool inUse;
};

struct SharedMidiState
{
	bool inited;
	std::vector<Synth> synths;
	std::string soundFont;
	fluid_settings_t *flSettings;

	SharedMidiState()
	    : inited(false)
	{}

	~SharedMidiState()
	{
		if (!inited)
			return;

		for (size_t i = 0; i < synths.size(); ++i)
		{
			assert(!synths[i].inUse);
			delete_fluid_synth(synths[i].synth);
		}

		delete_fluid_settings(flSettings);
	}

	/* Each synth parses its own copy of the SoundFont's instrument
	 * tables, about 19 MB for GeneralUser GS. FluidSynth shares only
	 * the sample data between synths, so the pool starts with one. */
	void initIfNeeded(const Config &conf)
	{
		if (inited)
			return;

		inited = true;

		flSettings = new_fluid_settings();
		fluid_settings_setnum(flSettings, "synth.gain", 1.0f);
		fluid_settings_setnum(flSettings, "synth.sample-rate", SYNTH_SAMPLERATE);
		fluid_settings_setint(flSettings, "synth.chorus.active", conf.midi.chorus);
		fluid_settings_setint(flSettings, "synth.reverb.active", conf.midi.reverb);

		fluid_synth_t *syn = new_fluid_synth(flSettings);
		const std::string candidates[] = { conf.midi.soundFont, bundledSoundFont() };

		for (const std::string &path : candidates)
		{
			if (path.empty())
				continue;

			if (fluid_synth_sfload(syn, path.c_str(), 1) != FLUID_FAILED)
			{
				soundFont = path;
				break;
			}

			Debug() << "Failed to load the MIDI SoundFont" << path;
		}

		if (soundFont.empty())
			Debug() << "Warning: No MIDI SoundFont loaded, MIDI is silent";
		else
			Debug() << "MIDI SoundFont:" << soundFont;

		synths.push_back({ syn, false });
	}

	fluid_synth_t *allocateSynth()
	{
		assert(inited);

		for (Synth &s : synths)
		{
			if (s.inUse)
				continue;

			fluid_synth_system_reset(s.synth);
			s.inUse = true;

			return s.synth;
		}

		fluid_synth_t *syn = new_fluid_synth(flSettings);

		if (!soundFont.empty())
			fluid_synth_sfload(syn, soundFont.c_str(), 1);

		synths.push_back({ syn, true });

		return syn;
	}

	void releaseSynth(fluid_synth_t *synth)
	{
		size_t i;

		for (i = 0; i < synths.size(); ++i)
			if (synths[i].synth == synth)
				break;

		assert(i < synths.size());

		synths[i].inUse = false;
	}

private:
	static std::string bundledSoundFont()
	{
		try
		{
			return filesystemImpl::getPathForAsset("SoundFonts/GeneralUser-GS", "sf2");
		}
		catch (const Exception &)
		{
			return std::string();
		}
	}
};

#endif // SHAREDMIDISTATE_H
