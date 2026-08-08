/*
 * A one-word compiler command that runs "ccache <compiler> <arguments>".
 *
 * R-devel's tools:::ccE(), which backs the "checking use of non-API entry
 * points" check, reads R CMD config CC, discards everything after the first
 * word, and then runs the remainder:
 * https://github.com/r-devel/r-svn/commit/ca19f35240517186ed447e773ee67b55e207cf27
 * A "CC = ccache gcc" prefix therefore collapses to a bare "ccache" and the
 * check fails. Naming the compiler ccache-gcc instead keeps it a single word,
 * so the truncation is a no-op.
 *
 * On Unix that wrapper is a #!/bin/sh script. Windows has no such thing:
 * Sys.which() and make recipes both need a real executable, so this file is
 * compiled once per compiler with the Rtools toolchain when the workflow sets
 * ccache up. Build it with:
 *
 *   gcc -O2 -o ccache-gcc.exe ccache-wrapper.c \
 *     -DCCACHE_EXE='"C:/path/to/ccache.exe"' -DWRAPPED_COMPILER='"gcc"'
 *
 * The original command line is forwarded verbatim rather than rebuilt from
 * argv[], so the quoting of compiler arguments survives untouched.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef CCACHE_EXE
#error "CCACHE_EXE must be defined: the full path to ccache.exe"
#endif

#ifndef WRAPPED_COMPILER
#error "WRAPPED_COMPILER must be defined: the compiler to run under ccache"
#endif

/* Position just past argv[0] of a Windows command line, quotes honoured. */
static const char *skip_argv0(const char *p)
{
    int quoted = 0;

    while (*p != '\0') {
        if (*p == '"')
            quoted = !quoted;
        else if (!quoted && (*p == ' ' || *p == '\t'))
            break;
        p++;
    }
    while (*p == ' ' || *p == '\t')
        p++;

    return p;
}

int main(void)
{
    const char *args = skip_argv0(GetCommandLineA());
    size_t size = strlen(CCACHE_EXE) + strlen(WRAPPED_COMPILER) + strlen(args) + 5;
    char *cmd = malloc(size);
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD status = 1;

    if (cmd == NULL) {
        fprintf(stderr, "ccache wrapper: out of memory\n");
        return 127;
    }
    /* argv[0] must still be named ccache: that is how ccache tells its own
     * invocation apart from being masqueraded as the compiler itself. */
    snprintf(cmd, size, "\"%s\" %s %s", CCACHE_EXE, WRAPPED_COMPILER, args);

    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);

    /* Naming the image explicitly keeps CreateProcess from searching for it,
     * so a forward-slash path from cygpath -m is resolved as a plain file. */
    if (!CreateProcessA(CCACHE_EXE, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "ccache wrapper: cannot run %s (error %lu)\n",
                cmd, (unsigned long) GetLastError());
        free(cmd);
        return 127;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &status);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(cmd);

    return (int) status;
}
