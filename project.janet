(declare-project
  :name "portable-agents"
  :version "0.2.0"
  :description "A small execution boundary for ordinary Janet programs"
  :license "AGPL-3.0-only"
  :dependencies [{:repo "https://github.com/janet-lang/spork.git" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}
                 {:repo "https://github.com/pyrmont/remarkable.git" :tag "e3bbf2f5e18c1b3ed33ccf7872b6719351334424"}])

(declare-source :source ["src/markdown.janet" "src/protocol.janet"] :prefix "portable-agents/src")

(os/mkdir "build")
(def host-source ```
#include <janet.h>
#include <errno.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#endif

static Janet protocol_output(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);
    fflush(stdout);
#ifdef _WIN32
    int descriptor = _dup(_fileno(stdout));
    if (descriptor < 0) janet_panic(strerror(errno));
    if (!SetHandleInformation((HANDLE)_get_osfhandle(descriptor), HANDLE_FLAG_INHERIT, 0))
        janet_panic("SetHandleInformation failed");
    if (_setmode(descriptor, _O_BINARY) < 0) janet_panic(strerror(errno));
    FILE *output = _fdopen(descriptor, "wb");
    if (!output || _dup2(_fileno(stderr), _fileno(stdout))) janet_panic(strerror(errno));
    if (!SetStdHandle(STD_OUTPUT_HANDLE, (HANDLE)_get_osfhandle(_fileno(stdout))))
        janet_panic("SetStdHandle failed");
#else
    int descriptor = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3);
    if (descriptor < 0) janet_panic(strerror(errno));
    FILE *output = fdopen(descriptor, "wb");
    if (!output || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) janet_panic(strerror(errno));
#endif
    return janet_makefile(output, JANET_FILE_WRITE | JANET_FILE_BINARY);
}

static Janet detach(int32_t argc, Janet *argv) {
    (void)argv;
    janet_fixarity(argc, 0);
#ifdef _WIN32
    if (!FreeConsole() && GetLastError() != ERROR_INVALID_HANDLE)
        janet_panic("FreeConsole failed");
#else
    if (getsid(0) != getpid()) {
        if (getpgrp() == getpid()) {
            pid_t child = fork();
            if (child < 0) janet_panic(strerror(errno));
            if (child) {
                int status;
                pid_t result;
                signal(SIGINT, SIG_DFL);
                do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
                if (result < 0) janet_panic(strerror(errno));
                _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
            }
        }
        if (setsid() < 0) janet_panic(strerror(errno));
    }
#endif
    return janet_wrap_nil();
}

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_def(env, "detach", janet_wrap_cfunction(detach), NULL);
    janet_def(env, "protocol-output", janet_wrap_cfunction(protocol_output), NULL);
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
         (string (dyn :modpath) "/spork/sh.janet")
         (string (dyn :modpath) "/spork/path.janet")
         (string (dyn :modpath) "/spork/base64" (dyn :modext))
         (string (dyn :modpath) "/spork/base64" (dyn :statext))
         (string (dyn :modpath) "/spork/json" (dyn :modext))
         (string (dyn :modpath) "/spork/json" (dyn :statext))
         (string (dyn :modpath) "/spork/utf8" (dyn :modext))
         (string (dyn :modpath) "/spork/utf8" (dyn :statext))
         (string "build/portable-agents/host" (dyn :modext))
         (string "build/portable-agents/host" (dyn :statext))
         "build/portable-agents/host.meta.janet"]
  :install true)
