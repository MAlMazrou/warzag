#!/usr/bin/env python3
"""Warzag's changelog (CHANGELOG.md): check it, cut a release from it, print a release's notes.

    tools/release/changelog.py check [--file <CHANGELOG.md>]
    tools/release/changelog.py next-version [--file <CHANGELOG.md>]
    tools/release/changelog.py release <x.y.z> [--date <YYYY-MM-DD>] [--file <CHANGELOG.md>]
    tools/release/changelog.py notes <x.y.z> [--file <CHANGELOG.md>]
    tools/release/changelog.py require-entry --range <a>..<b> [--repo <dir>]

The format (CHANGELOG.md says it in words): an "## [Unreleased]" section first, then one "## [x.y.z] - YYYY-MM-DD"
section per release, newest first. A section has up to three subsections, in this order: "### Major", "### Minor" and
"### Bug fixes", each with at least one "- " entry (an entry continues on lines indented by two spaces). The headings
decide the version (Semantic Versioning): a release with a Major entry raises the first number, one with Minor entries
but no Major the second, one with only Bug fixes the third.

  check          the format, newest first, and that each release's number follows from its headings and the release
                 before it
  next-version   the number the Unreleased entries call for
  release        moves the Unreleased entries into a new section for <x.y.z>, dated today unless --date; refused when
                 Unreleased is empty or the number does not follow from its headings
  notes          a released section's subsections and entries, for GitHub's release notes
  require-entry  for CI: fails when commits in <a>..<b> changed what players get (Sources/, App/, runtime/, bridge/) and
                 none of them changed CHANGELOG.md, unless each of those commits has a "Changelog: none" line (an
                 internal change); <a> of all zeros (a new branch) checks nothing

Exit status: 0 fine, 1 a check failed (the reasons go to stderr), 2 bad usage or an unreadable file.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_FILE = os.path.join(ROOT, "CHANGELOG.md")

KINDS = ("Major", "Minor", "Bug fixes")
UNRELEASED = "Unreleased"
SECTION = re.compile(r"^## \[(?P<name>[^\]]+)\](?: - (?P<date>\S+))?\s*$")
SUBSECTION = re.compile(r"^### (?P<kind>.+?)\s*$")
VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# What players get: a commit touching these needs an entry (or "Changelog: none").
PLAYER_FACING = ("Sources/", "App/", "runtime/", "bridge/")
NO_ENTRY = re.compile(r"^Changelog:\s*none\s*$", re.I | re.M)


class ChangelogError(Exception):
    """CHANGELOG.md breaks the format, or a command cannot do what it was asked."""


class Section:
    def __init__(self, name, date, line):
        self.name = name
        self.date = date
        self.line = line
        # kind -> its entries, each a list of lines (the "- " line and its continuation lines), in file order
        self.kinds = {}

    @property
    def version(self):
        match = VERSION.match(self.name)
        return tuple(int(part) for part in match.groups()) if match else None

    def entries(self):
        return sum(len(entries) for entries in self.kinds.values())

    def body(self):
        """The section's subsections and entries as Markdown, without its "## [...]" line."""
        out = []
        for kind in KINDS:
            if kind in self.kinds:
                out.append(f"### {kind}")
                out.append("")
                for entry in self.kinds[kind]:
                    out.extend(entry)
                out.append("")
        return "\n".join(out).rstrip("\n")


def parse(text):
    """(preamble lines, sections, problems): the problems are every format error found, with line numbers."""
    problems = []
    preamble = []
    sections = []
    current = None
    kind = None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        section = SECTION.match(line)
        if section:
            current = Section(section.group("name"), section.group("date"), number)
            sections.append(current)
            kind = None
            continue
        if current is None:
            # The introduction above the sections is free text.
            preamble.append(raw)
            continue
        if not line:
            continue
        subsection = SUBSECTION.match(line)
        if subsection:
            kind = subsection.group("kind")
            if kind not in KINDS:
                problems.append(f"line {number}: '### {kind}' is not one of " + ", ".join(f"'### {k}'" for k in KINDS))
                kind = None
            elif kind in current.kinds:
                problems.append(f"line {number}: a second '### {kind}' in [{current.name}]")
            elif any(KINDS.index(seen) > KINDS.index(kind) for seen in current.kinds):
                problems.append(f"line {number}: '### {kind}' comes after a later heading in [{current.name}] "
                                "(order: " + ", ".join(KINDS) + ")")
                current.kinds[kind] = []
            else:
                current.kinds[kind] = []
            continue
        if line.startswith("#"):
            problems.append(f"line {number}: unexpected heading {line!r} in [{current.name}]")
            continue
        if kind is None:
            problems.append(f"line {number}: text outside a '### Major', '### Minor' or '### Bug fixes' subsection "
                            f"in [{current.name}]")
            continue
        if line.startswith("- "):
            current.kinds[kind].append([line])
        elif line.startswith("  ") and current.kinds[kind]:
            current.kinds[kind][-1].append(line)
        else:
            problems.append(f"line {number}: neither a '- ' entry nor its indented continuation in [{current.name}]")
    return preamble, sections, problems


def bump(version, kinds):
    major, minor, patch = version
    if "Major" in kinds:
        return (major + 1, 0, 0)
    if "Minor" in kinds:
        return (major, minor + 1, 0)
    return (major, minor, patch + 1)


def text_version(version):
    return ".".join(str(part) for part in version)


def check(sections, problems):
    """Adds every problem with the order, the dates and the version numbers to `problems`."""
    if not sections or sections[0].name != UNRELEASED:
        problems.append("the first section must be '## [Unreleased]'")
    elif sections[0].date:
        problems.append(f"line {sections[0].line}: '## [Unreleased]' takes no date")
    releases = []
    for section in sections:
        if section.name == UNRELEASED:
            if section is not sections[0]:
                problems.append(f"line {section.line}: a second '## [Unreleased]'")
            continue
        if section.version is None:
            problems.append(f"line {section.line}: '{section.name}' is not a version number x.y.z")
            continue
        if not section.date or not DATE.match(section.date):
            problems.append(f"line {section.line}: [{section.name}] needs its date: '## [{section.name}] - YYYY-MM-DD'")
        else:
            try:
                datetime.date.fromisoformat(section.date)
            except ValueError:
                problems.append(f"line {section.line}: [{section.name}] has no real date: {section.date}")
        if not section.entries():
            problems.append(f"line {section.line}: [{section.name}] lists no change")
        releases.append(section)
    for section in sections:
        for kind, entries in section.kinds.items():
            if not entries:
                problems.append(f"line {section.line}: '### {kind}' in [{section.name}] has no entry")
    for newer, older in zip(releases, releases[1:]):
        if newer.version <= older.version:
            problems.append(f"line {newer.line}: [{newer.name}] must be newer than the release below it, [{older.name}]")
            continue
        expected = bump(older.version, newer.kinds)
        if newer.version != expected:
            problems.append(f"line {newer.line}: [{newer.name}] should be {text_version(expected)}: after "
                            f"{older.name}, its headings ({', '.join(newer.kinds)}) call for that number")
        if newer.date and older.date and DATE.match(newer.date) and DATE.match(older.date) and newer.date < older.date:
            problems.append(f"line {newer.line}: [{newer.name}] is dated before [{older.name}]")
    return releases


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        print(f"changelog: cannot read {path}: {error.strerror}", file=sys.stderr)
        sys.exit(2)
    return text


def checked(path):
    """(text, preamble, sections, releases); exits 1 with every problem when the file breaks the format."""
    text = load(path)
    preamble, sections, problems = parse(text)
    releases = check(sections, problems)
    if problems:
        for problem in problems:
            print(f"changelog: {problem}", file=sys.stderr)
        sys.exit(1)
    return text, preamble, sections, releases


def next_version(sections, releases):
    unreleased = sections[0]
    if not unreleased.entries():
        raise ChangelogError("Unreleased lists no change: there is nothing to release")
    if not releases:
        raise ChangelogError("there is no release yet: name the first version yourself (release <x.y.z>)")
    return text_version(bump(releases[0].version, unreleased.kinds))


def release(path, version, date):
    text, preamble, sections, releases = checked(path)
    if not VERSION.match(version):
        raise ChangelogError(f"'{version}' is not a version number x.y.z")
    if any(section.name == version for section in releases):
        raise ChangelogError(f"[{version}] is already released")
    unreleased = sections[0]
    if not unreleased.entries():
        raise ChangelogError("Unreleased lists no change: there is nothing to release")
    if releases:
        expected = next_version(sections, releases)
        if version != expected:
            raise ChangelogError(f"the Unreleased headings ({', '.join(unreleased.kinds)}) after "
                                 f"{releases[0].name} call for {expected}, not {version}")
    if not DATE.match(date):
        raise ChangelogError(f"'{date}' is not a date YYYY-MM-DD")
    datetime.date.fromisoformat(date)
    lines = text.splitlines()
    # The Unreleased section runs from its heading to the next section (or the end).
    start = unreleased.line - 1
    end = sections[1].line - 1 if len(sections) > 1 else len(lines)
    new = lines[:start] + [f"## [{UNRELEASED}]", "", f"## [{version}] - {date}", ""] + unreleased.body().splitlines()
    rest = lines[end:]
    if rest:
        new += [""] + rest
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(new).rstrip("\n") + "\n")
    # What was written must pass the same check.
    checked(path)


def notes(path, version):
    _, _, _, releases = checked(path)
    for section in releases:
        if section.name == version:
            return section.body()
    raise ChangelogError(f"CHANGELOG.md has no section for {version}: run 'tools/release/changelog.py release "
                         f"{version}' first")


def git(repo, *arguments):
    result = subprocess.run(["git", "-C", repo, *arguments], capture_output=True, text=True)
    if result.returncode:
        raise ChangelogError(f"git {' '.join(arguments)}: {result.stderr.strip()}")
    return result.stdout


def require_entry(repo, commit_range):
    match = re.fullmatch(r"(?P<a>[0-9A-Za-z_./~^-]+)\.\.(?P<b>[0-9A-Za-z_./~^-]+)", commit_range)
    if not match:
        raise ChangelogError(f"--range must be <a>..<b>, not {commit_range!r}")
    if set(match.group("a")) == {"0"}:
        print("changelog: a new branch (no earlier commit to compare with): nothing to check")
        return
    if subprocess.run(["git", "-C", repo, "cat-file", "-e", match.group("a") + "^{commit}"],
                      capture_output=True).returncode:
        # A force push replaced the history the range starts from.
        print(f"changelog: {match.group('a')} is not in this history (a force push?): nothing to check")
        return
    commits = git(repo, "rev-list", "--no-merges", commit_range).split()
    changelog_changed = False
    needs_entry = []
    for commit in commits:
        files = git(repo, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit).split("\n")
        if "CHANGELOG.md" in files:
            changelog_changed = True
        if any(name.startswith(PLAYER_FACING) for name in files):
            message = git(repo, "log", "-1", "--format=%B", commit)
            if not NO_ENTRY.search(message):
                needs_entry.append((commit, git(repo, "log", "-1", "--format=%s", commit).strip()))
    if needs_entry and not changelog_changed:
        print("changelog: these commits change what players get, but CHANGELOG.md has no new entry. Add one under "
              "'## [Unreleased]' (Major, Minor or Bug fixes), or end an internal commit's message with "
              "'Changelog: none':", file=sys.stderr)
        for commit, subject in needs_entry:
            print(f"  {commit[:12]} {subject}", file=sys.stderr)
        sys.exit(1)
    print(f"changelog: {len(commits)} commit(s) checked")


def main(argv):
    parser = argparse.ArgumentParser(prog="changelog.py", description="Check and cut releases from CHANGELOG.md.")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "next-version"):
        command = commands.add_parser(name)
        command.add_argument("--file", default=DEFAULT_FILE)
    command = commands.add_parser("release")
    command.add_argument("version")
    command.add_argument("--date", default=datetime.date.today().isoformat())
    command.add_argument("--file", default=DEFAULT_FILE)
    command = commands.add_parser("notes")
    command.add_argument("version")
    command.add_argument("--file", default=DEFAULT_FILE)
    command = commands.add_parser("require-entry")
    command.add_argument("--range", required=True, dest="commit_range")
    command.add_argument("--repo", default=ROOT)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "check":
            _, _, sections, releases = checked(arguments.file)
            print(f"changelog: ok ({len(releases)} release(s), {sections[0].entries()} unreleased entries)")
        elif arguments.command == "next-version":
            _, _, sections, releases = checked(arguments.file)
            print(next_version(sections, releases))
        elif arguments.command == "release":
            release(arguments.file, arguments.version, arguments.date)
            print(f"changelog: released {arguments.version}")
        elif arguments.command == "notes":
            print(notes(arguments.file, arguments.version))
        elif arguments.command == "require-entry":
            require_entry(arguments.repo, arguments.commit_range)
    except ChangelogError as error:
        print(f"changelog: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
