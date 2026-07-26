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
/* Multi-Ruby dispatch, per-session instance edition.
 *
 * The host's `mkxp_setActiveRubyVersion()` selects which Ruby
 * interpreter + matching binding code runs for the active game.
 * Each Ruby version's binding + libruby is a symbol-islanded unit
 * (see ios/Dependencies/multiruby/wrapper.cpp + the make targets in
 * ios/Dependencies/common.make) whose single export,
 * `_mkxp_get_script_binding_NN()`, returns that version's
 * `ScriptBinding` vtable.
 *
 * Session lifecycle moved into src/ruby_instance.cpp: main.cpp's
 * RGSS thread acquires a fresh instance of the right island per
 * session (dlopen'd RubyIsland<NN> dylib when shipped, the
 * statically-linked merged.o as single-shot fallback) and retires it
 * at session end. This accessor serves mid-session dispatch only -
 * terminate/reset calls from sharedstate.cpp / graphics.cpp between
 * acquire and retire. Version selection, stub fallback (a build
 * whose SDK lacks some island gets a nullptr-returning stub entry
 * from the project.yml pre-build script), and freshness tracking all
 * live in the instance manager. */
#include "app_bridge.h"
#include "ruby_instance.h"

inline ScriptBinding *getActiveScriptBinding(void) {
    return mkxpi_currentScriptBinding();
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
