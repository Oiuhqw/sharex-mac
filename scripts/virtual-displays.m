#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

// Private interfaces are confined to this CI helper. Chromium documents the ABI at
// https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@property(nonatomic, strong) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

typedef struct {
    unsigned int width;
    unsigned int height;
    unsigned int scale;
    int32_t x;
    int32_t y;
} DisplaySpec;

static volatile sig_atomic_t stopRequested = 0;

static void HandleSignal(int signalNumber) {
    (void)signalNumber;
    stopRequested = 1;
}

static void PumpRunLoop(void) {
    @autoreleasepool {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
        if (event) [NSApp sendEvent:event];
    }
}

static NSDictionary *FrameJSON(CGRect frame) {
    return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
             @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

static CGVirtualDisplay *CreateDisplay(DisplaySpec spec, unsigned int serialNumber) {
    CGVirtualDisplayDescriptor *descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    descriptor.vendorID = 505;
    descriptor.productID = 0x5358;
    descriptor.serialNum = serialNumber;
    descriptor.serialNumber = serialNumber;
    descriptor.name = [NSString stringWithFormat:@"ShareX E2E %ux", spec.scale];
    descriptor.maxPixelsWide = spec.width * spec.scale;
    descriptor.maxPixelsHigh = spec.height * spec.scale;
    descriptor.sizeInMillimeters = CGSizeMake(spec.width * 25.4 / 110, spec.height * 25.4 / 110);
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == kCGNullDirectDisplay) {
        NSLog(@"Cannot create the %ux virtual display. WindowServer may not support virtual displays in this session.", spec.scale);
        return nil;
    }
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:spec.width height:spec.height refreshRate:60];
    CGVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI = spec.scale == 2;
    settings.rotation = 0;
    settings.modes = @[mode];
    if (![display applySettings:settings]) {
        NSLog(@"Cannot apply the %ux virtual display mode.", spec.scale);
        return nil;
    }
    return display;
}

static BOOL ModeMatches(CGDisplayModeRef mode, DisplaySpec spec) {
    return mode && CGDisplayModeGetWidth(mode) == spec.width &&
        CGDisplayModeGetHeight(mode) == spec.height &&
        CGDisplayModeGetPixelWidth(mode) == spec.width * spec.scale &&
        CGDisplayModeGetPixelHeight(mode) == spec.height * spec.scale;
}

static NSDictionary *ModeJSON(CGDisplayModeRef mode) {
    if (!mode) return @{};
    return @{ @"id": @(CGDisplayModeGetIODisplayModeID(mode)),
              @"width": @(CGDisplayModeGetWidth(mode)), @"height": @(CGDisplayModeGetHeight(mode)),
              @"pixelWidth": @(CGDisplayModeGetPixelWidth(mode)), @"pixelHeight": @(CGDisplayModeGetPixelHeight(mode)),
              @"refreshRate": @(CGDisplayModeGetRefreshRate(mode)), @"flags": @(CGDisplayModeGetIOFlags(mode)),
              @"usableForDesktop": @(CGDisplayModeIsUsableForDesktopGUI(mode)) };
}

static void LogDisplayModes(CGDirectDisplayID displayID, CGDisplayModeRef current, CFArrayRef modes) {
    NSMutableArray<NSDictionary *> *available = [NSMutableArray array];
    if (modes) {
        for (CFIndex index = 0; index < CFArrayGetCount(modes); index++) {
            [available addObject:ModeJSON((CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index))];
        }
    }
    NSLog(@"Display %u mode state %@", displayID,
          @{ @"online": @(CGDisplayIsOnline(displayID)), @"active": @(CGDisplayIsActive(displayID)),
             @"inMirrorSet": @(CGDisplayIsInMirrorSet(displayID)), @"mirrorOf": @(CGDisplayMirrorsDisplay(displayID)),
             @"bounds": FrameJSON(CGDisplayBounds(displayID)), @"current": ModeJSON(current),
             @"enumerationAvailable": @(modes != NULL), @"available": available });
}

static BOOL SelectMode(CGDirectDisplayID displayID, DisplaySpec spec, NSTimeInterval deadline) {
    BOOL loggedInitialState = NO;
    while (!stopRequested) {
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
        BOOL matchesCurrent = ModeMatches(current, spec);
        CGDisplayModeRef selected = NULL;
        if (!matchesCurrent && modes) {
            for (CFIndex index = 0; index < CFArrayGetCount(modes); index++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index);
                if (ModeMatches(mode, spec)) {
                    selected = mode;
                    break;
                }
            }
        }
        BOOL timedOut = NSProcessInfo.processInfo.systemUptime >= deadline;
        BOOL finished = matchesCurrent || selected || timedOut;
        if (!loggedInitialState || finished) {
            LogDisplayModes(displayID, current, modes);
            loggedInitialState = YES;
        }
        if (finished) {
            BOOL success = matchesCurrent;
            if (matchesCurrent) {
                NSLog(@"Display %u already uses the requested %ux%u at %ux mode.",
                      displayID, spec.width, spec.height, spec.scale);
            } else if (selected) {
                CGError result = CGDisplaySetDisplayMode(displayID, selected, NULL);
                success = result == kCGErrorSuccess;
                NSLog(@"CGDisplaySetDisplayMode for display %u, mode %@, returned %d.",
                      displayID, ModeJSON(selected), result);
            } else {
                NSLog(@"No exact %ux%u at %ux mode for display %u before the 15-second setup deadline. No mode-setting call was made.",
                      spec.width, spec.height, spec.scale, displayID);
            }
            if (current) CGDisplayModeRelease(current);
            if (modes) CFRelease(modes);
            return success;
        }
        if (current) CGDisplayModeRelease(current);
        if (modes) CFRelease(modes);
        PumpRunLoop();
    }
    return NO;
}

static BOOL ArrangeDisplays(NSArray<CGVirtualDisplay *> *displays, const DisplaySpec *specs) {
    CGDisplayConfigRef configuration = NULL;
    CGError result = CGBeginDisplayConfiguration(&configuration);
    if (result == kCGErrorSuccess) {
        for (NSUInteger index = 0; index < displays.count; index++) {
            result = CGConfigureDisplayMirrorOfDisplay(configuration, displays[index].displayID, kCGNullDirectDisplay);
            if (result != kCGErrorSuccess) break;
            result = CGConfigureDisplayOrigin(configuration, displays[index].displayID, specs[index].x, specs[index].y);
            if (result != kCGErrorSuccess) break;
        }
        if (result == kCGErrorSuccess) {
            result = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
        } else {
            CGCancelDisplayConfiguration(configuration);
        }
    }
    if (result != kCGErrorSuccess) NSLog(@"Cannot arrange the virtual displays. Core Graphics error %d.", result);
    return result == kCGErrorSuccess;
}

static NSArray<NSDictionary *> *DisplaySnapshot(NSArray<CGVirtualDisplay *> *displays,
                                                const DisplaySpec *specs,
                                                NSString **failure) {
    CGDirectDisplayID online[32];
    uint32_t onlineCount = 0;
    CGError result = CGGetOnlineDisplayList(32, online, &onlineCount);
    if (result != kCGErrorSuccess) {
        *failure = [NSString stringWithFormat:@"CGGetOnlineDisplayList failed with error %d", result];
        return nil;
    }
    NSMutableArray<NSDictionary *> *snapshot = [NSMutableArray array];
    for (NSUInteger index = 0; index < displays.count; index++) {
        CGDirectDisplayID displayID = displays[index].displayID;
        BOOL foundOnline = NO;
        for (uint32_t item = 0; item < onlineCount; item++) {
            if (online[item] == displayID) foundOnline = YES;
        }
        NSScreen *screen = nil;
        for (NSScreen *candidate in NSScreen.screens) {
            if ([candidate.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) {
                screen = candidate;
                break;
            }
        }
        *failure = [NSString stringWithFormat:@"Display %u is not ready in WindowServer and NSScreen", displayID];
        if (!foundOnline || !screen || !CGDisplayIsActive(displayID) || CGDisplayIsInMirrorSet(displayID)) return nil;

        CGRect frame = CGDisplayBounds(displayID);
        DisplaySpec spec = specs[index];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        if (!mode) return nil;
        size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
        size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
        CGDisplayModeRelease(mode);
        *failure = [NSString stringWithFormat:@"Display %u has CG frame %@, Cocoa frame %@, pixels %zux%zu, scale %.2f",
                    displayID, NSStringFromRect(NSRectFromCGRect(frame)), NSStringFromRect(screen.frame),
                    pixelWidth, pixelHeight, screen.backingScaleFactor];
        if (!CGRectEqualToRect(frame, CGRectMake(spec.x, spec.y, spec.width, spec.height)) ||
            screen.frame.size.width != spec.width || screen.frame.size.height != spec.height ||
            pixelWidth != spec.width * spec.scale || pixelHeight != spec.height * spec.scale ||
            fabs(screen.backingScaleFactor - spec.scale) > 0.01 ||
            CGDisplayVendorNumber(displayID) != 505 || CGDisplayModelNumber(displayID) != 0x5358) return nil;

        [snapshot addObject:@{@"displayID": @(displayID), @"frame": FrameJSON(frame),
                              @"cocoaFrame": FrameJSON(NSRectToCGRect(screen.frame)),
                              @"pixels": @{@"width": @(pixelWidth), @"height": @(pixelHeight)},
                              @"scale": @(screen.backingScaleFactor),
                              @"vendorID": @(CGDisplayVendorNumber(displayID)),
                              @"productID": @(CGDisplayModelNumber(displayID)),
                              @"serialNumber": @(CGDisplaySerialNumber(displayID))}];
    }
    return snapshot;
}

static int RunDisplays(NSString *readyPath, NSString *layout, CGDirectDisplayID *displayIDs,
                       NSHashTable<CGVirtualDisplay *> *lifetimes) {
    for (NSString *className in @[@"CGVirtualDisplay", @"CGVirtualDisplayDescriptor", @"CGVirtualDisplayMode", @"CGVirtualDisplaySettings"]) {
        if (!NSClassFromString(className)) {
            NSLog(@"Virtual display API unavailable. Missing %@.", className);
            return 1;
        }
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    [NSApp finishLaunching];
    DisplaySpec specs[2] = {{1280, 800, 1, -2560, 0}, {1280, 800, 2, -1280, 0}};
    if ([layout isEqualToString:@"vertical-negative"]) {
        specs[0].x = -1280;
        specs[1].y = -800;
    }
    NSMutableArray<CGVirtualDisplay *> *displays = [NSMutableArray array];
    unsigned int firstSerial = arc4random_uniform(UINT32_MAX - 2) + 1;
    for (NSUInteger index = 0; index < 2; index++) {
        @autoreleasepool {
            CGVirtualDisplay *display = CreateDisplay(specs[index], firstSerial + (unsigned int)index);
            if (!display) return 1;
            displayIDs[index] = display.displayID;
            [lifetimes addObject:display];
            [displays addObject:display];
        }
    }

    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 15;
    while (!stopRequested && (!CGDisplayIsOnline(displays[0].displayID) || !CGDisplayIsOnline(displays[1].displayID))) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            NSLog(@"Virtual displays did not become online within 15 seconds.");
            return 1;
        }
        PumpRunLoop();
    }
    if (stopRequested) return 0;
    for (NSUInteger index = 0; index < displays.count; index++) {
        if (!SelectMode(displays[index].displayID, specs[index], deadline)) return stopRequested ? 0 : 1;
    }
    if (!ArrangeDisplays(displays, specs)) return 1;

    deadline = NSProcessInfo.processInfo.systemUptime + 15;
    NSArray<NSDictionary *> *snapshot = nil;
    NSString *failure = @"No display snapshot";
    while (!stopRequested && !(snapshot = DisplaySnapshot(displays, specs, &failure))) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            NSLog(@"Virtual displays did not reach the requested layout within 15 seconds. %@.", failure);
            return 1;
        }
        PumpRunLoop();
    }
    if (stopRequested) return 0;

    NSDictionary *ready = @{@"layout": layout, @"pid": @(getpid()), @"displays": snapshot};
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:ready options:NSJSONWritingPrettyPrinted error:&error];
    if (!json || ![json writeToFile:readyPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Cannot write the ready file %@. %@", readyPath, error);
        return 1;
    }
    NSLog(@"Virtual displays ready for %@. %@", layout, snapshot);
    deadline = NSProcessInfo.processInfo.systemUptime + 360;
    while (!stopRequested && NSProcessInfo.processInfo.systemUptime < deadline) PumpRunLoop();
    if (!stopRequested) {
        NSLog(@"Virtual display keepalive exceeded 360 seconds.");
        return 1;
    }
    return 0;
}

static BOOL DisplaysRemoved(const CGDirectDisplayID *displayIDs, NSHashTable<CGVirtualDisplay *> *lifetimes, BOOL log) {
    @autoreleasepool {
        NSUInteger alive = lifetimes.allObjects.count;
        BOOL offline = YES;
        NSMutableArray<NSDictionary *> *states = [NSMutableArray array];
        for (NSUInteger index = 0; index < 2; index++) {
            CGDirectDisplayID displayID = displayIDs[index];
            if (displayID == kCGNullDirectDisplay) continue;
            BOOL online = CGDisplayIsOnline(displayID);
            offline = offline && !online;
            if (log) [states addObject:@{@"displayID": @(displayID), @"online": @(online),
                                         @"active": @(CGDisplayIsActive(displayID)), @"bounds": FrameJSON(CGDisplayBounds(displayID))}];
        }
        if (log) NSLog(@"Virtual display cleanup at uptime %.3f: alive objects %lu, displays %@.",
                       NSProcessInfo.processInfo.systemUptime, (unsigned long)alive, states);
        return offline && alive == 0;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: virtual-displays <ready.json> <horizontal|vertical-negative>\n");
            return 2;
        }
        NSString *readyPath = [NSString stringWithUTF8String:argv[1]];
        NSString *layout = [NSString stringWithUTF8String:argv[2]];
        if (![layout isEqualToString:@"horizontal"] && ![layout isEqualToString:@"vertical-negative"]) {
            fprintf(stderr, "Unsupported virtual display layout.\n");
            return 2;
        }
        struct sigaction action = {0};
        action.sa_handler = HandleSignal;
        sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, NULL);
        sigaction(SIGINT, &action, NULL);
        CGDirectDisplayID displayIDs[2] = {kCGNullDirectDisplay, kCGNullDirectDisplay};
        NSHashTable<CGVirtualDisplay *> *lifetimes = [NSHashTable weakObjectsHashTable];
        int status = 1;
        @autoreleasepool {
            @try {
                status = RunDisplays(readyPath, layout, displayIDs, lifetimes);
            } @catch (NSException *exception) {
                NSLog(@"Virtual display API failed. %@", exception);
            }
        }
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 3;
        BOOL removed = DisplaysRemoved(displayIDs, lifetimes, YES);
        while (!removed && NSProcessInfo.processInfo.systemUptime < deadline) {
            PumpRunLoop();
            removed = DisplaysRemoved(displayIDs, lifetimes, NO);
        }
        DisplaysRemoved(displayIDs, lifetimes, YES);
        if (!removed) {
            NSLog(@"Virtual displays remained online or retained after the lifecycle pool drained and the 3-second removal deadline.");
            return 1;
        }
        return status;
    }
}
