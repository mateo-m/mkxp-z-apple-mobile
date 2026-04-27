/*
** binding.h
**
** This file is part of mkxp.
**
** Copyright (C) 2013 - 2021 Amaryllis Kulla <ancurio@mapleshrine.eu>
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

#ifndef BINDING_H
#define BINDING_H

struct ScriptBinding
{
	/* Starts the part where the binding takes over,
	 * loading the compressed scripts and executing them.
	 * This function returns as soon as the scripts finish
	 * execution or an error is encountered */
	void (*execute) (void);

	/* Instructs the binding
	 * to immediately terminate script execution. This
	 * function will perform a longjmp instead of returning,
	 * so be careful about any variables with local storage */
	void (*terminate) (void);

	/* Instructs the binding to issue a game reset.
	 * Same conditions as for terminate apply */
	void (*reset) (void);
};

/* VTable defined in the binding source. Currently exposed by the
 * legacy direct-link path (binding/*.cpp compiled by Xcode +
 * libruby.3.1 linked) which serves as the default Ruby 3.1 binding.
 * Once 1.8 + 1.9 native builds land and the legacy path is
 * dropped, this `extern` goes away — every binding lives inside a
 * merged .o with its own private `scriptBinding`. */
extern ScriptBinding *scriptBinding;

#ifdef MKXPZ_BUILD_XCODE
/* Multi-Ruby Phase D dispatch.
 *
 * The host's `mkxp_setActiveRubyVersion()` selects which Ruby
 * interpreter + matching binding code runs for the active game.
 * Each Ruby version's binding+libruby is bundled in a per-version
 * merged .o (see ios/Dependencies/multiruby/wrapper.cpp + the
 * `mkxpNN-merged` make targets in ios/Dependencies/common.make).
 * Each merged .o exports exactly one symbol —
 * `_mkxp_get_script_binding_NN()` — returning a pointer to that
 * version's `ScriptBinding` vtable.
 *
 * Default fallback: the legacy global `scriptBinding` (Ruby 3.1
 * via the direct-link path, including syntax-transform). PE
 * fan-games rely on this until the 1.8/1.9 native builds land.
 *
 * NB: this header is included by both the Xcode-compiled engine
 * code (sharedstate.cpp, graphics.cpp, main.cpp) AND the per-Ruby
 * binding compile (binding-mri.cpp, etc., for the merged.o). The
 * inline implementation below works in both contexts.
 */
#include "app_bridge.h"

/* Per-version entry points. Each is provided either by the real
 * mkxpNN-merged.o (returning that version's hidden ScriptBinding*)
 * or by an auto-generated stub from project.yml's pre-build phase
 * (returning nullptr) when the merged .o hasn't been built yet
 * for the active SDK. The runtime check below falls back to the
 * legacy `scriptBinding` when nullptr. */
extern "C" ScriptBinding *mkxp_get_script_binding_30(void);
extern "C" ScriptBinding *mkxp_get_script_binding_31(void);
/* 1.8 / 1.9 entry points reserved for upcoming
 * mkxp{18,19}-merged.o builds. */

inline ScriptBinding *getActiveScriptBinding(void) {
    ScriptBinding *sb = nullptr;
    switch (mkxp_getActiveRubyVersion()) {
    case MKXP_RUBY_30: sb = mkxp_get_script_binding_30(); break;
    case MKXP_RUBY_31: sb = mkxp_get_script_binding_31(); break;
    /* MKXP_RUBY_18/19/UNSET fall through to legacy default. */
    default: break;
    }
    return sb ? sb : scriptBinding;
}
#else
inline ScriptBinding *getActiveScriptBinding(void) {
    return scriptBinding;
}
#endif

#endif // BINDING_H
