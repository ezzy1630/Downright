#import "DRParagraphIndex.h"
#include <string.h>

typedef unsigned char DRBytes16 __attribute__((ext_vector_type(16)));
typedef unsigned short DRUnits8 __attribute__((ext_vector_type(8)));

static inline void appendStart(NSInteger offset, NSInteger *starts, NSInteger capacity, NSInteger *count) {
    if (*count < capacity) starts[*count] = offset;
    *count += 1;
}

NSInteger DRParagraphStarts(CFStringRef text, NSInteger *starts, NSInteger capacity) {
    const NSInteger length = CFStringGetLength(text);
    NSInteger count = 0;
    appendStart(0, starts, capacity, &count);
    const char *ascii = CFStringGetCStringPtr(text, kCFStringEncodingASCII);
    if (ascii) {
        NSInteger scalarEnd = 0;
        for (NSInteger i = 0; i < length; ++i) {
            if (i >= scalarEnd && i + 16 <= length) {
                DRBytes16 units;
                memcpy(&units, ascii + i, sizeof units);
                if (!__builtin_reduce_or((units == 0x0A) | (units == 0x0D))) {
                    i += 15;
                    continue;
                }
                scalarEnd = i + 16;
            }
            if (ascii[i] == '\r') {
                if (i + 1 < length && ascii[i + 1] == '\n') ++i;
                appendStart(i + 1, starts, capacity, &count);
            } else if (ascii[i] == '\n') {
                appendStart(i + 1, starts, capacity, &count);
            }
        }
        return count;
    }
    // Chunked CF reads avoid both per-character Objective-C dispatch and a
    // document-sized UTF-16 copy. Carry CR across the chunk boundary.
    const UniChar *contiguous = CFStringGetCharactersPtr(text);
    UniChar scratch[8192];
    BOOL pendingCR = NO;
    for (NSInteger base = 0; base < length;) {
        NSInteger size = MIN(8192, length - base);
        const UniChar *units = contiguous ? contiguous + base : scratch;
        if (!contiguous) CFStringGetCharacters(text, CFRangeMake(base, size), scratch);
        NSInteger scalarEnd = 0;
        for (NSInteger i = 0; i < size; ++i) {
            if (!pendingCR && i >= scalarEnd && i + 8 <= size) {
                DRUnits8 batch;
                memcpy(&batch, units + i, sizeof batch);
                if (!__builtin_reduce_or((batch == 0x0A) | (batch == 0x0D) |
                        (batch == 0x85) | (batch == 0x2028) | (batch == 0x2029))) {
                    i += 7;
                    continue;
                }
                scalarEnd = i + 8;
            }
            UniChar unit = units[i];
            if (pendingCR) {
                pendingCR = NO;
                if (unit == '\n') {
                    appendStart(base + i + 1, starts, capacity, &count);
                    continue;
                }
                appendStart(base + i, starts, capacity, &count);
            }
            if (unit == '\r') pendingCR = YES;
            else if (unit == '\n' || unit == 0x85 || unit == 0x2028 || unit == 0x2029) {
                appendStart(base + i + 1, starts, capacity, &count);
            }
        }
        base += size;
    }
    if (pendingCR) appendStart(length, starts, capacity, &count);
    return count;
}
