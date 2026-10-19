(declare-project
  :name "portable-agents"
  :version "0.3.0"
  :description "A small execution boundary for ordinary Janet programs"
  :license "AGPL-3.0-only"
  :dependencies [])

(declare-source :source ["src"] :prefix "portable-agents")

(os/mkdir "build")
(def host-source ```
#include <janet.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#endif

static Janet executable(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);
    size_t capacity = 256;
    for (;;) {
#ifdef _WIN32
        wchar_t *wide = malloc(capacity * sizeof(wchar_t));
        if (!wide) janet_panic("executable path allocation failed");
        DWORD length = GetModuleFileNameW(NULL, wide, (DWORD)capacity);
        if (!length) { free(wide); janet_panic("GetModuleFileNameW failed"); }
        if (length < capacity) {
            int size = WideCharToMultiByte(CP_UTF8, 0, wide, length, NULL, 0, NULL, NULL);
            if (!size) { free(wide); janet_panic("executable path conversion failed"); }
            uint8_t *path = janet_string_begin(size);
            if (WideCharToMultiByte(CP_UTF8, 0, wide, length, (char *)path, size, NULL, NULL) != size)
                janet_panic("executable path conversion failed");
            free(wide);
            return janet_wrap_string(janet_string_end(path));
        }
        free(wide);
#else
        char *path = malloc(capacity);
        if (!path) janet_panic("executable path allocation failed");
#ifdef __APPLE__
        uint32_t size = (uint32_t)capacity;
        int status = _NSGetExecutablePath(path, &size);
        if (!status) {
            char *absolute = realpath(path, NULL);
            free(path);
            if (!absolute) janet_panic(strerror(errno));
            Janet result = janet_cstringv(absolute);
            free(absolute);
            return result;
        }
#else
        ssize_t size = readlink("/proc/self/exe", path, capacity);
        if (size < 0) { free(path); janet_panic(strerror(errno)); }
        if ((size_t)size < capacity) {
            Janet result = janet_stringv((const uint8_t *)path, (int32_t)size);
            free(path);
            return result;
        }
#endif
        free(path);
#endif
        capacity *= 2;
    }
}

static Janet detach(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);
#ifdef _WIN32
    if (!FreeConsole() && GetLastError() != ERROR_INVALID_HANDLE)
        janet_panic("FreeConsole failed");
#else
    if (getsid(0) != getpid() && setsid() < 0) janet_panic(strerror(errno));
#endif
    return janet_wrap_nil();
}

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_def(env, "executable", janet_wrap_cfunction(executable), NULL);
    janet_def(env, "detach", janet_wrap_cfunction(detach), NULL);
}
```)
(unless (and (os/stat "build/host.c") (= host-source (string (slurp "build/host.c"))))
  (spit "build/host.c" host-source :wb))
(declare-native :name "portable-agents/host" :source ["build/host.c"]
                :defines {"_POSIX_C_SOURCE" "200809L" "_XOPEN_SOURCE" "700"})

(declare-executable
  :name "agent"
  :entry "src/main.janet"
  :deps ["src/protocol.janet" "src/markdown.janet"
         (string "build/portable-agents/host" (dyn :modext))
         (string "build/portable-agents/host" (dyn :statext))
         "build/portable-agents/host.meta.janet"]
  :install true)
