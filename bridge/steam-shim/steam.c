/*
 * Copyright (c) 2015, 2019, 2020, 2021, 2022 Valve Corporation
 * Copyright (c) 2026 Warzag contributors (modifications)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation and/or
 * other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors
 * may be used to endorse or promote products derived from this software without
 * specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * steam.exe for Warzag's Steam bridge, adapted from Proton's steam_helper/steam.c (proton-11.0-2e).
 *
 * A Windows game's steam_api64.dll expects a running Windows Steam client: it reads
 * HKCU\Software\Valve\Steam\ActiveProcess, checks that the process named by "pid" is alive and loads the DLL
 * named by SteamClientDll64. In Warzag that DLL forwards to lsteamclient, which talks to the user's native Mac
 * Steam; this program is the "running Steam" that steam_api looks for.
 *
 *   steam.exe [--cwd <dir>] <program> [<argument>...]   run <program> (the game, or its launcher)
 *   steam.exe [--] steam://<...> [...]                  hand steam:// URLs to Mac Steam
 *
 * When SteamGameId is set it first
 *   - writes ActiveProcess {pid, SteamClientDll64, SteamPath, Universe} and
 *     Software\Valve\Steam {SteamPath, SteamExe, language};
 *   - creates the Steam3Master_SharedMemLock and Global\Valve_SteamIPC_Class events and a hidden
 *     "vguiPopupWindow" window titled "Steam";
 *   - sets SteamPath and ValvePlatformMutex in the environment the game inherits.
 * It then runs <program> in a job object and stays alive until every process in the job has exited, because
 * Warframe's launcher starts Warframe.x64.exe and exits while the game still needs a live Steam pid. It exits
 * with the exit code of the last process to leave the job, not counting Wine's own programs under C:\windows
 * such as conhost.exe (in a launcher hand-off: the game); 1 if <program> cannot be started; 2 for bad arguments.
 *
 * steam:// URLs go to the host through Wine's winebrowser (/usr/bin/open on macOS, which hands them to Mac
 * Steam), except run, rungameid and launch for the game already being played: Mac Steam cannot start the
 * Windows build and would only show an error.
 *
 * Differences from Proton: no Wine-private calls (ProcessWineMakeProcessSystem, __wine_unix_spawnvp,
 * wine_get_dos_file_name), no lsteamclient steamclient_init_registry, no VR/EA/Source SDK workarounds, and a job
 * object instead of waiting for every user process in the prefix. Problems are reported on stderr; they and a
 * trace of every process in the job also go to OutputDebugString (shown with WINEDEBUG=warn+seh).
 */

#define WIN32_LEAN_AND_MEAN
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>

#define STEAM_DIR L"C:\\Program Files (x86)\\Steam"
#define STEAM_KEY L"Software\\Valve\\Steam"
#define ACTIVE_PROCESS_KEY L"Software\\Valve\\Steam\\ActiveProcess"

/* Problems go to stderr and OutputDebugString; trace() lines only to the latter (WINEDEBUG=warn+seh). */
static void message(BOOL to_stderr, const WCHAR *fmt, va_list ap)
{
    HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    WCHAR msg[2048];
    char utf8[6144];
    DWORD written;
    int len;

    len = _snwprintf(msg, ARRAYSIZE(msg) - 1, L"steam.exe: ");
    _vsnwprintf(msg + len, ARRAYSIZE(msg) - 1 - len, fmt, ap);
    msg[ARRAYSIZE(msg) - 1] = 0;

    OutputDebugStringW(msg);
    if (!to_stderr || !err || err == INVALID_HANDLE_VALUE) return;
    if ((len = WideCharToMultiByte(CP_UTF8, 0, msg, -1, utf8, sizeof(utf8), NULL, NULL)) > 1)
        WriteFile(err, utf8, len - 1, &written, NULL);
}

static void report(const WCHAR *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    message(TRUE, fmt, ap);
    va_end(ap);
}

static void trace(const WCHAR *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    message(FALSE, fmt, ap);
    va_end(ap);
}

static void set_string(const WCHAR *key, const WCHAR *name, const WCHAR *value)
{
    LSTATUS status = RegSetKeyValueW(HKEY_CURRENT_USER, key, name, REG_SZ, value,
                                     (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));

    if (status) report(L"cannot set HKCU\\%ls\\%ls (error %ld)\n", key, name, (long)status);
}

static DWORD WINAPI steam_window_thread(void *arg)
{
    WNDCLASSEXW wc = {.cbSize = sizeof(wc)};
    MSG msg;

    (void)arg;
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"vguiPopupWindow";
    RegisterClassExW(&wc);
    /* WS_POPUP without WS_VISIBLE: never shown. Launchers look for this window to see that Steam runs. */
    if (!CreateWindowExW(0, wc.lpszClassName, L"Steam", WS_POPUP, 40, 40, 400, 300, NULL, NULL, wc.hInstance, NULL))
        report(L"cannot create the Steam window (error %lu)\n", GetLastError());

    while (GetMessageW(&msg, NULL, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

static void setup_game_session(void)
{
    DWORD pid = GetCurrentProcessId(), size = 0;
    WCHAR path[MAX_PATH], *p;
    HANDLE thread;
    LSTATUS status;

    /* What steam_api checks: a live Steam process and the client DLL to load (see bridge/README.md). */
    if ((status = RegSetKeyValueW(HKEY_CURRENT_USER, ACTIVE_PROCESS_KEY, L"pid", REG_DWORD, &pid, sizeof(pid))))
        report(L"cannot set the ActiveProcess pid (error %ld)\n", (long)status);
    set_string(ACTIVE_PROCESS_KEY, L"SteamClientDll64", STEAM_DIR L"\\steamclient64.dll");
    set_string(ACTIVE_PROCESS_KEY, L"SteamPath", STEAM_DIR);
    set_string(ACTIVE_PROCESS_KEY, L"Universe", L"Public");
    set_string(STEAM_KEY, L"SteamPath", STEAM_DIR);
    set_string(STEAM_KEY, L"SteamExe", STEAM_DIR L"\\steam.exe");
    /* English unless the prefix already names the user's Steam language. */
    if (RegGetValueW(HKEY_CURRENT_USER, STEAM_KEY, L"language", RRF_RT_REG_SZ, NULL, NULL, &size))
        set_string(STEAM_KEY, L"language", L"english");

    /* Objects the Windows client owns; some launchers wait for them. The handles stay open until we exit. */
    if (!CreateEventW(NULL, FALSE, FALSE, L"Steam3Master_SharedMemLock"))
        report(L"cannot create Steam3Master_SharedMemLock (error %lu)\n", GetLastError());
    if (!CreateEventW(NULL, FALSE, FALSE, L"Global\\Valve_SteamIPC_Class"))
        report(L"cannot create Global\\Valve_SteamIPC_Class (error %lu)\n", GetLastError());

    /* wmain has already made Wine start the desktop, so this thread cannot race it to do so. */
    if ((thread = CreateThread(NULL, 0, steam_window_thread, NULL, 0, NULL))) CloseHandle(thread);
    else report(L"cannot start the Steam window thread (error %lu)\n", GetLastError());

    SetEnvironmentVariableW(L"SteamPath", STEAM_DIR);
    /* Steam sets this to its own executable, with forward slashes. */
    if (GetModuleFileNameW(NULL, path, ARRAYSIZE(path)))
    {
        for (p = path; *p; p++) if (*p == '\\') *p = '/';
        SetEnvironmentVariableW(L"ValvePlatformMutex", path);
    }
}

/* Joins arguments into a command line that CommandLineToArgvW and the C runtimes split back into the same list. */
static WCHAR *join_arguments(int count, WCHAR **args)
{
    size_t size = 1;
    WCHAR *cmdline, *p;
    int i;

    for (i = 0; i < count; i++) size += 2 * wcslen(args[i]) + 3;
    if (!(cmdline = p = malloc(size * sizeof(WCHAR)))) return NULL;

    for (i = 0; i < count; i++)
    {
        const WCHAR *s = args[i];

        if (i) *p++ = ' ';
        if (*s && !wcspbrk(s, L" \t\n\v\""))
        {
            while (*s) *p++ = *s++;
            continue;
        }
        *p++ = '"';
        while (*s)
        {
            size_t backslashes = 0;

            while (*s == '\\')
            {
                backslashes++;
                s++;
            }
            /* Backslashes are literal unless a quote follows: then they double, and the quote gets escaped. */
            if (!*s || *s == '"') backslashes *= 2;
            for (; backslashes; backslashes--) *p++ = '\\';
            if (!*s) break;
            if (*s == '"') *p++ = '\\';
            *p++ = *s++;
        }
        *p++ = '"';
    }
    *p = 0;
    return cmdline;
}

static BOOL is_steam_url(const WCHAR *arg)
{
    return !_wcsnicmp(arg, L"steam://", 8);
}

/* steam://run/<id>, rungameid/<id> or launch/<id> naming the game that is already running. */
static BOOL is_self_launch(const WCHAR *url)
{
    static const WCHAR *const verbs[] = {L"steam://run/", L"steam://rungameid/", L"steam://launch/"};
    WCHAR id[32];
    DWORD len = GetEnvironmentVariableW(L"SteamGameId", id, ARRAYSIZE(id));
    size_t i, n;

    if (!len || len >= ARRAYSIZE(id)) return FALSE;
    for (i = 0; i < ARRAYSIZE(verbs); i++)
    {
        n = wcslen(verbs[i]);
        if (_wcsnicmp(url, verbs[i], n) || wcsncmp(url + n, id, len)) continue;
        if (!url[n + len] || url[n + len] == '/') return TRUE;
    }
    return FALSE;
}

/* winebrowser passes URLs to the host; on macOS that is /usr/bin/open, which gives steam:// to Mac Steam. */
static BOOL open_on_host(WCHAR *url)
{
    static WCHAR winebrowser[] = L"C:\\windows\\system32\\winebrowser.exe";
    WCHAR *args[] = {winebrowser, url}, *cmdline;
    STARTUPINFOW si = {.cb = sizeof(si)};
    PROCESS_INFORMATION pi;
    BOOL ok;

    if (!(cmdline = join_arguments(2, args))) return FALSE;
    if ((ok = CreateProcessW(winebrowser, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)))
    {
        WaitForSingleObject(pi.hProcess, 10000);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    else report(L"cannot start winebrowser for %ls (error %lu)\n", url, GetLastError());
    free(cmdline);
    return ok;
}

static int forward_urls(int argc, WCHAR **argv)
{
    int i, status = 0;

    for (i = 1; i < argc; i++)
    {
        if (!is_steam_url(argv[i])) continue;
        if (is_self_launch(argv[i])) report(L"not forwarding %ls: this game is already running\n", argv[i]);
        else if (!open_on_host(argv[i])) status = 1;
    }
    return status;
}

/* Processes seen in the job, so their exit codes can still be read once they are gone. */
static struct child
{
    DWORD pid;
    HANDLE process;
} *children;
static size_t child_count, child_capacity;

static void track_child(DWORD pid)
{
    struct child *grown;
    HANDLE process;

    if (!(process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid))) return; /* already gone */
    if (child_count == child_capacity)
    {
        size_t capacity = child_capacity ? 2 * child_capacity : 16;

        if (!(grown = realloc(children, capacity * sizeof(*children))))
        {
            CloseHandle(process);
            return;
        }
        children = grown;
        child_capacity = capacity;
    }
    children[child_count].pid = pid;
    children[child_count++].process = process;
    trace(L"process %04lx joined the job\n", pid);
}

/* Reads the exit code of a process that left the job. Returns FALSE when it is unknown or the process is one of
 * Wine's own programs under C:\windows (conhost.exe for console programs, start.exe, winebrowser.exe, ...). The
 * image name is read now rather than when the process joins: Wine only knows it once the process has mapped its
 * executable, and keeps it for as long as we hold a handle. */
static BOOL untrack_child(DWORD pid, DWORD *exit_code)
{
    WCHAR image[MAX_PATH] = L"", windows[MAX_PATH];
    DWORD size = ARRAYSIZE(image);
    BOOL known;
    size_t i;
    UINT len;

    for (i = 0; i < child_count; i++)
    {
        if (children[i].pid != pid) continue;
        known = GetExitCodeProcess(children[i].process, exit_code)
                && QueryFullProcessImageNameW(children[i].process, 0, image, &size);
        len = GetWindowsDirectoryW(windows, ARRAYSIZE(windows));
        if (known) trace(L"process %04lx (%ls) exited with %lu\n", pid, image, *exit_code);
        known = known && !(len && !_wcsnicmp(image, windows, len) && image[len] == '\\');
        CloseHandle(children[i].process);
        children[i] = children[--child_count];
        return known;
    }
    return FALSE;
}

/* Waits until no process is left in the job. Returns the exit code of the last one to exit, not counting Wine's
 * own programs; in a launcher hand-off that is the game. Falls back to the first process's exit code. */
static DWORD wait_for_job(HANDLE job, HANDLE port, HANDLE first)
{
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
    DWORD msg, exit_code = 0, code;
    BOOL have_exit_code = FALSE, empty = FALSE;
    OVERLAPPED *data;
    ULONG_PTR key;

    for (;;)
    {
        if (!GetQueuedCompletionStatus(port, &msg, &key, &data, empty ? 0 : 5000))
        {
            if (empty) break; /* every queued message has been read */
            if (GetLastError() != WAIT_TIMEOUT)
            {
                report(L"lost track of the job (error %lu); waiting for the first process only\n", GetLastError());
                WaitForSingleObject(first, INFINITE);
                break;
            }
            /* Notifications are only a hint on Windows (the queue can overflow); the process count is not. */
            if (QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &accounting,
                                          sizeof(accounting), NULL) && !accounting.ActiveProcesses)
                empty = TRUE;
            continue;
        }
        if (key != (ULONG_PTR)job) continue;
        switch (msg)
        {
        case JOB_OBJECT_MSG_NEW_PROCESS:
            track_child((DWORD)(ULONG_PTR)data);
            break;
        case JOB_OBJECT_MSG_EXIT_PROCESS:
        case JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS:
            if (untrack_child((DWORD)(ULONG_PTR)data, &code))
            {
                exit_code = code;
                have_exit_code = TRUE;
            }
            break;
        case JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO:
            empty = TRUE;
            break;
        }
    }
    if (!have_exit_code) GetExitCodeProcess(first, &exit_code);
    trace(L"job empty, exiting with %lu\n", exit_code);
    return exit_code;
}

static DWORD run_in_job(WCHAR *cmdline, const WCHAR *cwd)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    JOBOBJECT_ASSOCIATE_COMPLETION_PORT completion;
    STARTUPINFOW si = {.cb = sizeof(si)};
    PROCESS_INFORMATION pi;
    HANDLE job, port = NULL;
    DWORD exit_code = 0;
    BOOL in_job = FALSE;

    /* Killing steam.exe takes the game down with it instead of leaving it without a live Steam pid. Breakaway
     * stays allowed, so a process that asks for it (a sandboxing browser engine, say) still starts. */
    memset(&limits, 0, sizeof(limits));
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    if ((job = CreateJobObjectW(NULL, NULL))
        && SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))
        && (port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1)))
    {
        completion.CompletionKey = job;
        completion.CompletionPort = port;
        in_job = SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, &completion,
                                         sizeof(completion));
    }
    if (!in_job) report(L"cannot set up a job object (error %lu)\n", GetLastError());

    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, NULL, cwd,
                        &si, &pi))
    {
        report(L"cannot start %ls (error %lu)\n", cmdline, GetLastError());
        return 1;
    }
    if (in_job && !AssignProcessToJobObject(job, pi.hProcess))
    {
        report(L"cannot add the game to the job (error %lu)\n", GetLastError());
        in_job = FALSE;
    }
    if (!in_job) report(L"waiting for the first process only; a launcher hand-off will end the session early\n");
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    if (in_job) exit_code = wait_for_job(job, port, pi.hProcess);
    else
    {
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &exit_code);
    }
    CloseHandle(pi.hProcess);
    return exit_code;
}

int wmain(int argc, WCHAR **argv)
{
    const WCHAR *cwd = NULL;
    WCHAR *cmdline;
    int first = 1;

    if (argc > 1 && (is_steam_url(argv[1]) || !wcscmp(argv[1], L"--"))) return forward_urls(argc, argv);

    if (argc > 1 && !wcscmp(argv[1], L"--cwd"))
    {
        if (argc < 4) first = argc; /* no directory or no program: usage */
        else
        {
            cwd = argv[2];
            first = 3;
        }
    }
    if (first >= argc)
    {
        report(L"usage: steam.exe [--cwd <dir>] <program> [<argument>...]  |  steam.exe [--] steam://<url>...\n");
        return 2;
    }
    if (argv[first][0] == '-')
    {
        /* Options for the real Windows client, such as -applaunch or -shutdown: nothing here can act on them. */
        report(L"ignoring Steam client option %ls\n", argv[first]);
        return 0;
    }
    /* Relative program names resolve against <dir> too, not only the new process's working directory. */
    if (cwd && !SetCurrentDirectoryW(cwd))
    {
        report(L"cannot change to %ls (error %lu)\n", cwd, GetLastError());
        return 1;
    }

    /* Have Wine start the desktop process (explorer.exe /desktop) now, from here, with or without a Steam
     * session: if a process in the job were the first to need it (any window, even the conhost of a console
     * program), explorer would start inside the job and the job would never become empty. */
    GetDesktopWindow();

    if (GetEnvironmentVariableW(L"SteamGameId", NULL, 0) > 1) setup_game_session();

    if (!(cmdline = join_arguments(argc - first, argv + first))) return 1;
    return (int)run_in_job(cmdline, cwd);
}
