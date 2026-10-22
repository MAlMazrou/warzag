#!/usr/bin/env python3
"""Fail if a tree (repo, build output, release bundle) contains anything Warzag must never ship or commit.

Usage: tools/release/forbidden-scan.py [--repo] [--personal [--home <dir>] [--user <name>] [--path <dir>]...]
                                      [<path> ...]   (default: the current folder)

  --repo       also forbid Valve Steamworks SDK sources (allowed only in build caches, never committed)
  --personal   also read every file and fail if it names the builder: the current user's home folder (their account
               name in a path) or their user name on its own, as UTF-8 or UTF-16LE text. Runtime builds compile
               source paths into binaries (__FILE__, debug maps) unless they are mapped away; runtime/n/build.sh
               does, tools/release/mkpack.sh refuses a pack that still names the builder.
  --home, --user  scan for these instead of $HOME and the login name (tests).
  --path <dir> with --personal: also fail if a file names this directory (UTF-8 or UTF-16LE, as given and with its
               symbolic links resolved), e.g. the build cache and the checkout, which need not live in the home
               folder. Repeatable.

Forbidden everywhere:
  * Apple D3DMetal / Game Porting Toolkit (license EA18380 forbids redistribution)
  * Digital Extremes game files (Warframe executables, caches, tools)
  * Valve's Windows Steam client DLLs / the Steam client itself
  * CrossOver binaries and its encrypted compatibility database
  * GPL tools from the CrossOver source tarball that Warzag never ships (busybox, cabextract, ghostscript, po4a)
  * signing secrets: the project identity's .p12, keychains, Ed25519 private keys (public keys, *.pub, and
    certificates, *.cer, are public and allowed)

No finding prints the home folder or the user name: paths show the home folder as "~" and the user name as "<user>"
(a build output usually lives in the builder's home folder), so the scan's own output can be shared.
"""
import getpass
import mmap
import os
import re
import sys

# Only file paths are checked: Warzag's own sources mention these names (this scanner, docs).
ALWAYS = [
    (re.compile(r"(^|/)D3DMetal\.framework(/|$)", re.I), "Apple D3DMetal framework"),
    (re.compile(r"(^|/)libd3dshared\.dylib$", re.I), "Apple D3DMetal shared library"),
    (re.compile(r"(^|/)apple_gptk(/|$)", re.I), "Apple Game Porting Toolkit files"),
    (re.compile(r"(^|/)Warframe(\.x64)?\.exe$", re.I), "Warframe game executable"),
    (re.compile(r"(^|/)Cache\.Windows(/|$)", re.I), "Warframe content cache"),
    (re.compile(r"(^|/)Tools/Launcher\.exe$", re.I), "Warframe launcher"),
    (re.compile(r"(^|/)Warframe\.msi$", re.I), "Warframe installer"),
    (re.compile(r"(^|/)(steamclient|steamclient64|tier0_s64|vstdlib_s64|GameOverlayRenderer64)\.dll$", re.I),
     "Valve Windows Steam client DLL (fetch on the user's Mac, never ship)"),
    (re.compile(r"(^|/)steamclient\.dylib$", re.I), "Valve macOS Steam client library"),
    (re.compile(r"(^|/)compatdb-[\d.]+\.dat$", re.I), "CrossOver compatibility database"),
    (re.compile(r"(^|/)CrossOver\.app(/|$)", re.I), "CrossOver application"),
    (re.compile(r"(^|/)(busybox|cabextract|ghostscript|po4a)(/|$)", re.I), "GPL tool from the CrossOver tarball"),
    (re.compile(r"\.(p12|pfx)$", re.I), "signing identity (PKCS#12): keep it in ~/.warzag/signing, never ship it"),
    (re.compile(r"\.keychain(-db)?$", re.I), "keychain file: never ship it"),
    (re.compile(r"\.ed25519$", re.I), "Ed25519 private key (manifest signing): keep it in ~/.warzag/keys"),
]

REPO_ONLY = [
    (re.compile(r"(^|/)steamworks_sdk_\d+[a-z]*(/|$)", re.I), "Valve Steamworks SDK sources (fetch at build time)"),
    (re.compile(r"(^|/)isteam\w+\.h$", re.I), "Valve Steamworks SDK header"),
    (re.compile(r"(^|/)steam_api(64)?\.(dll|lib|dylib)$", re.I), "Valve steam_api redistributable"),
]

SKIP_DIRS = {".git", ".build", ".swiftpm"}

# User names too common to look for on their own: they appear in ordinary text and binaries. Their home folder is
# still looked for.
GENERIC_USERS = {"root", "admin", "administrator", "user", "users", "test", "tester", "build", "builder", "runner",
                 "ci", "dev", "developer", "guest", "mac", "home", "owner", "staff", "daemon", "nobody", "wine",
                 "steam", "game", "games", "player", "warzag", "local", "shared", "apple"}


def scan(root, repo_mode):
    rules = ALWAYS + (REPO_ONLY if repo_mode else [])
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in dirnames + filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            for rx, why in rules:
                if rx.search(rel):
                    hits.append((rel, why))
                    break
    return hits


def extra_directories(paths):
    """The directories --path names, absolute, each as given and with its symbolic links resolved (a compiler may
    record either), without duplicates, the root or empty entries."""
    found = []
    for path in paths:
        if not path:
            continue
        for variant in (os.path.abspath(path), os.path.realpath(path)):
            variant = variant.rstrip("/")
            if variant and variant not in found:
                found.append(variant)
    return found


def personal_patterns(home, user, paths=()):
    """(needle, regex, finding) for the directories given with --path, the builder's home folder and their user name,
    in UTF-8 and UTF-16LE. The needle is a plain substring every match contains (a fast first pass); the regex, when
    there is one, then decides. The extra directories come first: a build cache inside the home folder is reported
    as the cache."""
    patterns = []
    for directory in extra_directories(paths):
        for encoding in ("utf-8", "utf-16-le"):
            patterns.append((directory.encode(encoding, "surrogateescape"), None,
                             f"names {shown(directory, home, user)}"))
    home = home.rstrip("/")
    if home and home != "/":
        for encoding in ("utf-8", "utf-16-le"):
            patterns.append((home.encode(encoding), None, "names the builder's home folder"))
    if user and len(user) >= 3 and user.lower() not in GENERIC_USERS:
        # The name on its own, not as part of a longer word.
        word = user.encode("utf-8")
        patterns.append((word, re.compile(rb"(?<![A-Za-z0-9])" + re.escape(word) + rb"(?![A-Za-z0-9])"),
                         "names the builder's user name"))
        wide = user.encode("utf-16-le")
        patterns.append((wide, re.compile(rb"(?<![A-Za-z0-9]\x00)" + re.escape(wide) + rb"(?![A-Za-z0-9]\x00)"),
                         "names the builder's user name"))
    return patterns


def names_builder(data, patterns):
    """The first finding for `data` (bytes or an mmap), or None."""
    for needle, regex, why in patterns:
        if data.find(needle) < 0:
            continue
        if regex is None or regex.search(data):
            return why
    return None


def scan_personal(root, home, user, paths=()):
    """Files under `root` whose contents (or paths, or link targets) name the builder or one of `paths`."""
    patterns = personal_patterns(home, user, paths)
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_DIRS:
                continue  # a git worktree's .git is a file naming its checkout
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            if os.path.islink(path):
                found = names_builder(os.readlink(path).encode("utf-8", "surrogateescape"), patterns)
                if found:
                    hits.append((rel, found + " (a symbolic link's target)"))
                continue
            if not os.path.isfile(path):
                continue
            found = names_builder(rel.encode("utf-8", "surrogateescape"), patterns)
            if not found and os.path.getsize(path) > 0:
                with open(path, "rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    found = names_builder(data, patterns)
            if found:
                hits.append((rel, found))
    return hits


def shown(path, home, user):
    """How a finding names `path`: the builder's home folder as "~" and their user name as "<user>"."""
    home = home.rstrip("/")
    if home and home != "/" and (path == home or path.startswith(home + "/")):
        path = "~" + path[len(home):]
    if user and len(user) >= 3 and user.lower() not in GENERIC_USERS:
        path = re.sub(r"(?<![A-Za-z0-9])" + re.escape(user) + r"(?![A-Za-z0-9])", "<user>", path)
    return path


def main(argv):
    repo_mode = False
    personal = False
    home = os.path.expanduser("~")
    user = os.environ.get("USER") or getpass.getuser()
    extra = []
    paths = []
    args = list(argv)
    while args:
        argument = args.pop(0)
        if argument == "--repo":
            repo_mode = True
        elif argument == "--personal":
            personal = True
        elif argument in ("--home", "--user", "--path"):
            if not args:
                print(f"forbidden-scan: {argument} needs a value", file=sys.stderr)
                return 2
            value = args.pop(0)
            if argument == "--home":
                home = value
            elif argument == "--user":
                user = value
            else:
                extra.append(value)
        elif argument in ("-h", "--help"):
            print(__doc__)
            return 0
        elif argument.startswith("-"):
            print(f"forbidden-scan: unknown option: {argument}", file=sys.stderr)
            return 2
        else:
            paths.append(argument)
    if extra and not personal:
        print("forbidden-scan: --path only works with --personal", file=sys.stderr)
        return 2
    paths = paths or ["."]
    for p in paths:
        if not os.path.exists(p):
            print(f"forbidden-scan: no such file or directory: {shown(p, home, user)}", file=sys.stderr)
            return 2
    bad = 0
    for p in paths:
        for rel, why in scan(p, repo_mode):
            print(f"FORBIDDEN {shown(os.path.join(p, rel), home, user)}: {why}")
            bad += 1
        if personal:
            for rel, why in scan_personal(p, home, user, extra):
                print(f"PERSONAL {shown(os.path.join(p, rel), home, user)}: {why}")
                bad += 1
    if personal and (not user or len(user) < 3 or user.lower() in GENERIC_USERS):
        print("forbidden-scan: the user name is too generic to look for on its own; only the home folder was checked")
    print(f"forbidden-scan: {'clean' if bad == 0 else f'{bad} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
