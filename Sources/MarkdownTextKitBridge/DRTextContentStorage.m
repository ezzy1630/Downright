#import "DRTextContentStorage.h"

@implementation DRTextContentStorage
- (nullable NSEnumerator<NSTextElement *> *)textElementEnumeratorFromLocation:(nullable id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options {
    return nil;
}

- (nullable id<NSTextLocation>)enumerateTextElementsFromLocation:(nullable id<NSTextLocation>)location
    options:(NSTextContentManagerEnumerationOptions)options
    usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block {
    NSEnumerator<NSTextElement *> *elements = [self textElementEnumeratorFromLocation:location options:options];
    if (!elements) {
        return [super enumerateTextElementsFromLocation:location options:options usingBlock:block];
    }
    // Rebridging this native callback through a Swift override leaves macOS 26
    // viewportRange nil, even when that override only forwards to super. Keep
    // callback delivery native; Swift still owns paragraph mapping and caching.
    BOOL reverse = (options & NSTextContentManagerEnumerationOptionsReverse) != 0;
    id<NSTextLocation> edge = location ?: (reverse ? self.documentRange.endLocation : self.documentRange.location);
    NSTextElement *element;
    while ((element = [elements nextObject])) {
        BOOL more = block(element);
        edge = reverse ? element.elementRange.location : element.elementRange.endLocation;
        if (!more) break;
    }
    return edge;
}
@end
