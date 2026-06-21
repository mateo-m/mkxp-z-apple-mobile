#import <Foundation/Foundation.h>

#include "ios_fatal_report.h"
#include "app_bridge.h"
#include "util/exception.h"

#include <cstdio>
#include <atomic>
#include <string>

extern "C" void mkxp_noteRgssThreadFailure(void *userdata, const char *message);
extern "C" void mkxp_rgssThreadShutdownAfterFailure(void *userdata);

static void mkxp_uncaughtObjcExceptionHandler(NSException *exception) {
    if (!exception)
        return;

    char buffer[1024];
    const char *name = exception.name.UTF8String ?: "NSException";
    const char *reason = exception.reason.UTF8String ?: "";
    std::snprintf(buffer, sizeof(buffer), "Native error (%s): %s", name, reason);
    mkxp_debugLog("FATAL", "ios_fatal_report.mm", buffer);
    mkxp_setErrorMessage(buffer);
}

void mkxp_installFatalErrorHandlers(void) {
    static std::atomic<bool> installed{false};
    if (installed.exchange(true))
        return;

    NSSetUncaughtExceptionHandler(mkxp_uncaughtObjcExceptionHandler);
}

int mkxp_guardedRgssThreadMain(void *userdata, int (*body)(void *)) {
    if (!body)
        return 0;

    try {
        @autoreleasepool {
            @try {
                return body(userdata);
            } @catch (NSException *exception) {
                char buffer[1024];
                const char *name = exception.name.UTF8String ?: "NSException";
                const char *reason = exception.reason.UTF8String ?: "";
                std::snprintf(buffer, sizeof(buffer), "Native error (%s): %s",
                              name, reason);
                mkxp_noteRgssThreadFailure(userdata, buffer);
                mkxp_rgssThreadShutdownAfterFailure(userdata);
                return 0;
            }
        }
    } catch (const Exception &exc) {
        mkxp_noteRgssThreadFailure(userdata, exc.msg.c_str());
        mkxp_rgssThreadShutdownAfterFailure(userdata);
        return 0;
    } catch (const std::exception &exc) {
        std::string message = std::string("Engine error: ") + exc.what();
        mkxp_noteRgssThreadFailure(userdata, message.c_str());
        mkxp_rgssThreadShutdownAfterFailure(userdata);
        return 0;
    } catch (...) {
        mkxp_noteRgssThreadFailure(userdata,
                                   "An unexpected engine error occurred.");
        mkxp_rgssThreadShutdownAfterFailure(userdata);
        return 0;
    }
}
