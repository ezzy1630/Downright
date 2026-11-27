#include "NativeUITestBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>


// Preferences mirrors Quick Look settings into the user's global defaults on load
// and update, even with DOWNRIGHT_SUPPORT_DIRECTORY set. Suppress only that
// cross-process mirror in the test executable. The app still reads, writes
// and broadcasts the actual document and preferences under the support root.
void CFPreferencesSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef application,
                           CFStringRef user, CFStringRef host) {
    if (CFEqual(application, kCFPreferencesAnyApplication) &&
        CFEqual(user, kCFPreferencesCurrentUser) &&
        CFEqual(host, kCFPreferencesAnyHost) &&
        (CFEqual(key, CFSTR("com.ezzy.downright.quickLook.appearance")) ||
         CFEqual(key, CFSTR("com.ezzy.downright.quickLook.lightTheme")) ||
         CFEqual(key, CFSTR("com.ezzy.downright.quickLook.darkTheme")) ||
         CFEqual(key, CFSTR("com.ezzy.downright.quickLook.language")) ||
         CFEqual(key, CFSTR("com.ezzy.downright.quickLook.measureCharacters")))) {
        return;
    }
    void (*original)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef) =
        dlsym(RTLD_NEXT, "CFPreferencesSetValue");
    if (!original) abort();
    original(key, value, application, user, host);
}

#import <objc/runtime.h>

void DRSendWindowMouseGesture(NSWindow *window, NSEvent *down, NSArray<NSEvent *> *tracking) {
    SEL selector = @selector(nextEventMatchingMask:untilDate:inMode:dequeue:);
    Method method = class_getInstanceMethod(NSWindow.class, selector);
    NSEvent *(*nextEvent)(NSWindow *, SEL, NSEventMask, NSDate *, NSRunLoopMode, BOOL) =
        (void *)method_getImplementation(method);
    NSMutableArray<NSEvent *> *pending = [NSMutableArray arrayWithArray:tracking];
    // AppKit's mouseDown tracking asks its own NSWindow for drag/up events.
    // Supplying these events here avoids NSApp.postEvent stopping SwiftPM's
    // main run loop, and leaves every other window's queue alone.
    IMP feed = imp_implementationWithBlock(^NSEvent *(NSWindow *receiver, NSEventMask mask,
                                                     NSDate *deadline, NSRunLoopMode mode, BOOL dequeue) {
        if (receiver != window) return nextEvent(receiver, selector, mask, deadline, mode, dequeue);
        for (NSUInteger index = 0; index < pending.count; index++) {
            NSEvent *event = pending[index];
            if (!(mask & NSEventMaskFromType(event.type))) continue;
            if (dequeue) [pending removeObjectAtIndex:index];
            return event;
        }
        return nil;
    });
    // During link clicks NSTextView can put mouse-up back for NSWindow.
    // Preserve that repost within the fixture's queue as well.
    SEL postSelector = @selector(postEvent:atStart:);
    Method postMethod = class_getInstanceMethod(NSApplication.class, postSelector);
    void (*postEvent)(NSApplication *, SEL, NSEvent *, BOOL) = (void *)method_getImplementation(postMethod);
    IMP repost = imp_implementationWithBlock(^(NSApplication *app, NSEvent *event, BOOL atStart) {
        if (![tracking containsObject:event]) {
            postEvent(app, postSelector, event, atStart);
            return;
        }
        if (atStart) [pending insertObject:event atIndex:0];
        else [pending addObject:event];
    });
    method_setImplementation(method, feed);
    method_setImplementation(postMethod, repost);
    @try {
        [window sendEvent:down];
    } @finally {
        method_setImplementation(postMethod, (IMP)postEvent);
        method_setImplementation(method, (IMP)nextEvent);
        imp_removeBlock(repost);
        imp_removeBlock(feed);
    }
    for (NSEvent *event in pending) [window sendEvent:event];
}

void DRWithPrivatePasteboard(NSPasteboard *pasteboard, void (NS_NOESCAPE ^run)(void)) {
    Method method = class_getClassMethod(NSPasteboard.class, @selector(generalPasteboard));
    IMP redirect = imp_implementationWithBlock(^NSPasteboard *(Class receiver) {
        return pasteboard;
    });
    IMP original = method_setImplementation(method, redirect);
    @try {
        run();
    } @finally {
        method_setImplementation(method, original);
        imp_removeBlock(redirect);
    }
}

// A mouseMoved event created outside WindowServer has no tracking destination.
// AppKit's untagged movement path uses firstResponder. Supply the registered
// tracking owner for this one dispatch without making it the keyboard target.
void DRSendWindowTrackedMove(NSWindow *window, NSEvent *event, NSResponder *owner) {
    SEL selector = @selector(firstResponder);
    Method method = class_getInstanceMethod(NSWindow.class, selector);
    NSResponder *(*firstResponder)(NSWindow *, SEL) = (void *)method_getImplementation(method);
    IMP dispatchToOwner = imp_implementationWithBlock(^NSResponder *(NSWindow *receiver) {
        return receiver == window ? owner : firstResponder(receiver, selector);
    });
    method_setImplementation(method, dispatchToOwner);
    @try {
        [window sendEvent:event];
    } @finally {
        method_setImplementation(method, (IMP)firstResponder);
        imp_removeBlock(dispatchToOwner);
    }
}
