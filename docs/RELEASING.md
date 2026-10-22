# Releasing Warzag

One GitHub release carries:

| File | Made by |
|---|---|
| `Warzag.dmg`, `Warzag.dmg.sha256`, `install.sh` | `App/make-app.sh --dmg` |
| `Warzag-<x.y.z>.zip`, the app update | `App/make-app.sh --dmg` |
| `Warzag-<x.y.z>.manifest.json`, and a copy named `Warzag.manifest.json` (the app feed) | `tools/release/mkappupdate.sh` |
| `WarzagRuntime-n-<v>.aar`, `.aar.sha256` and `.manifest.json`, when the engine changed | `tools/release/mkpack.sh` |
| `WarzagRuntime-n.manifest.json`, a copy of the current engine's manifest (the engine feed) | step 2 |
| `Warzag-engine-source-<v>.tar.gz`, when the engine changed | step 2 |

Signing needs the project signing identity (`tools/sign/make-cert.sh` creates it or restores it from its backup) and
the release manifest key, whose public half is `tools/sign/release-manifest.ed25519.pub`. Signing keys and the
certificate stay outside the repository.

In the commands, `<x.y.z>` is the release, `<v>` the engine version, `<key>` the release manifest key and
`R=https://github.com/<owner>/<repo>/releases`. Everything is written to `dist/`.

## Checklist

1. **Changelog and version.**

   ```sh
   python3 -I tools/release/changelog.py next-version     # the number the Unreleased entries call for
   python3 -I tools/release/changelog.py release <x.y.z>
   ```

   For the first release, choose the number yourself. Set `Commands.version` in `Sources/warzagctl/Commands.swift`
   to `<x.y.z>` (`App/make-app.sh` takes the app's version from it), commit both files as "Release <x.y.z>", push,
   then tag the commit `v<x.y.z>` and push the tag. Build everything below from a clean checkout of that tag.

2. **Engine**, when it changed:

   ```sh
   runtime/n/fetch.sh --check-digests
   CCACHE_DISABLE=1 runtime/n/build.sh --redo
   runtime/n/make-host.sh --version <v>
   make -C qa/pe && qa/n/smoke.sh && qa/n/exit-hang.sh && qa/n/pso-reject.sh
   tools/release/mkpack.sh --key <key> --url-base $R/download/v<x.y.z>
   cp dist/WarzagRuntime-n-<v>.manifest.json dist/WarzagRuntime-n.manifest.json
   C="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
   tar -czf dist/Warzag-engine-source-<v>.tar.gz --exclude .git -C "$C" \
       work/n/downloads/wine/wine-11.19.tar.xz downloads/crossover-sources/crossover-sources-26.3.0.tar.gz \
       downloads/nettle/nettle-3.10.2.tar.gz work/n/repos/dxmt
   ```

   `mkpack.sh` signs the engine, packs it, signs its manifest and installs the result in a scratch home to check it.
   It refuses an engine that names the build machine and, for a public URL, any key but the pinned release key; never
   pass `--allow-builder-paths` for a release. The source archive holds the pinned upstream sources of the engine's
   LGPL components; take the file names from the lock files when a version changes, and keep `--exclude .git`, since
   git metadata records the builder's name and email.

   When the engine did not change, take the engine feed's manifest over from the previous release
   (`gh release download v<previous> -p WarzagRuntime-n.manifest.json -D dist`), and sign it again if it expires
   within a month (see Keeping the feeds fresh).

3. **App, disk image and update:**

   ```sh
   App/make-app.sh --dmg --feed-url $R/latest/download/WarzagRuntime-n.manifest.json \
       --update-url $R/latest/download/Warzag.manifest.json --dmg-url $R/download/v<x.y.z>/Warzag.dmg
   tools/release/mkappupdate.sh --archive dist/Warzag-<x.y.z>.zip --key <key> --url-base $R/download/v<x.y.z> \
       --release-notes $R/tag/v<x.y.z>
   cp dist/Warzag-<x.y.z>.manifest.json dist/Warzag.manifest.json
   ```

   The build number (`CFBundleVersion`) is the commit count. Only a higher build is offered as an update: pass
   `--build <n>` to `make-app.sh` when the commit count is not above the last release's.

4. **Checks:**

   ```sh
   swift build --build-tests -Xswiftc -warnings-as-errors && swift test
   qa/packaging/run.sh
   python3 -I tools/release/forbidden-scan.py --repo --personal .
   ```

5. **Publish:**

   ```sh
   python3 -I tools/release/changelog.py notes <x.y.z> > dist/notes.md
   gh release create v<x.y.z> --verify-tag --draft --title "Warzag <x.y.z>" --notes-file dist/notes.md \
       dist/Warzag.dmg dist/Warzag.dmg.sha256 dist/install.sh dist/Warzag-<x.y.z>.zip \
       dist/Warzag-<x.y.z>.manifest.json dist/Warzag.manifest.json dist/WarzagRuntime-n.manifest.json
   gh release upload v<x.y.z> dist/WarzagRuntime-n-<v>.aar dist/WarzagRuntime-n-<v>.aar.sha256 \
       dist/WarzagRuntime-n-<v>.manifest.json dist/Warzag-engine-source-<v>.tar.gz    # when the engine changed
   gh release edit v<x.y.z> --draft=false --latest
   ```

   Check the draft on GitHub before the last command, which publishes it.

6. **Website.** Publishing starts the Site workflow (`.github/workflows/pages.yml`), which deploys the website, with
   the new version on its Changes page, once the latest release's `Warzag.dmg` matches its `Warzag.dmg.sha256` and
   `install.sh`; follow it under Actions > Site.
   Every release marked Latest must carry `Warzag.dmg`, `Warzag.dmg.sha256`, `install.sh` and both feed manifests.
   Publish anything else, such as a build without `--feed-url`, as a pre-release (`--prerelease`): the website and
   the feeds never offer one. `site/README.md` describes the one-time Pages setup.

7. **Try it.** Install `Warzag.dmg` from the release on a Mac, go through setup and Play, and check that an installed
   earlier Warzag offers the update. If the release is broken, mark it as a pre-release
   (`gh release edit v<x.y.z> --prerelease`): the website and the feeds then offer the previous release again, and
   the Site workflow's next run (daily, or Actions > Site > Run workflow) takes it off the Changes page.

## Keeping the feeds fresh

Manifests expire 60 days after they are signed. Before the latest release's manifests expire, sign them again with a
higher serial and replace them on that release:

```sh
tools/release/mkappupdate.sh --archive dist/Warzag-<x.y.z>.zip --key <key> --url-base $R/download/v<x.y.z> \
    --release-notes $R/tag/v<x.y.z>
cp dist/Warzag-<x.y.z>.manifest.json dist/Warzag.manifest.json
swift build -c release --product warzag-release
"$(swift build -c release --show-bin-path)/warzag-release" manifest --pack dist/WarzagRuntime-n-<v>.aar \
    --version <v> --serial "$(date +%s)" --expires 60 --url <the pack's URL> --key <key> \
    --signer-sha256 "$(cut -d' ' -f1 tools/sign/project-certificate.sha256)" --out dist/WarzagRuntime-n.manifest.json
gh release upload v<x.y.z> dist/Warzag.manifest.json dist/WarzagRuntime-n.manifest.json --clobber
```

`gh release download` fetches the archive and the pack from their releases when `dist/` no longer has them. A serial
must never go down: a Mac refuses a manifest older than one it has accepted.

## What the app pins

A release build (`swift build -c release`, which `App/make-app.sh` uses) trusts one manifest key, the release key
(`tools/sign/release-manifest.ed25519.pub`, key id `01053f82ada7e84d`), and one signer for engines and app updates,
the project certificate (`tools/sign/project-certificate.sha256`). Debug builds also trust a development key, which
release builds never do; `warzagctl runtime trust` prints a build's pins, and `make-app.sh` refuses a build that
trusts the development key.

Keep offline backups of the release key and the signing identity. Without the key, installed copies of Warzag accept
no engine or app update. A new key reaches players only through an app release that pins it, so pin the next key one
release before signing with it.

## Updates

### The engine

`--feed-url` writes the engine feed into the app's `Info.plist` (`WarzagRuntimeManifestURL`). Setup and Updates fetch
the signed runtime manifest there and check its signature, serial, expiry, revocations and signer, download the pack
it names, check its size and SHA-256, unpack it and check its code signature, then make it current and keep the
previous engine.

To withdraw an engine, sign a manifest for a good one (a fixed engine, or the previous one with a higher serial) with
`warzag-release manifest ... --revoke n-<version>` and put it on the feed. A player's next engine update first rolls a
revoked engine back to the previous one.

### Warzag's own updates

`--update-url` writes the app feed into `Info.plist` (`WarzagAppManifestURL`). Check for Updates fetches the signed app
manifest there, offers only a build higher than the running one, downloads the update archive and checks its size and
SHA-256, then checks the unpacked app: signed by the project certificate, `com.warzag.app`, the manifest's version and
build, arm64. The new copy's own executable (`Warzag --update-swap`) then replaces the installed app once Warzag has
quit, and puts the previous one back if the new one fails its check in place. When macOS does not let Warzag replace
itself, the checked copy is shown in Finder to drag into Applications.
