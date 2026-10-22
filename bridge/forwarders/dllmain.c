/*
 * steamclient64.dll of Warzag's Steam bridge.
 *
 * A game's steam_api64 loads the DLL named by HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64. This DLL
 * carries no code: every export forwards to Wine's builtin lsteamclient.dll (steamclient64.def), which talks to the
 * native Mac Steam. It keeps Steam's file name because Steamworks DRM looks the module up again by name.
 *
 * Built with -nostdlib: no C runtime and no imports, only this entry point.
 *
 * Copyright (C) 2026 Warzag contributors. Licensed under the GNU General Public License v3.0 (see LICENSE).
 */
#include <windef.h>

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance;
    (void)reason;
    (void)reserved;
    return TRUE;
}
