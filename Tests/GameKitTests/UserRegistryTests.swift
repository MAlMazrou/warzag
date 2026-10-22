import EngineKit
import Foundation
import Testing
import WarzagTestSupport
@testable import GameKit

/// DE's launcher keys in user.reg as Wine writes them, read as GameKit reads them (EngineKit's `WineRegistryHive`).
@Suite struct UserRegistryTests {
    @Test func readsDEsLauncherKeysAsWineWritesThem() {
        let registry = WineRegistryHive(text: Fixtures.userReg(eula: Fixtures.eulaHash, launcherOverrides: true,
                                                               steam: true))
        let steamLauncher = #"Software\Digital Extremes\Warframe\SteamLauncher"#
        #expect(registry.string(steamLauncher, "ReadEula") == Fixtures.eulaHash)
        #expect(registry.string(steamLauncher, "ReadCba") == "")
        #expect(registry.value(steamLauncher, "ServerCluster") == .dword(0))
        #expect(registry.value(#"Software\Digital Extremes\Warframe\Launcher"#, "GraphicsAPI") == .dword(0))
        #expect(registry.string(#"Software\Digital Extremes\Warframe\Launcher"#, "LauncherExe")
            == #"X:\Tools\Launcher.exe"#)
        #expect(registry.string(#"Software\Valve\Steam\ActiveProcess"#, "SteamClientDll64")
            == #"C:\Program Files (x86)\Steam\steamclient64.dll"#)
        #expect(registry.value(#"Control Panel\Desktop"#, "LogPixels") == .dword(96))
        for dll in ["dwrite", "libglesv2", "nvapi64", "nvngx"] {
            #expect(registry.string(#"Software\Wine\AppDefaults\Launcher.exe\DllOverrides"#, dll) == "")
        }
    }

    @Test func keysAndNamesMatchCaseInsensitively() {
        let registry = WineRegistryHive(text: Fixtures.userReg(eula: "ABC", launcherOverrides: false, steam: false))
        #expect(registry.string(#"SOFTWARE\digital extremes\WARFRAME\steamlauncher"#, "readeula") == "ABC")
        #expect(registry.hasKey(#"software\Digital Extremes\Warframe\Launcher\"#))
    }

    @Test func missingKeysAndValuesAreNil() {
        let registry = WineRegistryHive(text: Fixtures.userReg(eula: nil, launcherOverrides: false, steam: false))
        #expect(registry.string(#"Software\Digital Extremes\Warframe\SteamLauncher"#, "ReadEula") == nil)
        #expect(!registry.hasKey(#"Software\Wine\AppDefaults\Launcher.exe\DllOverrides"#))
        #expect(registry.string(#"Software\Digital Extremes\Warframe\Launcher"#, "GraphicsAPI") == nil)
    }

    @Test func loadsFromAFileSystem() {
        let fileSystem = InMemoryFileSystem()
        let url = URL(filePath: "/prefix/user.reg")
        #expect(WineRegistryHive.load(url, fileSystem: fileSystem) == nil)
        fileSystem.addFile(url.plainPath, Fixtures.userReg(eula: "X", launcherOverrides: true, steam: true))
        #expect(WineRegistryHive.load(url, fileSystem: fileSystem)?
            .string(#"Software\Digital Extremes\Warframe\SteamLauncher"#, "ReadEula") == "X")
    }
}
