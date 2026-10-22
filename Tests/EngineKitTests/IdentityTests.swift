import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit

@Suite struct VolumeSerialTests {
    @Test(arguments: [
        ("Volume in drive C has no label.\r\nVolume Serial Number is 4300-0000\r\n\r\n", "43000000"),
        ("Volume Serial Number is 1a2b-3c4d", "1A2B3C4D"),
        ("Le volume dans le lecteur X n'a pas de nom.\r\nLe numéro de série du volume est 0BAD-F00D\r\n", "0BADF00D"),
        ("Volumeseriennummer: 5800-0000", "58000000"),
    ])
    func volOutputIsParsedInAnyLanguage(_ output: String, _ serial: String) {
        #expect(VolumeSerial.parse(volOutput: output) == serial)
    }

    @Test(arguments: ["", "The system cannot find the path specified.", "Number is 12345-6789", "abcd-1234ef"])
    func noSerialInOutput(_ output: String) {
        #expect(VolumeSerial.parse(volOutput: output) == nil)
    }

    @Test func normalizing() {
        #expect(VolumeSerial.normalized("1a2b3c4d\n") == "1A2B3C4D")
        #expect(VolumeSerial.normalized("4300-0000") == "43000000")
        #expect(VolumeSerial.normalized("ff") == "000000FF")
        #expect(VolumeSerial.normalized("123456789") == nil)
        #expect(VolumeSerial.normalized("xyz") == nil)
        #expect(String(decoding: VolumeSerial.fileContents("43000000"), as: UTF8.self) == "43000000\n")
    }
}

@Suite struct MachineIdentityTests {
    let identity = MachineIdentity(machineGuid: "0246cdda-9597-4817-832b-facf99e960fa", computerName: "TENNOS-MAC",
                                   volumeSerials: ["C": "43000000", "X": "58000000"], windowsUserName: "tenno",
                                   capturedAt: Date(timeIntervalSince1970: 1_792_000_000))

    @Test func theRegistryPinsGuidNameAndStopsHostNameRenames() throws {
        let entries = RegeditFile.entries(of: identity.registry)
        #expect(entries == [
            RegistryEntry(hive: .system, key: #"Software\Microsoft\Cryptography"#, name: "MachineGuid",
                          value: .string("0246cdda-9597-4817-832b-facf99e960fa")),
            RegistryEntry(hive: .system, key: #"System\CurrentControlSet\Control\ComputerName\ComputerName"#,
                          name: "ComputerName", value: .string("TENNOS-MAC")),
            RegistryEntry(hive: .user, key: #"Software\Wine\Network"#, name: "UseDnsComputerName", value: .string("N")),
        ])
        _ = try identity.registry.rendered()
    }

    @Test func validation() throws {
        try identity.validate()
        #expect(MachineIdentity.isValidMachineGuid("0246CDDA-9597-4817-832B-FACF99E960FA"))
        #expect(!MachineIdentity.isValidMachineGuid("0246cdda95974817832bfacf99e960fa"))
        #expect(!MachineIdentity.isValidMachineGuid("zzzzzzzz-9597-4817-832b-facf99e960fa"))
        #expect(MachineIdentity.isValidComputerName("MAC"))
        for bad in ["", "HAS SPACE", "quo\"te", "back\\slash", "naïve", String(repeating: "A", count: 64)] {
            #expect(!MachineIdentity.isValidComputerName(bad))
        }
        var broken = identity
        broken.volumeSerials["X"] = "58000000ff"
        #expect(throws: IdentityError.self) { try broken.validate() }
    }

    @Test func theVaultRoundTripsAndRejectsDamage() throws {
        let fileSystem = InMemoryFileSystem()
        let vault = IdentityVault(paths: WarzagPaths(home: URL(filePath: "/Users/tenno"), userCacheDirectory: nil),
                                  fileSystem: fileSystem)
        #expect(try vault.load() == nil)
        try vault.save(identity)
        #expect(try vault.load() == identity)
        let text = try #require(fileSystem.text(at: vault.file.plainPath))
        #expect(vault.file.plainPath == "/Users/tenno/Library/Application Support/Warzag/Identity/identity.json")
        #expect(text.contains(#""volumeSerials" : {"#))

        fileSystem.addFile(vault.file.plainPath, "{not json")
        #expect(throws: IdentityError.self) { try vault.load() }
        var malformed = identity
        malformed.machineGuid = "nope"
        #expect(throws: IdentityError.self) { try vault.save(malformed) }
    }
}
