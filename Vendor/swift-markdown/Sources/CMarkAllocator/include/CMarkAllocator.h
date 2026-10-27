#ifndef MARKDOWN_CMARK_ALLOCATOR_H
#define MARKDOWN_CMARK_ALLOCATOR_H

#include <cmark-gfm.h>

typedef struct MarkdownAllocationScope MarkdownAllocationScope;
/// Synchronous, thread-bound scope. End only after all cmark objects are freed.
MarkdownAllocationScope *markdown_allocation_begin(void);
cmark_mem *markdown_allocation_memory(MarkdownAllocationScope *scope);
void markdown_allocation_end(MarkdownAllocationScope *scope);

#endif
