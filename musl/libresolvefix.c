// libresolvefix.c — make musl's DNS work on Android.
//
// Musl reads /etc/resolv.conf — redirect to Termux's copy.
// Musl's getaddrinfo sends raw UDP — forward to bionic's getaddrinfo
// which uses Android's netd daemon.
//
// Build:
//   clang -shared -fPIC -o libresolvefix.so libresolvefix.c
//
// Usage:
//   LD_PRELOAD=libresolvefix.so <binary>

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <stdarg.h>
#include <netdb.h>
#include <sys/types.h>

// --- Part 1: redirect /etc/resolv.conf reads ---

static const char *RESOLV_CONF = "/etc/resolv.conf";
static const char *TERMUX_RESOLV = "/data/data/com.termux/files/usr/etc/resolv.conf";

static const char *redirect(const char *p) {
    return (p && strcmp(p, RESOLV_CONF) == 0) ? TERMUX_RESOLV : p;
}

int open(const char *pathname, int flags, ...) {
    int (*real_open)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
    const char *p = redirect(pathname);
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode_t m = va_arg(ap, mode_t);
        va_end(ap);
        return real_open(p, flags, m);
    }
    return real_open(p, flags);
}

FILE *fopen(const char *pathname, const char *mode) {
    FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
    return real_fopen(redirect(pathname), mode);
}

// --- Part 2: getaddrinfo -> bionic's via dlopen ---

static void *bionic_lib = NULL;

static void ensure_bionic(void) {
    if (bionic_lib) return;
    bionic_lib = dlopen("/apex/com.android.runtime/lib64/bionic/libc.so",
                        RTLD_NOW | RTLD_NODELETE);
    if (!bionic_lib)
        bionic_lib = dlopen("/system/lib64/libc.so",
                            RTLD_NOW | RTLD_NODELETE);
    if (!bionic_lib)
        bionic_lib = dlopen("libc.so", RTLD_NOW | RTLD_NODELETE);
}

typedef int (*bionic_getaddrinfo_fn)(const char *, const char *,
                                     const struct addrinfo *, struct addrinfo **);
typedef void (*bionic_freeaddrinfo_fn)(struct addrinfo *);
typedef const char *(*bionic_gai_strerror_fn)(int);

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
    ensure_bionic();
    if (bionic_lib) {
        bionic_getaddrinfo_fn real =
            (bionic_getaddrinfo_fn)dlsym(bionic_lib, "getaddrinfo");
        if (real)
            return real(node, service, hints, res);
    }
    bionic_getaddrinfo_fn real =
        (bionic_getaddrinfo_fn)dlsym(RTLD_NEXT, "getaddrinfo");
    return real(node, service, hints, res);
}

void freeaddrinfo(struct addrinfo *res) {
    ensure_bionic();
    if (bionic_lib) {
        bionic_freeaddrinfo_fn real =
            (bionic_freeaddrinfo_fn)dlsym(bionic_lib, "freeaddrinfo");
        if (real) { real(res); return; }
    }
    bionic_freeaddrinfo_fn real =
        (bionic_freeaddrinfo_fn)dlsym(RTLD_NEXT, "freeaddrinfo");
    real(res);
}

const char *gai_strerror(int errcode) {
    ensure_bionic();
    if (bionic_lib) {
        bionic_gai_strerror_fn real =
            (bionic_gai_strerror_fn)dlsym(bionic_lib, "gai_strerror");
        if (real) return real(errcode);
    }
    bionic_gai_strerror_fn real =
        (bionic_gai_strerror_fn)dlsym(RTLD_NEXT, "gai_strerror");
    return real(errcode);
}
