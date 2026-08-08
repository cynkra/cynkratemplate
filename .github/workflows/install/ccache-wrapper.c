/*
 * A one-word compiler command that runs "ccache <compiler> <arguments>",
 * the Windows counterpart of the #!/bin/sh wrapper used on Unix.
 *
 * R-devel's tools:::ccE(), which backs the "checking use of non-API entry
 * points" check, reads R CMD config CC, discards everything after the first
 * word, and then runs the remainder:
 * https://github.com/r-devel/r-svn/commit/ca19f35240517186ed447e773ee67b55e207cf27
 * A "CC = ccache gcc" prefix therefore collapses to a bare "ccache" and the
 * check fails. Naming the compiler ccache-gcc instead keeps it a single word,
 * so the truncation is a no-op. Sys.which() will not find a shell script and a
 * make recipe cannot run one, hence a real executable. Build one per compiler
 * with the Rtools toolchain:
 *
 *   gcc -O2 -o ccache-gcc.exe ccache-wrapper.c -DWRAPPED_COMPILER='L"gcc"'
 *
 * Both ccache and the compiler are found on the PATH, nothing is baked in by
 * path: this only ever runs from processes that already have ccache and R's
 * toolchain set up, which is exactly what the Unix wrapper relies on too.
 *
 * The command line is forwarded verbatim instead of being rebuilt from argv[],
 * which is also why this is not the far shorter _spawnvp() one-liner: the CRT
 * joins argv with spaces and re-quotes nothing, so a compiler argument
 * containing a space would arrive at the compiler split in two. (_execvp() is
 * no good either -- on Windows it does not wait, so make would see the wrapper
 * exit before the compiler had run.)
 */

#include <windows.h>
#include <stdio.h>

#ifndef WRAPPED_COMPILER
#error "WRAPPED_COMPILER must be defined, e.g. -DWRAPPED_COMPILER='L\"gcc\"'"
#endif

/* Position just past argv[0] of a command line, quotes honoured. */
static const wchar_t *skip_argv0(const wchar_t *p)
{
    int quoted = 0;

    while (*p != L'\0') {
        if (*p == L'"')
            quoted = !quoted;
        else if (!quoted && (*p == L' ' || *p == L'\t'))
            break;
        p++;
    }
    while (*p == L' ' || *p == L'\t')
        p++;

    return p;
}

int main(void)
{
    /* A Windows command line is limited to 32767 characters. */
    static wchar_t cmd[32767];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD status = 1;

    if (_snwprintf(cmd, ARRAYSIZE(cmd), L"ccache %ls %ls",
                   WRAPPED_COMPILER, skip_argv0(GetCommandLineW())) < 0) {
        fwprintf(stderr, L"ccache wrapper: command line too long\n");
        return 127;
    }
    cmd[ARRAYSIZE(cmd) - 1] = L'\0';

    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);

    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fwprintf(stderr, L"ccache wrapper: cannot run %ls (error %lu)\n",
                 cmd, (unsigned long) GetLastError());
        return 127;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &status);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return (int) status;
}
