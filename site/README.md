# The Warzag website

`site/` is the download site for players: four HTML pages in the style of a 1990s web page. They are unstyled: no
stylesheet and no CSS of any kind, so the browser's own look shows (black serif text on white, blue underlined
links, rules between sections), light mode only. No JavaScript, no web fonts, no CDNs, no cookies or analytics:
each page's Content-Security-Policy allows only the site's own images, which also means the browser refuses any CSS.

| File | What it is |
|---|---|
| `index.html` | The home page: the icon, the name, one line on what Warzag is, the Download link with the requirements, links to First Launch, the FAQ, the Changes page and the source code, and a one-line disclaimer, centred in the window and short enough to need no scrolling |
| `first-launch.html` | The Open Anyway steps (macOS 15 and later) in four lines, and what happens next |
| `faq.html` | Account safety, Open Anyway, checking the download, the Terminal installer, Rosetta, Steam, updates, privacy, help, uninstalling, the source code |
| `changes.html` | What changed in each version, newest first, from `CHANGELOG.md` (below) |
| `icon.png` | The Warzag icon (on the home page and as the favicon): the snail from `App/AppIcon.png` without its grey background, 128 px, transparent |
| `build.py` | Fills in the repository and the Changes page, and writes the site to publish (not published itself) |

The home page centres itself without CSS, as 1990s pages did: a layout table as wide and as tall as the window, with
one centred cell holding the whole page. A table fills the window's height only in quirks mode, so the home page
starts with the HTML 3.2 doctype (`<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">`) instead of
`<!doctype html>`: keep it, or the page jumps to the top of the window. The other three pages are ordinary pages in
standards mode and share one header (the navigation bar, `[ Home | First Launch | FAQ | Changes | Source Code ]`) and
one footer (the license and the disclaimer).

## The repository name

The pages never name the GitHub repository themselves: they say `OWNER/REPO`, and only ever right after
`github.com/`, and `build.py` fills in the real one (the Pages workflow passes the repository it runs in):

| URL in the pages | Where |
|---|---|
| `https://github.com/OWNER/REPO/releases/latest/download/Warzag.dmg` | `index.html`: the Download link |
| `https://github.com/OWNER/REPO/releases/latest/download/Warzag.dmg.sha256` | `faq.html`: the checksum to check a download against |
| `https://github.com/OWNER/REPO/releases/latest/download/install.sh` | `faq.html`: the Terminal installer command |
| `https://github.com/OWNER/REPO` | every page: "Source Code"; the footers and `faq.html`: "GitHub" and the source code answer |
| `https://github.com/OWNER/REPO/blob/main/LICENSE` | `first-launch.html`, `faq.html` and `changes.html`: the footer |
| `https://github.com/OWNER/REPO/blob/main/tools/release/install.sh` | `faq.html`: the installer's source |
| `https://github.com/OWNER/REPO/issues` | `faq.html`: where to get help |

Nobody edits these by hand. `build.py` copies the pages and `icon.png` into an output folder with `OWNER/REPO`
replaced by the repository and the Changes page filled in (below):

```sh
python3 -I site/build.py --repo <owner>/<name> --out _site                      # a preview
python3 -I site/build.py --repo <owner>/<name> --fetch-release --out _site      # what the Pages workflow runs
```

`--fetch-release` first checks the latest release: it downloads its `Warzag.dmg.sha256`, `Warzag.dmg`, `install.sh`
and `Warzag.manifest.json` from `https://github.com/<owner>/<name>/releases/latest/download/` (where the Download
link, the FAQ's checksum link and its Terminal command point) and refuses to build unless the image hashes to the
published checksum and `install.sh` installs that same image: its `DMG_SHA256=` line holds the checksum and its
`DMG_URL=` line a plain https URL serving an image with that checksum. So players get the same image whichever way
they install, and the checksum the FAQ sends them to matches it. `Warzag.manifest.json`, the app feed, names the
version the release offers, which tells the Changes page what is out (below). With no release yet (none of the four
files) it warns and builds; with only some of them it fails. `--out` must be missing, empty or an earlier build's
output, outside `site/`, and nothing is written unless every check passed. To preview, build into a scratch folder
and open its `index.html`.

## The Changes page

`changes.html` lists what changed in each released version of Warzag, newest first. Nobody writes that list by hand:
`build.py` makes it from `CHANGELOG.md` every time it builds the site, so the page always says what the changelog
says. The page holds everything else and marks where the list goes:

```html
<!-- releases: site/build.py fills this in from CHANGELOG.md -->
<p>No version has been released yet.</p>
<!-- /releases -->
```

`build.py` replaces these lines with the released sections of the changelog, never Unreleased: after an `<hr>`, the
version as a heading with an anchor (`changes.html#v0.1.0`), its date, and its Major, Minor and Bug fixes entries as
lists. With `--fetch-release`, as the Pages workflow builds it, only the releases that are out: the version the latest
release's `Warzag.manifest.json` offers and the ones before it. A release's section is in the changelog before the
release is built and published, and stays there if the release is withdrawn (marked as a pre-release again); the
build fails if the changelog has no section for the version that is out. Before the first release, only the line
between the markers stays. Entries are plain text: their continuation lines are joined, everything is escaped, and
only Markdown's `` `inline code` `` becomes `<code>`. The changelog is read with `tools/release/changelog.py`, so
whenever `python3 -I tools/release/changelog.py check` fails, the build fails too, naming the same problems.
`--changelog <file>` builds the page from another changelog (the checks use it).

## Publishing on GitHub Pages

`.github/workflows/pages.yml` checks, builds and deploys the site. It needs no secrets: only the workflow's own
`GITHUB_TOKEN`, with `pages: write` and `id-token: write` for the deploy job and `actions: write` for the job that
re-runs the workflow after a release. Its actions are pinned to commit SHAs (checkout v7.0.1, upload-pages-artifact
v5.0.0, deploy-pages v5.0.1).

One-time setup in the repository, once the first release is published: **Settings > Pages > Build and deployment >
Source: GitHub Actions**, then **Actions > Site > Run workflow** (or wait for the daily run). Turning Pages on earlier
publishes nothing either: no run deploys before a release carries the files below, and the first such release's own
run then deploys the site.

It runs on pushes to `main` that touch the site or `CHANGELOG.md` (or `tools/release/install.sh` and
`App/make-app.sh`, which the checks read, and `tools/release/changelog.py`, which reads the changelog for the build),
on pull requests (checks and build, no deploy), daily, by hand (**Actions > Site > Run workflow**) and when a release
is published. So the Changes page follows every edit to the changelog within minutes. A release event runs on the
release's tag, which the `github-pages` environment does not deploy from, so that run only starts the workflow again
on the default branch: that run puts the new release on the Changes page as the release is published. A release
withdrawn by marking it as a pre-release leaves the page with the next run (daily, or by hand).

A run deploys only a released site. `build.py --fetch-release` adds `released=true` to its step's outputs when the
latest release's files were there and passed the checks above, and `released=false` when there is no release yet:
then the Download link and the Terminal command would lead to GitHub 404s, so the run checks and builds the site,
adds a "Site not deployed" notice and stops there. Pull requests build the same way and never deploy.

Every release marked **Latest** must carry `Warzag.dmg`, `Warzag.dmg.sha256`, `install.sh` and
`Warzag.manifest.json`, because the Download link points at `releases/latest/download/Warzag.dmg`, the FAQ links
`releases/latest/download/Warzag.dmg.sha256`, its Terminal command runs `releases/latest/download/install.sh`
(without it, `curl` gets a 404 and `sh` runs nothing) and the Changes page lists the version the manifest offers.
`App/make-app.sh --dmg --dmg-url <URL>` writes the first three and `tools/release/mkappupdate.sh` the manifest
(`docs/RELEASING.md`). Publish a release without them (a runtime pack on its own, say) as a pre-release. If the
latest release has only some of them, the build fails; if it has none, the run warns and deploys nothing.

## Checks

```sh
python3 -I qa/site/site-test.py
```

Page structure (language, viewport, CSP, one `h1` and headings in order, alt text, labelled landmarks), no scripts or
resources from elsewhere, internal links and anchors that resolve, external links only to the repository,
`OWNER/REPO` only inside `github.com` URLs, the disclaimer, nothing personal; unstyled (no stylesheet, `<style>`,
`style=` or `class=`, no `style-src` in the CSP, no colour-scheme or theme-color tags); the home page unchanged (its
SHA-256), short (45 words at most) and centred (its doctype, the layout table and its one cell); the other pages'
shared header and footer, with the navigation bar at the top only; one "Back to top" link, in the footers of the FAQ
and the Changes page; the icon; and `build.py`, including `--fetch-release` against a local stand-in for a release
(with its `install.sh`, made from `tools/release/install.sh` as `App/make-app.sh` makes it, and its
`Warzag.manifest.json`), its refusals, and the Changes page it builds from sample changelogs (every release newest
first with its date and entries, nothing from Unreleased, with `--fetch-release` only the releases that are out,
escaping and `<code>`, the page before the first release, the repository's own `CHANGELOG.md`, and the changelogs it
refuses); and that a change to `CHANGELOG.md` runs the workflow. Python 3.9 or later, nothing else. The workflow runs
it before every build.

## What the copy relies on

Keep these in step with the app and the release:

- The button, menu and setting names (Get Started, Play, Use a Warframe Account Instead, Export Diagnostics, Check for
  Updates, Updates, Update, Update Now) and the setup are the app's own (`Sources/WarzagApp/Model/Strings.swift`).
- The Open Anyway steps are Apple's for macOS 15 Sequoia and macOS 26 Tahoe, which are the same on both (Apple's Mac
  User Guide, "Open a Mac app from an unknown developer").
- Updates: `faq.html#updates` says Warzag checks for new versions of itself and its engine once a day (the app's
  "Check for updates automatically" setting, on by default) and that Update downloads, checks and installs them,
  keeping the previous engine; `faq.html#privacy` says Warzag downloads its engine from the Warzag project. Both hold
  for releases built with the app feed and the engine feed (`App/make-app.sh --update-url` and `--feed-url`,
  `docs/RELEASING.md` step 3, "Warzag's own updates" and "The engine"). A build without them is published as a
  pre-release, which the site never offers (`docs/RELEASING.md`, step 6).
- The Terminal installer is the release's `install.sh` (`docs/RELEASING.md`); "downloads the same Warzag.dmg"
  (`faq.html#installer`) holds because the build checks it (above).

## Changing things

- **The look** is the browser's own, on purpose. The checks refuse stylesheets, `<style>`, `style=` and `class=`;
  HTML of the period that is not CSS is fine (`<hr>`, `<b>`, `<small>`, `align=`, `valign=`).
- **The home page** is finished: the checks hold it to its SHA-256 (`HOME_SHA256` in `qa/site/site-test.py`), so a
  change to it must change that checksum too. It stays short (the checks allow 45 words) and everything on it stays
  inside the layout table's one cell, under its HTML 3.2 doctype.
- **The icon**: replace `icon.png`, keeping the name: a square PNG (128 px, the snail from
  `App/AppIcon.png` on a transparent background; the app's own icon keeps its grey square).
- **The header and footer** of `first-launch.html`, `faq.html` and `changes.html` are the same on all three, but for
  `aria-current="page"` on the page's own link in the navigation bar and the "Back to top" link at the start of the
  long pages' footers (the FAQ and Changes): change all three the same way (the checks compare them). The home page
  has its own links and disclaimer, inside its cell.
- **What changed** goes in `CHANGELOG.md`, never in `changes.html`, whose own text is outside its marked region (and,
  for the time before the first release, the line inside it).
- **Terminal commands** in the FAQ are `<code>` in a paragraph, not `<pre>`, so they wrap on a phone; `<wbr>` marks
  where the long URL may wrap without changing what a copy gets.
