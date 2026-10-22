/*
 * wz-steamprobe: can a Windows program reach Steam through Warzag's bridge, and is the account ready to play?
 *
 * Repeats what a game's steam_api64.dll does in SteamAPI_Init, one step at a time, and stops at the first step
 * that fails ("stage" in the output):
 *   registry    HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64 names the client DLL (the forwarder)
 *   load        LoadLibrary that DLL
 *   export      find CreateInterface in it
 *   client      CreateInterface("SteamClient023", then older versions): loads lsteamclient and steamclient.dylib
 *   pipe        ISteamClient::CreateSteamPipe          fails when Steam is not running
 *   connect     ISteamClient::ConnectToGlobalUser
 *   interfaces  GetISteamUser("SteamUser023"), GetISteamApps("STEAMAPPS_INTERFACE_VERSION008")
 *   logged_on   ISteamUser::BLoggedOn                  false when nobody is signed in to Steam
 *   owns_app    ISteamApps::BIsSubscribedApp(--appid)  false without a license for the app
 * and prints exactly one JSON line on stdout (never a Steam ID or persona name).
 *
 *   wz-steamprobe.exe [--appid <id>] [--load-only] [--timeout <seconds>]
 *
 *   --appid <id>   app to check ownership of (default 230410, Warframe)
 *   --load-only    stop after "client": proves the bridge loads, never contacts Steam (works with Steam closed)
 *   --timeout <s>  give up after this long (default 30) with stage "timeout"
 *
 * Exit status: 0 every step passed; 2 bad arguments; otherwise the first failed stage:
 *   10 registry  11 load  12 export  13 client  20 pipe  21 connect  22 interfaces  23 logged_on  24 owns_app
 *   25 timeout
 *
 * Connecting registers this process with Steam as the app named by the SteamAppId environment variable: Steam
 * shows it as playing and Family Sharing lenders are locked out while it runs, so run the full probe only to
 * diagnose sign-in or license problems. --load-only has no such effect.
 *
 * Copyright (C) 2026 Warzag contributors. Licensed under the GNU General Public License v3.0 (see LICENSE).
 */
#define WIN32_LEAN_AND_MEAN
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>

#include "jsonline.h" /* qa/pe/common */

#ifndef __x86_64__
#error "the vtable calls below assume the x86-64 Windows ABI (32-bit Steam interfaces are __thiscall)"
#endif

/*
 * Steam interfaces are C++ objects: the first word of an object points to its vtable. Only the slots used here
 * have names. Indices are declaration order in the Steamworks SDK headers that ship with Proton's lsteamclient
 * (none of these classes has overloaded virtuals, so the MSVC layout is the same), the same slots as the Windows
 * vtables Proton generates (winISteamClient.c, winISteamUser.c, winISteamApps.c):
 *
 *   ISteamClient, SteamClient017 to SteamClient023 (steamworks_sdk_165/isteamclient.h)
 *      0 CreateSteamPipe   1 BReleaseSteamPipe   2 ConnectToGlobalUser   4 ReleaseUser
 *      5 GetISteamUser    15 GetISteamApps
 *   ISteamUser, SteamUser023 (steamworks_sdk_165/isteamuser.h)            1 BLoggedOn
 *   ISteamApps, STEAMAPPS_INTERFACE_VERSION008 (steamworks_sdk_162/isteamapps.h)   6 BIsSubscribedApp
 *
 * x86-64 Windows has a single calling convention: `this` is the first argument and a C++ bool comes back in AL.
 */
typedef int32_t HSteamPipe;
typedef int32_t HSteamUser;

struct steam_client_vtbl
{
    HSteamPipe (*CreateSteamPipe)(void *self);
    uint8_t (*BReleaseSteamPipe)(void *self, HSteamPipe pipe);
    HSteamUser (*ConnectToGlobalUser)(void *self, HSteamPipe pipe);
    void *CreateLocalUser;
    void (*ReleaseUser)(void *self, HSteamPipe pipe, HSteamUser user);
    void *(*GetISteamUser)(void *self, HSteamUser user, HSteamPipe pipe, const char *version);
    void *slots_6_to_14[9];
    void *(*GetISteamApps)(void *self, HSteamUser user, HSteamPipe pipe, const char *version);
};

struct steam_user_vtbl
{
    void *GetHSteamUser;
    uint8_t (*BLoggedOn)(void *self);
};

struct steam_apps_vtbl
{
    void *slots_0_to_5[6];
    uint8_t (*BIsSubscribedApp)(void *self, uint32_t app_id);
};

#define SLOT(type, field) (offsetof(struct type, field) / sizeof(void *))
_Static_assert(SLOT(steam_client_vtbl, CreateSteamPipe) == 0, "ISteamClient::CreateSteamPipe");
_Static_assert(SLOT(steam_client_vtbl, BReleaseSteamPipe) == 1, "ISteamClient::BReleaseSteamPipe");
_Static_assert(SLOT(steam_client_vtbl, ConnectToGlobalUser) == 2, "ISteamClient::ConnectToGlobalUser");
_Static_assert(SLOT(steam_client_vtbl, ReleaseUser) == 4, "ISteamClient::ReleaseUser");
_Static_assert(SLOT(steam_client_vtbl, GetISteamUser) == 5, "ISteamClient::GetISteamUser");
_Static_assert(SLOT(steam_client_vtbl, GetISteamApps) == 15, "ISteamClient::GetISteamApps");
_Static_assert(SLOT(steam_user_vtbl, BLoggedOn) == 1, "ISteamUser::BLoggedOn");
_Static_assert(SLOT(steam_apps_vtbl, BIsSubscribedApp) == 6, "ISteamApps::BIsSubscribedApp");

/* Newest first: SteamClient023 is the version in steamworks_sdk_165, the newest SDK the pinned Proton wraps. */
static const char *const client_versions[] = {
    "SteamClient023", "SteamClient021", "SteamClient020", "SteamClient019", "SteamClient018", "SteamClient017",
};

#define VTBL(iface, type) (*(const struct type *const *)(iface))

typedef void *(*create_interface_fn)(const char *name, int *return_code);

static const struct
{
    const char *name;
    int exit_code;
} stages[] = {
    {"registry", 10}, {"load", 11},       {"export", 12},    {"client", 13},   {"pipe", 20},
    {"connect", 21},  {"interfaces", 22}, {"logged_on", 23}, {"owns_app", 24}, {"timeout", 25},
};

struct probe
{
    uint32_t appid;
    BOOL load_only;
    BOOL steamclient_loaded, pipe, logged_on, owns_app;
    const char *stage;     /* first failed stage; NULL when everything passed */
    DWORD error;           /* Win32 error of the call that failed, when there is one */
    const char *interface; /* the SteamClient version CreateInterface accepted */
    WCHAR client_dll[MAX_PATH];
};

static struct probe probe = {.appid = 230410};
static volatile LONG finished; /* set by whichever of the main thread and the watchdog reports */

static void fail(const char *stage, DWORD error)
{
    if (probe.stage) return;
    probe.stage = stage;
    probe.error = error;
}

static int exit_code(void)
{
    size_t i;

    if (!probe.stage) return 0;
    for (i = 0; i < ARRAYSIZE(stages); i++)
        if (!strcmp(stages[i].name, probe.stage)) return stages[i].exit_code;
    return 1;
}

/* Prints the JSON line; returns the exit code. */
static int report(void)
{
    struct jsonline j = {0};

    jl_bool(&j, "steamclient_loaded", probe.steamclient_loaded);
    jl_bool(&j, "pipe", probe.pipe);
    jl_bool(&j, "logged_on", probe.logged_on);
    jl_bool(&j, "owns_app", probe.owns_app);
    jl_int(&j, "appid", probe.appid);
    jl_bool(&j, "load_only", probe.load_only);
    jl_bool(&j, "ok", !probe.stage);
    if (probe.stage) jl_str(&j, "stage", probe.stage);
    if (probe.error) jl_int(&j, "error", probe.error);
    if (probe.interface) jl_str(&j, "interface", probe.interface);
    if (probe.client_dll[0]) jl_wstr(&j, "client_dll", probe.client_dll);
    jl_print(&j, INVALID_HANDLE_VALUE);
    return exit_code();
}

/* Steam's IPC can block, e.g. while the client starts or updates; a stuck probe would stall Warzag's checks. */
static DWORD WINAPI watchdog(void *timeout_ms)
{
    Sleep((DWORD)(ULONG_PTR)timeout_ms);
    if (InterlockedCompareExchange(&finished, 1, 0)) return 0; /* the main thread got there first */
    fail("timeout", 0);
    ExitProcess((UINT)report());
}

static void run(void)
{
    DWORD size = sizeof(probe.client_dll);
    void *client = NULL, *steam_user, *steam_apps;
    create_interface_fn create_interface;
    HSteamPipe pipe;
    HSteamUser user;
    LSTATUS status;
    HMODULE module;
    size_t i;
    int rc;

    if ((status = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", L"SteamClientDll64",
                               RRF_RT_REG_SZ, NULL, probe.client_dll, &size)))
    {
        probe.client_dll[0] = 0;
        fail("registry", (DWORD)status);
        return;
    }
    /* The flags steam_api uses, so the DLL's own directory is searched for its dependencies. */
    if (!(module = LoadLibraryExW(probe.client_dll, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)))
    {
        fail("load", GetLastError());
        return;
    }
    /* For a forwarder this also loads the DLL the export forwards to, i.e. lsteamclient.dll. */
    if (!(create_interface = (create_interface_fn)(void *)GetProcAddress(module, "CreateInterface")))
    {
        fail("export", GetLastError());
        return;
    }

    for (i = 0; i < ARRAYSIZE(client_versions) && !client; i++)
    {
        rc = 0;
        if ((client = create_interface(client_versions[i], &rc))) probe.interface = client_versions[i];
    }
    if (!client)
    {
        fail("client", 0);
        return;
    }
    probe.steamclient_loaded = TRUE;
    if (probe.load_only) return;

    if (!(pipe = VTBL(client, steam_client_vtbl)->CreateSteamPipe(client)))
    {
        fail("pipe", 0);
        return;
    }
    probe.pipe = TRUE;
    if (!(user = VTBL(client, steam_client_vtbl)->ConnectToGlobalUser(client, pipe)))
    {
        fail("connect", 0);
        VTBL(client, steam_client_vtbl)->BReleaseSteamPipe(client, pipe);
        return;
    }

    steam_user = VTBL(client, steam_client_vtbl)->GetISteamUser(client, user, pipe, "SteamUser023");
    steam_apps = VTBL(client, steam_client_vtbl)->GetISteamApps(client, user, pipe, "STEAMAPPS_INTERFACE_VERSION008");
    if (!steam_user || !steam_apps) fail("interfaces", 0);
    else if (!(probe.logged_on = !!VTBL(steam_user, steam_user_vtbl)->BLoggedOn(steam_user))) fail("logged_on", 0);
    else if (!(probe.owns_app = !!VTBL(steam_apps, steam_apps_vtbl)->BIsSubscribedApp(steam_apps, probe.appid)))
        fail("owns_app", 0);

    /* Ends the connection, so Steam stops showing the app as running. */
    VTBL(client, steam_client_vtbl)->ReleaseUser(client, pipe, user);
    VTBL(client, steam_client_vtbl)->BReleaseSteamPipe(client, pipe);
}

static const char usage[] =
    "usage: wz-steamprobe.exe [--appid <id>] [--load-only] [--timeout <seconds>]\n"
    "  --appid <id>     app to check ownership of (default 230410)\n"
    "  --load-only      only load the Steam client through the bridge; never contact Steam\n"
    "  --timeout <s>    give up after this many seconds (default 30)\n";

static BOOL parse_number(const WCHAR *s, unsigned long max, unsigned long *value)
{
    WCHAR *end;

    if (!s || !*s || *s == '-') return FALSE;
    *value = wcstoul(s, &end, 10);
    return !*end && *value && *value <= max;
}

int wmain(int argc, WCHAR **argv)
{
    unsigned long value, timeout = 30;
    DWORD written;
    HANDLE thread;
    int i;

    for (i = 1; i < argc; i++)
    {
        if (!wcscmp(argv[i], L"--load-only")) probe.load_only = TRUE;
        else if (!wcscmp(argv[i], L"--appid") && parse_number(argv[i + 1], 0xffffffff, &value))
        {
            probe.appid = (uint32_t)value;
            i++;
        }
        else if (!wcscmp(argv[i], L"--timeout") && parse_number(argv[i + 1], 600, &value))
        {
            timeout = value;
            i++;
        }
        else
        {
            BOOL help = !wcscmp(argv[i], L"--help") || !wcscmp(argv[i], L"-h");

            WriteFile(GetStdHandle(help ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE), usage, sizeof(usage) - 1,
                      &written, NULL);
            return help ? 0 : 2;
        }
    }

    if ((thread = CreateThread(NULL, 0, watchdog, (void *)(ULONG_PTR)(timeout * 1000), 0, NULL)))
        CloseHandle(thread);
    run();
    if (InterlockedCompareExchange(&finished, 1, 0)) Sleep(INFINITE); /* the watchdog is reporting and exiting */
    return report();
}
