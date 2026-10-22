#!/bin/bash
# Check that this Mac can build and run Warzag. Prints one line per check; exits non-zero on a hard failure.
set -uo pipefail

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

echo "Machine"
[ "$(uname -m)" = arm64 ] && ok "Apple silicon ($(sysctl -n machdep.cpu.brand_string))" || bad "not Apple silicon"
ver="$(sw_vers -productVersion)"
major="${ver%%.*}"
[ "$major" -ge 15 ] && ok "macOS $ver" || bad "macOS $ver (need 15.0 or later)"
mem=$(( $(sysctl -n hw.memsize) / 1073741824 ))
[ "$mem" -ge 16 ] && ok "${mem} GB RAM" || warn "${mem} GB RAM (8 GB Macs get the low-memory preset)"
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[ "$free_gb" -ge 80 ] && ok "${free_gb} GB free" || warn "${free_gb} GB free (Warframe needs about 80 GB)"
if pmset -g | grep -q 'lowpowermode *1'; then warn "Low Power Mode is on (builds will be slow)"; else ok "Low Power Mode off"; fi
if pmset -g batt | grep -q "AC Power"; then ok "on AC power"; else warn "on battery"; fi

echo "Toolchain"
xcode-select -p >/dev/null 2>&1 && ok "Xcode: $(xcodebuild -version 2>/dev/null | head -1)" || bad "Xcode / Command Line Tools missing"
clt="$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | awk '/version/ {print $2}')"
[ -n "$clt" ] && ok "Command Line Tools $clt" || warn "Command Line Tools package not found"
command -v brew >/dev/null && ok "Homebrew $(brew --version | head -1 | awk '{print $2}')" || bad "Homebrew missing"
for f in mingw-w64 bison flex pkgconf cmake ninja meson autoconf automake; do
    v="$(brew list --versions "$f" 2>/dev/null)"
    [ -n "$v" ] && ok "$v" || bad "brew install $f"
done
v="$(brew list --versions ccache 2>/dev/null)"
[ -n "$v" ] && ok "$v" || warn "ccache not installed (optional: meson uses it for faster rebuilds)"
command -v jq >/dev/null && ok "jq $(jq --version)" || bad "jq missing"
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && ok "gh authenticated" || warn "gh not authenticated (needed for fetch.sh --check-digests and releases)"

echo "Steam"
steam_macos="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
if [ -d /Applications/Steam.app ] || [ -d "$HOME/Applications/Steam.app" ]; then ok "Steam.app installed"; else warn "Steam.app not installed (Warzag installs it on first run)"; fi
if [ -f "$steam_macos/steamclient.dylib" ]; then
    archs="$(lipo -archs "$steam_macos/steamclient.dylib")"
    [[ "$archs" == *arm64* ]] && ok "steamclient.dylib: $archs" || bad "steamclient.dylib lacks an arm64 slice ($archs)"
else
    warn "Steam client runtime not bootstrapped yet"
fi
pgrep -x steam_osx >/dev/null && ok "Steam is running" || warn "Steam is not running"

echo
[ $fail -eq 0 ] && echo "doctor: OK" || echo "doctor: problems found"
exit $fail
