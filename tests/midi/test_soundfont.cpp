// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

/*
** Tests for the SoundFont choice in src/audio/sharedmidistate.h, run
** against the static FluidSynth that the engine links.
**
** The config of a session dies when the session ends, so the MIDI
** state must keep its own copy of the SoundFont path.
*/

#include "harness.h"

#include "audio/sharedmidistate.h"

#include <cstdlib>
#include <string>

Config::Config() {}

namespace {

std::string bundledSoundFont;

std::string soundFontDir()
{
    const char *dir = std::getenv("MIDI_TEST_SOUNDFONTS");
    return dir ? dir : "";
}

std::string sf2Path()
{
    return soundFontDir() + "/VintageDreamsWaves-v2.sf2";
}

std::string dlsPath()
{
    return soundFontDir() + "/VintageDreamsWaves-v2.dls";
}

/* FluidSynth's default loader names a SoundFont after its file. */
std::string loadedSoundFont(fluid_synth_t *synth)
{
    fluid_sfont_t *sfont = fluid_synth_get_sfont(synth, 0);
    return sfont ? fluid_sfont_get_name(sfont) : "";
}

/* Plays one note and returns the peak sample. Silence means that no
 * instrument answered the note. */
int peakOfOneNote(fluid_synth_t *synth)
{
    short buf[2 * 4410];
    fluid_synth_noteon(synth, 0, 60, 127);
    fluid_synth_write_s16(synth, 4410, buf, 0, 2, buf, 1, 2);
    fluid_synth_noteoff(synth, 0, 60);

    int peak = 0;
    for (short s : buf)
        peak = std::max(peak, std::abs(int(s)));
    return peak;
}

void initFrom(SharedMidiState &state, const std::string &soundFont)
{
    /* The config dies before the state uses the path, as a session's
     * config does when the session ends. */
    Config *conf = new Config;
    conf->midi.soundFont = soundFont;
    conf->midi.chorus = false;
    conf->midi.reverb = false;
    state.initIfNeeded(*conf);
    delete conf;
}

} // namespace

std::string filesystemImpl::getPathForAsset(const char *baseName, const char *ext)
{
    if (bundledSoundFont.empty())
        throw Exception(Exception::NoFileError, "%s.%s", baseName, ext);
    return bundledSoundFont;
}

TEST(state_keeps_its_soundfont_after_the_config_dies)
{
    std::string first;
    {
        SharedMidiState session1;
        initFrom(session1, sf2Path());
        fluid_synth_t *synth = session1.allocateSynth();
        first = loadedSoundFont(synth);
        session1.releaseSynth(synth);
    }

    SharedMidiState session2;
    initFrom(session2, dlsPath());
    fluid_synth_t *synth = session2.allocateSynth();
    CHECK_EQ(sf2Path(), first);
    CHECK_EQ(dlsPath(), loadedSoundFont(synth));
    session2.releaseSynth(synth);
}

TEST(every_pooled_synth_loads_the_soundfont)
{
    SharedMidiState state;
    initFrom(state, sf2Path());

    fluid_synth_t *a = state.allocateSynth();
    fluid_synth_t *b = state.allocateSynth();
    fluid_synth_t *c = state.allocateSynth();
    CHECK_EQ(sf2Path(), loadedSoundFont(a));
    CHECK_EQ(sf2Path(), loadedSoundFont(b));
    CHECK_EQ(sf2Path(), loadedSoundFont(c));
    state.releaseSynth(a);
    state.releaseSynth(b);
    state.releaseSynth(c);
}

TEST(empty_setting_uses_the_bundled_soundfont)
{
    bundledSoundFont = sf2Path();
    SharedMidiState state;
    initFrom(state, "");
    bundledSoundFont.clear();

    fluid_synth_t *synth = state.allocateSynth();
    CHECK_EQ(sf2Path(), loadedSoundFont(synth));
    state.releaseSynth(synth);
}

TEST(game_setting_wins_over_the_bundled_soundfont)
{
    bundledSoundFont = sf2Path();
    SharedMidiState state;
    initFrom(state, dlsPath());
    bundledSoundFont.clear();

    fluid_synth_t *synth = state.allocateSynth();
    CHECK_EQ(dlsPath(), loadedSoundFont(synth));
    state.releaseSynth(synth);
}

TEST(broken_game_soundfont_falls_back_to_the_bundled_soundfont)
{
    bundledSoundFont = sf2Path();
    SharedMidiState state;
    initFrom(state, soundFontDir() + "/missing.sf2");
    bundledSoundFont.clear();

    fluid_synth_t *a = state.allocateSynth();
    fluid_synth_t *b = state.allocateSynth();
    CHECK_EQ(sf2Path(), loadedSoundFont(a));
    CHECK_EQ(sf2Path(), loadedSoundFont(b));
    state.releaseSynth(a);
    state.releaseSynth(b);
}

TEST(broken_game_soundfont_and_no_bundled_soundfont_leave_the_synth_empty)
{
    SharedMidiState state;
    initFrom(state, soundFontDir() + "/missing.sf2");

    fluid_synth_t *synth = state.allocateSynth();
    CHECK_EQ(std::string(), loadedSoundFont(synth));
    state.releaseSynth(synth);
}

TEST(no_bundled_soundfont_leaves_the_synth_empty)
{
    SharedMidiState state;
    initFrom(state, "");

    fluid_synth_t *synth = state.allocateSynth();
    CHECK_EQ(std::string(), loadedSoundFont(synth));
    state.releaseSynth(synth);
}

TEST(dls_soundfont_plays_a_note)
{
    SharedMidiState state;
    initFrom(state, dlsPath());

    fluid_synth_t *synth = state.allocateSynth();
    CHECK(peakOfOneNote(synth) > 0);
    state.releaseSynth(synth);
}
