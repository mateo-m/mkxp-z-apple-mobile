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

#ifdef MKXPZ_BUILD_XCODE
/* Multi-Ruby Phase D dispatch.
 *
 * The host's `mkxp_setActiveRubyVersion()` selects which Ruby
 * interpreter + matching binding code runs for the active game.
 * Each Ruby version's binding + libruby is bundled in a
 * per-version merged .o (see ios/Dependencies/multiruby/wrapper.cpp +
 * the `mkxpNN-merged` make targets in ios/Dependencies/common.make).
 * Each merged .o exports exactly one symbol,
 * `_mkxp_get_script_binding_NN()`, returning a pointer to that
 * version's `ScriptBinding` vtable.
 *
 * Default fallback: 3.1, since the legacy path used Ruby 3.1 with
 * syntax-transform applied. UNSET / MKXP_RUBY_18 / MKXP_RUBY_19
 * also fall through to 3.1 today (1.8 / 1.9 native builds aren't
 * wired yet; see MULTI_RUBY_PLAN.md).
 *
 * The merged .o files might not exist on a given SDK build (e.g.
 * fresh device build that hasn't run `make mkxp-merged` for that
 * SDK). The pre-build script in project.yml stubs out missing
 * merged.o files with `mkxp_get_script_binding_NN()` returning
 * nullptr; the runtime check here detects that and falls through
 * to whichever binding does exist.
 */
#include "app_bridge.h"

extern "C" ScriptBinding *mkxp_get_script_binding_18(void);
extern "C" ScriptBinding *mkxp_get_script_binding_19(void);
extern "C" ScriptBinding *mkxp_get_script_binding_31(void);

inline ScriptBinding *getActiveScriptBinding(void) {
    ScriptBinding *sb = nullptr;
    switch (mkxp_getActiveRubyVersion()) {
    case MKXP_RUBY_18: sb = mkxp_get_script_binding_18(); break;
    case MKXP_RUBY_19: sb = mkxp_get_script_binding_19(); break;
    /* UNSET / MKXP_RUBY_30 (deprecated, routed to 3.1 + Legacy
     * compat) / MKXP_RUBY_31 / unknown → 3.1 (default modern). */
    default:           sb = mkxp_get_script_binding_31(); break;
    }
    /* Last-resort fallback if the chosen merged.o is a build-time
     * stub (returning nullptr because that SDK didn't ship it).
     * Order: prefer 3.1, then 1.9, then 1.8; newest available
     * wins so script-engine features stay maximal. */
    if (!sb) sb = mkxp_get_script_binding_31();
    if (!sb) sb = mkxp_get_script_binding_19();
    if (!sb) sb = mkxp_get_script_binding_18();
    return sb;
}
#else
/* Non-iOS build: the legacy global `scriptBinding` is set by
 * binding-mri.cpp's static initialiser, which is compiled directly
 * into the executable on desktop builds. */
extern ScriptBinding *scriptBinding;
inline ScriptBinding *getActiveScriptBinding(void) {
    return scriptBinding;
}
#endif

#endif // BINDING_H
