// Test host shim.
//
// The engine's own main() blocks in mkxp_waitForGamePath() until a
// host names a game folder. A launcher does that when a person taps a
// game. This host has no interface, so it answers straight away with
// the game folder it prepared.
//
// WARNING: do not set the bridge state from the constructor itself.
// The constructor runs before the C++ static initializers in
// app_bridge.cpp, so every value written there is destroyed when those
// statics are constructed. The constructor therefore only queues a
// block on the main queue. mkxp_waitForGamePath pumps the main run
// loop while it waits, so the block runs from inside that wait, long
// after static initialization.
//
// tools/build-test-host-ios.sh copies tests/engine into the bundle as
// "Game". The host copies that folder into Documents, because the app
// bundle is read only and the engine writes a path cache next to the
// game. The folder holds an mkxp.json with a customScript, so the
// engine runs the suite instead of a game.

#import <Foundation/Foundation.h>

#import "app_bridge.h"

// Copy the suite out of the read only bundle. Returns the writable
// copy, or the bundle folder if the copy fails.
static NSString *prepareGameFolder(NSString *source, NSString *documents) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *target = [documents stringByAppendingPathComponent:@"Game"];

    [fm removeItemAtPath:target error:nil];

    NSError *error = nil;
    if ([fm copyItemAtPath:source toPath:target error:&error])
        return target;

    NSLog(@"[host] could not copy the game folder: %@", error);
    return source;
}

static void engineTestHostStart(void) {
    @autoreleasepool {
        NSString *resources = NSBundle.mainBundle.resourcePath;
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

        NSString *game = prepareGameFolder(
            [resources stringByAppendingPathComponent:@"Game"], documents);

        mkxp_setLauncherIdentity("mkxp-z engine tests");
        mkxp_setUserDataDirectory(documents.fileSystemRepresentation);
        mkxp_setSharedFontsDirectory(
            [resources stringByAppendingPathComponent:@"Assets.bundle/Fonts"]
                .fileSystemRepresentation);
        mkxp_setCABundlePath(
            [resources stringByAppendingPathComponent:@"Assets.bundle/cacert.pem"]
                .fileSystemRepresentation);

        // The engine reads mkxp.json from the managed config directory
        // when a host sets one. Point it at the game folder so the
        // read never depends on the working directory.
        mkxp_setManagedConfigDir(game.fileSystemRepresentation);

        NSLog(@"[host] game folder: %@", game);
        mkxp_setGamePath(game.fileSystemRepresentation);
    }
}

__attribute__((constructor)) static void engineTestHostInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        engineTestHostStart();
    });
}
