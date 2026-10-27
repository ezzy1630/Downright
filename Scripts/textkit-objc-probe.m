// Temporary remote-only TextKit contract probe; remove before release.
#import <AppKit/AppKit.h>
@interface DRForwardingContentStorage : NSTextContentStorage
@end
@implementation DRForwardingContentStorage
- (id<NSTextLocation>)enumerateTextElementsFromLocation:(id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options
    usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block {
    return [super enumerateTextElementsFromLocation:location options:options usingBlock:block];
}
@end
