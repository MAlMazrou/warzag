# Changelog

Every change players would notice is listed here, in plain words. Each release groups its changes under three
headings, in this order:

- **Major**: a big new capability, or a change in how Warzag is used (including anything players must do, such as
  updating macOS).
- **Minor**: smaller features and improvements.
- **Bug fixes**: something that did not work as it should, and now does.

The headings decide the version number (MAJOR.MINOR.PATCH, Semantic Versioning): a release with a Major entry raises
the first number, one with Minor entries but no Major the second, and one with only Bug fixes the third.

New entries go under **Unreleased** in the same change that makes them; a commit to the app or the engine that players
would not notice says `Changelog: none` in its message instead. `tools/release/changelog.py release <version>` turns
Unreleased into the release's section, and no release is built or published without its section
(`docs/RELEASING.md`).

## [Unreleased]

## [0.1.0] - 2026-10-21

### Major

- Warframe runs on Apple silicon Macs through Warzag's own engine (Wine for ARM64, FEX and DXMT). No Rosetta needed.
- One-step setup: Warzag installs its engine and Warframe using Digital Extremes' own installer. You only accept DE's
  EULA.
- Sign in with your own Mac Steam app, or play with your Warframe account without Steam.
- Check for Updates for Warzag, its engine and Warframe. Every update is signed and verified before it installs.

### Minor

- Graphics presets for your Mac with AMD FSR 3 upscaling. Motion blur is off by default.
- Steam card on Home with your Steam name and picture, Log In and Log Out.
- Warns before Play when your Mac is on a weak charger or low battery.
- Troubleshoot: checks, repair, logs, and diagnostics with personal details removed.
- What's New in Warzag and a Changes page on the website.
