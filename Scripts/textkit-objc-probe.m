// Temporary remote-only TextKit contract probe; remove before release.
#import "textkit-objc-probe.h"
@implementation DRForwardingContentStorage
- (id<NSTextLocation>)enumerateTextElementsFromLocation:(id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options
    usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block {
    return [super enumerateTextElementsFromLocation:location options:options usingBlock:block];
}
@end
@implementation DRWrappedContentStorage
- (id<NSTextLocation>)enumerateTextElementsFromLocation:(id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options
    usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block {
    return [super enumerateTextElementsFromLocation:location options:options usingBlock:^BOOL(NSTextElement *element) {
        BOOL result = block(element);
        static int count = 0;
        if (++count < 16) printf("OBJC callback=%d\n", (int)result);
        return result;
    }];
}
@end
@implementation DRVendingContentStorage
- (NSEnumerator<NSTextElement *> *)probeElementsFromLocation:(id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options { return nil; }
- (id<NSTextLocation>)enumerateTextElementsFromLocation:(id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options
    usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block {
    NSEnumerator<NSTextElement *> *elements = [self probeElementsFromLocation:location options:options];
    if (!elements) return [super enumerateTextElementsFromLocation:location options:options usingBlock:block];
    BOOL reverse = (options & NSTextContentManagerEnumerationOptionsReverse) != 0;
    id<NSTextLocation> edge = location ?: (reverse ? self.documentRange.endLocation : self.documentRange.location);
    for (NSTextElement *element in elements) {
        BOOL more = block(element);
        edge = reverse ? element.elementRange.location : element.elementRange.endLocation;
        if (!more) break;
    }
    return edge;
}
@end
