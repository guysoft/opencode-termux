#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/data/data/com.termux/files/usr/lib/libopentui.so";

    printf("Attempting dlopen: %s\n", path);

    dlerror();
    void *handle = dlopen(path, RTLD_NOW);
    if (handle) {
        printf("SUCCESS: dlopen returned %p\n", handle);
        dlclose(handle);
        return 0;
    }

    const char *err = dlerror();
    printf("FAILED: %s\n", err ? err : "(null dlerror)");
    return 1;
}
