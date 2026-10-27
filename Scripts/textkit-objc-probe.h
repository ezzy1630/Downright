#import <AppKit/AppKit.h>
@interface DRForwardingContentStorage : NSTextContentStorage
@end
@interface DRWrappedContentStorage : NSTextContentStorage
@end
@interface DRVendingContentStorage : NSTextContentStorage
- (nullable NSEnumerator<NSTextElement *> *)probeElementsFromLocation:(nullable id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options;
@end
