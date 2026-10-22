# Warzag's Windows test programs: small, dependency-free PE x86-64 executables built with Homebrew mingw-w64.
#
#   make -C qa/pe          build build/pe/wz-d3d11-smoke.exe, wz-d3d11-pso-reject.exe and wz-winhttp-probe.exe
#   make -C qa/pe check    build, then check PE headers and that only Windows system DLLs are imported
#   make -C qa/pe clean
#   make -C qa/pe OUT=<dir> <dir>/wz-d3d11-pso-reject.exe    one program into another folder (qa/n/pso-reject.sh)
#
# Run them on the Warzag runtime with runtime/dev-wine.sh; see README.md. Warnings are errors because the
# toolchain is pinned (runtime/toolchain.lock.json); pass WERROR= to relax that with another compiler.

HERE := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
OUT ?= $(abspath $(HERE)/../../build/pe)

CC = x86_64-w64-mingw32-gcc
OBJDUMP = x86_64-w64-mingw32-objdump
# Plain assignments, not ?=: CFLAGS and LDFLAGS in the environment belong to the Mac compiler (clang flags such as
# -mmacosx-version-min) and break a mingw build. Values given on the make command line still win.
CFLAGS = -O2
LDFLAGS =
WERROR = -Werror

# Console programs with a wide wmain; UCRT is the toolchain's default C runtime. -static-libgcc keeps libgcc's
# DLL out of the import table, and no link timestamp keeps rebuilds byte-identical.
WZ_CFLAGS = -std=gnu17 -Wall -Wextra $(WERROR) -municode -mconsole -DUNICODE -D_UNICODE
WZ_LDFLAGS = -static-libgcc -Wl,--no-insert-timestamp

SMOKE = $(OUT)/wz-d3d11-smoke.exe
PSO_REJECT = $(OUT)/wz-d3d11-pso-reject.exe
PROBE = $(OUT)/wz-winhttp-probe.exe

all: $(SMOKE) $(PSO_REJECT) $(PROBE)

$(SMOKE): $(HERE)/d3d11-smoke/main.c $(HERE)/common/jsonline.h | $(OUT)
	$(CC) $(WZ_CFLAGS) $(CFLAGS) -o $@ $< $(WZ_LDFLAGS) $(LDFLAGS) -ldxguid -luser32

# d3d11.dll and d3dcompiler_47.dll are loaded at run time, as in the smoke test.
$(PSO_REJECT): $(HERE)/d3d11-pso-reject/main.c $(HERE)/common/jsonline.h | $(OUT)
	$(CC) $(WZ_CFLAGS) $(CFLAGS) -o $@ $< $(WZ_LDFLAGS) $(LDFLAGS) -ldxguid -luser32

$(PROBE): $(HERE)/winhttp-probe/main.c $(HERE)/common/jsonline.h | $(OUT)
	$(CC) $(WZ_CFLAGS) $(CFLAGS) -o $@ $< $(WZ_LDFLAGS) $(LDFLAGS) -lwinhttp

$(OUT):
	mkdir -p $@

check: all
	OBJDUMP=$(OBJDUMP) $(HERE)/check-pe.sh $(SMOKE) $(PSO_REJECT) $(PROBE)

clean:
	rm -f $(SMOKE) $(PSO_REJECT) $(PROBE)
	rmdir $(OUT) 2>/dev/null || true

.PHONY: all check clean
