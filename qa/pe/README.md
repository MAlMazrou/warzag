# Windows test programs

Small C programs, built with Homebrew's mingw-w64, that check the engine from the Windows side the way a game or
Digital Extremes' launcher uses it. Each prints exactly one JSON line on stdout; `--out <file>` writes the same line to
a file (a Windows path such as `Z:\tmp\out.json`). Exit status: 0 passed, 1 a stage failed (the line names it), 2 bad
arguments.

| Program | Checks |
|---|---|
| `wz-d3d11-smoke.exe` | Direct3D 11 reaches a window, and which implementation drew it: DXMT or Wine's own |
| `wz-d3d11-pso-reject.exe` | a pipeline Metal rejects leaves nothing freed in DXMT's worker threads |
| `wz-winhttp-probe.exe` | Wine's WinHTTP downloads Digital Extremes' content index over TLS, completely |

## Build

```sh
make -C qa/pe          # build/pe/*.exe
make -C qa/pe check    # x86-64 console programs that import only Windows system DLLs
```

The compiler is pinned in `runtime/toolchain.lock.json`, and warnings are errors (`make WERROR=` relaxes that).
`CFLAGS` and `LDFLAGS` from the environment are ignored because they usually belong to the Mac compiler; pass them on
the make command line instead.

## Run

```sh
P=~/Library/Caches/warzag-build/prefixes/qa-pe
WINEDLLOVERRIDES='mscoree,mshtml=' runtime/dev-wine.sh --prefix $P --renderer dxmt wineboot -i     # once
runtime/dev-wine.sh --prefix $P --renderer dxmt build/pe/wz-d3d11-smoke.exe
qa/pe/gpu-smoke.sh     # the smoke test with and without NVEXT, with a verdict for each
```

Boot the prefix with `--renderer dxmt`: wineboot then adds the system32 placeholders for DXMT's DLLs, without which
every DXMT run fails at stage `d3d11_load`. Wine and DXMT log to stderr; scripts should still read the last line of
stdout, or use `--out`. A run passed only when the exit status is 0 and `ok` is true.

## wz-d3d11-smoke.exe

```
wz-d3d11-smoke.exe [--frames N] [--sync-interval 0-4] [--fullscreen] [--discard] [--out <file>]
```

It opens a 1280x720 window, creates a D3D11 device and a flip-discard swap chain (legacy discard as the fallback),
then clears and presents N frames (default 300). The line reports the adapter, feature level, swap effect, frame
times and, in `d3d11_impl` and `dxgi_impl`, the implementation actually loaded: `dxmt` when `d3d11.dll` and
`dxgi.dll` import `winemetal.dll`, `wined3d` for Wine's own. Under Wine every builtin reports a system32 path, so the
imports are the only reliable sign. DXMT reports Apple's vendor ID `0x106B`, and NVIDIA's `0x10DE` with
`DXMT_ENABLE_NVEXT=1`. `gpu-smoke.sh` checks the two runs as a pair, because Wine's own DXGI reports `0x10DE` too.

## wz-d3d11-pso-reject.exe

```
wz-d3d11-pso-reject.exe [--pipelines N] [--frames N] [--out <file>]
```

It draws with a vertex and pixel shader pair that Metal refuses to link, so DXMT compiles a rejected pipeline on its
worker threads, then releases the device and waits until those threads have exited. `qa/n/pso-reject.sh` builds it,
runs it with `NSZombieEnabled=YES` and judges the run (`wz-n-dxmt-0002`).

## wz-winhttp-probe.exe

```
wz-winhttp-probe.exe [--url <http(s) URL>] [--out <file>]
```

By default it sends one GET for Digital Extremes' content index
(`https://origin.warframe.com/origin/<8 random hex digits>/index.txt.lzma`, the first request of every launcher
update) and reads the body as the launcher does. A pass covers name resolution, TLS through Wine's GnuTLS,
certificate validation and a body as long as its `Content-Length`. It sends exactly one request per run, never
retries and never follows a redirect: run it by hand, never in a loop or on every commit. `--url` takes any URL,
including a local server (`qa/n/winhttp-local.sh`).

## Notes

- Load renderer overlays with `WINEDLLPATH_PREPEND`, as `runtime/dev-wine.sh` does: Wine searches `WINEDLLPATH` after
  its own DLLs, so its own `d3d11.dll` would win.
- Every program calls `SetErrorMode`, so a crash never waits on a dialog.
- `common/jsonline.h` writes the JSON line; `bridge/steamprobe` uses it too.
