# The Warzag website

`site/` is the download site for players: four HTML pages in the style of a 1990s web page. They are unstyled: no
stylesheet and no CSS of any kind, so the browser's own look shows (black serif text on white, blue underlined
links, rules between sections). The pages follow the system's light or dark mode (a `color-scheme` tag: the browser
draws its own dark look, still without CSS), and **Theme: [ Light | Dark | System ]** at the bottom of every page
overrides it. That line comes from the site's only script, a few lines inline in each page's `<head>`: it applies the
saved choice before the page is drawn and keeps it in the browser's local storage (`warzag-theme`); nothing is sent
anywhere, and without JavaScript the pages simply follow the system. No web fonts, no CDNs, no cookies or analytics:
each page's Content-Security-Policy allows only the site's own images and that one script, by its SHA-256, which also
means the browser refuses any CSS. Change the script on all four pages at once and update the hash in each CSP
(`qa/site/site-test.py` checks both and runs the script in Node).

| File | What it is |
|---|---|
| `index.html` | The home page: the icon, the name, one line on what Warzag is, the Download link with the requirements, links to First Launch, the FAQ, the Changes page and the source code, the developer's GitHub avatar and name, linking to their profile, and a one-line disclaimer, centred in the window and short enough to need no scrolling |
| `first-launch.html` | How to play Warframe on a Mac with Warzag: the download, the Open Anyway steps (macOS 15 and later) in four lines, and what happens next |
| `faq.html` | Playing Warframe on a Mac, which Macs, account safety, Open Anyway, checking the download, the Terminal installer, Rosetta, Steam, the iPhone version, other ways to play, updates, privacy, help, uninstalling, the source code |
| `changes.html` | What changed in each version, newest first, from `CHANGELOG.md` (below) |
| `avatar.png` | The developer's GitHub avatar for the home page's credit, 96 px (shown at 48 px); a copy, because the pages load nothing from other sites: replace it when the GitHub avatar changes |
| `download.png` | The download arrow above the home page's Download link: 32 x 32 pixel art in the old blue style, scaled to 128 px with hard edges (shown at 64 px) |
| `icon.png` | The Warzag icon (on the home page and as the favicon): the snail from `App/AppIcon.png` without its grey background, 128 px, transparent |
| `preview.png` | The picture link previews show (Open Graph and X's large card; not on the pages): the snail from `App/AppIcon.png` centred on its own light grey, 1200 x 630 |
| `build.py` | Fills in the repository, the site's address and the Changes page, writes `sitemap.xml`, and writes the site to publish (not published itself) |

The home page centres itself without CSS, as 1990s pages did: a layout table as wide and as tall as the window, with
one centred cell holding the whole page. A table fills the window's height only in quirks mode, so the home page
starts with the HTML 3.2 doctype (`<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">`) instead of
`<!doctype html>`: keep it, or the page jumps to the top of the window. The other three pages are ordinary pages in
standards mode and share one header (the navigation bar, `[ Home | First Launch | FAQ | Changes | Source Code ]`, with Download Warzag and its arrow at the top right, in a layout table) and
one footer (the license and the disclaimer).

## The repository name

The pages never name the GitHub repository themselves: they say `OWNER/REPO`, and only ever right after
`github.com/`, and `build.py` fills in the real one (the Pages workflow passes the repository it runs in):

| URL in the pages | Where |
|---|---|
| `https://github.com/OWNER/REPO/releases/latest/download/Warzag.dmg` | `index.html`: the Download link; the other pages: Download Warzag in the header; `first-launch.html`: "download Warzag" in its first paragraph |
| `https://github.com/OWNER/REPO/releases/latest/download/Warzag.dmg.sha256` | `faq.html`: the checksum to check a download against |
| `https://github.com/OWNER/REPO/releases/latest/download/install.sh` | `faq.html`: the Terminal installer command |
| `https://github.com/OWNER/REPO` | every page: "Source Code"; the footers and `faq.html`: "GitHub" and the source code answer |
| `https://github.com/OWNER/REPO/blob/main/LICENSE` | `first-launch.html`, `faq.html` and `changes.html`: the footer |
| `https://github.com/OWNER/REPO/blob/main/tools/release/install.sh` | `faq.html`: the installer's source |
| `https://github.com/OWNER/REPO/issues` | `faq.html`: where to get help |

Their own address, which search engines and link previews need in full (below), is written
`https://OWNER.github.io/REPO/`, followed by the page's or the image's name: `build.py` replaces it with the address
GitHub Pages serves the site at, `https://<owner>.github.io/<name>/`, with the owner in lowercase as in its host name:

| URL in the pages | Where |
|---|---|
| `https://OWNER.github.io/REPO/` and `https://OWNER.github.io/REPO/<page>.html` | every page: its canonical link and Open Graph address |
| `https://OWNER.github.io/REPO/preview.png` | every page: the link-preview picture |

Nobody edits these by hand. `build.py` copies the pages and the images into an output folder with `OWNER/REPO`
replaced by the repository, `https://OWNER.github.io/REPO/` by the site's address and the Changes page filled in
(below), and writes `sitemap.xml` there:

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

## Search engines and link previews

Each page's `<head>` carries what search engines and link previews read, without changing how the page looks: its
own `<title>` (60 characters at most, so results show it whole) and meta description (160 at most), a canonical link
to its own address (the home page's is the site's address itself, so the bare address and `index.html` count as one
page), Open Graph tags (title, description, address, `preview.png` with its size and description) and an X card
tag. Keep all of it true to what the pages say. There is no structured data (JSON-LD): Google's software-app result
needs ratings or reviews shown on the page and it no longer shows FAQ results, so it would earn nothing, and Search
Console would list the app as an invalid item.

`sitemap.xml`, which `build.py` writes, lists every page at the site's address. Search Console takes it only for a
site you have verified, and keeps checking the proof, so: add a URL-prefix property for
`https://<owner>.github.io/<name>/`, choose the HTML tag, and put its
`<meta name="google-site-verification" content="...">` in `index.html`'s `<head>`, after the description, for good
(with a new `HOME_SHA256`; the page looks the same). Then submit `https://<owner>.github.io/<name>/sitemap.xml` once,
and import the site into Bing Webmaster Tools from Search Console. Not a verification file: the checks refuse any
`.html` that is not one of the pages, and `build.py` would list it in the sitemap. A `robots.txt` would do nothing
in `site/`: crawlers read it only at the root of the host, `https://<owner>.github.io/robots.txt`, and without one
there they may read every page. With a custom domain, `site_url()` in `build.py` must return it.

## Checks

```sh
python3 -I qa/site/site-test.py
```

Page structure (language, viewport, CSP, one `h1` and headings in order, alt text, labelled landmarks), no script but
the theme switch (inline, identical on every page, allowed by its hash) and no resources from elsewhere, internal
links and anchors that resolve, external links only to the repository, `OWNER/REPO` only inside `github.com` URLs,
the disclaimer, nothing personal; what search engines and link previews read (each page's own title and description
within their lengths, its canonical link, the Open Graph and X card tags, each once, and the preview picture's size);
unstyled (no stylesheet, `<style>`,
`style=` or `class=`, no `style-src` in the CSP, no theme-color tag; the `light dark` colour-scheme tag); the theme
switch's behaviour in Node (System by default, a saved choice applied before the page is drawn, Light, Dark and
System saved and cleared, blocked storage); the home page unchanged (its
SHA-256), short (45 words at most) and centred (its doctype, the layout table and its one cell); the other pages'
shared header and footer, with the navigation bar at the top only; one "Back to top" link, in the footers of the FAQ
and the Changes page; the icon; and `build.py`, including the site's address it fills in and the sitemap it writes,
`--fetch-release` against a local stand-in for a release
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
- The requirements (Apple silicon, macOS 15 or later, 80 GB free) in `faq.html#mac`, `#macs`, the titles and the
  descriptions are the README's; "graphics settings to suit your Mac" is the app's graphics presets.

Others' facts, as checked on 2026-10-23: look at them again with each release, and after Apple announces new Macs:

- "Warframe has no Mac version" (`faq.html#mac`): Digital Extremes' download page (warframe.com/en/download) and
  Warframe's Steam page both say there is no Mac client.
- The iPhone and iPad version is not offered for Mac (`faq.html#iphone`): its App Store listing (id1520001008) lists
  iPhone and iPad only.
- `faq.html#other-ways`: CrossOver is a paid app that runs Warframe; GeForce NOW lists Warframe and its free tier has
  time limits; Sikarugir is free and active; Whisky's development ended in 2025; Boot Camp needs an Intel Mac
  (Apple's support article 102622). The answer gives no prices or ratings, which change too often.

## Changing things

- **The look** is the browser's own, on purpose. The checks refuse stylesheets, `<style>`, `style=` and `class=`;
  HTML of the period that is not CSS is fine (`<hr>`, `<b>`, `<small>`, `align=`, `valign=`).
- **The home page** is finished: the checks hold it to its SHA-256 (`HOME_SHA256` in `qa/site/site-test.py`), so a
  change to it must change that checksum too. It stays short (the checks allow 45 words) and everything on it stays
  inside the layout table's one cell, under its HTML 3.2 doctype.
- **The icon**: replace `icon.png`, keeping the name: a square PNG (128 px, the snail from
  `App/AppIcon.png` on a transparent background; the app's own icon keeps its grey square).
- **Titles and descriptions** are what search results show, so they say what people search for (Warframe, Mac,
  Apple silicon) in plain words. A new page gets its own title, description, Open Graph tags and canonical link like
  the others; `build.py` adds it to the sitemap by itself.
- **The header and footer** of `first-launch.html`, `faq.html` and `changes.html` are the same on all three, but for
  `aria-current="page"` on the page's own link in the navigation bar and the "Back to top" link at the start of the
  long pages' footers (the FAQ and Changes): change all three the same way (the checks compare them). The home page
  has its own links and disclaimer, inside its cell.
- **What changed** goes in `CHANGELOG.md`, never in `changes.html`, whose own text is outside its marked region (and,
  for the time before the first release, the line inside it).
- **Terminal commands** in the FAQ are `<code>` in a paragraph, not `<pre>`, so they wrap on a phone; `<wbr>` marks
  where the long URL may wrap without changing what a copy gets.
