#import <Foundation/Foundation.h>

#include <SDL.h>
#include <SDL_main.h>
#include <SDL_system.h>

#include "app_bridge.h"

extern "C" int SDL_main(int argc, char *argv[]);

extern "C" int mkxp_run_app(int argc, char **argv) {
    @autoreleasepool {
        // SDLUIKitDelegate does this before it calls SDL_main
        // (SDL_uikitappdelegate.m:460). Nothing else sets the working
        // directory, and getDefaultGameRoot reads it.
        [NSFileManager.defaultManager
            changeCurrentDirectoryPath:NSBundle.mainBundle.resourcePath];
    }

    // SDL_Init fails without this (SDL.c:172). The delegate that calls
    // it does not run when a launcher owns UIApplicationMain.
    SDL_SetMainReady();

    // Makes SDL pump the UIKit run loop from inside SDL_PumpEvents and
    // start its lifecycle observers (SDL_uikitevents.m:45-63). Without
    // it the engine holds the main thread and the launcher stops
    // drawing.
    SDL_iPhoneSetEventPump(SDL_TRUE);
    int status = SDL_main(argc, argv);
    SDL_iPhoneSetEventPump(SDL_FALSE);
    return status;
}
