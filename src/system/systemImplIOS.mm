// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#define AL_ALEXT_PROTOTYPES
#include <alc.h>
#include <alext.h>
#else
#import <AppKit/AppKit.h>
#endif
#import "system.h"
#import "app_bridge.h"

std::string systemImpl::getSystemLanguage() {
    @autoreleasepool {
        // Return the ISO 639-1 language code only ("en", "fr",
        // "ja"), NOT the full locale identifier ("en_US"). Game
        // scripts that branch on language (Insurgence's
        // `getRegion`, Reborn's localization shim, etc.) only care
        // about the language. Including the country code splits
        // "en_US" / "en_GB" / "en_AU" into different cohorts which
        // is rarely what those scripts want. NSLocale.languageCode
        // gives us the language code straight from the user's iOS
        // language preference (Settings > General > Language &
        // Region), with `preferredLanguages.firstObject` as a
        // fallback for the rare case where currentLocale's
        // languageCode is nil.
        NSString *lang = NSLocale.currentLocale.languageCode;
        if (lang.length == 0) {
            lang = NSLocale.preferredLanguages.firstObject;
            // preferredLanguages entries can include a region tag
            // (e.g. "en-US" or "zh-Hans-CN") - take only the first
            // component to keep the contract identical.
            if (lang.length != 0) {
                NSRange dash = [lang rangeOfString:@"-"];
                if (dash.location != NSNotFound) {
                    lang = [lang substringToIndex:dash.location];
                }
            }
        }
        return std::string(lang.length != 0 ? lang.UTF8String : "en");
    }
}

std::string systemImpl::getUserName() {
    @autoreleasepool {
        return std::string("Player");
    }
}

static float displayScale() {
#if TARGET_OS_IPHONE
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            return ws.traitCollection.displayScale;
        }
    }
    return 2.0f;
#else
    return NSScreen.mainScreen ? NSScreen.mainScreen.backingScaleFactor : 2.0f;
#endif
}

int systemImpl::getScalingFactor() {
    return (int)displayScale();
}

bool systemImpl::isWine() {
    return false;
}

bool systemImpl::isRosetta() {
    return false;
}

systemImpl::WineHostType systemImpl::getRealHostType() {
    return WineHostType::Mac;
}

#if TARGET_OS_IPHONE
// UIKit updates applicationState and posts its notifications only when
// the main run loop runs. UIKit can get a move to the background seconds
// after the system moved the app.
static void handleQueuedEvents() {
    while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true) == kCFRunLoopRunHandledSource) {
    }
}

// iOS refuses the session while the app is in the background or an
// interruption is on.
static bool iosAllowsSound() {
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
           [AVAudioSession.sharedInstance setActive:YES error:nil];
}

static unsigned soundEvents;
static ALCdevice *interruptibleDevice;
static bool devicePaused;

// OpenAL Soft on iOS does not start its output again after an
// interruption. A start that iOS refuses disconnects the device, and a
// disconnected device cannot resume, so the resume waits until iOS
// allows sound.
static void resumeDevice() {
    if (!devicePaused || !iosAllowsSound())
        return;
    devicePaused = false;
    alcDeviceResumeSOFT(interruptibleDevice);
}

unsigned systemImpl::soundEventCount() {
    static bool watching;
    if (!watching) {
        watching = true;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        [center addObserverForName:UIApplicationWillResignActiveNotification
                            object:nil
                             queue:main
                        usingBlock:^(NSNotification *) {
                          soundEvents++;
                        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:main
                        usingBlock:^(NSNotification *) {
                          soundEvents++;
                          resumeDevice();
                        }];
        // iOS can send a start with no end, so the end is not the only
        // event that resumes the device.
        [center addObserverForName:AVAudioSessionInterruptionNotification
                            object:nil
                             queue:main
                        usingBlock:^(NSNotification *note) {
                          soundEvents++;
                          if ([note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] !=
                              AVAudioSessionInterruptionTypeBegan) {
                              resumeDevice();
                          } else if (interruptibleDevice && !devicePaused) {
                              alcDevicePauseSOFT(interruptibleDevice);
                              devicePaused = true;
                          }
                        }];
    }
    return soundEvents;
}

bool systemImpl::waitForSoundEvent(unsigned since) {
    handleQueuedEvents();
    if (soundEvents == since && iosAllowsSound())
        return false;
    // A timeout this long never ends. The run returns after each source
    // that it handles, and each notification comes from one.
    while (soundEvents == since)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, true);
    return true;
}

void systemImpl::pauseDuringInterruptions(ALCdevice *device) {
    interruptibleDevice = device;
    devicePaused = false;
}
#endif

void openSettingsWindow() {
    // No settings window on iOS
}

bool isMetalSupported() {
    return true;
}

std::string getPlistValue(const char *key) {
    @autoreleasepool {
        NSString *hash = [[NSBundle mainBundle] objectForInfoDictionaryKey:@(key)];
        if (hash != nil) {
            return std::string(hash.UTF8String);
        }
        return "";
    }
}

float mkxp_getScreenScale(void) {
    // Screen scale is a device constant (e.g. 3.0 on iPhone Pro) that
    // never changes at runtime.  Cache it to avoid dispatch_sync to the
    // main queue on every resize, that call can stall the RGSS thread
    // during rapid rotation while UIKit is processing layout animations.
    static float cachedScale = 0.0f;
    if (cachedScale > 0.0f)
        return cachedScale;

    __block float scale = 2.0f;

    void (^queryBlock)(void) = ^{
        scale = displayScale();
    };

    if ([NSThread isMainThread]) {
        queryBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), queryBlock);
    }

    cachedScale = scale;
    return scale;
}
