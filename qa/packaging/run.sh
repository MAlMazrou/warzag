#!/bin/bash
# Runs every packaging test.
#
#   qa/packaging/run.sh [--quick]
#
#   forbidden-scan-test.py   the release scanner's rules
#   changelog-test.py        tools/release/changelog.py: the format, releases, notes, CI's entry check
#   sign-test.sh             make-cert/sign/verify against a scratch identity and keychain
#   pack-test.sh             mkpack.sh and warzag-release on the real game host, with tampering cases
#   app-test.sh              make-app.sh --dmg, the bundle and the image, install.sh
#   app-update-test.sh       Warzag's own updates on signed stand-in apps: archives, app manifests, refusals, the
#                            helper's swap and the app's hand-over
# --quick runs only the first three, which need neither the project identity nor a game host. By hand only (it
# launches processes through Launch Services): app-update-rehearsal.sh --launch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
QUICK=0
case "${1:-}" in
    "") ;;
    --quick) QUICK=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

status=0
run() {
    echo "=== $*"
    "$@" || status=1
}
run python3 -I "$HERE/forbidden-scan-test.py"
run python3 -I "$HERE/changelog-test.py"
run "$HERE/sign-test.sh"
if [ "$QUICK" = 0 ]; then
    run "$HERE/pack-test.sh"
    run "$HERE/app-test.sh"
    run "$HERE/app-update-test.sh"
fi
[ $status -eq 0 ] && echo "packaging tests: all passed" || echo "packaging tests: FAILED"
exit $status
