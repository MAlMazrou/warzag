# Engine patches

`runtime/n/build.sh` applies these patches, in this order, to the sources pinned in `runtime/n/inputs.lock.json`:

| Directory | Applied to | How |
|---|---|---|
| `llvm-mingw/` | the llvm-mingw 20260908 toolchain | `patch -p1` |
| `wine/` | the Wine 11.19 tarball | `patch -p1`, `0001` to `0017` in order |
| `proton/` | Proton's `lsteamclient/`, copied into the Wine tree as `dlls/lsteamclient` | `patch -p1` in that folder |
| `warzag/wz-n-proton-*` | the same `dlls/lsteamclient` | `patch -p1`, after `proton/` |
| `warzag/wz-n-0*` | the Wine tree | `patch -p1`, after `wine/` and the lsteamclient copy; then `autoreconf -f` |
| `fex/` | FEX-2610 (`14c92681`) | `git apply`, in order |
| `dxmt/` | DXMT `e94c312f` | `git apply`, in order |
| `warzag/wz-n-dxmt-*` | the same DXMT tree | `git apply`, after `dxmt/` |

A patch that does not apply stops the build. `SHA256SUMS` lists every patch file (`shasum -a 256 -c SHA256SUMS`).

## neutron's patches

Everything in `wine/`, `fex/`, `dxmt/`, `llvm-mingw/` and `proton/` is an unchanged copy of neutron's `patches/`
directory (https://github.com/lixsldotnet/neutron, commit `0ac2574d46c186664f40b8efd0410e3d8145aa14`), without the
two patches Warzag skips (below). Each patch starts with neutron's description, and neutron's `docs/neutron.md` at
that commit explains them. The Wine series is one unit: neutron keeps each file in exactly one patch, so a feature
can span several patches, and a subset does not build.

neutron's own files are LGPL-2.1-or-later, and each patch is under the license of the project it changes: the Wine
and DXMT patches LGPL-2.1-or-later, the FEX patches MIT, the llvm-mingw patch that of mingw-w64's `winnt.h`
(ZPL-2.1 and public domain), and the lsteamclient patches the Steamworks SDK license of Valve's lsteamclient, whose
sources are fetched at build time and never committed. The LGPL-2.1 text is `runtime/licenses/Wine-COPYING.LIB.txt`;
the other license texts come with the pinned sources, and the engine ships them in `Contents/Resources/licenses` and
`Contents/share/warzag/bridge/licenses`.

| Skipped | Why |
|---|---|
| `dxmt/0006-cache-in-compatdata.patch` | It moves DXMT's shader cache into Steam's `compatdata` when `DXMT_SHADER_CACHE_PATH` is set, which Warzag never sets. No later patch depends on it. |
| `proton/0003-steam-helper-macos.patch` | It changes Proton's `steam_helper`, which Warzag does not build (`wz-n-0005`): Warzag ships its own `steam.exe` (`bridge/steam-shim`). |

neutron's Steam integration (its compat-tool script, the Steam.app change, `steam_dev.cfg`, the CEF hook and the
`compatibilitytools.d` manifests) is not used: Warzag never changes Steam.app or Steam's files.

### NEUTRON_* switches

Some patches are switched by environment variables. Warzag's Wine environment sets `NEUTRON_PRECISE_TIMERS`,
`NEUTRON_FAST_QPC`, `NEUTRON_RAW_MOUSE`, `NEUTRON_NATIVE_FULLSCREEN`, `NEUTRON_RENDER_SCALE` and `NEUTRON_MSYNC`
explicitly, to these defaults (`WineEnvironment.neutronDefaults`).

| Variable | Patch | Default |
|---|---|---|
| `NEUTRON_PRECISE_TIMERS` | wine 0012 | on: kqueue timers for `NtDelayExecution` (`0` turns it off) |
| `NEUTRON_FAST_QPC` | wine 0003, 0012, 0016 | on: `QueryPerformanceCounter` from the commpage after a self-check (`0` turns it off) |
| `NEUTRON_RAW_MOUSE` | wine 0010, 0014 | on: raw mouse input from GameController's `GCMouse` (`0` uses Wine's NSEvent deltas) |
| `NEUTRON_NATIVE_FULLSCREEN` | wine 0007, 0009 | off |
| `NEUTRON_RENDER_SCALE` | wine 0010 | 1.0 |
| `NEUTRON_MSYNC`, `NEUTRON_MSYNC_SPIN` | wine 0015, `wz-n-0006` | off: Wine's server-side sync (`1` turns msync on) |
| `NEUTRON_PAD_SYSTEM_GESTURES` | wine 0010, 0017 | the gamepad's Home and Share buttons go to the game (`1` keeps the macOS gestures) |
| `NEUTRON_PAD_HIDRAW`, `NEUTRON_PAD_VIRTUAL` | wine 0017 | off |
| `NEUTRON_APP_NAME` | wine 0007 | the bundle's `CFBundleName` (Warzag) |
| `NEUTRON_APP_BUNDLE`, `NEUTRON_NTDLL` | wine 0003, 0006 | unused: `wz-n-0001` takes precedence |
| `NEUTRON_SANDBOX` | wine 0003 | no effect outside a macOS sandbox |
| `NEUTRON_STEAMCLIENT_DYLIB` | proton 0001 | lsteamclient uses `STEAM_COMPAT_CLIENT_INSTALL_PATH` |
| `NEUTRON_HUD_INFO`, `NEUTRON_HUD`, `NEUTRON_FPS_LOG`, `NEUTRON_BENCH_NOVSYNC`, `NEUTRON_LAYER_FORMAT`, `NEUTRON_NATIVE_DRAWABLE`, `NEUTRON_DXMT_WRITE_COMBINED` | dxmt 0003, 0004, 0007, 0010, 0011, 0019 | the series' defaults: 10-bit layer format and native drawable size on, write-combining off |

## Warzag's patches (`warzag/`)

Each is under the license of the project it changes.

| Patch | What it does |
|---|---|
| `wz-n-0001-loader-bundle-main-executable` | The loader is `Warzag.app/Contents/MacOS/wine` and child processes start through it, so every Wine process has the bundle's identity (Game Mode, Dock). Takes precedence over neutron's `Neutron.app` and `NEUTRON_APP_BUNDLE`. |
| `wz-n-0002-loader-info-plist-identity` | The loader's embedded `Info.plist`: `com.warzag.gamehost`, "Warzag", the action-games category and the Game Mode keys. |
| `wz-n-0003-ntdll-winedllpath-prepend` | `WINEDLLPATH_PREPEND`, searched before Wine's own DLLs, so the DXMT overlay in `renderers/dxmt` wins over Wine's d3d11 and dxgi. Ported from highball-engine's patch 0003, which comes from MacPorts' game-porting-toolkit port. |
| `wz-n-0004-wineinf-fex-x64-emulator` | `wine.inf` registers `libarm64ecfex.dll` as the x86-64 emulator (`HKLM\Software\Microsoft\Wow64\amd64`), so every new prefix runs x86-64 code under FEX. Wine's own `xtajit64.dll` is a stub. |
| `wz-n-0005-configure-no-steam-helper` | Proton's `steam_helper` is not built: Warzag ships its own `steam.exe`. |
| `wz-n-0006-server-msync-opt-in` | msync only with `NEUTRON_MSYNC=1`, as wine 0015 describes it (its wineserver enables msync unless the variable is `0`). With msync on, the wineserver can wait forever for a lock when a prefix's last process exits. |
| `wz-n-0007-ntdll-unaligned-shared-section-private-copy` | A writable shared image section that does not fill whole 16K host pages is mapped as a private copy instead of failing the image (`c000007b`). Digital Extremes' `Launcher.exe` and `Warframe.x64.exe` each have such a section. Only sharing it between processes is lost. |
| `wz-n-0008-winemac-sharp-app-icon` | The Dock icon is one image with every size, the densest first. |
| `wz-n-0009-winemac-app-icon-entries-static` | The icon entries winemac.drv passes to its unix side are static: from a stack array, only the first entry arrives intact in an ARM64EC process. |
| `wz-n-0010-winemac-hide-windows` | `WARZAG_HIDE_WINDOWS=1` keeps a process's windows off the screen and out of the Dock while it keeps working. Warzag sets it for Digital Extremes' launcher when it only updates the game. |
| `wz-n-0011-ntdll-exiting-thread-tsd-fault` | A Wine thread whose pthread TSD destructor faults while it exits finishes exiting, instead of retrying the fault forever and keeping the process from exiting. `abort()` and traps in such a thread, and faults in threads without Wine data, stay fatal. Test: `qa/n/exit-hang.sh`. |
| `wz-n-proton-0001-lsteamclient-ndebug` | lsteamclient is built with `NDEBUG`: without Mac Steam, `CreateInterface` fails and Warframe falls back to its own login instead of aborting. |
| `wz-n-dxmt-0001-airconv-shaders-from-stdin` | airconv's Metal helper shaders are compiled from stdin, so `winemetal.so` does not record the path of the build folder. The code is the same. |
| `wz-n-dxmt-0002-winemetal-owned-errors-and-pools` | DXMT holds its own reference to each NSError Metal returns, so an exiting thread's autorelease pool never releases a freed error, and runs its pipeline tasks and per-frame display queries in autorelease pools. Test: `qa/n/pso-reject.sh`. |
