#ifndef IOS_FATAL_REPORT_H
#define IOS_FATAL_REPORT_H

#ifdef __cplusplus
extern "C" {
#endif

/* Wrap the RGSS thread entry so ObjC/C++ failures surface in the UI
 * instead of freezing with a black screen. */
int mkxp_guardedRgssThreadMain(void *userdata, int (*body)(void *));

/* Record RGSS-thread failure state and nudge the event loop to unwind.
 * Implemented in main.cpp where RGSSThreadData is visible. */
void mkxp_noteRgssThreadFailure(void *userdata, const char *message);

/* Tear down SharedState after a guarded-thread failure path. */
void mkxp_rgssThreadShutdownAfterFailure(void *userdata);

#ifdef __cplusplus
}
#endif

#endif /* IOS_FATAL_REPORT_H */
