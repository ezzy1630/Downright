#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

void DRSendWindowMouseGesture(NSWindow *window, NSEvent *down, NSArray<NSEvent *> *tracking);
void DRSendWindowTrackedMove(NSWindow *window, NSEvent *event, NSResponder *owner);
void DRWithPrivatePasteboard(NSPasteboard *pasteboard, void (NS_NOESCAPE ^run)(void));

NS_ASSUME_NONNULL_END
