#!/usr/bin/env python3
"""Build the Warzag download site: fill in the repository and the Changes page, check the latest release, write a
deployable copy.

    python3 -I site/build.py --repo <owner>/<name> --out <dir> [--fetch-release [--release-base <url>]]
                             [--changelog <file>]

The pages in site/ name the GitHub repository with the literal text OWNER/REPO, always right after "github.com/"
(site/README.md). This script copies the published files (the .html, .css and .png files; not itself or the README)
into --out, with OWNER/REPO replaced by --repo. In changes.html, the region from the "<!-- releases: ... -->" line to
the "<!-- /releases -->" line becomes the released sections of CHANGELOG.md (with --fetch-release, only those already
out), newest first: each version with its date and its Major, Minor and Bug fixes entries, escaped, with `code` as
<code>. Before the first release, only the text inside the region stays. The changelog is read with
tools/release/changelog.py, so the build fails wherever "changelog.py check" would.

  --fetch-release         check the latest release first: its Warzag.dmg.sha256, Warzag.dmg, install.sh and
                          Warzag.manifest.json are downloaded from the release base (default
                          https://github.com/<repo>/releases/latest/download, where the Download link, the FAQ's
                          checksum link and its Terminal command point). The build fails unless the image hashes to the
                          published value and install.sh expects that value and downloads, from its DMG_URL, an image
                          that hashes to it. The Changes page then lists only the version Warzag.manifest.json (the app
                          feed) offers and the ones before it, and the build fails if the changelog has no section for
                          that version: a release's section is in CHANGELOG.md before the release is built and
                          published, and stays there if the release is withdrawn. With none of the four files there (no
                          release yet) the build goes on with a warning and lists no version; with only some of them it
                          fails.
  --release-base <url>    another https:// location for --fetch-release (file:// for tests, where install.sh may
                          download from a file:// URL too)
  --changelog <file>      another changelog for the Changes page (tests; default: the repository's CHANGELOG.md)

--out must be missing, empty or an earlier build's output, and outside site/. Nothing is written unless every check
passed. Exit status: 0 built, 1 refused or failed, 2 usage.

With --fetch-release under GitHub Actions ($GITHUB_OUTPUT names a file), a build that passed also appends
released=true (the latest release's files were there and checked) or released=false (no release yet) to that file.
The Pages workflow deploys only a released site: before the first release, its Download link and Terminal command
would lead to GitHub 404s.
"""
import argparse
import base64
import errno
import hashlib
import html
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request

SITE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SITE)
PUBLISHED_EXTENSIONS = (".html", ".css", ".png")
PLACEHOLDER = "OWNER/REPO"
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
CHANGES_PAGE = "changes.html"
RELEASES_BEGIN = "<!-- releases: site/build.py fills this in from CHANGELOG.md -->\n"
RELEASES_END = "<!-- /releases -->\n"
# A code span as in Markdown, which GitHub's release notes use: a run of backticks, the code, and a run of as many
# backticks, neither run touching another backtick.
INLINE_CODE_RE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
DMG = "Warzag.dmg"
INSTALLER = "install.sh"
MANIFEST = "Warzag.manifest.json"
MAX_DMG_BYTES = 2 << 30  # far above today's image of about 2 MB
MAX_INSTALLER_BYTES = 64 << 10  # today's install.sh is about 5 KB
MAX_MANIFEST_BYTES = 64 << 10  # today's app manifest is about 1 KB

# GitHub owner names: letters, digits and hyphens, up to 39 characters; repository names: letters, digits, '.', '-'
# and '_'. Neither can carry anything that means something in HTML or a URL. Matched with fullmatch: '$' would let a
# trailing newline through.
REPO_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
# The two lines of tools/release/install.sh that App/make-app.sh --dmg fills in, and the download URLs it accepts for
# the second (its URL_PATTERN: https, and nothing that means something inside the script's double quotes).
INSTALLER_SHA256_RE = re.compile(r'^DMG_SHA256="\$\{WARZAG_DMG_SHA256:-(.*)\}"$', re.M)
INSTALLER_URL_RE = re.compile(r'^DMG_URL="\$\{WARZAG_DMG_URL:-(.*)\}"$', re.M)
DMG_URL_RE = re.compile(r"https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/%+=,@:;!*'()&?#-]*)?")


def load_changelog_tool():
    """tools/release/changelog.py, whose parser and checks the Changes page uses, so the two never disagree."""
    sys.dont_write_bytecode = True  # no __pycache__ in tools/release/
    spec = importlib.util.spec_from_file_location("changelog", os.path.join(ROOT, "tools", "release", "changelog.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


changelog = load_changelog_tool()


class BuildError(Exception):
    pass


def check_repo(repo):
    if not REPO_RE.fullmatch(repo) or repo.split("/")[1] in (".", ".."):
        raise BuildError(f"--repo must be <owner>/<name> as on GitHub, not {repo!r}")
    if repo.lower() == PLACEHOLDER.lower():
        raise BuildError("--repo is still the placeholder OWNER/REPO")


def check_sha256(value, origin):
    value = value.strip().lower()
    if not SHA256_RE.fullmatch(value):
        raise BuildError(f"{origin}: not a SHA-256 (64 hex digits)")
    return value


def parse_sha256_file(text, origin):
    """The checksum from a "<hex>  Warzag.dmg" line (shasum -a 256 output); the name, when given, must be the image."""
    lines = text.strip().splitlines()
    if not lines:
        raise BuildError(f"{origin}: empty")
    fields = lines[0].split()
    if len(fields) > 1 and os.path.basename(fields[1].lstrip("*")) != DMG:
        raise BuildError(f"{origin}: the checksum is for {fields[1]!r}, not {DMG}")
    return check_sha256(fields[0], origin)


def open_url(url):
    """The response for `url`, or None when nothing is there (HTTP 404, or a missing file:// path)."""
    try:
        response = urllib.request.urlopen(url, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise BuildError(f"{url}: HTTP {error.code}")
    except urllib.error.URLError as error:
        if isinstance(error.reason, OSError) and error.reason.errno == errno.ENOENT:
            return None
        raise BuildError(f"{url}: {error.reason}")
    # GitHub redirects release downloads to its storage host; never accept a redirect away from https.
    if url.startswith("https://") and not response.geturl().startswith("https://"):
        response.close()
        raise BuildError(f"{url}: redirected away from https")
    return response


def read_limited(response, limit, url):
    """A response's whole body, refused when it is longer than `limit` bytes."""
    data = b""
    while True:
        chunk = response.read(limit + 1 - len(data))
        if not chunk:
            return data
        data += chunk
        if len(data) > limit:
            raise BuildError(f"{url}: larger than {limit} bytes")


def sha256_of(response, url):
    """The SHA-256 of a response's body, refused past MAX_DMG_BYTES."""
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = response.read(1 << 20)
        if not chunk:
            return digest.hexdigest()
        size += len(chunk)
        if size > MAX_DMG_BYTES:
            raise BuildError(f"{url}: larger than {MAX_DMG_BYTES} bytes")
        digest.update(chunk)


def installer_value(text, pattern, name, url):
    values = pattern.findall(text)
    if len(values) != 1:
        raise BuildError(f"{url}: {len(values)} {name}= lines instead of the one tools/release/install.sh has, so it "
                         f"is not an installer App/make-app.sh --dmg wrote")
    return values[0]


def check_installer(text, url, checksum, base, verified_dmg_url):
    """The FAQ's Terminal command (curl <url> | sh) must install the image whose checksum the release publishes:
    install.sh expects that checksum (DMG_SHA256) and downloads, from DMG_URL, an image that hashes to it."""
    expected = installer_value(text, INSTALLER_SHA256_RE, "DMG_SHA256", url)
    if expected.lower() != checksum:  # install.sh lowercases it too
        raise BuildError(f"{url} expects an image with SHA-256 {expected!r}, but the release's {DMG} is {checksum}: "
                         "the Terminal command would refuse it")
    download = installer_value(text, INSTALLER_URL_RE, "DMG_URL", url)
    if not download or "@DMG_URL@" in download:
        raise BuildError(f"{url} has no download URL (App/make-app.sh --dmg was run without --dmg-url), so the "
                         "Terminal command would stop with 'no download URL'")
    if not (DMG_URL_RE.fullmatch(download) or (base.startswith("file://") and download.startswith("file://"))):
        raise BuildError(f"{url}: its download URL {download!r} is not a plain https:// URL")
    if download == verified_dmg_url:
        return
    response = open_url(download)
    if response is None:
        raise BuildError(f"{url} downloads {download}, which does not exist: the Terminal command would fail")
    with response:
        actual = sha256_of(response, download)
    if actual != checksum:
        raise BuildError(f"{url} downloads {download}, which hashes to {actual}, not to the release's {checksum}: "
                         "the Terminal command would refuse it")


def parse_manifest(data, url):
    """The version the app feed offers. Warzag.manifest.json is a signed envelope whose base64 "payload" is the app
    manifest (kind "app", and the version players get); Warzag checks its signature, the site only reads the
    version."""
    try:
        payload = json.loads(base64.b64decode(json.loads(data)["payload"], validate=True))
    except (ValueError, TypeError, KeyError):
        raise BuildError(f"{url}: not a signed manifest (a JSON envelope with a base64 payload)")
    if not isinstance(payload, dict) or payload.get("kind") != "app":
        raise BuildError(f"{url}: not an app manifest (kind 'app'), so not the app feed tools/release/mkappupdate.sh "
                         "signs")
    version = payload.get("version")
    if not isinstance(version, str) or not changelog.VERSION.fullmatch(version):
        raise BuildError(f"{url}: the app manifest's version is {version!r}, not a version x.y.z as in CHANGELOG.md")
    return version


def joined(names, word):
    """'a', 'a and b', 'a, b and c' (or with 'or')."""
    return f"{', '.join(names[:-1])} {word} {names[-1]}" if len(names) > 1 else names[0]


def fetch_release(base):
    """The latest release's (checksum of Warzag.dmg, version): the checksum verified against the image itself and
    against the release's install.sh, the version read from its app feed manifest; None when none of the four files is
    there (no release yet)."""
    names = (f"{DMG}.sha256", DMG, INSTALLER, MANIFEST)
    urls = [f"{base}/{name}" for name in names]
    sha_url, dmg_url, installer_url, manifest_url = urls
    responses = []
    try:
        for url in urls:
            responses.append(open_url(url))
        missing = [name for name, response in zip(names, responses) if response is None]
        if len(missing) == len(names):
            return None
        if missing:
            present = [name for name in names if name not in missing]
            raise BuildError(f"{base} has {joined(present, 'and')} but not {joined(missing, 'or')}: a release marked "
                             f"Latest carries {joined(names, 'and')} (App/make-app.sh --dmg writes the first three, "
                             f"tools/release/mkappupdate.sh the manifest)")
        sha_response, dmg_response, installer_response, manifest_response = responses
        published = parse_sha256_file(sha_response.read(4096).decode("utf-8", "replace"), sha_url)
        installer = read_limited(installer_response, MAX_INSTALLER_BYTES, installer_url).decode("utf-8", "replace")
        version = parse_manifest(read_limited(manifest_response, MAX_MANIFEST_BYTES, manifest_url), manifest_url)
        actual = sha256_of(dmg_response, dmg_url)
    finally:
        for response in responses:
            if response is not None:
                response.close()
    if actual != published:
        raise BuildError(f"{dmg_url} hashes to {actual} but {sha_url} says {published}: the published checksum "
                         "does not match the download")
    check_installer(installer, installer_url, published, base, dmg_url)
    return published, version


def check_placeholders(name, text):
    for match in re.finditer(re.escape(PLACEHOLDER), text):
        if not text[:match.start()].endswith("github.com/"):
            line = text.count("\n", 0, match.start()) + 1
            raise BuildError(f"{name}:{line}: {PLACEHOLDER} outside a github.com/ URL")


def read_releases(path, name):
    """The changelog's released sections, newest first (never Unreleased), checked as changelog.py check does."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise BuildError(f"{name}: {error.strerror}")
    except UnicodeDecodeError:
        raise BuildError(f"{name}: not UTF-8 text")
    _, sections, problems = changelog.parse(text)
    releases = changelog.check(sections, problems)
    if problems:
        raise BuildError(f"{name} breaks the changelog format, so the Changes page cannot be built "
                         "(tools/release/changelog.py check):\n" + "\n".join(f"  {problem}" for problem in problems))
    return releases


def published_releases(releases, version, name):
    """The releases players can download: the latest release's version and the ones before it, or none before the
    first release. The changelog gets a release's section before the release is built and published, and keeps it
    when the release is withdrawn (marked as a pre-release again)."""
    if version is None:
        return []
    number = tuple(int(part) for part in version.split("."))
    if number not in [release.version for release in releases]:
        raise BuildError(f"the latest release is Warzag {version}, but {name} has no [{version}] section "
                         "(tools/release/changelog.py release cuts it before the release is built)")
    return [release for release in releases if release.version <= number]


def code_html(match):
    """A code span's <code>. As in Markdown, code that starts and ends with a space (`` `a` `` shows `a`) loses one
    space at each end."""
    code = match.group(2)
    if code.startswith(" ") and code.endswith(" ") and code.strip(" "):
        code = code[1:-1]
    return f'<code translate="no">{code}</code>'


def entry_html(lines):
    """One entry: its "- " line and continuation lines as one escaped line, with `code` as <code>."""
    text = " ".join([lines[0][len("- "):].strip()] + [line.strip() for line in lines[1:]])
    return INLINE_CODE_RE.sub(code_html, html.escape(text, quote=False))


def releases_html(releases):
    """The Changes page's list: each release's version, date and entries, newest first, after a rule."""
    blocks = []
    for release in releases:
        version = html.escape(release.name)
        parts = [f'<hr>\n\n<h2 id="v{version}">Version {version}</h2>',
                 f"<p>Released {html.escape(release.date)}.</p>"]
        for kind in changelog.KINDS:
            if kind in release.kinds:
                items = "".join(f"<li>{entry_html(entry)}</li>\n" for entry in release.kinds[kind])
                parts.append(f"<h3>{html.escape(kind)}</h3>\n\n<ul>\n{items}</ul>")
        blocks.append("\n\n".join(parts))
    return "\n\n".join(blocks) + "\n"


def fill_releases(text, releases):
    """changes.html with its marked region replaced by the releases, or by what the region holds before the first
    release."""
    if (text.count(RELEASES_BEGIN) != 1 or text.count(RELEASES_END) != 1
            or text.index(RELEASES_BEGIN) > text.index(RELEASES_END)):
        raise BuildError(f"{CHANGES_PAGE}: needs one {RELEASES_BEGIN.strip()!r} line and, below it, one "
                         f"{RELEASES_END.strip()!r} line")
    before, rest = text.split(RELEASES_BEGIN)
    no_release, after = rest.split(RELEASES_END)
    return before + (releases_html(releases) if releases else no_release) + after


def render(repo, releases):
    """{published file name: bytes} for the whole site."""
    names = sorted(name for name in os.listdir(SITE)
                   if name.endswith(PUBLISHED_EXTENSIONS) and os.path.isfile(os.path.join(SITE, name)))
    for page in ("index.html", CHANGES_PAGE):
        if page not in names:
            raise BuildError(f"site/{page} is missing")
    files = {}
    for name in names:
        with open(os.path.join(SITE, name), "rb") as handle:
            data = handle.read()
        if not name.endswith(".html"):
            if PLACEHOLDER.encode() in data:
                raise BuildError(f"{name}: only the pages may name {PLACEHOLDER}")
            files[name] = data
            continue
        text = data.decode("utf-8")
        check_placeholders(name, text)
        text = text.replace(PLACEHOLDER, repo)
        # Only after OWNER/REPO is replaced, so the changelog's text is never changed.
        if name == CHANGES_PAGE:
            text = fill_releases(text, releases)
        files[name] = text.encode("utf-8")
    return files


def write(out, files):
    out = os.path.abspath(out)
    if out == SITE or out.startswith(SITE + os.sep):
        raise BuildError("--out must be outside site/")
    if os.path.lexists(out) and not os.path.isdir(out):
        raise BuildError(f"--out {out!r} exists and is not a directory")
    if os.path.isdir(out):
        # Only an earlier build's output may be overwritten (its files, and the .<name>.part files of a build that
        # was interrupted): never a directory with anything else in it.
        for entry in os.listdir(out):
            path = os.path.join(out, entry)
            name = entry[1:-len(".part")] if entry.startswith(".") and entry.endswith(".part") else entry
            if not name.endswith(PUBLISHED_EXTENSIONS) or os.path.islink(path) or not os.path.isfile(path):
                raise BuildError(f"--out holds {entry!r}, so it is not an earlier build's output; use an empty "
                                 "directory")
        for entry in os.listdir(out):
            if entry not in files:
                os.remove(os.path.join(out, entry))
    os.makedirs(out, exist_ok=True)
    for name, data in files.items():
        temporary = os.path.join(out, f".{name}.part")
        with open(temporary, "wb") as handle:
            handle.write(data)
        os.replace(temporary, os.path.join(out, name))


def warn(message):
    print(f"site-build: warning: {message}", file=sys.stderr)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::warning title=Site checksum::{message}")


def report_released(released):
    """released=true|false for the GitHub Actions workflow, when it gave us an output file."""
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"released={'true' if released else 'false'}\n")
    except OSError as error:
        raise BuildError(f"$GITHUB_OUTPUT {path}: {error.strerror}")


def main(argv):
    parser = argparse.ArgumentParser(prog="site/build.py", description="Build the Warzag download site.")
    parser.add_argument("--repo", required=True, help="the GitHub repository, <owner>/<name>")
    parser.add_argument("--out", required=True, help="output directory (missing, empty or an earlier build)")
    parser.add_argument("--fetch-release", action="store_true",
                        help="check the latest release first (its Warzag.dmg against Warzag.dmg.sha256 and "
                             "install.sh) and list only its version and older ones on the Changes page")
    parser.add_argument("--release-base", help="where --fetch-release downloads from (default: the latest release)")
    parser.add_argument("--changelog", help="the changelog the Changes page lists (default: the repository's "
                                            "CHANGELOG.md)")
    args = parser.parse_args(argv)
    if args.release_base and not args.fetch_release:
        parser.error("--release-base needs --fetch-release")

    try:
        check_repo(args.repo)
        path, name = (CHANGELOG, "CHANGELOG.md") if args.changelog is None else (args.changelog, args.changelog)
        releases = read_releases(path, name)
        sha = version = None
        if args.fetch_release:
            base = (args.release_base or f"https://github.com/{args.repo}/releases/latest/download").rstrip("/")
            if not base.startswith(("https://", "file://")):
                raise BuildError("--release-base must be an https:// URL")
            latest = fetch_release(base)
            if latest is None:
                warn(f"no release at {base} yet (no {DMG}, {DMG}.sha256, {INSTALLER} or {MANIFEST}): the site's "
                     "Download link and Terminal installer have nothing to download")
            else:
                sha, version = latest
            releases = published_releases(releases, version, name)
        files = render(args.repo, releases)
        write(args.out, files)
        if args.fetch_release:
            report_released(sha is not None)
    except BuildError as error:
        print(f"site-build: {error}", file=sys.stderr)
        return 1
    if not args.fetch_release:
        release = "release not checked"
    else:
        release = f"release {version} ({sha}) checked" if sha else "no release yet"
    print(f"site-build: {len(files)} files in {args.out} for {args.repo}, {release}, "
          f"{len(releases)} release(s) on the Changes page")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
