import AppUpdateKit
import Foundation
import GameKit
import ProfileKit
import WarzagCore

// Every string the app shows, with its key and its English text. The catalog App/Localizable.xcstrings holds the same
// keys (App/make-app.sh compiles it into Contents/Resources/en.lproj); LocalizationCatalogTests keeps the two in step
// and checks that views use only these. Interpolated values are pre-formatted strings, so every placeholder is %@.

enum L10n {
    // MARK: App

    static var appName: String { String(localized: "app.name", defaultValue: "Warzag") }
    static var windowTitleDemo: String { String(localized: "app.windowTitleDemo", defaultValue: "Warzag — Demo") }
    static var demoBadge: String { String(localized: "app.demoBadge", defaultValue: "DEMO") }
    static var demoBadgeAccessibility: String { String(localized: "app.demoBadgeAccessibility", defaultValue: "Demo mode") }
    static var demoBanner: String {
        String(localized: "app.demoBanner", defaultValue: "Demo mode: every step is simulated. Nothing is installed, and Steam, Wine and Digital Extremes' launcher are never started.")
    }
    static var disclaimer: String {
        String(localized: "app.disclaimer", defaultValue: "Unofficial; not affiliated with Digital Extremes or Valve.")
    }
    static var troubleshootMenu: String { String(localized: "app.troubleshootMenu", defaultValue: "Troubleshoot…") }
    /// The same window from a button (Home, banners, failed steps): no ellipsis.
    static var troubleshoot: String { String(localized: "app.troubleshoot", defaultValue: "Troubleshoot") }
    static var unknown: String { String(localized: "app.unknown", defaultValue: "unknown") }
    static var justNow: String { String(localized: "app.justNow", defaultValue: "just now") }
    static var dismiss: String { String(localized: "app.dismiss", defaultValue: "Dismiss") }

    // MARK: Formatting

    static func perSecond(_ amount: String) -> String {
        String(localized: "format.perSecond", defaultValue: "\(amount)/s")
    }
    static func bytesOf(_ done: String, _ total: String) -> String {
        String(localized: "format.bytesOf", defaultValue: "\(done) of \(total)")
    }
    static func bytesOfAbout(_ done: String, _ total: String) -> String {
        String(localized: "format.bytesOfAbout", defaultValue: "\(done) of about \(total)")
    }
    static func timeLeft(_ duration: String) -> String {
        String(localized: "format.timeLeft", defaultValue: "about \(duration) left")
    }

    // MARK: Welcome

    static var welcomeTitle: String { String(localized: "welcome.title", defaultValue: "Play Warframe on your Mac") }
    static var welcomeBody: String {
        String(localized: "welcome.body", defaultValue: "Warzag sets up everything Warframe needs: its Windows engine, your Steam sign-in and the game itself. It only asks you when something needs you.")
    }
    static var welcomeSteam: String {
        String(localized: "welcome.steam", defaultValue: "Signs in with your own Mac Steam. Warzag never sees your password.")
    }
    static var welcomeContent: String {
        String(localized: "welcome.content", defaultValue: "Downloads Warframe only through Digital Extremes' own launcher.")
    }
    static var welcomeTuned: String {
        String(localized: "welcome.tuned", defaultValue: "Tunes graphics for Apple silicon Macs.")
    }
    static var getStarted: String { String(localized: "welcome.getStarted", defaultValue: "Get Started") }

    // MARK: Setup

    static var setupTitle: String { String(localized: "setup.title", defaultValue: "Setting up Warframe") }
    static var setupSubtitle: String {
        String(localized: "setup.subtitle", defaultValue: "Everything runs by itself. A card appears here when something needs you.")
    }
    static func setupProgress(_ percent: String) -> String {
        String(localized: "setup.progress", defaultValue: "\(percent) done")
    }
    static var setupUnsupportedTitle: String {
        String(localized: "setup.unsupportedTitle", defaultValue: "This Mac can't run Warzag")
    }
    static var engineDone: String {
        String(localized: "setup.engineDone", defaultValue: "Native Apple silicon engine")
    }
    static var steamSkipped: String {
        String(localized: "setup.steamSkipped", defaultValue: "Signing in with a Warframe account instead")
    }
    static var waitsForEngine: String { String(localized: "setup.waitsForEngine", defaultValue: "Waits for the engine") }
    static var waitsForChecks: String {
        String(localized: "setup.waitsForChecks", defaultValue: "Waits for the checks on this Mac")
    }
    static var retryingSoon: String {
        String(localized: "setup.retryingSoon", defaultValue: "Didn't work. Trying again shortly…")
    }
    static var tryAgain: String { String(localized: "setup.tryAgain", defaultValue: "Try Again") }
    static var chooseEngine: String { String(localized: "setup.chooseEngine", defaultValue: "Choose Engine…") }
    static func showSteps(_ track: String) -> String {
        String(localized: "setup.showSteps", defaultValue: "Show the steps of \(track)")
    }

    static func trackTitle(_ track: SetupTrack) -> String {
        switch track {
        case .preflight: String(localized: "track.preflight", defaultValue: "This Mac")
        case .engine: String(localized: "track.engine", defaultValue: "Engine")
        case .steam: String(localized: "track.steam", defaultValue: "Steam")
        case .game: String(localized: "track.game", defaultValue: "Warframe")
        }
    }

    static func status(_ status: StepDisplayStatus) -> String {
        switch status {
        case .done: String(localized: "status.done", defaultValue: "Done")
        case .active: String(localized: "status.active", defaultValue: "In progress")
        case .needsYou: String(localized: "status.needsYou", defaultValue: "Needs you")
        case .failed: String(localized: "status.failed", defaultValue: "Didn't work")
        case .offline: String(localized: "status.offline", defaultValue: "Waiting for the internet")
        case .pending: String(localized: "status.pending", defaultValue: "Waiting")
        case .skipped: String(localized: "status.skipped", defaultValue: "Not needed")
        }
    }

    static func accessibilityStatus(_ item: String, _ status: String) -> String {
        String(localized: "status.accessibility", defaultValue: "\(item): \(status)")
    }

    /// A step as a row in the list.
    static func stepTitle(_ step: SetupStep) -> String {
        switch step {
        case .checkPlatform: String(localized: "step.checkPlatform", defaultValue: "Check this Mac")
        case .checkLocation: String(localized: "step.checkLocation", defaultValue: "Check where Warzag runs from")
        case .checkStorage: String(localized: "step.checkStorage", defaultValue: "Check free space")
        case .checkNetwork: String(localized: "step.checkNetwork", defaultValue: "Check the internet connection")
        case .fetchManifest: String(localized: "step.fetchManifest", defaultValue: "Find the engine")
        case .downloadRuntime: String(localized: "step.downloadRuntime", defaultValue: "Get the engine")
        case .verifyRuntime: String(localized: "step.verifyRuntime", defaultValue: "Verify the engine")
        case .activateRuntime: String(localized: "step.activateRuntime", defaultValue: "Install the engine")
        case .createPrefix: String(localized: "step.createPrefix", defaultValue: "Prepare Windows compatibility")
        case .installSteam: String(localized: "step.installSteam", defaultValue: "Install Steam")
        case .startSteam: String(localized: "step.startSteam", defaultValue: "Start Steam")
        case .waitForSignIn: String(localized: "step.waitForSignIn", defaultValue: "Sign in to Steam")
        case .checkLicense: String(localized: "step.checkLicense", defaultValue: "Check your Steam library")
        case .downloadInstaller: String(localized: "step.downloadInstaller", defaultValue: "Download Warframe's installer")
        case .extractGame: String(localized: "step.extractGame", defaultValue: "Unpack Warframe")
        case .applyProfile: String(localized: "step.applyProfile", defaultValue: "Tune graphics for this Mac")
        case .acceptEULA: String(localized: "step.acceptEULA", defaultValue: "Accept Digital Extremes' license")
        case .pinDirectX11: String(localized: "step.pinDirectX11", defaultValue: "Set up DirectX 11")
        case .downloadContent: String(localized: "step.downloadContent", defaultValue: "Download Warframe")
        }
    }

    /// What a running step with no more specific activity is doing.
    static func stepActive(_ step: SetupStep) -> String {
        switch step {
        case .checkPlatform: String(localized: "stepActive.checkPlatform", defaultValue: "Checking this Mac…")
        case .checkLocation: String(localized: "stepActive.checkLocation", defaultValue: "Checking where Warzag runs from…")
        case .checkStorage: String(localized: "stepActive.checkStorage", defaultValue: "Checking free space…")
        case .checkNetwork: String(localized: "stepActive.checkNetwork", defaultValue: "Checking the internet connection…")
        case .fetchManifest: String(localized: "stepActive.fetchManifest", defaultValue: "Looking for the engine…")
        case .downloadRuntime: String(localized: "stepActive.downloadRuntime", defaultValue: "Getting the engine…")
        case .verifyRuntime: String(localized: "stepActive.verifyRuntime", defaultValue: "Verifying the engine…")
        case .activateRuntime: String(localized: "stepActive.activateRuntime", defaultValue: "Installing the engine…")
        case .createPrefix: String(localized: "stepActive.createPrefix", defaultValue: "Preparing Windows compatibility…")
        case .installSteam: String(localized: "stepActive.installSteam", defaultValue: "Checking for Steam…")
        case .startSteam: String(localized: "stepActive.startSteam", defaultValue: "Starting Steam…")
        case .waitForSignIn: String(localized: "stepActive.waitForSignIn", defaultValue: "Waiting for Steam sign-in…")
        case .checkLicense: String(localized: "stepActive.checkLicense", defaultValue: "Checking your Steam library…")
        case .downloadInstaller: String(localized: "stepActive.downloadInstaller", defaultValue: "Downloading Warframe's installer…")
        case .extractGame: String(localized: "stepActive.extractGame", defaultValue: "Unpacking Warframe…")
        case .applyProfile: String(localized: "stepActive.applyProfile", defaultValue: "Tuning graphics for this Mac…")
        case .acceptEULA: String(localized: "stepActive.acceptEULA", defaultValue: "Opening Digital Extremes' license…")
        case .pinDirectX11: String(localized: "stepActive.pinDirectX11", defaultValue: "Setting up DirectX 11…")
        case .downloadContent: String(localized: "stepActive.downloadContent", defaultValue: "Downloading Warframe…")
        }
    }

    static func activity(_ detail: ActivityDetail) -> String {
        switch detail {
        case .downloadingInstaller: String(localized: "activity.downloadingInstaller", defaultValue: "Downloading Warframe's installer from Digital Extremes…")
        case .checkingInstaller: String(localized: "activity.checkingInstaller", defaultValue: "Checking the installer…")
        case .extractingInstaller: String(localized: "activity.extractingInstaller", defaultValue: "Unpacking Warframe's launcher…")
        case .startingLauncher(let restart):
            restart == 0 ? String(localized: "activity.startingLauncher", defaultValue: "Starting Digital Extremes' launcher…")
                : String(localized: "activity.restartedLauncher", defaultValue: "Starting Digital Extremes' launcher again…")
        case .waitingForEULA: String(localized: "activity.waitingForEULA", defaultValue: "Waiting for you in Digital Extremes' window…")
        case .maybeWaitingForEULA: String(localized: "activity.maybeWaitingForEULA", defaultValue: "Digital Extremes' launcher may be waiting for you in its window…")
        case .downloadingGame: String(localized: "activity.downloadingGame", defaultValue: "Digital Extremes' launcher is downloading Warframe…")
        case .preparingGameFiles: String(localized: "activity.preparingGameFiles", defaultValue: "Preparing game files…")
        case .finishing: String(localized: "activity.finishing", defaultValue: "Finishing up…")
        case .restartingLauncher(_, let stalled):
            stalled ? String(localized: "activity.restartStalled", defaultValue: "The download stalled; restarting Digital Extremes' launcher…")
                : String(localized: "activity.restartExited", defaultValue: "Digital Extremes' launcher closed early; starting it again…")
        case .closingLauncher: String(localized: "activity.closingLauncher", defaultValue: "Closing Digital Extremes' launcher…")
        case .checkingForEngine: String(localized: "activity.checkingForEngine", defaultValue: "Checking Warzag's release page for the engine…")
        case .downloadingEngine: String(localized: "activity.downloadingEngine", defaultValue: "Downloading the engine from Warzag's release page…")
        case .verifyingEngine: String(localized: "activity.verifyingEngine", defaultValue: "Checking the engine's signature…")
        case .installingEngine: String(localized: "activity.installingEngine", defaultValue: "Installing the engine…")
        case .registeringEngine: String(localized: "activity.registeringEngine", defaultValue: "Registering the development engine…")
        case .settingUpWindows: String(localized: "activity.settingUpWindows", defaultValue: "Setting up Windows compatibility and the Steam connection…")
        case .installingSteam: String(localized: "activity.installingSteam", defaultValue: "Downloading Steam from Valve…")
        case .startingSteam: String(localized: "activity.startingSteam", defaultValue: "Starting Steam in the background…")
        case .checkingLicense: String(localized: "activity.checkingLicense", defaultValue: "Asking Steam whether Warframe is in your library…")
        }
    }

    // MARK: Setup failures (one sentence each; the detail goes to Warzag.log)

    static var failureNeedsAppleSilicon: String {
        String(localized: "failure.needsAppleSilicon", defaultValue: "Warzag needs a Mac with Apple silicon.")
    }
    static func failureNeedsMacOS(_ version: String) -> String {
        String(localized: "failure.needsMacOS", defaultValue: "Warzag needs macOS \(version) or later.")
    }
    static var failureMove: String {
        String(localized: "failure.move", defaultValue: "Warzag couldn't move itself to the Applications folder.")
    }
    static var failureNotAnEngine: String {
        String(localized: "failure.notAnEngine", defaultValue: "The development engine you chose isn't a Warzag engine.")
    }
    static var failureNoEngine: String {
        String(localized: "failure.noEngine", defaultValue: "This build of Warzag can't download the engine. Download Warzag from its website.")
    }
    static var failureEngineFeed: String {
        String(localized: "failure.engineFeed", defaultValue: "Warzag's release page doesn't offer the engine right now.")
    }
    static var failureEngineDownload: String {
        String(localized: "failure.engineDownload", defaultValue: "The engine couldn't be downloaded from Warzag's release page.")
    }
    static var failureEngineDamaged: String {
        String(localized: "failure.engineDamaged", defaultValue: "The engine download was damaged, so Warzag downloads it again.")
    }
    static var failureEngineRejected: String {
        String(localized: "failure.engineRejected", defaultValue: "The engine download didn't pass Warzag's security checks, so it wasn't installed.")
    }
    static var failureEngineNeedsNewerApp: String {
        String(localized: "failure.engineNeedsNewerApp", defaultValue: "The engine needs a newer Warzag. Download the latest Warzag from its website.")
    }
    static func failureEngineNeedsMacOS(_ version: String) -> String {
        String(localized: "failure.engineNeedsMacOS", defaultValue: "The engine needs macOS \(version) or later.")
    }
    static var failureEnginePaused: String {
        String(localized: "failure.enginePaused", defaultValue: "This engine version is paused while the Warzag team fixes a problem. Try again later.")
    }
    static var failureEngineInstall: String {
        String(localized: "failure.engineInstall", defaultValue: "The engine couldn't be installed.")
    }
    static var failureRegisterEngine: String {
        String(localized: "failure.registerEngine", defaultValue: "The development engine couldn't be registered. Rebuild it and try again.")
    }
    static var failureEngineMissing: String {
        String(localized: "failure.engineMissing", defaultValue: "The engine is missing or damaged.")
    }
    static var failurePrefix: String {
        String(localized: "failure.prefix", defaultValue: "Windows compatibility couldn't be set up.")
    }
    static var failureSteamInstall: String {
        String(localized: "failure.steamInstall", defaultValue: "Steam couldn't be installed.")
    }
    static var failureSteamStart: String {
        String(localized: "failure.steamStart", defaultValue: "Steam didn't start.")
    }
    static var failureSteamNotRunning: String {
        String(localized: "failure.steamNotRunning", defaultValue: "Steam isn't running.")
    }
    static var failureSteamOffline: String {
        String(localized: "failure.steamOffline", defaultValue: "Steam isn't connected to its servers. If Steam is in offline mode, go online in Steam, then try again.")
    }
    static var failureProbe: String {
        String(localized: "failure.probe", defaultValue: "Steam didn't answer whether Warframe is in your library.")
    }
    static var failureBridge: String {
        String(localized: "failure.bridge", defaultValue: "Warzag's connection to Steam isn't working. Repair may fix it.")
    }
    static var failureInstallerDownload: String {
        String(localized: "failure.installerDownload", defaultValue: "Warframe's installer couldn't be downloaded.")
    }
    static var failureInstallerCheck: String {
        String(localized: "failure.installerCheck", defaultValue: "The downloaded installer didn't pass Warzag's checks.")
    }
    static var failureExtract: String {
        String(localized: "failure.extract", defaultValue: "Warframe's installer couldn't be unpacked.")
    }
    static var failureProfile: String {
        String(localized: "failure.profile", defaultValue: "Graphics settings couldn't be prepared.")
    }
    static var failureLauncher: String {
        String(localized: "failure.launcher", defaultValue: "Digital Extremes' launcher didn't start.")
    }
    static var failureLauncherStuck: String {
        String(localized: "failure.launcherStuck", defaultValue: "Digital Extremes' launcher kept stopping before its license appeared.")
    }
    static var failureDirectX11: String {
        String(localized: "failure.directX11", defaultValue: "The launcher couldn't be set to DirectX 11.")
    }
    static var failureDownload: String {
        String(localized: "failure.download", defaultValue: "The download didn't finish.")
    }
    static var failureDownloadStuck: String {
        String(localized: "failure.downloadStuck", defaultValue: "The download is stuck. Warzag restarted Digital Extremes' launcher, but it made no progress.")
    }
    static var failureNeedsRepair: String {
        String(localized: "failure.needsRepair", defaultValue: "Warzag's Windows setup is incomplete. Repair should fix it.")
    }

    // MARK: Cards (things only the player can do)

    static func cardTitle(_ action: UserAction) -> String {
        switch action {
        case .moveToApplications: String(localized: "card.move.title", defaultValue: "Move Warzag to Applications")
        case .chooseStorage: String(localized: "card.storage.title", defaultValue: "Make room for Warframe")
        case .installSteam: String(localized: "card.installSteam.title", defaultValue: "Install Steam")
        case .signInToSteam: String(localized: "card.signIn.title", defaultValue: "Sign in to Steam")
        case .addWarframeToLibrary: String(localized: "card.library.title", defaultValue: "Add Warframe to your Steam library")
        case .acceptEULA: String(localized: "card.eula.title", defaultValue: "Accept Digital Extremes' license")
        }
    }

    static func cardBody(_ action: UserAction) -> String {
        switch action {
        case .moveToApplications:
            String(localized: "card.move.body", defaultValue: "Warzag keeps itself up to date from the Applications folder.")
        case .chooseStorage:
            String(localized: "card.storage.body", defaultValue: "Warframe needs about 80 GB on a drive that isn't case-sensitive. Warzag continues by itself once there's room.")
        case .installSteam:
            String(localized: "card.installSteam.body", defaultValue: "Warzag signs you in with your own Steam account. It downloads Steam from Valve and checks Valve's signature first.")
        case .signInToSteam:
            String(localized: "card.signIn.body", defaultValue: "Use Steam's window to sign in. Warzag carries on by itself as soon as you're signed in.")
        case .addWarframeToLibrary:
            String(localized: "card.library.body", defaultValue: "Warframe is free. On its Steam store page, click Play Game to add it to your library, then come back here.")
        case .acceptEULA:
            String(localized: "card.eula.declinedBody", defaultValue: "Digital Extremes' window closed before the license was accepted. Warframe can only be installed after you accept it there.")
        }
    }

    static func cardPrimary(_ action: UserAction) -> String {
        switch action {
        case .moveToApplications: String(localized: "card.move.primary", defaultValue: "Move to Applications")
        case .chooseStorage: String(localized: "card.storage.primary", defaultValue: "Check Again")
        case .installSteam: String(localized: "card.installSteam.primary", defaultValue: "Install Steam")
        case .signInToSteam: String(localized: "card.signIn.primary", defaultValue: "Show Steam")
        case .addWarframeToLibrary: String(localized: "card.library.primary", defaultValue: "Open in Steam")
        case .acceptEULA: String(localized: "card.eula.primary", defaultValue: "Open It Again")
        }
    }

    static var notNow: String { String(localized: "card.notNow", defaultValue: "Not Now") }
    static var checkAgain: String { String(localized: "card.checkAgain", defaultValue: "Check Again") }
    static var useWarframeAccount: String {
        String(localized: "card.useWarframeAccount", defaultValue: "Use a Warframe Account Instead")
    }
    static var openStorageSettings: String {
        String(localized: "card.openStorageSettings", defaultValue: "Open Storage Settings")
    }
    static func storageFree(_ free: String) -> String {
        String(localized: "card.storage.free", defaultValue: "\(free) free now.")
    }
    static var eulaLiveBody: String {
        String(localized: "card.eula.liveBody", defaultValue: "Accept Digital Extremes' EULA in the window that just opened. Warzag never accepts it for you.")
    }
    static var showDEWindow: String { String(localized: "card.eula.showWindow", defaultValue: "Show the Window") }
    /// The EULA is only guessed (DE's launcher went quiet at its start): softer than the card for a logged EULA.
    static var eulaGuessedTitle: String {
        String(localized: "card.eula.guessedTitle", defaultValue: "Check Digital Extremes' window")
    }
    static var eulaGuessedBody: String {
        String(localized: "card.eula.guessedBody", defaultValue: "Digital Extremes' launcher seems to be waiting. If its window shows the license, read it and accept it there. Warzag never accepts it for you.")
    }

    // MARK: Home

    static var homeChecking: String { String(localized: "home.checking", defaultValue: "Checking Warframe's files…") }
    static func homeWarframeVersion(_ build: String) -> String {
        String(localized: "home.warframeVersion", defaultValue: "Warframe \(build)")
    }
    static var homeNotInstalled: String {
        String(localized: "home.notInstalled", defaultValue: "Warframe's files are missing. Try Repair.")
    }
    static func homeUpdated(_ relative: String) -> String {
        String(localized: "home.updated", defaultValue: "Updated \(relative)")
    }
    static var play: String { String(localized: "home.play", defaultValue: "Play") }
    static var playAccessibility: String { String(localized: "home.playAccessibility", defaultValue: "Play Warframe") }
    static var playPreparing: String { String(localized: "home.playPreparing", defaultValue: "Starting…") }
    static var playWaitingForSteam: String {
        String(localized: "home.playWaitingForSteam", defaultValue: "Sign in to Steam to continue…")
    }
    static var playUpdating: String { String(localized: "home.playUpdating", defaultValue: "Updating Warframe…") }
    static var playLaunching: String { String(localized: "home.playLaunching", defaultValue: "Opening Warframe…") }
    static var playEULA: String {
        String(localized: "home.playEULA", defaultValue: "Digital Extremes updated their license. Accept it in their window to finish the update.")
    }
    static var playEULAGuessed: String {
        String(localized: "home.playEULAGuessed", defaultValue: "Digital Extremes' launcher seems to be waiting. If its window shows their license, accept it there to finish the update.")
    }
    static var repair: String { String(localized: "home.repair", defaultValue: "Repair") }
    static var repairing: String { String(localized: "home.repairing", defaultValue: "Repairing…") }
    static var repairDone: String { String(localized: "home.repairDone", defaultValue: "Warzag's Windows setup was repaired.") }
    static var repairFailed: String {
        String(localized: "home.repairFailed", defaultValue: "Repair didn't finish. Export Diagnostics and report the problem.")
    }
    static var showLogs: String { String(localized: "home.showLogs", defaultValue: "Show Logs") }
    /// Home's button that opens the Updates window.
    static var updates: String { String(localized: "home.updates", defaultValue: "Updates") }
    static var updatesAvailableAccessibility: String {
        String(localized: "home.updatesAvailable", defaultValue: "Updates: an update is available")
    }
    static var homeUpdatingWarzag: String { String(localized: "home.updatingWarzag", defaultValue: "Updating Warzag…") }
    static var homeUpdatingEngine: String {
        String(localized: "home.updatingEngine", defaultValue: "Updating the engine…")
    }
    static var homePrefixNeedsSetUp: String {
        String(localized: "home.prefixNeedsSetUp", defaultValue: "Windows compatibility isn't set up for the new engine yet. Press Repair.")
    }
    /// What Home shows in place of Play while an update runs.
    static func homeUpdating(_ part: UpdatePart) -> String {
        switch part {
        case .warzag: homeUpdatingWarzag
        case .engine: homeUpdatingEngine
        case .warframe: playUpdating
        }
    }

    // MARK: Steam (Home card, Settings)

    static var signInWithSteam: String { String(localized: "steam.signInWithSteam", defaultValue: "Sign in with Steam") }
    static var settingsSteam: String { String(localized: "settings.steam", defaultValue: "Steam") }
    static var signInWithSteamNote: String {
        String(localized: "steam.signInWithSteamNote", defaultValue: "Off: Warframe asks for your Warframe account, and Warzag never starts Steam.")
    }
    static var keepSteamOutOfSight: String {
        String(localized: "steam.keepOutOfSight", defaultValue: "Keep Steam out of sight")
    }
    static var keepSteamOutOfSightNote: String {
        String(localized: "steam.keepOutOfSightNote", defaultValue: "Warzag hides Steam's windows after you sign in and while Warframe starts. Steam's icon stays in the Dock while it runs.")
    }
    static var steamCardNotInstalled: String { String(localized: "steam.card.notInstalled", defaultValue: "Steam isn't installed") }
    static var steamCardNotInstalledNote: String {
        String(localized: "steam.card.notInstalledNote", defaultValue: "Install it in Setup, or turn off Sign in with Steam to use your Warframe account.")
    }
    static var steamCardOff: String { String(localized: "steam.card.off", defaultValue: "Steam is off") }
    static var steamCardStarting: String { String(localized: "steam.card.starting", defaultValue: "Starting Steam…") }
    static var steamCardSigningIn: String { String(localized: "steam.card.signingIn", defaultValue: "Signing in to Steam…") }
    static var steamCardSignedOut: String { String(localized: "steam.card.signedOut", defaultValue: "Not signed in") }
    static var steamCardSignedOutNote: String {
        String(localized: "steam.card.signedOutNote", defaultValue: "Log in to play with Steam.")
    }
    static var steamCardSignInWindowNote: String {
        String(localized: "steam.card.signInWindowNote", defaultValue: "Sign in in Steam's window. Tick Remember me to be signed in automatically next time.")
    }
    static var steamCardSignedOutElsewhere: String {
        String(localized: "steam.card.signedOutElsewhere", defaultValue: "Steam signed you out")
    }
    static var steamCardSignedOutElsewhereNote: String {
        String(localized: "steam.card.signedOutElsewhereNote", defaultValue: "Your account is in use on another device.")
    }
    static var steamCardSignedIn: String { String(localized: "steam.card.signedIn", defaultValue: "Signed in to Steam") }
    static var steamLogIn: String { String(localized: "steam.logIn", defaultValue: "Log In") }
    static var steamLogOut: String { String(localized: "steam.logOut", defaultValue: "Log Out") }
    static var steamSignInAgain: String { String(localized: "steam.signInAgain", defaultValue: "Sign In Again") }
    static var steamQuitWarframeFirst: String {
        String(localized: "steam.quitWarframeFirst", defaultValue: "Quit Warframe first")
    }

    static var sessionProblems: String {
        String(localized: "home.sessionProblems", defaultValue: "Warframe reported a problem:")
    }

    static var playFailureSteam: String {
        String(localized: "playFailure.steam", defaultValue: "Steam isn't signed in. Sign in to Steam, or choose a Warframe account in Settings.")
    }
    static var playFailureRepair: String {
        String(localized: "playFailure.repair", defaultValue: "Warzag's Windows setup needs a repair before Warframe can start.")
    }
    static var playFailureBusy: String {
        String(localized: "playFailure.busy", defaultValue: "Warframe or Digital Extremes' launcher is still running. Close it and try again.")
    }
    static var playFailureEULA: String {
        String(localized: "playFailure.eula", defaultValue: "The update needs Digital Extremes' license to be accepted in their window.")
    }
    static var playFailureStuck: String {
        String(localized: "playFailure.stuck", defaultValue: "The update didn't finish. Check the internet connection and try again.")
    }
    static var playFailureNotInstalled: String {
        String(localized: "playFailure.notInstalled", defaultValue: "Warframe's files are missing.")
    }
    static var playFailureOther: String {
        String(localized: "playFailure.other", defaultValue: "Warframe couldn't start.")
    }

    // MARK: Power

    static func powerLowPowerMode(_ cap: String) -> String {
        String(localized: "power.lowPowerMode", defaultValue: "Low Power Mode is on: Warframe is held to \(cap) fps and may stutter. Turn it off for the best experience.")
    }
    static func powerBatteryFanless(_ cap: String) -> String {
        String(localized: "power.batteryFanless", defaultValue: "On battery, Warzag holds Warframe to \(cap) fps to keep this fanless Mac cool. Plug in for 60 fps.")
    }
    static var powerBattery: String {
        String(localized: "power.battery", defaultValue: "Running on battery: Warframe runs best plugged in.")
    }
    static func powerThermal(_ cap: String) -> String {
        String(localized: "power.thermal", defaultValue: "Your Mac is hot: Warframe is held to \(cap) fps until it cools down.")
    }
    static func powerWeakCharger(_ watts: String, _ minimum: String) -> String {
        String(localized: "power.weakCharger", defaultValue: "Your charger supplies only \(watts). Warframe needs about 20–30 W, so the battery drains while you play and the Mac slows down when it gets low. Use your Mac's own charger (\(minimum) or more).")
    }
    static func powerLowBattery(_ percent: String) -> String {
        String(localized: "power.lowBattery", defaultValue: "The battery is at \(percent). When it's nearly empty, macOS slows the Mac down and Warframe stutters. Charge it, or plug in your Mac's own charger.")
    }
    /// The sentence for one piece of GameKit's power advice, from its kind and values.
    static func power(_ advice: PowerAdvice) -> String {
        let cap = String(advice.frameRateCap ?? FramePacing.coolCap)
        switch advice.kind {
        case .lowPowerMode: return powerLowPowerMode(cap)
        case .battery: return advice.frameRateCap.map { powerBatteryFanless(String($0)) } ?? powerBattery
        case .thermal: return powerThermal(cap)
        case .weakCharger:
            return powerWeakCharger(Formatting.watts(advice.adapterWatts ?? 0),
                                    Formatting.watts(advice.recommendedWatts ?? PowerAdvisor.minimumAdapterWatts))
        case .lowBattery:
            return powerLowBattery(Formatting.percent(Double(advice.batteryPercent ?? 0) / 100))
        }
    }
    static var batterySettings: String { String(localized: "power.batterySettings", defaultValue: "Battery Settings…") }

    // MARK: Warframe's own settings

    static var motionBlurOn: String {
        String(localized: "notice.motionBlurOn", defaultValue: "Motion blur is on. Under Warzag it can smear; turn it off in Warframe: Options › Display.")
    }

    // MARK: Game signals (EE.log)

    static func signal(_ signal: GameSignal) -> String {
        switch signal {
        case .steamActive: String(localized: "signal.steamActive", defaultValue: "Connected to Steam")
        case .steamLogin: String(localized: "signal.steamLogin", defaultValue: "Signing in with Steam…")
        case .loggedIn: String(localized: "signal.loggedIn", defaultValue: "Signed in to Warframe")
        case .steamNotRunning: String(localized: "signal.steamNotRunning", defaultValue: "Warframe says Steam isn't running.")
        case .steamOutOfDate: String(localized: "signal.steamOutOfDate", defaultValue: "Warframe says Steam is out of date.")
        case .steamInitFailed: String(localized: "signal.steamInitFailed", defaultValue: "Warframe couldn't reach Steam (license or sign-in).")
        case .mustRunFromLauncher: String(localized: "signal.mustRunFromLauncher", defaultValue: "This Warframe build only starts from Digital Extremes' launcher.")
        case .metalViewFailed: String(localized: "signal.metalViewFailed", defaultValue: "The graphics engine is damaged. Try Repair.")
        case .downloadCorrupted: String(localized: "signal.downloadCorrupted", defaultValue: "Warframe found damaged downloaded files.")
        case .closing: String(localized: "signal.closing", defaultValue: "Warframe is closing…")
        }
    }

    // MARK: Playing

    static var playingTitle: String { String(localized: "playing.title", defaultValue: "Warframe is running") }
    static func playingElapsed(_ time: String) -> String {
        String(localized: "playing.elapsed", defaultValue: "Playing for \(time)")
    }
    static var playingStarting: String {
        String(localized: "playing.starting", defaultValue: "Warframe is starting…")
    }
    static var returnToGame: String { String(localized: "playing.returnToGame", defaultValue: "Return to Game") }
    static var quitGame: String { String(localized: "playing.quit", defaultValue: "Quit Warframe") }
    static var quitting: String { String(localized: "playing.quitting", defaultValue: "Asking Warframe to quit…") }
    static var forceQuit: String { String(localized: "playing.forceQuit", defaultValue: "Force Quit") }
    static var forceQuitHint: String {
        String(localized: "playing.forceQuitHint", defaultValue: "Warframe isn't responding to Quit. Force Quit ends it and everything Warzag started for it.")
    }
    static var playingFinishing: String {
        String(localized: "playing.finishing", defaultValue: "Warframe closed. Cleaning up…")
    }

    // MARK: Settings

    static var settingsGraphics: String { String(localized: "settings.graphics", defaultValue: "Graphics") }
    static func graphicsName(_ choice: GraphicsChoice) -> String {
        switch choice {
        case .performance: String(localized: "graphics.performance", defaultValue: "Performance")
        case .balanced: String(localized: "graphics.balanced", defaultValue: "Balanced")
        case .quality: String(localized: "graphics.quality", defaultValue: "Quality")
        }
    }
    static func graphicsDescription(_ upscaling: String, _ cap: String) -> String {
        String(localized: "graphics.description", defaultValue: "\(upscaling) · up to \(cap) fps")
    }
    /// The upscaling a preset suggests, as Warframe's Options › Display › Upscaling names it.
    static func upscalingName(_ choice: GraphicsChoice) -> String {
        switch choice {
        case .performance: String(localized: "upscaling.fsr3Performance", defaultValue: "FSR 3 Performance")
        case .balanced: String(localized: "upscaling.fsr3Balanced", defaultValue: "FSR 3 Balanced")
        case .quality: String(localized: "upscaling.off", defaultValue: "No upscaling")
        }
    }
    static var recommended: String { String(localized: "graphics.recommended", defaultValue: "Recommended") }
    static var graphicsFootnote: String {
        String(localized: "graphics.footnote", defaultValue: "Warzag caps the frame rate. Set the upscaling once in Warframe, in Options › Display › Upscaling: FSR 3 with the preset's quality, or off for Quality. DLSS isn't available under Warzag. On a MacBook Air on battery, in Low Power Mode or when the Mac is hot, the cap drops to 30 fps.")
    }
    static var settingsPlaying: String { String(localized: "settings.playing", defaultValue: "While Playing") }
    static var hideWhilePlaying: String {
        String(localized: "settings.hideWhilePlaying", defaultValue: "Hide Warzag while playing")
    }
    static var hideWhilePlayingNote: String {
        String(localized: "settings.hideWhilePlayingNote", defaultValue: "About a minute after Warframe's window appears, Warzag leaves the Dock, so only the game shows there. It comes back when the game ends. To see it sooner, open Warzag again.")
    }
    static var settingsUpdates: String { String(localized: "settings.updates", defaultValue: "Updates") }
    static var checkForUpdatesAutomatically: String {
        String(localized: "settings.checkForUpdates", defaultValue: "Check for updates automatically")
    }
    static var checkForUpdatesAutomaticallyNote: String {
        String(localized: "settings.checkForUpdatesNote", defaultValue: "Once a day, Warzag asks its release page whether a newer Warzag or engine is out. It never downloads or installs anything by itself, and never checks while you play.")
    }
    static var advancedButton: String { String(localized: "settings.advancedButton", defaultValue: "Advanced…") }
    static var settingsAdvanced: String { String(localized: "settings.advanced", defaultValue: "Advanced") }
    static var performanceHUD: String {
        String(localized: "settings.performanceHUD", defaultValue: "Show Apple's performance HUD in the game")
    }
    static var developmentEngine: String {
        String(localized: "settings.developmentEngine", defaultValue: "Development engine")
    }
    static var developmentEngineNone: String { String(localized: "settings.developmentEngineNone", defaultValue: "None") }
    static var developmentEngineFromEnvironment: String {
        String(localized: "settings.developmentEngineFromEnvironment", defaultValue: "Set by WARZAG_DEV_RUNTIME for this run.")
    }
    static var choose: String { String(localized: "settings.choose", defaultValue: "Choose…") }
    static var clear: String { String(localized: "settings.clear", defaultValue: "Clear") }
    static var chooseEnginePanelMessage: String {
        String(localized: "settings.chooseEngineMessage", defaultValue: "Choose a Warzag engine (a Warzag.app game host built with runtime/n/make-host.sh).")
    }

    // MARK: Updates

    static var updatesTitle: String { String(localized: "updates.title", defaultValue: "Updates") }
    /// The App menu's item: it opens the Updates window and checks.
    static var checkForUpdatesMenu: String { String(localized: "updates.menu", defaultValue: "Check for Updates…") }
    static var checkForUpdates: String { String(localized: "updates.check", defaultValue: "Check for Updates") }
    static var updatesIntro: String {
        String(localized: "updates.intro", defaultValue: "Warzag asks its release page for a newer Warzag and engine. Warframe updates through Digital Extremes' launcher, as it does before every Play.")
    }
    static var updatesNotChecked: String { String(localized: "updates.notChecked", defaultValue: "Not checked yet") }
    static var updatesUpToDate: String { String(localized: "updates.upToDate", defaultValue: "Up to date") }
    static func updatesVersion(_ version: String) -> String {
        String(localized: "updates.version", defaultValue: "Version \(version)")
    }
    static func updatesVersionBuild(_ version: String, _ build: String) -> String {
        String(localized: "updates.versionBuild", defaultValue: "Version \(version) (\(build))")
    }
    static func updatesAvailable(_ version: String, _ size: String) -> String {
        String(localized: "updates.available", defaultValue: "Version \(version) is available (\(size))")
    }
    static var updatesNotConfigured: String {
        String(localized: "updates.notConfigured", defaultValue: "This build has no update feed.")
    }
    static var update: String { String(localized: "updates.update", defaultValue: "Update") }
    static var updateNow: String { String(localized: "updates.updateNow", defaultValue: "Update Now") }
    static func updateAccessibility(_ part: String) -> String {
        String(localized: "updates.updateAccessibility", defaultValue: "Update \(part)")
    }
    static var cancelUpdate: String { String(localized: "updates.cancel", defaultValue: "Cancel") }
    static var cancelWarframeUpdateAccessibility: String {
        String(localized: "updates.cancelAccessibility", defaultValue: "Cancel the Warframe update")
    }
    static var releaseNotes: String { String(localized: "updates.releaseNotes", defaultValue: "Release Notes") }
    static func updatesDownloadingWarzag(_ version: String) -> String {
        String(localized: "updates.downloadingWarzag", defaultValue: "Downloading Warzag \(version)…")
    }
    static var updatesInstallingWarzag: String {
        String(localized: "updates.installingWarzag", defaultValue: "Installing. Warzag quits and opens again by itself.")
    }
    static var updatesEngineNotInstalled: String {
        String(localized: "updates.engineNotInstalled", defaultValue: "Not installed")
    }
    static var updatesEngineSetup: String {
        String(localized: "updates.engineSetup", defaultValue: "Setup installs the engine.")
    }
    static var updatesEngineNoFeed: String {
        String(localized: "updates.engineNoFeed", defaultValue: "This build gets no engine updates.")
    }
    static var updatesEngineDevelopment: String {
        String(localized: "updates.engineDevelopment", defaultValue: "A development engine is in use. Rebuild it to update it.")
    }
    static var updatesWarframeSetup: String {
        String(localized: "updates.warframeSetup", defaultValue: "Setup downloads Warframe.")
    }
    static var updatesWarframeBeforePlay: String {
        String(localized: "updates.warframeBeforePlay", defaultValue: "Digital Extremes' launcher also updates it before every Play.")
    }
    static var updatesWarframeDue: String {
        String(localized: "updates.warframeDue", defaultValue: "Digital Extremes may have released an update since.")
    }
    static var updatesWarframeUpdated: String {
        String(localized: "updates.warframeUpdated", defaultValue: "Warframe was updated.")
    }
    static var updatesWarframeUpToDate: String {
        String(localized: "updates.warframeUpToDate", defaultValue: "Warframe is up to date.")
    }
    /// Update Now waits, as Play does, while the prefix is not set up for the current engine.
    static var updatesWarframeWaitsForPrefix: String {
        String(localized: "updates.warframeWaitsForPrefix", defaultValue: "Waits until Windows compatibility is set up for the new engine.")
    }
    static func updatesWait(_ blocker: UpdateBlocker) -> String {
        switch blocker {
        case .playing: String(localized: "updates.waitPlay", defaultValue: "Updates wait until Warframe has closed.")
        case .settingUp: String(localized: "updates.waitSetup", defaultValue: "Updates wait until setup has finished.")
        case .repairing: String(localized: "updates.waitRepair", defaultValue: "Updates wait until Repair has finished.")
        case .updating: String(localized: "updates.waitUpdate", defaultValue: "Updates run one at a time.")
        }
    }

    // MARK: Update failures (one sentence each; the detail goes to Warzag.log)

    static var updatesUnreachable: String {
        String(localized: "updates.unreachable", defaultValue: "Warzag's release page couldn't be reached. Check the internet connection and try again.")
    }
    static var updatesGameRunning: String {
        String(localized: "updates.gameRunning", defaultValue: "Warframe or Digital Extremes' launcher is running. Updates wait until it closes.")
    }
    static var updatesWarzagRejected: String {
        String(localized: "updates.warzagRejected", defaultValue: "The update didn't pass Warzag's security checks, so nothing was installed.")
    }
    static func updatesWarzagNeedsMacOS(_ version: String) -> String {
        String(localized: "updates.warzagNeedsMacOS", defaultValue: "This update needs macOS \(version) or later.")
    }
    static var updatesWarzagCannotReplace: String {
        String(localized: "updates.warzagCannotReplace", defaultValue: "Warzag can't replace itself where it is. Download the new version from Warzag's website.")
    }
    static var updatesWarzagCannotReplaceCopy: String {
        String(localized: "updates.warzagCannotReplaceCopy",
               defaultValue: "Warzag can't replace itself here. Drag the new Warzag from Finder into Applications.")
    }
    static var showInFinder: String { String(localized: "updates.showInFinder", defaultValue: "Show in Finder") }
    static var showWarzagCopyAccessibility: String {
        String(localized: "updates.showWarzagCopyAccessibility", defaultValue: "Show the new Warzag in Finder")
    }
    static var updatesWarzagFailed: String {
        String(localized: "updates.warzagFailed", defaultValue: "Warzag couldn't be updated.")
    }
    static var updatesEngineNeedsNewerWarzag: String {
        String(localized: "updates.engineNeedsNewerWarzag", defaultValue: "This engine needs a newer Warzag. Update Warzag first.")
    }
    static var updatesEngineCheckFailed: String {
        String(localized: "updates.engineCheckFailed", defaultValue: "Warzag couldn't check for a new engine.")
    }
    static var updatesEnginePrefixFailed: String {
        String(localized: "updates.enginePrefixFailed", defaultValue: "The new engine is installed, but Windows compatibility couldn't be set up for it.")
    }
    static var updatesWarframeNeedsRepair: String {
        String(localized: "updates.warframeNeedsRepair", defaultValue: "Warzag's Windows setup needs a repair before Warframe can update.")
    }
    static var updatesWarframeFailed: String {
        String(localized: "updates.warframeFailed", defaultValue: "Warframe couldn't be updated.")
    }

    // MARK: What's New

    /// The window's title and the Help menu's item.
    static var whatsNewTitle: String { String(localized: "whatsNew.title", defaultValue: "What's New in Warzag") }
    /// The Updates window's button on Warzag's row.
    static var whatsNew: String { String(localized: "whatsNew.button", defaultValue: "What's New") }
    static var whatsNewIntro: String {
        String(localized: "whatsNew.intro", defaultValue: "What each version of Warzag changed, newest first.")
    }
    static var whatsNewNone: String {
        String(localized: "whatsNew.none", defaultValue: "This build of Warzag has no list of changes to show.")
    }
    /// The heading over a development build's changes that no release has yet.
    static var whatsNewNotReleased: String {
        String(localized: "whatsNew.notReleased", defaultValue: "Not released yet")
    }
    /// A release's heading for VoiceOver: "Version 0.1.0, released October 20, 2026".
    static func whatsNewReleased(_ heading: String, _ date: String) -> String {
        String(localized: "whatsNew.released", defaultValue: "\(heading), released \(date)")
    }
    static func changeKind(_ kind: Changelog.Kind) -> String {
        switch kind {
        case .major: String(localized: "whatsNew.major", defaultValue: "Major")
        case .minor: String(localized: "whatsNew.minor", defaultValue: "Minor")
        case .bugFixes: String(localized: "whatsNew.bugFixes", defaultValue: "Bug fixes")
        }
    }
    /// The mark before each change.
    static var whatsNewBullet: String { String(localized: "whatsNew.bullet", defaultValue: "•") }

    // MARK: Troubleshoot

    static var troubleshootTitle: String { String(localized: "troubleshoot.title", defaultValue: "Troubleshoot") }
    static var troubleshootIntro: String {
        String(localized: "troubleshoot.intro", defaultValue: "Warzag checks its engine, Steam and the game files. Repair sets up Warzag's Windows side again without touching your game files or Warframe settings.")
    }
    static var checking: String { String(localized: "troubleshoot.checking", defaultValue: "Checking…") }
    static func lastChecked(_ relative: String) -> String {
        String(localized: "troubleshoot.lastChecked", defaultValue: "Checked \(relative)")
    }
    static var repairWindowsSetup: String {
        String(localized: "troubleshoot.repair", defaultValue: "Repair Windows Setup")
    }
    static var openLogsFolder: String { String(localized: "troubleshoot.openLogs", defaultValue: "Open Logs Folder") }
    static var exportDiagnostics: String {
        String(localized: "troubleshoot.export", defaultValue: "Export Diagnostics…")
    }
    static var diagnosticsSaved: String { String(localized: "troubleshoot.exported", defaultValue: "Diagnostics saved.") }
    static var diagnosticsFailed: String {
        String(localized: "troubleshoot.exportFailed", defaultValue: "Diagnostics couldn't be saved.")
    }
    static var diagnosticsPrivacy: String {
        String(localized: "troubleshoot.privacy", defaultValue: "Diagnostics leave out your email, Steam ID, IP addresses and user name.")
    }
    static var passed: String { String(localized: "troubleshoot.passed", defaultValue: "Passed") }
    static var failedCheck: String { String(localized: "troubleshoot.failed", defaultValue: "Failed") }

    static var checkStorage: String { String(localized: "check.storage", defaultValue: "Free space") }
    static var checkStorageCaseSensitive: String {
        String(localized: "check.storageCaseSensitive", defaultValue: "The drive is case-sensitive; Warframe needs one that isn't.")
    }
    static func checkStorageFree(_ free: String) -> String {
        String(localized: "check.storageFree", defaultValue: "\(free) free")
    }
    static var checkSteam: String { String(localized: "check.steam", defaultValue: "Steam") }
    static var steamNotInstalled: String { String(localized: "check.steamNotInstalled", defaultValue: "Not installed") }
    static var steamNotRunning: String { String(localized: "check.steamNotRunning", defaultValue: "Not running") }
    static var steamSignedIn: String { String(localized: "check.steamSignedIn", defaultValue: "Running and signed in") }
    static var steamSignedOut: String { String(localized: "check.steamSignedOut", defaultValue: "Running, not signed in") }
    static var checkGameFiles: String { String(localized: "check.gameFiles", defaultValue: "Game files") }
    static var contentInstalled: String { String(localized: "check.contentInstalled", defaultValue: "Installed") }
    static var contentNeedsUpdate: String {
        String(localized: "check.contentNeedsUpdate", defaultValue: "Installed; an update is due")
    }
    static var contentNotInstalled: String { String(localized: "check.contentNotInstalled", defaultValue: "Not installed") }
    static var demoCheckDetail: String { String(localized: "check.demo", defaultValue: "Demo: simulated") }

    /// EngineKit's prefix doctor checks (PrefixService.checkNames).
    static func doctorTitle(_ name: String) -> String {
        switch name {
        case "runtime": String(localized: "doctor.runtime", defaultValue: "Engine")
        case "prefix": String(localized: "doctor.prefix", defaultValue: "Windows compatibility")
        case "manifest": String(localized: "doctor.manifest", defaultValue: "Engine version of the Windows setup")
        case "library": String(localized: "doctor.library", defaultValue: "Game library (X:)")
        case "dxmt": String(localized: "doctor.dxmt", defaultValue: "Graphics (DXMT)")
        case "lsteamclient": String(localized: "doctor.lsteamclient", defaultValue: "Steam bridge library")
        case "bridge": String(localized: "doctor.bridge", defaultValue: "Steam bridge files")
        case "registry": String(localized: "doctor.registry", defaultValue: "Windows settings")
        case "steam": String(localized: "doctor.steam", defaultValue: "Steam settings")
        case "folders": String(localized: "doctor.folders", defaultValue: "User folders")
        case "identity": String(localized: "doctor.identity", defaultValue: "PC identity")
        default: name
        }
    }

    /// What a passed engine check says in Troubleshoot: plain words instead of the engine's paths and build ids
    /// (a failed check keeps the engine's own detail, which helps support). nil: no wording for that check.
    static func doctorPassed(_ name: String) -> String? {
        switch name {
        case "runtime": String(localized: "doctorPassed.runtime", defaultValue: "Installed and verified")
        case "prefix": String(localized: "doctorPassed.prefix", defaultValue: "Set up")
        case "manifest": String(localized: "doctorPassed.manifest", defaultValue: "Matches the installed engine")
        case "library": String(localized: "doctorPassed.library", defaultValue: "Linked to the game folder")
        case "dxmt", "lsteamclient", "bridge", "registry", "steam":
            String(localized: "doctorPassed.inPlace", defaultValue: "In place")
        case "folders": String(localized: "doctorPassed.folders", defaultValue: "Ready")
        case "identity": String(localized: "doctorPassed.identity", defaultValue: "Unchanged")
        default: nil
        }
    }
}
