# Warzag

Warzag is a free, open-source Mac app that runs the Windows version of Warframe on Macs with Apple silicon. It
installs its own engine (Wine with the FEX x86-64 emulator and DXMT for Direct3D 11 on Metal), signs in through the
Steam app on your Mac and installs Warframe with Digital Extremes' own installer.

## Requirements

- A Mac with Apple silicon and macOS 15 or later
- 80 GB of free disk space
- A Steam account or a Warframe account

## Getting Warzag

Download `Warzag.dmg` from the Warzag website (linked in this repository's About section) or from the
[latest release](../../releases/latest), and drag Warzag into Applications. Warzag is not notarized by Apple, so the
first launch needs one confirmation: open Warzag, click **Done**, then click **Open Anyway** in System Settings >
Privacy & Security.

## What Warzag does

- Installs and updates its engine, and checks the signature of everything it downloads.
- Sets up Windows for Warframe and installs the game with Digital Extremes' installer and launcher. You accept
  Digital Extremes' EULA yourself, in their window.
- Signs in through the Steam app on your Mac, or lets you play with a Warframe account instead.
- Picks graphics settings for your Mac, and keeps itself, its engine and Warframe up to date.
- Shows what each version changed: Help > What's New in Warzag.

## What Warzag does not do

- It never changes Steam or Warframe files, the game's memory or its network traffic.
- It never sees your passwords: you sign in through Steam's own window or Warframe's login screen.
- It has no analytics and no account. Diagnostics leave your Mac only if you export and send them yourself.
- It does not use Rosetta.

## Building from source

See [docs/BUILDING.md](docs/BUILDING.md).

## License

Warzag is free software under the GPL-3.0 ([LICENSE](LICENSE)). The engine and the Steam bridge are built from
third-party components under their own licenses; see [NOTICE](NOTICE).

## Disclaimer

Warzag is an unofficial community project. It is not affiliated with or endorsed by Digital Extremes, Valve or Apple.
Warframe is a trademark of Digital Extremes Ltd. Steam is a trademark of Valve Corporation.
