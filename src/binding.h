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

/* VTable defined in the binding source */
extern ScriptBinding *scriptBinding;

#ifdef MKXPZ_BUILD_XCODE
/* Multi-Ruby Phase D dispatch.
 *
 * The host's `mkxp_setRubyVersion()` selects which Ruby
 * interpreter + matching binding code runs for the active game.
 * Each Ruby version's binding+libruby is bundled in a per-version
 * merged .o (see ios/Dependencies/multiruby/wrapper.cpp + the
 * `mkxpNN-merged` make targets in ios/Dependencies/common.make).
 * Each merged .o exports exactly one symbol —
 * `_mkxp_get_script_binding_NN()` — returning a pointer to that
 * version's `ScriptBinding` vtable.
 *
 * `getActiveScriptBinding()` is the single dispatch point used by
 * main.cpp, sharedstate.cpp, and graphics.cpp wherever they used
 * to dereference the global `scriptBinding`. The default (UNSET
 * or 31) keeps using the legacy directly-linked Ruby 3.1 binding
 * via the global `scriptBinding` pointer; other versions go
 * through their merged.o entry point.
 *
 * NB: this header is included by both the Xcode-compiled engine
 * code (sharedstate.cpp, graphics.cpp, main.cpp) AND the per-Ruby
 * binding compile (binding-mri.cpp, etc., for the merged.o). The
 * inline implementation below works in both contexts.
 */
#include "app_bridge.h"

extern "C" ScriptBinding *mkxp_get_script_binding_30(void);
/* 1.8 / 1.9 / 3.1 entry points reserved for upcoming
 * mkxp{18,19,31}-merged.o builds. Adding the corresponding
 * `extern "C"` declarations + cases here is the wiring step
 * once those merged .o files exist. */

inline ScriptBinding *getActiveScriptBinding(void) {
    switch (mkxp_getActiveRubyVersion()) {
    case MKXP_RUBY_30: return mkxp_get_script_binding_30();
    /* MKXP_RUBY_18/19/31 fall through to legacy default for now;
     * extend as their merged .o files come online. */
    default:           return scriptBinding;
    }
}
#else
inline ScriptBinding *getActiveScriptBinding(void) {
    return scriptBinding;
}
#endif

#endif // BINDING_H
