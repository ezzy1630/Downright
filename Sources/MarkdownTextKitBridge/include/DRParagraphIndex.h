#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Returns the required start count, writing at most capacity offsets.
/// Offsets include 0 and an empty final paragraph after a terminator.
FOUNDATION_EXPORT NSInteger DRParagraphStarts(CFStringRef text, NSInteger * _Nullable starts, NSInteger capacity);
NS_ASSUME_NONNULL_END
