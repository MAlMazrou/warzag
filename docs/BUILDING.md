# Building Warzag

Warzag has two parts, built separately:

- the app, `Warzag.app` (Swift, `Sources/`), with its command-line tool `warzagctl`;
- the engine, the game host that the app downloads as a signed runtime pack: native arm64 Wine 11.19 with FEX for
  x86-64 code, DXMT for Direct3D and the Steam bridge (`runtime/n`, `bridge/`).

## Requirements

- A Mac with Apple silicon and macOS 15 or later
- Xcode 26; for the engine also its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- Homebrew: `brew install bison flex autoconf automake cmake ninja meson pkgconf jq mingw-w64`
- Python 3

`tools/doctor.sh` checks the Mac. `runtime/toolchain.lock.json` records the tool versions releases are built with.

## The app

```sh
swift build                                  # every product, debug build
App/make-app.sh --identity adhoc             # build/app/Warzag.app (release build, signed ad hoc)
```

`App/make-app.sh` builds `WarzagApp` and `warzagctl` for arm64, assembles and signs the bundle and, with `--dmg`,
also writes `Warzag.dmg`, `install.sh` and the update archive into `dist/`. Without `--identity adhoc` it signs with
the project certificate. `--feed-url` and `--update-url` set where the app gets its engine and its own updates; a
build without them has neither (see [RELEASING.md](RELEASING.md)).

After changing `Sources/WarzagApp/Model/Strings.swift`, regenerate the string catalog with
`python3 -I App/strings-catalog.py`; `make-app.sh` refuses an outdated one.

Demo mode simulates every step without Wine, Steam or Digital Extremes' servers:
`open -n --env WARZAG_DEMO=1 build/app/Warzag.app`. `Sources/WarzagApp/Model/LaunchOptions.swift` lists the other
launch options.

## The engine

The engine is built from pinned upstream sources and the patches in this repository. Inputs and build output go to
`~/Library/Caches/warzag-build` (or `$WARZAG_CACHE`), which needs about 10 GB; nothing is written into the
repository. The paths of the cache and the checkout must not contain spaces, quotes, backslashes, `&`, `|` or `=`.

```sh
runtime/n/fetch.sh             # download and verify every input
runtime/n/build.sh             # build every stage
runtime/n/make-host.sh         # build/n/Warzag.app
```

### Inputs

- `runtime/n/inputs.lock.json`: Wine, llvm-mingw, SDL3, sdl2-compat, Proton (for lsteamclient), FEX, DXMT, LLVM and
  mingw-w64, each pinned by SHA-256 or git commit.
- `runtime/inputs.lock.json`: GMP, GnuTLS and FreeType (CodeWeavers' CrossOver source archive) and Nettle.

`fetch.sh` checks the size and SHA-256 of every archive and the commit of every checkout. `--check-digests` also
compares GitHub's release digests, and `--verify-signatures` checks Wine's OpenPGP signature (needs gpg and the WineHQ
key).

### Patches

`runtime/n/patches` holds neutron's patches for Wine, FEX, DXMT, llvm-mingw and lsteamclient, and Warzag's own in
`warzag/`. Its README says where each series comes from and in which order `build.sh` applies them.

### Stages

`runtime/n/build.sh [--jobs N] [--redo] [--with-mono] [stage ...]` runs these stages in order:

| Stage | Builds |
|---|---|
| `toolchain` | llvm-mingw with a patched `winnt.h` and rebuilt CRT startup objects |
| `deps` | GMP, Nettle, GnuTLS, FreeType, SDL3 and sdl2-compat for arm64 |
| `wine-src` | the Wine source tree: the tarball, the patches and lsteamclient |
| `wine` | Wine (arm64 Unix side, ARM64EC and ARM64 Windows side) and the Wine SDK DXMT builds against |
| `llvm` | the LLVM 15 libraries for DXMT's shader converter |
| `fex` | FEX as an ARM64EC DLL and its macOS library |
| `dxmt` | DXMT's DLLs and `winemetal.so` |
| `bridge` | the Steam bridge's Windows programs (`bridge/`) |
| `install` | the engine's `Contents/`, in the cache |

A finished stage is skipped on the next run. `--redo` rebuilds the named stages (every stage without names), and a
stage that runs again also invalidates the stages built from it. The `install` stage fails if anything in the engine
names the build machine: the home folder, the user name, the cache or the checkout. `--with-mono` adds Wine Mono to
the engine (`runtime/n/fetch.sh wine-mono` fetches it). The `make` stage, never run by default, is an incremental
`make` in the configured Wine tree, for development.

`runtime/n/make-host.sh [--version <x.y.z>] [--out <dir>] [--sign adhoc|none]` turns the stage into
`build/n/Warzag.app`. It checks that every Mach-O file is arm64-only and every Windows file ARM64 (except the bridge's
x86 programs), adds the license texts and signs the bundle ad hoc (`--sign none` leaves it unsigned).

### Rebuilding a released engine

From the release's tag:

```sh
runtime/n/fetch.sh --check-digests
CCACHE_DISABLE=1 runtime/n/build.sh --redo
runtime/n/make-host.sh --version <engine version>
```

Builds are not bit-for-bit identical: link timestamps differ. A release that ships an engine also publishes
`Warzag-engine-source-<version>.tar.gz`, the upstream sources of the engine's LGPL components (Wine, DXMT, GnuTLS, GMP
and Nettle).

To run Warzag with an engine you built, start it with
`open --env WARZAG_DEV_RUNTIME=<path to the engine's Warzag.app> /Applications/Warzag.app`, or register the engine with
`warzagctl runtime use-local <path>` (`warzagctl` is in `Warzag.app/Contents/Helpers`).

## Tests

```sh
swift build --build-tests -Xswiftc -warnings-as-errors
swift test                       # the app and its libraries, against fakes (no Wine, Steam or Digital Extremes)
qa/packaging/run.sh --quick      # the release scanner, the changelog tool and code signing
qa/packaging/run.sh              # also runtime packs, the app, the disk image and app updates
```

The full packaging run needs the project signing identity and `build/n/Warzag.app`. With `WARZAG_WARFRAME_MSI` set to
a downloaded Warframe.msi, `swift test` also checks Digital Extremes' signature on it.

The engine tests need `build/n/Warzag.app` and the Windows test programs (`make -C qa/pe`). They use their own scratch
Wine prefixes (in the build cache or a temporary folder), never Warzag's own:

| Command | Checks |
|---|---|
| `qa/n/smoke.sh` | the prefix boots, the Steam bridge loads the Mac Steam client, Direct3D 11 runs on DXMT (it opens a window), and no process runs under Rosetta. Its `winhttp` step sends one request to Digital Extremes' content server; `--only <steps>` runs a subset |
| `qa/n/exit-hang.sh` | a thread whose exit faults in a TSD destructor still exits (`wz-n-0011`) |
| `qa/n/pso-reject.sh` | a pipeline Metal rejects leaves no freed object in DXMT's worker threads (`wz-n-dxmt-0002`) |
| `qa/pe/gpu-smoke.sh` | Direct3D 11 on DXMT, with and without NVEXT |
| `qa/n/winhttp-local.sh` | WinHTTP downloads from a local server |
| `qa/n/path-map-probe.sh`, `qa/n/release-flags-check.sh` | the release build's path maps, without building an engine |
