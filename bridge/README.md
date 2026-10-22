# Steam bridge

The bridge lets Warframe's Windows `steam_api64.dll`, running in Warzag's engine, talk to the Steam app on the Mac. It
is Valve's Proton `lsteamclient` built for macOS, plus small Windows programs and registry values that make the Wine
prefix look like a Windows machine with Steam running. Warzag never changes Steam.app or Steam's files and never sees
credentials: sign-in, ownership and tickets stay in Valve's client.

```
Warframe.x64.exe
  steam_api64.dll      reads HKCU\Software\Valve\Steam\ActiveProcess: is "pid" alive? load SteamClientDll64
    C:\Program Files (x86)\Steam\steamclient64.dll     forwarders/: every export goes to lsteamclient
      lsteamclient.dll   Wine builtin (aarch64-windows, ARM64X), Valve's code with runtime/n/patches
        lsteamclient.so  its Unix library (aarch64-unix), loads the Mac client's steamclient.dylib
          Mac Steam, through Steam's own IPC
```

## Files

| Path | What | License |
|---|---|---|
| `forwarders/` | `steamclient64.dll`: every export forwarded to lsteamclient | GPL-3.0 |
| `steam-shim/steam.c` | `steam.exe`, the running Steam that steam_api checks for, adapted from Proton's `steam_helper` | BSD-3-Clause (`steam-shim/LICENSE`) |
| `steamprobe/steamprobe.c` | `wz-steamprobe.exe`: bridge, Steam, sign-in and license state as one JSON line | GPL-3.0 |
| `prefix/steam.reg` | the registry values of a prefix | GPL-3.0 |
| `install-prefix.sh` | puts the bridge into a Wine prefix, as the app does (development and tests) | GPL-3.0 |
| `lsteamclient/interfaces.sh` | compares the interface versions in the Mac client with those lsteamclient wraps | GPL-3.0 |

## Building

`runtime/n/build.sh` builds the bridge with the engine. `wine-src` copies `lsteamclient/` from the pinned Proton
commit into the Wine tree and applies neutron's and Warzag's patches; `wine` builds it like any Wine module; `bridge`
builds the forwarder (mingw-w64 GCC, x86-64), `steam.exe` (llvm-mingw, arm64) and `wz-steamprobe.exe` (x86-64, so
it runs under FEX like the game) and checks that the forwarder's exports match `lsteamclient.spec`;
`install` puts everything into the engine:

```
Contents/lib/wine/aarch64-windows/lsteamclient.dll
Contents/lib/wine/aarch64-unix/lsteamclient.so
Contents/share/warzag/bridge/
  steam.exe  wz-steamprobe.exe  steamclient64-forwarder.dll  steam.reg  NOTICE  licenses/
```

What the macOS build changes in lsteamclient:

| Change | Patch | Why |
|---|---|---|
| `-DNDEBUG` | `wz-n-proton-0001` | Without Mac Steam, `CreateInterface` returns NULL and Warframe falls back to its own login, instead of a failed assertion ending the game. |
| `Steam_IsKnownInterface` and `Steam_NotifyMissingInterface` optional | neutron `proton/0001` | The Mac `steamclient.dylib` exports neither. |
| macOS virtual key codes | neutron `proton/0001` | Proton's code only knows X11 keysyms. |
| libc++ headers before Wine's, `-lc++` | neutron `proton/0001`, `0002` | Wine's headers turn functions libc++ uses into compile errors. |

## In a prefix

The app copies the prefix-side files into `C:\Program Files (x86)\Steam` of every prefix
(`bridge/install-prefix.sh --prefix <dir>` does the same):

```
steam.exe
steamclient64.dll   <- steamclient64-forwarder.dll
wz-steamprobe.exe
```

The forwarder ships under another name because `tools/release/forbidden-scan.py` reserves `steamclient64.dll` for
Valve's own DLL, which Warzag never ships. In the prefix it needs Steam's name: steam_api64 loads the file the registry
names, and Steamworks DRM looks the module up by name.

| Registry key | Values |
|---|---|
| `HKCU\Software\Valve\Steam\ActiveProcess` | `SteamClientDll64` (the forwarder), `SteamPath`, `Universe`; `pid`, set by `steam.exe` |
| `HKCU\Software\Valve\Steam` | `SteamPath`, `SteamExe`; `language` (`english` unless set), set by `steam.exe` |
| `HKLM\Software\Valve\Steam`, `HKLM\Software\Wow6432Node\Valve\Steam` | `InstallPath` |
| `HKCR\steam\shell\open\command` | `steam://` links go to `steam.exe` |

`steam.reg` holds the static values, and `steam.exe` writes the HKCU values again in every game session. steam_api
counts Steam as running while `ActiveProcess\pid` names a live process, so `steam.exe` outlives the launcher.

A game session's environment (WineKit):

| Variable | Value | Why |
|---|---|---|
| `SteamAppId`, `SteamGameId`, `SteamOverlayGameId`, `STEAM_COMPAT_APP_ID` | `230410` | the app Steam sees; `SteamGameId` makes `steam.exe` set up a game session |
| `STEAM_COMPAT_CLIENT_INSTALL_PATH` | the Mac client's `Contents/MacOS` folder | where lsteamclient finds `steamclient.dylib` |
| `WINEDLLOVERRIDES` | `steamclient64=n;lsteamclient=b` | the forwarder, then lsteamclient |
| `SteamDeck` | `0` | |

`SteamClientLaunch` and `SteamAppUser` are never set (the second exposes the account name), and no `steam_appid.txt`
is created.

## steam.exe

```
steam.exe [--cwd <dir>] <program> [<argument>...]    run <program>, the launcher or the game
steam.exe [--] steam://<url> [...]                   hand steam:// URLs to Mac Steam
```

`steam.exe` writes the registry values, creates the events and the hidden window steam_api looks for, and starts the
program in a job object that ends everything in it when `steam.exe` ends. It exits once the job is empty, with the
game's exit code; 1 means a wrong program or folder, 2 bad arguments. `steam://` URLs go to Mac Steam through
`winebrowser` and `/usr/bin/open`, except `run`, `rungameid` and `launch` URLs for the game being played, which Mac
Steam cannot start.

## wz-steamprobe.exe

```
wz-steamprobe.exe [--appid <id>] [--load-only] [--timeout <seconds>]
```

It repeats `SteamAPI_Init` one step at a time and prints one JSON line, never with a Steam ID or name. Exit status:
0 passed, 2 bad arguments, 10 to 13 the bridge (registry, load, export, client), 20 Steam not running, 21 connect,
22 interfaces, 23 nobody signed in, 24 no license, 25 timeout. A full run registers with Steam as the game for a
moment, so Steam shows it as playing; `--load-only` never contacts Steam.

## Licensing

- `lsteamclient.dll` and `lsteamclient.so` are Valve's lsteamclient under the Steamworks SDK license. Its sources are
  fetched from Valve at build time and never committed, and the patches in `runtime/n/patches/proton/` and
  `runtime/n/patches/warzag/wz-n-proton-*` apply only to them. It is not linked with GPL code.
- `steam.exe`: BSD-3-Clause, Copyright Valve Corporation and Warzag contributors.
- The forwarder, `wz-steamprobe.exe`, `steam.reg` and the scripts: GPL-3.0.
- The engine ships these license texts in `share/warzag/bridge/licenses`, and `runtime/n/bridge-NOTICE` as `NOTICE`.
- Valve has not explicitly allowed redistributing lsteamclient outside Proton, so the bridge is kept separable:
  without it, Warframe still runs with a Warframe account.
