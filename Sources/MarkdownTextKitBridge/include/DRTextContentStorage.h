#import <AppKit/AppKit.h>
#import "DRParagraphIndex.h"

NS_ASSUME_NONNULL_BEGIN

/// Keeps AppKit's enumeration callback in Objective-C while subclasses supply
/// lazy elements without receiving or rebridging that callback.
@interface DRTextContentStorage : NSTextContentStorage
/// Return nil to use native physical paragraphs, or an enumerator whose elements
/// have source-aligned ranges and remain cached until layout is invalidated.
- (nullable NSEnumerator<NSTextElement *> *)textElementEnumeratorFromLocation:(nullable id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options
    NS_SWIFT_NAME(makeTextElementEnumerator(from:options:));
@end

NS_ASSUME_NONNULL_END
