#!/usr/bin/env python3
"""Tests for tools/release/forbidden-scan.py.

    python3 -I qa/packaging/forbidden-scan-test.py

Builds small trees in a temporary directory and checks what the scanner reports.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

# Importing the scanner by path must not leave a __pycache__ next to it in the repository.
sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCANNER = os.path.join(ROOT, "tools", "release", "forbidden-scan.py")

spec = importlib.util.spec_from_file_location("forbidden_scan", SCANNER)
forbidden_scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(forbidden_scan)


class ForbiddenScanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name

    def tearDown(self):
        self.temp.cleanup()

    def tree(self, *paths):
        for path in paths:
            full = os.path.join(self.root, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as handle:
                handle.write("x")

    def hits(self, repo=False):
        return sorted(rel for rel, _ in forbidden_scan.scan(self.root, repo))

    def test_signing_secrets_are_forbidden(self):
        self.tree("signing/warzag-community-code-signing.p12", "a/b/identity.PFX",
                  "keys/dev.ed25519", "Keychains/warzag-signing.keychain-db", "old.keychain")
        self.assertEqual(self.hits(), ["Keychains/warzag-signing.keychain-db", "a/b/identity.PFX",
                                       "keys/dev.ed25519", "old.keychain",
                                       "signing/warzag-community-code-signing.p12"])

    def test_public_signing_material_is_allowed(self):
        self.tree("keys/dev.ed25519.pub", "signing/warzag-community-code-signing.cer",
                  "tools/sign/project-certificate.sha256", "docs/ed25519-notes.md")
        self.assertEqual(self.hits(), [])

    def test_existing_rules_still_hold(self):
        self.tree("X/Warframe.x64.exe", "X/Tools/Launcher.exe", "Steam/steamclient64.dll",
                  "Contents/share/warzag/bridge/steamclient64-forwarder.dll",
                  "Contents/lib/wine/aarch64-unix/lsteamclient.so")
        self.assertEqual(self.hits(), ["Steam/steamclient64.dll", "X/Tools/Launcher.exe", "X/Warframe.x64.exe"])

    def test_repo_mode_adds_the_sdk_rules(self):
        self.tree("bridge/src/isteamclient.h")
        self.assertEqual(self.hits(repo=False), [])
        self.assertEqual(self.hits(repo=True), ["bridge/src/isteamclient.h"])

    def write(self, path, data):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as handle:
            handle.write(data)

    def personal(self, home="/Users/tenno", user="tenno"):
        return sorted(forbidden_scan.scan_personal(self.root, home, user))

    def test_personal_finds_the_home_folder_and_the_user_name(self):
        self.write("lib/ntdll.dll", b"\x00/Users/tenno/Library/Caches/warzag-build/work/n/src/wine/dlls/heap.c\x00")
        self.write("lib/wide.dll", "C:\\x /Users/tenno/src".encode("utf-16-le"))
        self.write("lib/built.txt", b"built by tenno@mac on Friday")
        self.write("lib/clean.dll", b"tennos attenno tenno2 /warzag-build/work/n/src/wine/dlls/heap.c")
        self.write("lib/empty.bin", b"")
        os.symlink("/Users/tenno/Library/x", os.path.join(self.root, "lib/link"))
        self.assertEqual(self.personal(), [
            ("lib/built.txt", "names the builder's user name"),
            ("lib/link", "names the builder's home folder (a symbolic link's target)"),
            ("lib/ntdll.dll", "names the builder's home folder"),
            ("lib/wide.dll", "names the builder's home folder"),
        ])

    def test_extra_paths_are_looked_for_anywhere(self):
        # A build cache and a checkout outside the home folder (an external volume): only --path finds them.
        self.write("lib/ntdll.dll", b"\x00/Volumes/Build/warzag-build/work/n/src/wine-11.19/dlls/ntdll/loader.c\x00")
        self.write("lib/wide.dll", "/Volumes/Build/src/warzag/bridge/steam.c".encode("utf-16-le"))
        self.write("lib/mapped.dll", b"/warzag-build/work/n/src/wine-11.19/dlls/ntdll/loader.c /warzag/bridge/steam.c")
        self.assertEqual(self.personal(), [])
        found = sorted(forbidden_scan.scan_personal(self.root, "/Users/tenno", "tenno",
                                                    ["/Volumes/Build/warzag-build/", "/Volumes/Build/src/warzag"]))
        self.assertEqual(found, [("lib/ntdll.dll", "names /Volumes/Build/warzag-build"),
                                 ("lib/wide.dll", "names /Volumes/Build/src/warzag")])

    def test_an_extra_path_in_the_home_folder_is_reported_as_itself(self):
        self.write("lib/x.dll", b"/Users/tenno/Library/Caches/warzag-build/work/n/deps-build/nettle/aes.o")
        found = forbidden_scan.scan_personal(self.root, "/Users/tenno", "tenno",
                                             ["/Users/tenno/Library/Caches/warzag-build"])
        self.assertEqual(found, [("lib/x.dll", "names ~/Library/Caches/warzag-build")])

    def test_an_extra_path_is_also_looked_for_with_its_links_resolved(self):
        real = os.path.join(self.root, "real-cache")
        os.makedirs(real)
        os.symlink(real, os.path.join(self.root, "cache-link"))
        scanned = os.path.join(self.root, "stage")
        target = os.path.join(scanned, "lib", "x.so")
        os.makedirs(os.path.dirname(target))
        with open(target, "wb") as handle:
            handle.write(os.path.realpath(real).encode() + b"/work/n/x.o")
        found = forbidden_scan.scan_personal(scanned, "/Users/tenno", "tenno", [os.path.join(self.root, "cache-link")])
        self.assertEqual([rel for rel, _ in found], ["lib/x.so"])

    def test_path_command_line(self):
        self.write("x.dll", b"/Volumes/Build/tenno-cache/work/n/x.c")
        alone = subprocess.run([sys.executable, "-I", SCANNER, "--path", "/Volumes/Build/tenno-cache", self.root],
                               capture_output=True, text=True)
        self.assertEqual(alone.returncode, 2)
        self.assertIn("--path only works with --personal", alone.stderr)
        flagged = subprocess.run([sys.executable, "-I", SCANNER, "--personal", "--home", "/Users/tenno", "--user",
                                  "tenno", "--path", "/Volumes/Build/tenno-cache", self.root],
                                 capture_output=True, text=True)
        self.assertEqual(flagged.returncode, 1)
        self.assertIn("x.dll: names /Volumes/Build/<user>-cache\n", flagged.stdout)
        self.assertNotIn("tenno", flagged.stdout.replace(self.root, ""))

    def test_a_generic_user_name_is_not_looked_for_on_its_own(self):
        self.write("a.txt", b"build 42 of the build tree")
        self.write("b.txt", b"/Users/build/x")
        self.assertEqual(self.personal(home="/Users/build", user="build"),
                         [("b.txt", "names the builder's home folder")])

    def test_personal_command_line(self):
        self.write("x.dll", b"/Users/tenno/src")
        plain = subprocess.run([sys.executable, "-I", SCANNER, self.root], capture_output=True, text=True)
        self.assertEqual(plain.returncode, 0, plain.stdout)
        flagged = subprocess.run([sys.executable, "-I", SCANNER, "--personal", "--home", "/Users/tenno", "--user", "tenno",
                                  self.root], capture_output=True, text=True)
        self.assertEqual(flagged.returncode, 1)
        self.assertIn("PERSONAL", flagged.stdout)
        # The finding never repeats what it found.
        self.assertNotIn("/Users/tenno", flagged.stdout.replace(self.root, ""))

    def test_the_report_never_names_the_home_folder_or_the_user(self):
        # A build output inside the builder's home folder, as build/n/Warzag.app is: its absolute path names them.
        home = os.path.join(self.root, "Users", "tenno")
        build = os.path.join(home, "src", "build")
        self.write(os.path.join(build, "lib", "x.dll"), (home + "/src/dlls/heap.c").encode("utf-8"))
        self.write(os.path.join(build, "tenno-notes.txt"), b"x")
        self.write(os.path.join(build, "keys", "dev.ed25519"), b"x")
        result = subprocess.run([sys.executable, "-I", SCANNER, "--personal", "--home", home, "--user", "tenno", build],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("PERSONAL ~/src/build/lib/x.dll: names the builder's home folder\n", result.stdout)
        self.assertIn("PERSONAL ~/src/build/<user>-notes.txt: names the builder's user name\n", result.stdout)
        self.assertIn("FORBIDDEN ~/src/build/keys/dev.ed25519: Ed25519 private key", result.stdout)
        self.assertNotIn(home, result.stdout)
        self.assertNotIn("tenno", result.stdout)

    def test_command_line_exit_status(self):
        self.tree("keys/dev.ed25519.pub")
        clean = subprocess.run([sys.executable, "-I", SCANNER, self.root], capture_output=True, text=True)
        self.assertEqual(clean.returncode, 0, clean.stdout)
        self.tree("keys/dev.ed25519")
        dirty = subprocess.run([sys.executable, "-I", SCANNER, self.root], capture_output=True, text=True)
        self.assertEqual(dirty.returncode, 1)
        self.assertIn("Ed25519 private key", dirty.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
