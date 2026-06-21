/*
 ** script-bootstrap.h
 **
 ** Engine preload/postload/cheat script orchestration extracted
 ** from binding-mri.cpp so load-order policy lives in one module.
 */

#ifndef MKXP_SCRIPT_BOOTSTRAP_H
#define MKXP_SCRIPT_BOOTSTRAP_H

struct Config;

namespace mkxp {
namespace ScriptBootstrap {

bool evalRubyString(void *string, void *filename, int *state);

void loadEnginePreloads();
void loadConfigPreloadScripts(const Config &conf);
void loadEnginePostloadsBeforeMain();
void loadCheatPostloadAndPoller();

} // namespace ScriptBootstrap
} // namespace mkxp

#endif
