#include <malloc.h>

// Bionic exports mallopt on all supported Android versions, but its declaration
// is hidden from API 24 headers.
extern int mallopt(int parameter, int value);

// Android 11+ heap pointers may carry a top-byte tag. JavaScriptCore's NaN
// boxing does not preserve it, so disable heap tagging before Bun/JSC starts.
__attribute__((constructor)) static void disable_heap_tagging(void) {
    mallopt(-204 /* M_BIONIC_SET_HEAP_TAGGING_LEVEL */, 0);
}
