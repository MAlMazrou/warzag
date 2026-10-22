#!/usr/bin/env python3
"""Tests for tools/release/changelog.py.

    python3 -I qa/packaging/changelog-test.py

Writes small changelogs and git repositories into a temp directory and checks what the tool accepts, refuses, cuts
and prints.
"""
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.path.join(ROOT, "tools", "release", "changelog.py")

INTRO = "# Changelog\n\nFree text, with a list:\n\n- **Major**: big\n- **Minor**: small\n\n"


def changelog(*sections):
    return INTRO + "\n".join(textwrap.dedent(section).strip("\n") + "\n" for section in sections)


UNRELEASED_EMPTY = "## [Unreleased]\n"
UNRELEASED_FIX = """
    ## [Unreleased]

    ### Bug fixes

    - A fix.
"""
UNRELEASED_MINOR = """
    ## [Unreleased]

    ### Minor

    - A smaller feature,
      described on two lines.

    ### Bug fixes

    - A fix.
"""
FIRST = """
    ## [0.1.0] - 2026-10-20

    ### Major

    - The first version.
"""


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.temp.name, "CHANGELOG.md")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, text):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def read(self):
        with open(self.path, encoding="utf-8") as handle:
            return handle.read()

    def run_tool(self, *arguments):
        return subprocess.run([sys.executable, "-I", TOOL, *arguments], capture_output=True, text=True)

    def check(self, text):
        self.write(text)
        return self.run_tool("check", "--file", self.path)

    def assertRefused(self, text, reason):
        result = self.check(text)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(reason, result.stderr)

    # check

    def test_a_valid_changelog_passes(self):
        result = self.check(changelog(UNRELEASED_MINOR, FIRST))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 release(s), 2 unreleased entries", result.stdout)

    def test_the_repositorys_own_changelog_passes(self):
        result = self.run_tool("check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unreleased_must_come_first(self):
        self.assertRefused(changelog(FIRST, UNRELEASED_FIX), "the first section must be '## [Unreleased]'")

    def test_only_the_three_headings(self):
        self.assertRefused(changelog("## [Unreleased]\n\n### Added\n\n- Something.\n", FIRST),
                           "'### Added' is not one of")

    def test_headings_in_order(self):
        self.assertRefused(changelog("## [Unreleased]\n\n### Bug fixes\n\n- A fix.\n\n### Major\n\n- Big.\n", FIRST),
                           "comes after a later heading")

    def test_a_heading_needs_an_entry(self):
        self.assertRefused(changelog("## [Unreleased]\n\n### Minor\n\n### Bug fixes\n\n- A fix.\n", FIRST),
                           "'### Minor' in [Unreleased] has no entry")

    def test_text_outside_a_subsection(self):
        self.assertRefused(changelog("## [Unreleased]\n\nLoose text.\n", FIRST), "text outside")

    def test_a_release_needs_its_date(self):
        self.assertRefused(changelog(UNRELEASED_EMPTY, "## [0.1.0]\n\n### Major\n\n- First.\n"), "needs its date")
        self.assertRefused(changelog(UNRELEASED_EMPTY, "## [0.1.0] - 2026-02-30\n\n### Major\n\n- First.\n"),
                           "has no real date")

    def test_a_release_lists_a_change(self):
        self.assertRefused(changelog(UNRELEASED_EMPTY, "## [0.1.0] - 2026-10-20\n"), "lists no change")

    def test_versions_follow_from_the_headings(self):
        minor = "## [0.1.1] - 2026-10-21\n\n### Minor\n\n- Small.\n"
        self.assertRefused(changelog(UNRELEASED_EMPTY, minor, FIRST), "[0.1.1] should be 0.2.0")
        fixes = "## [0.2.0] - 2026-10-21\n\n### Bug fixes\n\n- A fix.\n"
        self.assertRefused(changelog(UNRELEASED_EMPTY, fixes, FIRST), "[0.2.0] should be 0.1.1")
        major = "## [0.2.0] - 2026-10-21\n\n### Major\n\n- Big.\n"
        self.assertRefused(changelog(UNRELEASED_EMPTY, major, FIRST), "[0.2.0] should be 1.0.0")
        right = "## [1.0.0] - 2026-10-21\n\n### Major\n\n- Big.\n\n### Bug fixes\n\n- A fix.\n"
        self.assertEqual(self.check(changelog(UNRELEASED_EMPTY, right, FIRST)).returncode, 0)

    def test_newest_first(self):
        older = "## [0.0.9] - 2026-10-19\n\n### Major\n\n- Older.\n"
        self.assertRefused(changelog(UNRELEASED_EMPTY, older, FIRST), "must be newer than the release below it")
        earlier = "## [0.1.1] - 2026-10-19\n\n### Bug fixes\n\n- A fix.\n"
        self.assertRefused(changelog(UNRELEASED_EMPTY, earlier, FIRST), "is dated before")

    # next-version, release, notes

    def test_next_version(self):
        self.write(changelog(UNRELEASED_MINOR, FIRST))
        self.assertEqual(self.run_tool("next-version", "--file", self.path).stdout.strip(), "0.2.0")
        self.write(changelog(UNRELEASED_FIX, FIRST))
        self.assertEqual(self.run_tool("next-version", "--file", self.path).stdout.strip(), "0.1.1")

    def test_the_first_release_takes_any_number(self):
        self.write(changelog(UNRELEASED_MINOR))
        result = self.run_tool("release", "0.1.0", "--date", "2026-10-20", "--file", self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.read()
        self.assertIn("## [Unreleased]\n\n## [0.1.0] - 2026-10-20\n\n### Minor\n\n- A smaller feature,\n"
                      "  described on two lines.\n\n### Bug fixes\n\n- A fix.\n", text)
        self.assertTrue(text.startswith(INTRO))
        self.assertEqual(self.run_tool("check", "--file", self.path).returncode, 0)

    def test_release_moves_unreleased_and_keeps_older_releases(self):
        self.write(changelog(UNRELEASED_MINOR, FIRST))
        result = self.run_tool("release", "0.2.0", "--date", "2026-10-21", "--file", self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.read()
        self.assertLess(text.index("## [0.2.0] - 2026-10-21"), text.index("## [0.1.0] - 2026-10-20"))
        self.assertIn("- The first version.", text)
        self.assertEqual(self.run_tool("next-version", "--file", self.path).returncode, 1)

    def test_release_refuses_a_number_the_headings_do_not_call_for(self):
        self.write(changelog(UNRELEASED_MINOR, FIRST))
        result = self.run_tool("release", "0.1.1", "--date", "2026-10-21", "--file", self.path)
        self.assertEqual(result.returncode, 1)
        self.assertIn("call for 0.2.0, not 0.1.1", result.stderr)
        self.assertEqual(self.read(), changelog(UNRELEASED_MINOR, FIRST))

    def test_release_refuses_nothing_to_release_and_a_released_number(self):
        self.write(changelog(UNRELEASED_EMPTY, FIRST))
        self.assertIn("nothing to release",
                      self.run_tool("release", "0.1.1", "--file", self.path).stderr)
        self.write(changelog(UNRELEASED_FIX, FIRST))
        self.assertIn("already released", self.run_tool("release", "0.1.0", "--file", self.path).stderr)

    def test_notes(self):
        self.write(changelog(UNRELEASED_MINOR, FIRST))
        result = self.run_tool("notes", "0.1.0", "--file", self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "### Major\n\n- The first version.\n")
        missing = self.run_tool("notes", "0.3.0", "--file", self.path)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no section for 0.3.0", missing.stderr)


class RequireEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = self.temp.name
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.commit({"CHANGELOG.md": "# Changelog\n", "docs/a.md": "a"}, "base")
        self.base = self.git("rev-parse", "HEAD").strip()

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *arguments):
        return subprocess.run(["git", "-C", self.repo, *arguments], capture_output=True, text=True, check=True).stdout

    def commit(self, files, message):
        for name, content in files.items():
            path = os.path.join(self.repo, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write(content)
            self.git("add", name)
        self.git("commit", "-q", "-m", message)

    def require(self, start=None):
        return subprocess.run([sys.executable, "-I", TOOL, "require-entry", "--range", f"{start or self.base}..HEAD",
                               "--repo", self.repo], capture_output=True, text=True)

    def test_a_player_facing_change_without_an_entry_fails(self):
        self.commit({"Sources/App/Feature.swift": "1"}, "Add a feature")
        result = self.require()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Add a feature", result.stderr)

    def test_an_entry_in_the_range_passes(self):
        self.commit({"runtime/n/patches/x.patch": "1"}, "Fix the engine")
        self.commit({"CHANGELOG.md": "# Changelog\n\n- entry\n"}, "Changelog for the fix")
        self.assertEqual(self.require().returncode, 0)

    def test_changelog_none_passes(self):
        self.commit({"Sources/App/Refactor.swift": "1"}, "Refactor\n\nChangelog: none")
        self.assertEqual(self.require().returncode, 0)

    def test_internal_paths_need_no_entry(self):
        self.commit({"Tests/AppTests/T.swift": "1", "docs/b.md": "b", "qa/x.sh": "x", "tools/y.py": "y"}, "Tests")
        self.assertEqual(self.require().returncode, 0)

    def test_a_new_branch_or_a_rewritten_history_checks_nothing(self):
        self.commit({"App/Info.plist.in": "1"}, "Change the app")
        self.assertEqual(self.require("0" * 40).returncode, 0)
        self.assertEqual(self.require("1" * 40).returncode, 0)

    def test_a_malformed_range_is_refused(self):
        result = subprocess.run([sys.executable, "-I", TOOL, "require-entry", "--range", "HEAD", "--repo", self.repo],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("--range must be <a>..<b>", result.stderr)


if __name__ == "__main__":
    unittest.main()
