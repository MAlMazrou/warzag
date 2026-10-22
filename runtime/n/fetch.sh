#!/bin/bash
# Download and verify every pinned input of Warzag's engine (runtime/n/inputs.lock.json).
#
#   runtime/n/fetch.sh [--check-digests] [--verify-signatures] [--print-submodules] [name ...]
#
# Without names: every non-optional archive, every git input and the shared inputs of runtime/inputs.lock.json
# (crossover-sources, nettle; through tools/fetch-inputs.sh). Optional archives (wine-mono) are fetched only when named.
# A name is an archive or git input of runtime/n/inputs.lock.json, or shared (the shared inputs).
#   archives -> $WARZAG_CACHE/work/n/downloads/<name>/<file>   (size and SHA-256 checked against the lock)
#   git      -> $WARZAG_CACHE/work/n/repos/<name>              (HEAD must be the pinned commit; submodules too)
# --check-digests       also compares each github.com archive with the release asset digest GitHub publishes
# --verify-signatures   checks Wine's detached OpenPGP signature with gpg (needs gpg and the WineHQ key)
# --print-submodules    prints the submodule commits of fex/dxmt as JSON (to fill the lock after a pin bump)
# Nothing is fetched into the repository. Verified inputs are not downloaded again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$ROOT/runtime/n/inputs.lock.json"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
WORK="$CACHE/work/n"
DL="$WORK/downloads"
REPOS="$WORK/repos"

CHECK_DIGESTS=0
VERIFY_SIGS=0
PRINT_SUBMODULES=0
SELECTED=()
while [ $# -gt 0 ]; do
    case "$1" in
        --check-digests) CHECK_DIGESTS=1; shift ;;
        --verify-signatures) VERIFY_SIGS=1; shift ;;
        --print-submodules) PRINT_SUBMODULES=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) SELECTED+=("$1"); shift ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required"; }
need jq; need curl; need shasum; need git

lock() { jq -r "$1" "$LOCK"; }
known="$(lock '(.archives, .git) | keys[]')"
for n in ${SELECTED[@]+"${SELECTED[@]}"}; do
    [ "$n" = shared ] || grep -qxF -- "$n" <<< "$known" || { echo "unknown input: $n" >&2; exit 2; }
done
want() {  # want <name> <optional 0|1>
    if [ ${#SELECTED[@]} -eq 0 ]; then [ "$2" = 0 ]; return; fi
    local n
    for n in "${SELECTED[@]}"; do [ "$n" = "$1" ] && return 0; done
    return 1
}

sha_ok() { echo "$2  $1" | shasum -a 256 -c --status; }

fetch_archive() {
    local name="$1" url sha size file dir got
    url="$(lock ".archives[\"$name\"].url")"
    sha="$(lock ".archives[\"$name\"].sha256")"
    size="$(lock ".archives[\"$name\"].size // empty")"
    file="${url##*/}"
    dir="$DL/$name"
    mkdir -p "$dir"
    if [ -f "$dir/$file" ] && sha_ok "$dir/$file" "$sha"; then
        echo "ok      $name ($file, cached)"
    else
        echo "fetch   $name <- $url"
        curl -fL --retry 5 --retry-delay 3 -C - -o "$dir/$file.part" "$url"
        if [ -n "$size" ]; then
            got="$(stat -f %z "$dir/$file.part")"
            [ "$got" = "$size" ] || { rm -f "$dir/$file.part"; die "$name: size $got != $size"; }
        fi
        sha_ok "$dir/$file.part" "$sha" || { rm -f "$dir/$file.part"; die "$name: sha256 mismatch"; }
        mv "$dir/$file.part" "$dir/$file"
        echo "ok      $name ($file)"
    fi

    # A detached signature, when the lock names one (Wine).
    local sig_url sig_sha
    sig_url="$(lock ".archives[\"$name\"].signature.url // empty")"
    if [ -n "$sig_url" ]; then
        sig_sha="$(lock ".archives[\"$name\"].signature.sha256")"
        if ! { [ -f "$dir/${sig_url##*/}" ] && sha_ok "$dir/${sig_url##*/}" "$sig_sha"; }; then
            curl -fsL --retry 5 -o "$dir/${sig_url##*/}" "$sig_url"
            sha_ok "$dir/${sig_url##*/}" "$sig_sha" || die "$name: signature file sha256 mismatch"
        fi
        if [ "$VERIFY_SIGS" = 1 ]; then
            need gpg
            gpg --verify "$dir/${sig_url##*/}" "$dir/$file" 2>&1 | tee "$dir/gpg-verify.log" >/dev/null \
                || die "$name: gpg signature check failed (import key $(lock ".archives[\"$name\"].signature.issuer_fingerprint") first)"
            grep -q "$(lock ".archives[\"$name\"].signature.issuer_fingerprint" | sed 's/.\{4\}/& /g; s/ $//')" \
                "$dir/gpg-verify.log" || grep -qi "$(lock ".archives[\"$name\"].signature.issuer_fingerprint")" "$dir/gpg-verify.log" \
                || die "$name: signed by an unexpected key (see $dir/gpg-verify.log)"
            echo "ok      $name signature"
        fi
    fi

    # The digest GitHub publishes for a release asset (repos/<owner>/<repo>/releases/tags/<tag>).
    if [ "$CHECK_DIGESTS" = 1 ] && [[ "$url" == https://github.com/*/releases/download/* ]]; then
        need gh
        local path owner_repo tag digest
        path="${url#https://github.com/}"
        owner_repo="${path%%/releases/download/*}"
        tag="${path#*/releases/download/}"
        tag="${tag%/*}"
        digest="$(gh api "repos/$owner_repo/releases/tags/$tag" \
            --jq ".assets[] | select(.name == \"$file\") | .digest" 2>/dev/null || true)"
        if [ -z "$digest" ] || [ "$digest" = null ]; then
            echo "note    $name: GitHub publishes no digest for $file"
        elif [ "$digest" = "sha256:$sha" ]; then
            echo "ok      $name GitHub digest"
        else
            die "$name: GitHub digest $digest != lock sha256:$sha"
        fi
    fi
}

# git_checkout <dir> <url> <commit> [sparse paths...]: a shallow checkout of exactly one commit.
git_checkout() {
    local dir="$1" url="$2" commit="$3"
    shift 3
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)" = "$commit" ]; then
        return 0
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    if [ $# -gt 0 ]; then
        git -C "$dir" sparse-checkout set "$@"
        git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit"
    else
        git -C "$dir" fetch -q --depth 1 origin "$commit"
    fi
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

submodule_json() {  # submodule commits of a checkout as a JSON object {path: commit}
    git -C "$1" submodule status --recursive 2>/dev/null \
        | awk '{c = $1; sub(/^[-+U ]/, "", c); printf "%s\t%s\n", $2, c}' \
        | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}'
}

fetch_git() {
    local name="$1" repo commit dir sparse=() skip=() sm path want_commit got_commit
    repo="$(lock ".git[\"$name\"].repo")"
    commit="$(lock ".git[\"$name\"].commit")"
    dir="$REPOS/$name"
    while IFS= read -r path; do [ -n "$path" ] && sparse+=("$path"); done \
        < <(lock "(.git[\"$name\"].paths // .git[\"$name\"].sparse // [])[]")
    if ! git_checkout "$dir" "$repo" "$commit" ${sparse[@]+"${sparse[@]}"} 2>/dev/null; then
        local mirror
        mirror="$(lock ".git[\"$name\"].mirror // empty")"
        [ -n "$mirror" ] || die "$name: fetch of $commit from $repo failed"
        echo "note    $name: $repo failed, using the mirror $mirror (same commit id)"
        git_checkout "$dir" "$mirror" "$commit" ${sparse[@]+"${sparse[@]}"}
    fi
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$name not at $commit"

    # Submodules only for inputs whose lock entry has a "submodules" map (fex, dxmt); Proton's are not used.
    if [ -f "$dir/.gitmodules" ] && [ "$(lock ".git[\"$name\"] | has(\"submodules\")")" = true ]; then
        while IFS= read -r path; do [ -n "$path" ] && skip+=("$path"); done \
            < <(lock "(.git[\"$name\"].submodules_skipped // [])[]")
        for sm in $(git -C "$dir" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}'); do
            local skipped=0 s
            for s in ${skip[@]+"${skip[@]}"}; do [ "$s" = "$sm" ] && skipped=1; done
            [ "$skipped" = 1 ] && continue
            if [ ! -e "$dir/$sm/.git" ]; then
                git -C "$dir" submodule update -q --init --depth 1 -- "$sm" \
                    || git -C "$dir" submodule update -q --init -- "$sm" \
                    || die "$name: submodule $sm failed"
            fi
            want_commit="$(lock ".git[\"$name\"].submodules[\"$sm\"] // empty")"
            got_commit="$(git -C "$dir/$sm" rev-parse HEAD)"
            # The superproject's gitlink is the real pin; the lock repeats it for readers.
            [ "$got_commit" = "$(git -C "$dir" ls-tree HEAD "$sm" | awk '{print $3}')" ] \
                || die "$name: submodule $sm at $got_commit, not the commit $commit records"
            [ -z "$want_commit" ] || [ "$want_commit" = "$got_commit" ] \
                || die "$name: submodule $sm at $got_commit, lock says $want_commit"
        done
        if [ "$PRINT_SUBMODULES" = 1 ]; then echo "$name submodules:"; submodule_json "$dir"; fi
    fi
    echo "ok      $name @ ${commit:0:12}"
}

mkdir -p "$DL" "$REPOS"
for name in $(lock '.archives | keys[]'); do
    optional="$(lock ".archives[\"$name\"].optional // false")"
    want "$name" "$([ "$optional" = true ] && echo 1 || echo 0)" && fetch_archive "$name"
done
for name in $(lock '.git | keys[]'); do
    want "$name" 0 && fetch_git "$name"
done
# gmp/gnutls/freetype (crossover-sources) and nettle: pinned in runtime/inputs.lock.json.
if want shared 0; then
    "$ROOT/tools/fetch-inputs.sh" crossover-sources nettle
fi
echo "fetch: done"
