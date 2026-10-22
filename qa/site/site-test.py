#!/usr/bin/env python3
"""Tests for the download site (site/) and its build script (site/build.py).

    python3 -I qa/site/site-test.py

The pages: language, viewport, Content-Security-Policy, one h1 and headings in order, alt text, labelled landmarks, no
scripts or resources from elsewhere, internal links and anchors that resolve, external links only to the repository,
OWNER/REPO only inside github.com URLs, the disclaimer, nothing personal. Unstyled, as web pages were in the 1990s:
no stylesheet or CSS of any kind, no classes, no colour-scheme tags. The home page is unchanged (its checksum), short
and centred in the window by a layout table (quirks mode, from its HTML 3.2 doctype); the other pages share one
header and footer. The icon. build.py: the repository filled in, --fetch-release against a local stand-in for a
release (matching, mismatching, missing and half-published; its install.sh expecting another image, unfilled, or
downloading from elsewhere; its Warzag.manifest.json and the version it offers), the released=true|false it reports
to GitHub Actions, its refusals, and the output directory rules. The Changes page it builds from a changelog: every
release newest first with its date and entries, never Unreleased, with --fetch-release only the releases already out,
entries escaped with `code` as <code>, the page before the first release, the repository's own CHANGELOG.md, and the
changelogs it refuses. The Pages workflow's deploy gate (only a released site is deployed) and the changes that run
it. Needs nothing but Python 3.9+.
"""
import base64
import hashlib
import html.parser
import importlib.util
import itertools
import json
import os
import struct
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.request

sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SITE = os.path.join(ROOT, "site")
BUILD = os.path.join(SITE, "build.py")
RELEASE_TOOLS = os.path.join(ROOT, "tools", "release")
RELEASE_FILES = ("Warzag.dmg", "Warzag.dmg.sha256", "install.sh", "Warzag.manifest.json")
PAGES = sorted(name for name in os.listdir(SITE) if name.endswith(".html"))
PUBLISHED = sorted(PAGES + ["icon.png"])
HOME = "index.html"
CHANGES = "changes.html"
SUBPAGES = [name for name in PAGES if name != HOME]
# The pages long enough to need a "Back to top" link.
LONG_PAGES = ("changes.html", "faq.html")
# The home page is finished: a change to it must be deliberate, and change this checksum with it.
HOME_SHA256 = "ced4e0f6aa7d705d629aaa9845ac1740f9c02dbcb9cba49b2f0829454a816f98"
REPOSITORY_URL = "https://github.com/OWNER/REPO"
SAMPLE = hashlib.sha256(b"warzag site test").hexdigest()
# The home page's doctype puts browsers in quirks mode, where a table of height 100% fills the window: that centres
# the page without CSS. The other pages are in standards mode.
QUIRKS = '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">'
STANDARDS = "<!doctype html>"
# The most words the home page may show, so that it fits a phone's screen without scrolling.
HOME_WORDS = 45
DISCLAIMER = "affiliated with or endorsed by Digital Extremes or Valve."
BACK_TO_TOP = '<p><a href="#top">Back to top</a></p>\n'
NAVIGATION_BAR = "[ Home | First Launch | FAQ | Changes | Source Code ]"
# What the Changes page says before the first release.
NO_RELEASE = "<p>No version has been released yet.</p>\n"
# A changelog in the format tools/release/changelog.py checks, and the list the Changes page makes of it: its two
# releases, newest first, and nothing from Unreleased.
SAMPLE_CHANGELOG = """\
# Changelog

Free text.

## [Unreleased]

### Minor

- An unreleased change.

## [0.2.0] - 2026-11-04

### Minor

- `warzagctl status` shows the engine,
  on two lines.

### Bug fixes

- A fix.

## [0.1.0] - 2026-10-21

### Major

- The first version.
"""
SAMPLE_RELEASES = """\
<hr>

<h2 id="v0.2.0">Version 0.2.0</h2>

<p>Released 2026-11-04.</p>

<h3>Minor</h3>

<ul>
<li><code translate="no">warzagctl status</code> shows the engine, on two lines.</li>
</ul>

<h3>Bug fixes</h3>

<ul>
<li>A fix.</li>
</ul>

<hr>

<h2 id="v0.1.0">Version 0.1.0</h2>

<p>Released 2026-10-21.</p>

<h3>Major</h3>

<ul>
<li>The first version.</li>
</ul>
"""


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.elements = []
        self.ids = []
        self.headings = []
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.elements.append((tag, attrs))
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if re.fullmatch(r"h[1-6]", tag):
            self.headings.append(int(tag[1]))
        if tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def read(name, directory=SITE):
    with open(os.path.join(directory, name), encoding="utf-8") as handle:
        return handle.read()


def parse_text(text):
    page = Page()
    page.feed(text)
    page.close()
    return page


def parse(name, directory=SITE):
    return parse_text(read(name, directory))


def block(text, start, end):
    return text[text.index(start):text.index(end, text.index(start)) + len(end)]


def words(name):
    """The words a page shows (its body's text; the navigation bar's brackets and bars are not words)."""
    body = block(read(name), "<body>", "</body>")
    return [word for word in html.unescape(re.sub(r"<[^>]+>", " ", body)).split() if re.search(r"\w", word)]


class PageTests(unittest.TestCase):
    def test_there_are_pages(self):
        self.assertEqual(PAGES, ["changes.html", "faq.html", "first-launch.html", "index.html"])

    def test_every_page_has_the_basics(self):
        for name in PAGES:
            with self.subTest(page=name):
                text = read(name)
                page = parse(name)
                doctype = QUIRKS if name == HOME else STANDARDS
                self.assertTrue(text.startswith(f'{doctype}\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'))
                metas = [attrs for tag, attrs in page.elements if tag == "meta"]
                named = {attrs["name"]: attrs.get("content", "") for attrs in metas if "name" in attrs}
                self.assertIn("width=device-width", named.get("viewport", ""))
                self.assertTrue(named.get("description"))
                policies = [attrs["content"] for attrs in metas if attrs.get("http-equiv") == "Content-Security-Policy"]
                self.assertEqual(len(policies), 1)
                self.assertIn("default-src 'none'", policies[0])
                self.assertNotIn("script-src", policies[0])
                self.assertTrue(page.title.strip())
                links = [attrs for tag, attrs in page.elements if tag == "link"]
                self.assertEqual(links, [{"rel": "icon", "href": "icon.png", "type": "image/png"}])

    def test_unstyled(self):
        """The browser's own look, as web pages had in the 1990s: no stylesheet and no CSS of any kind (the CSP refuses
        it as well), no classes, and no colour-scheme or theme-color tags, so the pages stay black on white."""
        self.assertEqual([name for name in os.listdir(SITE) if name.endswith(".css")], [])
        for name in PAGES:
            with self.subTest(page=name):
                self.assertNotIn("<style", read(name))
                for tag, attrs in parse(name).elements:
                    self.assertNotIn("style", attrs)
                    self.assertNotIn("class", attrs)
                    if tag == "meta":
                        self.assertNotIn(attrs.get("name"), ("color-scheme", "theme-color"))
                        if attrs.get("http-equiv") == "Content-Security-Policy":
                            self.assertNotIn("style-src", attrs["content"])

    def test_structure_and_accessibility(self):
        for name in PAGES:
            with self.subTest(page=name):
                page = parse(name)
                self.assertEqual(page.headings[0], 1)
                self.assertEqual(page.headings.count(1), 1)
                for previous, level in zip(page.headings, page.headings[1:]):
                    self.assertLessEqual(level, previous + 1, "a heading level is skipped")
                self.assertEqual(len(page.ids), len(set(page.ids)), "duplicate ids")
                tags = [tag for tag, attrs in page.elements]
                self.assertEqual(tags.count("main"), 1)
                self.assertEqual(tags.count("footer"), 1)
                self.assertEqual(tags.count("header"), 0 if name == HOME else 1)
                current = [(tag, attrs.get("href")) for tag, attrs in page.elements
                           if attrs.get("aria-current") == "page"]
                self.assertEqual(current, [] if name == HOME else [("a", name)],
                                 "a page's navigation bar marks its own link (the home page has none)")
                for tag, attrs in page.elements:
                    if tag == "img":
                        for key in ("alt", "width", "height"):
                            self.assertIn(key, attrs)
                    if tag == "nav":
                        self.assertTrue(attrs.get("aria-label"))
                    if attrs.get("role") == "img":
                        self.assertTrue(attrs.get("aria-label"))
                    for target in attrs.get("aria-labelledby", "").split():
                        self.assertIn(target, page.ids)

    def test_nothing_runs_and_nothing_loads_from_elsewhere(self):
        for name in PAGES:
            with self.subTest(page=name):
                for tag, attrs in parse(name).elements:
                    self.assertNotIn(tag, ("script", "iframe", "object", "embed", "form", "base", "noscript"))
                    self.assertEqual([key for key in attrs if key.startswith("on")], [])
                    for key in ("src", "srcset", "poster", "data", "background"):
                        if key in attrs:
                            self.assertNotRegex(attrs[key], r"^([a-z]+:|//)", "resources are the site's own")
                    if tag == "link":
                        self.assertNotRegex(attrs.get("href", ""), r"^([a-z]+:|//)")

    def test_links_resolve(self):
        pages = {name: parse(name) for name in PAGES}
        for name, page in pages.items():
            for tag, attrs in page.elements:
                if tag != "a":
                    continue
                href = attrs.get("href", "")
                with self.subTest(page=name, href=href):
                    self.assertTrue(href)
                    if re.match(r"^[a-z]+:", href):
                        self.assertTrue(href == REPOSITORY_URL or href.startswith(REPOSITORY_URL + "/"),
                                        "external links go to the repository only")
                        continue
                    target, _, fragment = href.partition("#")
                    target = target or name
                    self.assertIn(target, pages)
                    if fragment:
                        self.assertIn(fragment, pages[target].ids)

    def test_placeholders(self):
        for name in PAGES:
            text = read(name)
            for match in re.finditer("OWNER/REPO", text):
                with self.subTest(page=name, offset=match.start()):
                    self.assertTrue(text[:match.start()].endswith("github.com/"))
        self.assertIn(("a", {"href": f"{REPOSITORY_URL}/releases/latest/download/Warzag.dmg"}), parse(HOME).elements)
        for name in os.listdir(SITE):
            if name.endswith((".css", ".svg")):
                self.assertNotIn("OWNER/REPO", read(name))

    def test_home_page_is_unchanged(self):
        with open(os.path.join(SITE, HOME), "rb") as handle:
            self.assertEqual(hashlib.sha256(handle.read()).hexdigest(), HOME_SHA256,
                             "the home page is finished: change HOME_SHA256 only with a deliberate change to it")

    def test_home_page_is_short_and_centred(self):
        """One screen, everything in the middle: a layout table as tall and wide as the window, with one centred
        cell that holds the whole page."""
        text = read(HOME)
        page = parse(HOME)
        tables = [attrs for tag, attrs in page.elements if tag == "table"]
        self.assertEqual(tables, [{"role": "presentation", "width": "100%", "height": "100%"}])
        cells = [attrs for tag, attrs in page.elements if tag in ("td", "th")]
        self.assertEqual(cells, [{"align": "center", "valign": "middle"}])
        body = block(text, "<body>", "</body>")
        cell = block(body, '<td align="center" valign="middle">', "</td>")
        self.assertEqual(re.sub(r"<[^>]+>", "", body.replace(cell, "")).strip(), "", "everything is in the cell")
        self.assertLessEqual(len(words(HOME)), HOME_WORDS, "the home page stays short")
        self.assertIn(DISCLAIMER, text)
        links = {attrs.get("href") for tag, attrs in page.elements if tag == "a"}
        self.assertLessEqual({"first-launch.html", "faq.html", REPOSITORY_URL}, links)

    def test_subpages_share_the_header_and_footer(self):
        """The same header and footer, but for the page's own link in the navigation bar (aria-current) and the
        long pages' "Back to top" link at the start of their footer."""
        headers = {block(read(name), "<header>", "</header>").replace(' aria-current="page"', "") for name in SUBPAGES}
        footers = {block(read(name), "<footer>", "</footer>").replace(BACK_TO_TOP, "") for name in SUBPAGES}
        self.assertEqual(len(headers), 1)
        self.assertEqual(len(footers), 1)
        header = headers.pop()
        footer = footers.pop()
        self.assertRegex(header, r"<p>\[ .* \]</p>", "the header holds the navigation bar")
        self.assertEqual(re.sub(r"<[^>]+>", "", re.search(r"<p>\[ .* \]</p>", header).group()), NAVIGATION_BAR)
        self.assertNotRegex(footer, r"<p>\[ .* \]</p>", "the navigation bar is at the top only")
        for sentence in ("Warzag is an unofficial community project.", "It is not " + DISCLAIMER,
                         "Warframe is a trademark of Digital Extremes Ltd.",
                         "Steam is a trademark of Valve Corporation.", "GPL-3.0"):
            self.assertIn(sentence, footer)

    def test_one_back_to_top_link(self):
        """The long pages, the FAQ and Changes, have one "Back to top" link, at the start of their footer: not one
        after every answer or version. The other pages are short and have none."""
        for name in PAGES:
            with self.subTest(page=name):
                tops = [attrs for tag, attrs in parse(name).elements if tag == "a" and attrs.get("href") == "#top"]
                self.assertEqual(len(tops), 1 if name in LONG_PAGES else 0)
        for name in LONG_PAGES:
            self.assertTrue(block(read(name), "<footer>", "</footer>").startswith("<footer>\n" + BACK_TO_TOP))

    def test_nothing_personal(self):
        patterns = [r"/Users/", r"/home/", r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+",
                    r"\b(?:\d{1,3}\.){3}\d{1,3}\b", r"7656119\d{10}"]
        home = os.path.expanduser("~")
        for name in sorted(os.listdir(SITE)):
            path = os.path.join(SITE, name)
            if not os.path.isfile(path):
                continue
            if name.endswith(".png"):
                # Binary: scan its bytes too (PNG text chunks could carry a path or a name).
                with open(path, "rb") as handle:
                    text = handle.read().decode("latin-1")
            else:
                text = read(name)
            with self.subTest(file=name):
                for pattern in patterns:
                    self.assertIsNone(re.search(pattern, text), pattern)
                if home not in ("", "/"):
                    self.assertNotIn(home, text)


class IconTests(unittest.TestCase):
    def test_icon_is_a_small_square_png(self):
        with open(os.path.join(SITE, "icon.png"), "rb") as handle:
            data = handle.read()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(data[12:16], b"IHDR")
        width, height = struct.unpack(">II", data[16:24])
        self.assertEqual(width, height)
        self.assertGreaterEqual(width, 64)
        # Shown at 64 pixels on the home page and as the favicon: keep it light.
        self.assertLess(len(data), 64 * 1024)


def run_build(*args, github_output=None):
    """build.py in a subprocess. The workflow runs these checks inside GitHub Actions: the builds here must not add
    outputs to that job's own $GITHUB_OUTPUT, so it is replaced by `github_output` (or left out)."""
    env = {key: value for key, value in os.environ.items() if key not in ("GITHUB_OUTPUT", "GITHUB_ACTIONS")}
    if github_output is not None:
        env["GITHUB_OUTPUT"] = github_output
    return subprocess.run([sys.executable, "-I", BUILD, *args], capture_output=True, text=True, env=env)


def filled_installer(checksum, url):
    """tools/release/install.sh as App/make-app.sh --dmg writes it: only the DMG_SHA256= line and, given a URL, the
    DMG_URL= line are filled in."""
    lines = []
    for line in read("install.sh", RELEASE_TOOLS).splitlines(keepends=True):
        if line.startswith("DMG_SHA256="):
            line = line.replace("@DMG_SHA256@", checksum)
        elif line.startswith("DMG_URL=") and url is not None:
            line = line.replace("@DMG_URL@", url)
        lines.append(line)
    return "".join(lines)


def app_manifest(version, kind="app"):
    """A Warzag.manifest.json as tools/release/mkappupdate.sh signs it, with only what build.py reads filled in: the
    envelope (key id, base64 payload, signature) around an app manifest naming `version`. The signature is a
    stand-in, which build.py does not check."""
    payload = {"build": "1", "kind": kind, "schema": 1, "version": version}
    return json.dumps({"keyId": "0123456789abcdef",
                       "payload": base64.b64encode(json.dumps(payload, sort_keys=True).encode()).decode(),
                       "signature": base64.b64encode(bytes(64)).decode()}, indent=2, sort_keys=True) + "\n"


def file_url(path):
    return "file://" + urllib.request.pathname2url(path)


def load_build():
    """site/build.py as a module, for the rules a file:// stand-in cannot reach (sys.dont_write_bytecode is set, so
    no __pycache__ appears in site/)."""
    spec = importlib.util.spec_from_file_location("site_build", BUILD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = self.temp.name
        self.out = os.path.join(self.dir, "out")

    def tearDown(self):
        self.temp.cleanup()

    def release(self, image=b"disk image", checksum=None, files=RELEASE_FILES, installer_sha256=None,
                installer_url="", installer_text=None, version="0.2.0", manifest_text=None):
        """A local stand-in for releases/latest/download, as a file:// URL. Its install.sh expects the image's
        checksum and downloads the release's own Warzag.dmg unless told otherwise (installer_url None: not filled
        in, as App/make-app.sh --dmg leaves it without --dmg-url). Its Warzag.manifest.json offers `version`, the
        newest release in the changelog fetch() builds with."""
        base = os.path.join(self.dir, "release")
        os.makedirs(base, exist_ok=True)
        actual = hashlib.sha256(image).hexdigest()
        if "Warzag.dmg" in files:
            with open(os.path.join(base, "Warzag.dmg"), "wb") as handle:
                handle.write(image)
        if "Warzag.dmg.sha256" in files:
            with open(os.path.join(base, "Warzag.dmg.sha256"), "w") as handle:
                handle.write(f"{checksum or actual}  Warzag.dmg\n")
        if "install.sh" in files:
            if installer_text is None:
                url = file_url(os.path.join(base, "Warzag.dmg")) if installer_url == "" else installer_url
                installer_text = filled_installer(installer_sha256 or actual, url)
            with open(os.path.join(base, "install.sh"), "w") as handle:
                handle.write(installer_text)
        if "Warzag.manifest.json" in files:
            with open(os.path.join(base, "Warzag.manifest.json"), "w") as handle:
                handle.write(app_manifest(version) if manifest_text is None else manifest_text)
        return file_url(base)

    def fetch(self, base, github_output=None):
        """build.py --fetch-release from `base`, with SAMPLE_CHANGELOG for the Changes page: the repository's own
        changelog may not have the stand-in's version yet."""
        changelog = os.path.join(self.dir, "CHANGELOG.md")
        with open(changelog, "w", encoding="utf-8") as handle:
            handle.write(SAMPLE_CHANGELOG)
        return run_build("--repo", "o/r", "--fetch-release", "--release-base", base, "--out", self.out,
                         "--changelog", changelog, github_output=github_output)

    def assert_refused(self, result, message):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse(os.path.exists(self.out), "nothing is written after a failed check")

    def fresh(self):
        """A scratch directory and output path of its own, for one subtest."""
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = temp.name
        self.out = os.path.join(temp.name, "out")

    def test_fills_in_the_repository(self):
        result = run_build("--repo", "test-owner/warzag.site", "--out", self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(os.listdir(self.out)), PUBLISHED)
        self.assertEqual(read(HOME, self.out), read(HOME).replace("OWNER/REPO", "test-owner/warzag.site"),
                         "the build changes nothing else on the home page")
        for name in PAGES:
            text = read(name, self.out)
            self.assertNotIn("OWNER/REPO", text)
            self.assertIn("https://github.com/test-owner/warzag.site", text)
            for tag, attrs in parse(name, self.out).elements:
                href = attrs.get("href", "") if tag == "a" else ""
                if href.startswith("https://"):
                    self.assertTrue(href.startswith("https://github.com/test-owner/warzag.site"))
        self.assertIn('href="https://github.com/test-owner/warzag.site/releases/latest/download/Warzag.dmg"',
                      read("index.html", self.out))

    def test_fetch_release_checks_the_image(self):
        base = self.release(image=b"the real image")
        result = self.fetch(base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(hashlib.sha256(b"the real image").hexdigest(), result.stdout)

    def test_fetch_release_refuses_a_checksum_that_does_not_match(self):
        base = self.release(image=b"the real image", checksum=SAMPLE, installer_sha256=SAMPLE)
        self.assert_refused(self.fetch(base), "does not match the download")

    def test_fetch_release_without_a_release_warns(self):
        result = self.fetch(self.release(files=()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning", result.stderr)
        self.assertIn("no release yet", result.stdout)

    def test_fetch_release_tells_the_workflow_whether_there_is_a_release(self):
        """released=true|false in $GITHUB_OUTPUT: the Pages workflow deploys only a released site."""
        def outputs(path):
            if not os.path.exists(path):
                return ""
            with open(path) as handle:
                return handle.read()

        for name, options, returncode, expected in (
                ("released", dict(), 0, "released=true\n"),
                ("no release yet", dict(files=()), 0, "released=false\n"),
                ("a failed check", dict(checksum=SAMPLE), 1, "")):
            with self.subTest(case=name):
                self.fresh()
                github_output = os.path.join(self.dir, "github-output")
                with open(github_output, "w") as handle:
                    handle.write("earlier=kept\n")
                result = self.fetch(self.release(**options), github_output)
                self.assertEqual(result.returncode, returncode, result.stderr)
                self.assertEqual(outputs(github_output), "earlier=kept\n" + expected, "appended, never replaced")
        with self.subTest(case="not --fetch-release"):
            self.fresh()
            github_output = os.path.join(self.dir, "github-output")
            result = run_build("--repo", "o/r", "--out", self.out, github_output=github_output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs(github_output), "", "only --fetch-release knows whether a release exists")

    def test_fetch_release_with_part_of_a_release_fails(self):
        for files in [files for size in range(1, len(RELEASE_FILES))
                      for files in itertools.combinations(RELEASE_FILES, size)]:
            with self.subTest(files=files):
                self.fresh()
                self.assert_refused(self.fetch(self.release(files=files)), "a release marked Latest carries")

    def test_fetch_release_checks_the_installer(self):
        """The FAQ's Terminal command runs the release's install.sh, which must install the image the release's
        Warzag.dmg.sha256 names."""
        image = b"the real image"
        cases = [
            ("expects another image", dict(installer_sha256=SAMPLE), "the Terminal command would refuse it"),
            ("checksum not filled in", dict(installer_sha256="@DMG_SHA256@"), "'@DMG_SHA256@'"),
            ("no download URL", dict(installer_url=None), "no download URL"),
            ("not https", dict(installer_url="http://example.com/Warzag.dmg"), "not a plain https:// URL"),
            ("not an installer", dict(installer_text="<!doctype html><p>Not Found</p>\n"), "0 DMG_SHA256= lines"),
            ("too large", dict(installer_text="#" * (64 << 10) + "\n"), "larger than 65536 bytes"),
        ]
        for name, options, message in cases:
            with self.subTest(case=name):
                self.fresh()
                self.assert_refused(self.fetch(self.release(image=image, **options)), message)
        with self.subTest(case="two DMG_SHA256 lines"):
            self.fresh()
            text = filled_installer(hashlib.sha256(image).hexdigest(),
                                    file_url(os.path.join(self.dir, "release", "Warzag.dmg")))
            text += next(line for line in text.splitlines(keepends=True) if line.startswith("DMG_SHA256="))
            self.assert_refused(self.fetch(self.release(image=image, installer_text=text)), "2 DMG_SHA256= lines")

    def test_fetch_release_downloads_what_the_installer_downloads(self):
        image = b"the real image"
        for name, mirrored, message in (("the same image elsewhere", image, None),
                                        ("another image", b"another image", "the Terminal command would refuse it"),
                                        ("nothing there", None, "which does not exist")):
            with self.subTest(case=name):
                self.fresh()
                mirror = os.path.join(self.dir, "mirror", "Warzag.dmg")
                if mirrored is not None:
                    os.makedirs(os.path.dirname(mirror))
                    with open(mirror, "wb") as handle:
                        handle.write(mirrored)
                result = self.fetch(self.release(image=image, installer_url=file_url(mirror)))
                if message is None:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(hashlib.sha256(image).hexdigest(), result.stdout)
                else:
                    self.assert_refused(result, message)

    def test_fetch_release_reads_the_app_feed_manifest(self):
        """The version comes from the release's Warzag.manifest.json, the app feed: a signed envelope whose base64
        payload is an app manifest naming a version x.y.z."""
        envelope = json.loads(app_manifest("0.2.0"))
        for name, text, message in (
                ("not JSON", "<!doctype html><p>Not Found</p>\n", "not a signed manifest"),
                ("payload not base64", json.dumps(dict(envelope, payload="not base64")), "not a signed manifest"),
                ("a runtime manifest", app_manifest("0.2.0", kind="runtime"), "not an app manifest"),
                ("a version that is not x.y.z", app_manifest("0.2"), "the app manifest's version is '0.2'"),
                ("too large", " " * (64 << 10) + app_manifest("0.2.0"), "larger than 65536 bytes")):
            with self.subTest(case=name):
                self.fresh()
                self.assert_refused(self.fetch(self.release(manifest_text=text)), message)

    def test_the_changes_page_lists_the_releases_that_are_out(self):
        """A release's section is in CHANGELOG.md before the release is built and published, and stays there when the
        release is withdrawn (marked as a pre-release again). With --fetch-release, the Changes page lists the version
        the latest release offers and the ones before it, and none before the first release; the build fails when
        the changelog has no section for that version."""
        for name, options, listed in (("the newest one out", dict(version="0.2.0"), ["v0.2.0", "v0.1.0"]),
                                      ("the newest one not out yet, or withdrawn", dict(version="0.1.0"), ["v0.1.0"]),
                                      ("no release yet", dict(files=()), [])):
            with self.subTest(case=name):
                self.fresh()
                result = self.fetch(self.release(**options))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"{len(listed)} release(s) on the Changes page", result.stdout)
                self.assertEqual([attrs["id"] for tag, attrs in parse(CHANGES, self.out).elements if tag == "h2"],
                                 listed)
                if not listed:
                    self.assertIn(NO_RELEASE, read(CHANGES, self.out))
        with self.subTest(case="not in the changelog"):
            self.fresh()
            self.assert_refused(self.fetch(self.release(version="0.3.0")), "has no [0.3.0] section")

    def test_installer_download_urls(self):
        """The download URLs build.py accepts in a release's install.sh are those App/make-app.sh --dmg-url writes
        (https only; file:// only next to a file:// release base, which only tests use)."""
        make_app = re.search(r'^URL_PATTERN="\^(.*)\\\$"$', read("make-app.sh", os.path.join(ROOT, "App")), re.M)
        self.assertIsNotNone(make_app)
        build = load_build()
        self.assertEqual(build.DMG_URL_RE.pattern, make_app.group(1))
        base = "https://github.com/o/r/releases/latest/download"
        own = f"{base}/Warzag.dmg"
        build.check_installer(filled_installer(SAMPLE, own), f"{base}/install.sh", SAMPLE, base, own)
        for url in ("file:///tmp/Warzag.dmg", "http://example.com/Warzag.dmg", "https://example.com/$(id).dmg",
                    "https://example.com/a b.dmg", "https://example.com/`id`.dmg"):
            with self.subTest(url=url), self.assertRaisesRegex(build.BuildError, "not a plain https:// URL"):
                build.check_installer(filled_installer(SAMPLE, url), f"{base}/install.sh", SAMPLE, base, own)

    def test_refusals(self):
        # --option=value, so that a value starting with '-' reaches the checks instead of argparse.
        for repo in ("owner", "a/b/c", "-owner/repo", "owner/..", "owner/re po", "owner/<b>", "OWNER/REPO",
                     "owner/", "/repo", "owner/repo\n", ""):
            with self.subTest(repo=repo):
                self.assertEqual(run_build(f"--repo={repo}", "--out", self.out).returncode, 1)
        self.assertEqual(run_build("--repo", "o/r", "--fetch-release", "--release-base", "http://example.com",
                                   "--out", self.out).returncode, 1)
        self.assertFalse(os.path.exists(self.out))
        for args in (("--repo", "o/r"), ("--out", self.out),
                     ("--repo", "o/r", "--out", self.out, "--sha256", SAMPLE),
                     ("--repo", "o/r", "--out", self.out, "--release-base", "https://example.com")):
            with self.subTest(args=args):
                self.assertEqual(run_build(*args).returncode, 2)

    def test_output_directory(self):
        os.makedirs(self.out)
        with open(os.path.join(self.out, "notes.txt"), "w") as handle:
            handle.write("mine")
        result = run_build("--repo", "o/r", "--out", self.out)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(os.listdir(self.out), ["notes.txt"])

        earlier = os.path.join(self.dir, "earlier")
        self.assertEqual(run_build("--repo", "o/r", "--out", earlier).returncode, 0)
        with open(os.path.join(earlier, "removed-page.html"), "w") as handle:
            handle.write("an earlier build's page")
        with open(os.path.join(earlier, ".index.html.part"), "w") as handle:
            handle.write("left by an interrupted build")
        result = run_build("--repo", "o/r", "--out", earlier)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(os.listdir(earlier)), PUBLISHED)

        inside = os.path.join(SITE, "_site")
        self.assertEqual(run_build("--repo", "o/r", "--out", inside).returncode, 1)
        self.assertFalse(os.path.exists(inside))


class ChangesTests(unittest.TestCase):
    """The Changes page: build.py lists a changelog's releases in the marked region of changes.html."""

    @classmethod
    def setUpClass(cls):
        cls.build = load_build()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = temp.name

    def build_with(self, changelog):
        """build.py with a changelog of `changelog` (text, or bytes as they are): (result, output directory, path of
        the changelog)."""
        directory = tempfile.mkdtemp(dir=self.dir)
        path = os.path.join(directory, "CHANGELOG.md")
        with open(path, "wb") as handle:
            handle.write(changelog if isinstance(changelog, bytes) else changelog.encode("utf-8"))
        out = os.path.join(directory, "out")
        return run_build("--repo", "o/r", "--out", out, "--changelog", path), out, path

    def page_with(self, changelog):
        result, out, _ = self.build_with(changelog)
        self.assertEqual(result.returncode, 0, result.stderr)
        return read(CHANGES, out)

    def frame(self):
        """changes.html with the repository filled in, split at its marked region: (before, inside, after)."""
        before, rest = read(CHANGES).replace("OWNER/REPO", "o/r").split(self.build.RELEASES_BEGIN)
        inside, after = rest.split(self.build.RELEASES_END)
        return before, inside, after

    def listed(self, page):
        """What a changelog made of a built page: everything between the page's own frame."""
        before, _, after = self.frame()
        self.assertTrue(page.startswith(before) and page.endswith(after), "the page keeps its frame")
        return page[len(before):len(page) - len(after)]

    def test_lists_every_release_newest_first(self):
        """Each released version with its date and its Major, Minor and Bug fixes entries, continuation lines joined;
        nothing from Unreleased, and nothing else on the site changes."""
        result, out, _ = self.build_with(SAMPLE_CHANGELOG)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 release(s) on the Changes page", result.stdout)
        page = read(CHANGES, out)
        self.assertEqual(self.listed(page), SAMPLE_RELEASES)
        self.assertNotIn("unreleased change", page)
        for name in PAGES:
            if name != CHANGES:
                with self.subTest(page=name):
                    self.assertEqual(read(name, out), read(name).replace("OWNER/REPO", "o/r"))

    def test_the_list_keeps_the_page_rules(self):
        """Headings in order below the page's h1, an anchor for each version (changes.html#v0.2.0), and plain
        elements without style or class."""
        page = self.page_with(SAMPLE_CHANGELOG)
        whole = parse_text(page)
        self.assertEqual(whole.headings, [1, 2, 3, 3, 2, 3])
        self.assertEqual(whole.ids, ["top", "v0.2.0", "v0.1.0"])
        for tag, attrs in parse_text(self.listed(page)).elements:
            with self.subTest(tag=tag, attrs=attrs):
                self.assertIn(tag, ("hr", "h2", "p", "h3", "ul", "li", "code"))
                expected = {"h2": ["id"], "code": ["translate"]}.get(tag, [])
                self.assertEqual(sorted(attrs), expected)

    def test_entries_are_escaped(self):
        """An entry is plain text: what looks like markup shows as written, and only `code` becomes <code>, read as
        Markdown reads it (GitHub's release notes show the same entries)."""
        entry = ('Shows <script>alert("x")</script> & <b>bold</b>, `<i>`, ``a ` b`` and `` `c` `` as code and a lone '
                 '` as it is.')
        page = self.page_with("# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-10-21\n\n### Bug fixes\n\n"
                              f"- {entry}\n")
        listed = self.listed(page)
        self.assertIn('<li>Shows &lt;script&gt;alert("x")&lt;/script&gt; &amp; &lt;b&gt;bold&lt;/b&gt;, '
                      '<code translate="no">&lt;i&gt;</code>, <code translate="no">a ` b</code> and '
                      '<code translate="no">`c`</code> as code and a lone ` as it is.</li>\n', listed)
        self.assertEqual([tag for tag, attrs in parse_text(listed).elements if tag in ("script", "b", "i")], [])

    def test_the_page_before_the_first_release(self):
        """With only Unreleased, the page says there is no release yet: the region's own text, without its markers."""
        page = self.page_with("# Changelog\n\n## [Unreleased]\n\n### Major\n\n- An unreleased change.\n")
        before, inside, after = self.frame()
        self.assertEqual(inside, NO_RELEASE)
        self.assertEqual(page, before + NO_RELEASE + after)
        self.assertNotIn("<!--", page)

    def test_the_repositorys_changelog(self):
        """Without --changelog, the page lists the releases in the repository's CHANGELOG.md."""
        out = os.path.join(self.dir, "out")
        result = run_build("--repo", "o/r", "--out", out)
        self.assertEqual(result.returncode, 0, result.stderr)
        versions = re.findall(r"^## \[(\d+\.\d+\.\d+)\] - ", read("CHANGELOG.md", ROOT), re.M)
        self.assertIn(f"{len(versions)} release(s) on the Changes page", result.stdout)
        self.assertEqual([attrs["id"] for tag, attrs in parse(CHANGES, out).elements if tag == "h2"],
                         [f"v{version}" for version in versions])
        if not versions:
            self.assertIn(NO_RELEASE, read(CHANGES, out))

    def test_refuses_a_changelog_that_breaks_the_format(self):
        """The problems tools/release/changelog.py check finds stop the build, which names them and writes nothing."""
        cases = [
            ("an unknown heading", "## [Unreleased]\n\n### Features\n\n- New.\n",
             "line 5: '### Features' is not one of"),
            ("a release without its date", "## [Unreleased]\n\n## [0.1.0]\n\n### Major\n\n- First.\n",
             "[0.1.0] needs its date"),
            ("no Unreleased first", "## [0.1.0] - 2026-10-21\n\n### Major\n\n- First.\n",
             "the first section must be '## [Unreleased]'"),
            ("oldest first", "## [Unreleased]\n\n## [0.1.0] - 2026-10-21\n\n### Major\n\n- First.\n\n"
                             "## [0.2.0] - 2026-11-04\n\n### Minor\n\n- Second.\n",
             "[0.1.0] must be newer than the release below it, [0.2.0]"),
        ]
        for name, sections, problem in cases:
            with self.subTest(case=name):
                result, out, path = self.build_with("# Changelog\n\n" + sections)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"{path} breaks the changelog format", result.stderr)
                self.assertIn(problem, result.stderr)
                self.assertFalse(os.path.exists(out), "nothing is written")
                tool = subprocess.run([sys.executable, "-I", os.path.join(RELEASE_TOOLS, "changelog.py"), "check",
                                       "--file", path], capture_output=True, text=True)
                self.assertEqual(tool.returncode, 1, "changelog.py check refuses it too")
                self.assertIn(problem, tool.stderr)
        with self.subTest(case="not UTF-8"):
            result, out, path = self.build_with(b"# Changelog\n\n## [Unreleased]\n\n### Minor\n\n- \xff\n")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(f"{path}: not UTF-8 text", result.stderr)
            self.assertFalse(os.path.exists(out))
        with self.subTest(case="missing"):
            out = os.path.join(self.dir, "out")
            missing = os.path.join(self.dir, "missing.md")
            result = run_build("--repo", "o/r", "--out", out, "--changelog", missing)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(f"{missing}: ", result.stderr)
            self.assertFalse(os.path.exists(out))

    def test_the_marked_region(self):
        """changes.html holds one region, at the end of <main>; build.py refuses a page without it."""
        build = self.build
        text = read(CHANGES)
        self.assertTrue(block(text, "<main>", "</main>").endswith(build.RELEASES_END + "</main>"))
        swapped = (text.replace(build.RELEASES_BEGIN, "\0").replace(build.RELEASES_END, build.RELEASES_BEGIN)
                   .replace("\0", build.RELEASES_END))
        for name, broken in (("no start", text.replace(build.RELEASES_BEGIN, "")),
                             ("no end", text.replace(build.RELEASES_END, "")),
                             ("two starts", text + build.RELEASES_BEGIN), ("end first", swapped)):
            with self.subTest(case=name), self.assertRaisesRegex(build.BuildError, "needs one"):
                build.fill_releases(broken, [])

    def test_the_faq_points_to_the_changes_page(self):
        self.assertIn(f'<a href="{CHANGES}">', block(read("faq.html"), '<h2 id="updates">', "<hr>"))


class WorkflowTests(unittest.TestCase):
    """.github/workflows/pages.yml cannot run here; this holds its deploy gate in place (plain text, no YAML parser)."""

    def setUp(self):
        self.text = read("pages.yml", os.path.join(ROOT, ".github", "workflows"))

    def job(self, name):
        match = re.search(rf"^  {name}:\n(.*?)(?=^  [a-z-]+:\n|\Z)", self.text, re.M | re.S)
        self.assertIsNotNone(match, f"job {name}")
        return match.group(1)

    def step(self, job, name):
        match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", job, re.M | re.S)
        self.assertIsNotNone(match, f"step {name}")
        return match.group(1)

    def test_only_a_released_site_is_deployed(self):
        build = self.job("build")
        self.assertRegex(build, r"(?m)^    outputs:\n      released: \$\{\{ steps\.site\.outputs\.released \}\}$")
        site = self.step(build, "Build the site")
        self.assertRegex(site, r"(?m)^        id: site$")
        self.assertRegex(site, r"(?m)^        run: python3 -I site/build\.py .*--fetch-release")
        upload = self.step(build, "Upload the site")
        self.assertRegex(upload, r"(?m)^        if: github\.event_name != 'pull_request' && "
                                 r"steps\.site\.outputs\.released == 'true'$")
        deploy = self.job("deploy")
        self.assertRegex(deploy, r"(?m)^    if: .*github\.event_name != 'pull_request' && "
                                 r"needs\.build\.outputs\.released == 'true'$")
        self.assertRegex(deploy, r"(?m)^    needs: build$")

    def test_a_changelog_edit_runs_it(self):
        """The Changes page follows CHANGELOG.md: a push or pull request that changes it, or the script that reads
        it, runs the workflow."""
        for event in ("push", "pull_request"):
            match = re.search(rf"^  {event}:\n(.*?)(?=^  [a-z_]+:\n)", self.text, re.M | re.S)
            self.assertIsNotNone(match, f"event {event}")
            paths = re.findall(r'(?m)^      - "([^"]+)"$', match.group(1))
            for path in ("CHANGELOG.md", "tools/release/changelog.py"):
                with self.subTest(event=event, path=path):
                    self.assertIn(path, paths)


if __name__ == "__main__":
    unittest.main()
