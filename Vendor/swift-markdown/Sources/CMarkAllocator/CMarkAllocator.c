#include "CMarkAllocator.h"
#include <stdlib.h>

#ifdef __APPLE__
#include <malloc/malloc.h>

struct MarkdownAllocationScope {
    malloc_zone_t *zone;
    struct MarkdownAllocationScope *previous;
};
static _Thread_local MarkdownAllocationScope *current;

static void *parse_calloc(size_t count, size_t size) {
    return malloc_zone_calloc(current->zone, count, size);
}
static void *parse_realloc(void *pointer, size_t size) {
    return malloc_zone_realloc(current->zone, pointer, size);
}
static void parse_free(void *pointer) {
    if (pointer) malloc_zone_free(current->zone, pointer);
}
static cmark_mem memory = { parse_calloc, parse_realloc, parse_free };

MarkdownAllocationScope *markdown_allocation_begin(void) {
    MarkdownAllocationScope *scope = malloc(sizeof(*scope));
    if (!scope) abort();
    scope->zone = malloc_create_zone(0, 0);
    if (!scope->zone) abort();
    scope->previous = current;
    current = scope;
    return scope;
}
cmark_mem *markdown_allocation_memory(MarkdownAllocationScope *scope) {
    (void)scope;
    return &memory;
}
void markdown_allocation_end(MarkdownAllocationScope *scope) {
    current = scope->previous;
    malloc_destroy_zone(scope->zone);
    free(scope);
}
#else
MarkdownAllocationScope *markdown_allocation_begin(void) { return NULL; }
cmark_mem *markdown_allocation_memory(MarkdownAllocationScope *scope) {
    (void)scope;
    return cmark_get_default_mem_allocator();
}
void markdown_allocation_end(MarkdownAllocationScope *scope) { (void)scope; }
#endif
