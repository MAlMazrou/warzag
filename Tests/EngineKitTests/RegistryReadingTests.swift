import Foundation
import Testing
import WineKit
@testable import EngineKit

@Suite struct WineRegistryHiveTests {
    // Lines as this runtime wrote them in a scratch prefix (values replaced), plus the escapes Wine's server uses.
    let text = #"""
        WINE REGISTRY Version 2
        ;; All keys relative to \\Machine

        #arch=win64

        [Software\\Classes\\steam\\shell\\open\\command] 1792175888
        #time=1dd5d9d7d6f2848
        @="\"C:\\Program Files (x86)\\Steam\\steam.exe\" -- \"%1\""

        [Software\\Microsoft\\Cryptography] 1792175710
        #time=1dd5d9d1351bb60
        "MachineGuid"="0246cdda-9597-4817-832b-facf99e960fa"

        [System\\ControlSet001\\Control\\ComputerName\\ComputerName] 1792175707
        "ComputerName"="MAC"

        [Software\\Wine\\Escapes] 1792175707
        "Accent"="caf\x00e9"
        "Octal"="a\101b"
        "Tab"="x\ty"
        "Quote \"name\""="v"
        "Size"=dword:000000c0
        "Path"=str(2):"%SystemRoot%\\system32"
        "Short"=str(1):"text"
        "Blob"=hex:01,02,03,04,05,06,07,08,09,0a,0b,0c,0d,0e,0f,10,11,12,13,14,15,16,17,18,19,1a,\
          1b,1c,1d
        "After"="still read"
        """#

    @Test func readsValuesCaseInsensitively() {
        let hive = WineRegistryHive(text: text)
        #expect(hive.value(#"Software\Microsoft\Cryptography"#, "MachineGuid")
            == .string("0246cdda-9597-4817-832b-facf99e960fa"))
        #expect(hive.value(#"SOFTWARE\microsoft\CRYPTOGRAPHY"#, "machineguid") != nil)
        #expect(hive.value(#"Software\Classes\steam\shell\open\command"#, nil)
            == .string(#""C:\Program Files (x86)\Steam\steam.exe" -- "%1""#))
        #expect(hive.hasKey(#"Software\Classes\steam\shell\open\command"#))
        #expect(!hive.hasKey(#"Software\Valve"#))
        #expect(hive.value(#"Software\Microsoft\Cryptography"#, "Missing") == nil)
    }

    @Test func currentControlSetIsReadFromControlSet001() {
        let hive = WineRegistryHive(text: text)
        #expect(hive.value(#"System\CurrentControlSet\Control\ComputerName\ComputerName"#, "ComputerName") == .string("MAC"))
    }

    @Test func escapesAndValueTypes() {
        let hive = WineRegistryHive(text: text)
        let key = #"Software\Wine\Escapes"#
        #expect(hive.value(key, "Accent") == .string("café"))
        #expect(hive.value(key, "Octal") == .string("aAb"))
        #expect(hive.value(key, "Tab") == .string("x\ty"))
        #expect(hive.value(key, #"Quote "name""#) == .string("v"))
        #expect(hive.value(key, "Size") == .dword(192))
        #expect(hive.value(key, "Path") == .string(#"%SystemRoot%\system32"#))
        #expect(hive.string(key, "Short") == "text")
        #expect(hive.string(key, "Size") == nil)
        if case .other(let raw)? = hive.value(key, "Blob") {
            #expect(raw.hasPrefix("hex:01,02") && raw.hasSuffix("1b,1c,1d"))
        } else {
            Issue.record("hex value not kept")
        }
        // The value after a continued line is still read.
        #expect(hive.value(key, "After") == .string("still read"))
    }

    @Test func emptyOrGarbageTextHasNoKeys() {
        #expect(!WineRegistryHive(text: "").hasKey("Software"))
        #expect(WineRegistryHive(text: "[unterminated\n\"a\"=\"b\"").value("unterminated", "a") == nil)
    }
}

@Suite struct RegeditFileTests {
    @Test func theBridgesSteamRegIsReadAndPlacedWhereWineStoresIt() throws {
        let entries = try RegeditFile.parse(EngineFixture.steamReg)
        #expect(entries.count == 10)
        #expect(entries.contains(RegistryEntry(hive: .user, key: #"Software\Valve\Steam\ActiveProcess"#,
                                               name: "SteamClientDll64",
                                               value: .string(#"C:\Program Files (x86)\Steam\steamclient64.dll"#))))
        #expect(entries.contains(RegistryEntry(hive: .system, key: #"Software\Wow6432Node\Valve\Steam"#,
                                               name: "InstallPath", value: .string(#"C:\Program Files (x86)\Steam"#))))
        // HKEY_CLASSES_ROOT lives under HKLM\Software\Classes in system.reg.
        #expect(entries.contains(RegistryEntry(hive: .system, key: #"Software\Classes\steam\shell\open\command"#,
                                               name: nil,
                                               value: .string(#""C:\Program Files (x86)\Steam\steam.exe" -- "%1""#))))
        #expect(entries.contains(RegistryEntry(hive: .system, key: #"Software\Classes\steam"#, name: "URL Protocol",
                                               value: .string(""))))
        #expect(!entries.contains { $0.name == "pid" || $0.name == "SteamClientLaunch" })
    }

    @Test func renderedTemplatesRoundTrip() throws {
        var file = PrefixTemplate.registry(macDriver: MacDriverSettings(retinaMode: true, commandAsControl: true))
        file.set(.localMachine, #"System\CurrentControlSet\Control\ComputerName\ComputerName"#, "ComputerName", .string("PC"))
        #expect(try RegeditFile.parse(file.rendered()) == RegeditFile.entries(of: file))
        #expect(RegeditFile.entries(of: file).contains(RegistryEntry(
            hive: .user, key: #"Control Panel\Desktop"#, name: "LogPixels", value: .dword(192))))
    }

    @Test(arguments: [
        ("", "not a REGEDIT4 file"),
        ("Windows Registry Editor Version 5.00\r\n", "not a REGEDIT4 file"),
        ("REGEDIT4\r\n\"a\"=\"b\"\r\n", "value outside a key"),
        ("REGEDIT4\r\n[HKEY_USERS\\x]\r\n", "unsupported root key HKEY_USERS"),
        ("REGEDIT4\r\n[HKEY_CURRENT_USER\\x\r\n", "unterminated key"),
        ("REGEDIT4\r\n[HKEY_CURRENT_USER\\x]\r\nnonsense\r\n", "unreadable value"),
    ])
    func malformedFilesAreRejected(_ text: String, _ reason: String) {
        #expect(throws: RegistryParseError.self) { try RegeditFile.parse(text) }
        do {
            _ = try RegeditFile.parse(text)
        } catch let error as RegistryParseError {
            #expect(error.reason == reason)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func displayNamesForMessages() {
        #expect(RegistryEntry(hive: .user, key: #"Software\Valve\Steam"#, name: "SteamPath", value: .string(""))
            .displayName == #"HKCU\Software\Valve\Steam\SteamPath"#)
        #expect(RegistryEntry(hive: .system, key: #"Software\Classes\steam"#, name: nil, value: .string(""))
            .displayName == #"HKLM\Software\Classes\steam\@"#)
    }
}
