import Foundation
import Testing
@testable import WineKit

@Suite struct RegistryFileTests {
    @Test func renderingEscapesAndFormats() throws {
        var file = RegistryFile()
        file.set(.currentUser, #"Software\Warzag\Test"#, "Path", .string(#"C:\Program Files (x86)\Steam"#))
        file.set(.currentUser, #"Software\Warzag\Test"#, #"Name "with" \ odd"#, .string(#"say "hi""#))
        file.set(.currentUser, #"Software\Warzag\Test"#, nil, .string("default"))
        file.set(.currentUser, #"Software\Warzag\Test"#, "Empty", .string(""))
        file.set(.localMachine, #"Software\Wow6432Node\Valve\Steam"#, "LogPixels", .dword(192))
        file.set(.localMachine, #"Software\Wow6432Node\Valve\Steam"#, "Max", .dword(0xFFFF_FFFF))

        let expected = [
            "REGEDIT4",
            "",
            #"[HKEY_CURRENT_USER\Software\Warzag\Test]"#,
            #""Path"="C:\\Program Files (x86)\\Steam""#,
            #""Name \"with\" \\ odd"="say \"hi\"""#,
            #"@="default""#,
            #""Empty"="""#,
            "",
            #"[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Valve\Steam]"#,
            #""LogPixels"=dword:000000c0"#,
            #""Max"=dword:ffffffff"#,
            "",
            "",
        ].joined(separator: "\r\n")
        #expect(try file.rendered() == expected)
        #expect(try file.data() == Data(expected.utf8))
    }

    @Test func setReplacesValuesAndMergesKeysCaseInsensitively() throws {
        var file = RegistryFile()
        file.set(.currentUser, #"Software\Wine\Mac Driver"#, "RetinaMode", .string("n"))
        file.set(.currentUser, #"software\wine\mac driver"#, "retinamode", .string("y"))
        file.set(.localMachine, #"Software\Wine\Mac Driver"#, "RetinaMode", .string("n"))
        #expect(file.keys.count == 2)
        #expect(file.keys[0].entries == [RegistryFile.Entry(name: "retinamode", value: .string("y"))])
        #expect(try file.rendered().components(separatedBy: "\r\n").filter { $0.hasPrefix("[") }.count == 2)
    }

    @Test(arguments: ["Café", "مرحبا", "emoji ✓"])
    func nonASCIITextIsRejected(_ text: String) {
        var file = RegistryFile()
        file.set(.currentUser, "Software", "Value", .string(text))
        #expect(throws: RegistryFileError.notASCII(text)) { try file.rendered() }
        var named = RegistryFile()
        named.set(.currentUser, "Software", text, .string("x"))
        #expect(throws: RegistryFileError.notASCII(text)) { try named.rendered() }
    }

    @Test(arguments: ["line\nbreak", "carriage\rreturn", "tab\there", "nul\u{0}byte", "del\u{7F}"])
    func controlCharactersAreRejected(_ text: String) {
        var file = RegistryFile()
        file.set(.currentUser, "Software", "Value", .string(text))
        #expect(throws: RegistryFileError.controlCharacter(text)) { try file.rendered() }
    }

    @Test(arguments: [#"Software\\Wine"#, #"Software\Wine\"#, #"\Software"#, "", #"Software\[x]"#, "Soft\u{1}ware", "Logiciel\\é"])
    func malformedKeyPathsAreRejected(_ path: String) {
        var file = RegistryFile()
        file.set(.currentUser, path, "Value", .dword(1))
        #expect(throws: RegistryFileError.invalidKeyPath(path)) { try file.rendered() }
    }

    @Test func anEmptyFileIsJustTheHeader() throws {
        #expect(try RegistryFile().rendered() == "REGEDIT4\r\n\r\n")
    }
}

@Suite struct PrefixTemplateTests {
    @Test func theCompleteTemplate() throws {
        let text = try PrefixTemplate.registry(macDriver: MacDriverSettings(retinaMode: false)).rendered()
        let expected = [
            "REGEDIT4",
            "",
            #"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#,
            #""RetinaMode"="n""#,
            #""LeftOptionIsAlt"="y""#,
            #""RightOptionIsAlt"="y""#,
            "",
            #"[HKEY_CURRENT_USER\Control Panel\Desktop]"#,
            #""LogPixels"=dword:00000060"#,
            "",
            #"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\Launcher.exe\DllOverrides]"#,
            #""dwrite"="""#,
            #""libglesv2"="""#,
            #""nvapi64"="""#,
            #""nvngx"="""#,
            "",
            "",
        ].joined(separator: "\r\n")
        #expect(text == expected)
    }

    @Test func steamKeysAreLeftToTheBridgesSteamReg() throws {
        // bridge/prefix/steam.reg is the single source of truth for Steam keys; the template must not duplicate it.
        let text = try PrefixTemplate.registry(macDriver: MacDriverSettings(retinaMode: true)).rendered()
        #expect(!text.contains("Valve"))
        #expect(PrefixTemplate.steamDirectory == #"C:\Program Files (x86)\Steam"#)
    }

    @Test func retinaAndCommandAsControl() throws {
        let text = try PrefixTemplate.registry(
            macDriver: MacDriverSettings(retinaMode: true, optionAsAlt: true, commandAsControl: true)).rendered()
        #expect(text.contains("\"RetinaMode\"=\"y\"\r\n"))
        #expect(text.contains("\"LeftCommandIsCtrl\"=\"y\"\r\n\"RightCommandIsCtrl\"=\"y\"\r\n"))
        #expect(text.contains("\"LogPixels\"=dword:000000c0\r\n"))

        let plain = try PrefixTemplate.registry(macDriver: MacDriverSettings(retinaMode: false, optionAsAlt: false)).rendered()
        #expect(plain.contains("\"LeftOptionIsAlt\"=\"n\"\r\n"))
        #expect(!plain.contains("CommandIsCtrl"))
    }

    @Test func theTemplateNeverNamesSteamClientLaunchOrCredentials() throws {
        let text = try PrefixTemplate.registry(macDriver: MacDriverSettings(retinaMode: true)).rendered()
        for forbidden in ["SteamClientLaunch", "SteamAppUser", "AutoLoginUser", "Password", "pid"] {
            #expect(!text.contains(forbidden))
        }
    }
}
