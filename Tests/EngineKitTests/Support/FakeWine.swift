import Foundation
import Synchronization
import WarzagCore
import WarzagTestSupport
@testable import EngineKit

/// Plays Wine and the system tools for the engine services, modelled on this runtime's behaviour and Wine's source:
///
/// - `wine wineboot --init` on an empty directory creates the prefix: drive_c, dosdevices c: and z:, and hives with
///   a fresh MachineGuid and a ComputerName from the Mac's host name.
/// - Every session start runs Wine's prefix update (wine.inf) when `<prefix>/.update-timestamp` does not hold the
///   runtime's wine.inf time. wineboot writes that file before the update, so Wine never redoes an update cut short.
///   The update installs Wine's DLL stubs in system32 (over any placeholder) and links the shell folders that do not
///   exist yet into the Mac home.
/// - Every Wine process start resets ComputerName from the host name unless UseDnsComputerName is "N".
/// - `wine reg import C:\...` merges the REGEDIT4 file into the hives (CurrentControlSet stored as ControlSet001).
/// - `wine cmd /c vol D: > C:\file [& ...]` writes what `vol` prints, from `.windows-serial` or Wine's defaults.
/// - `wineserver` returns at once.
final class FakeWine: Sendable {
    struct HiveValue: Sendable {
        var name: String?
        var value: RegistryValue
    }

    struct HiveKey: Sendable {
        var path: String
        var values: [HiveValue]
    }

    struct Hive: Sendable {
        var keys: [HiveKey] = []

        mutating func set(_ path: String, _ name: String?, _ value: RegistryValue) {
            let stored = Self.storagePath(path)
            let index: Int
            if let found = keys.firstIndex(where: { $0.path.caseInsensitiveCompare(stored) == .orderedSame }) {
                index = found
            } else {
                keys.append(HiveKey(path: stored, values: []))
                index = keys.count - 1
            }
            if let existing = keys[index].values.firstIndex(where: { Self.same($0.name, name) }) {
                keys[index].values[existing].value = value
            } else {
                keys[index].values.append(HiveValue(name: name, value: value))
            }
        }

        func value(_ path: String, _ name: String?) -> RegistryValue? {
            let stored = Self.storagePath(path)
            return keys.first { $0.path.caseInsensitiveCompare(stored) == .orderedSame }?
                .values.first { Self.same($0.name, name) }?.value
        }

        /// Wine keeps HKLM\System\CurrentControlSet as a link to ControlSet001.
        static func storagePath(_ path: String) -> String {
            let alias = #"System\CurrentControlSet"#
            if path.lowercased().hasPrefix(alias.lowercased()) {
                return #"System\ControlSet001"# + path.dropFirst(alias.count)
            }
            return path
        }

        static func same(_ lhs: String?, _ rhs: String?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): true
            case let (left?, right?): left.caseInsensitiveCompare(right) == .orderedSame
            default: false
            }
        }

        /// Wine's own format: `[Key\\Path] <time>` and escaped `"name"=value` lines.
        func rendered(relativeTo root: String) -> String {
            var lines = ["WINE REGISTRY Version 2", ";; All keys relative to \(root)", "", "#arch=win64", ""]
            for key in keys {
                lines.append("[\(Self.escape(key.path))] 1792000000")
                lines.append("#time=1dd5d9d1351bb60")
                for value in key.values {
                    let name = value.name.map { "\"\(Self.escape($0))\"" } ?? "@"
                    switch value.value {
                    case .string(let text): lines.append("\(name)=\"\(Self.escape(text))\"")
                    case .dword(let number): lines.append("\(name)=dword:\(String(format: "%08x", number))")
                    case .other(let text): lines.append("\(name)=\(text)")
                    }
                }
                lines.append("")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
    }

    struct PrefixHives: Sendable {
        var system = Hive()
        var user = Hive()
    }

    private struct State {
        var hives: [String: PrefixHives] = [:]
        var machineGuids = ["0246cdda-9597-4817-832b-facf99e960fa", "7d1f3b2a-5c4e-4a8b-9f6d-2e1c0b9a8f7e",
                            "c3b2a190-8f7e-4d6c-b5a4-938271605f4e"]
        var boots = 0
        /// Completed runs of Wine's prefix update (wine.inf), the first boot's included.
        var updates = 0
        /// The runtime's wine.inf modification time: what wineboot writes to .update-timestamp.
        var wineInfTime = 1_792_000_000
        var hostName = "TENNOS-MAC"
        var imports: [String] = []
        var programs: [Command] = []
        var programOutput = ProcessOutput(exitCode: 0)
        var programFiles: [String: Data] = [:]
        var failing: @Sendable (Command) -> Int32? = { _ in nil }
        var hanging: @Sendable (Command) -> Bool = { _ in false }
    }

    let fileSystem: FakeEngineFileSystem
    let macHome: String
    let userName: String
    private let state = Mutex(State())

    init(fileSystem: FakeEngineFileSystem, macHome: String = "/Users/tenno", userName: String = "tenno") {
        self.fileSystem = fileSystem
        self.macHome = macHome
        self.userName = userName
    }

    // MARK: Test controls

    func setHostName(_ name: String) { state.withLock { $0.hostName = name } }
    /// A runtime with a newer wine.inf: the next session start in a prefix runs Wine's prefix update.
    func simulateRuntimeUpdate() { state.withLock { $0.wineInfTime += 60 } }
    /// A first `wineboot --init` stopped during the wine.inf install (app quit, crash, kill -9): ntdll made the
    /// prefix's skeleton, wineboot wrote the timestamp, the server saved its hives, and nothing else happened (no
    /// system32, no profile, no stubs).
    func simulateInterruptedFirstBoot(_ prefix: String) {
        createPrefix(prefix)
        writeTimestamp(prefix)
    }
    /// A session start stopped during Wine's prefix update: the timestamp names the runtime's wine.inf, the update
    /// itself never ran.
    func simulateInterruptedUpdate(_ prefix: String) { writeTimestamp(prefix) }
    /// Returns an exit code to fail a command, nil to let it run.
    func fail(when decide: @escaping @Sendable (Command) -> Int32?) { state.withLock { $0.failing = decide } }
    /// Commands that hang until the runner's deadline stops them (the runner then throws `ProcessTimedOut`).
    func hang(when decide: @escaping @Sendable (Command) -> Bool) { state.withLock { $0.hanging = decide } }
    /// What a program run prints, and files it leaves (path in the prefix -> contents).
    func setProgramResult(_ output: ProcessOutput, files: [String: Data] = [:]) {
        state.withLock {
            $0.programOutput = output
            $0.programFiles = files
        }
    }

    /// The REGEDIT4 files `reg import` received, in order.
    var imports: [String] { state.withLock { $0.imports } }
    var programs: [Command] { state.withLock { $0.programs } }
    var boots: Int { state.withLock { $0.boots } }
    var updates: Int { state.withLock { $0.updates } }
    /// What .update-timestamp holds once the current runtime's update has started.
    var timestampText: String { "\(state.withLock { $0.wineInfTime })\n" }

    func value(in prefix: String, _ hive: RegistryHiveFile, _ key: String, _ name: String?) -> RegistryValue? {
        state.withLock {
            let hives = $0.hives[prefix] ?? PrefixHives()
            return (hive == .system ? hives.system : hives.user).value(key, name)
        }
    }

    /// Changes a value as a Windows program would.
    func setValue(in prefix: String, _ hive: RegistryHiveFile, _ key: String, _ name: String?, _ value: RegistryValue) {
        updateHives(prefix) { hive == .system ? $0.system.set(key, name, value) : $0.user.set(key, name, value) }
    }

    // MARK: Runner

    func handle(_ command: Command) throws -> ProcessOutput {
        if state.withLock({ $0.hanging(command) }) {
            throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
        }
        if let code = state.withLock({ $0.failing(command) }) { return ProcessOutput(exitCode: code) }
        switch command.executable.lastPathComponent {
        case "wineserver":
            return ProcessOutput(exitCode: 0)
        case "wine":
            guard let prefix = command.environment?["WINEPREFIX"] else { return ProcessOutput(exitCode: 1) }
            return try wine(command.arguments, prefix: prefix, command: command)
        default:
            return ProcessOutput(exitCode: 127)
        }
    }

    private func wine(_ arguments: [String], prefix: String, command: Command) throws -> ProcessOutput {
        let booted = fileSystem.fileExists(at: URL(filePath: prefix + "/system.reg"))
        if arguments == ["wineboot", "--init"] {
            if !booted { createPrefix(prefix) }
            sessionStart(prefix)
            return ProcessOutput(exitCode: 0)
        }
        guard booted else { return ProcessOutput(exitCode: 1) }
        sessionStart(prefix)
        switch arguments.first {
        case "reg":
            guard arguments.count == 3, arguments[1] == "import", let path = unixPath(arguments[2], prefix: prefix),
                  let data = fileSystem.data(at: path) else { return ProcessOutput(exitCode: 1) }
            let text = String(decoding: data, as: UTF8.self)
            state.withLock { $0.imports.append(text) }
            let entries = try RegeditFile.parse(text)
            updateHives(prefix) { hives in
                for entry in entries {
                    if entry.hive == .system { hives.system.set(entry.key, entry.name, entry.value) }
                    else { hives.user.set(entry.key, entry.name, entry.value) }
                }
            }
            return ProcessOutput(exitCode: 0)
        case "cmd":
            return vol(Array(arguments.dropFirst(2)), prefix: prefix)
        default:
            let files = state.withLock {
                $0.programs.append(command)
                return $0.programFiles
            }
            for (path, data) in files { fileSystem.addFile(prefix + "/" + path, data) }
            return state.withLock { $0.programOutput }
        }
    }

    /// What ntdll and the first wineboot make before Wine's prefix update: the skeleton and the hives.
    private func createPrefix(_ prefix: String) {
        let guid = state.withLock { state in
            state.boots += 1
            return state.machineGuids[(state.boots - 1) % state.machineGuids.count]
        }
        fileSystem.addDirectory(prefix + "/drive_c")
        fileSystem.addLink(prefix + "/dosdevices/c:", to: "../drive_c")
        fileSystem.addLink(prefix + "/dosdevices/z:", to: "/")
        let hostName = state.withLock { $0.hostName }
        state.withLock { $0.hives[prefix] = PrefixHives() }
        updateHives(prefix) { hives in
            hives.system.set(#"Software\Microsoft\Cryptography"#, "MachineGuid", .string(guid))
            hives.system.set(#"System\CurrentControlSet\Control\ComputerName\ComputerName"#, "ComputerName",
                             .string(hostName))
            hives.system.set(#"Software\Microsoft\Windows NT\CurrentVersion"#, "ProductId", .string("00330-80000-00000-AA478"))
            hives.user.set(#"Control Panel\Desktop"#, "LogPixels", .dword(96))
        }
    }

    /// wineboot at a session start: the prefix update when the timestamp differs (written first), then
    /// create_computer_name_keys.
    private func sessionStart(_ prefix: String) {
        let timestamp = fileSystem.text(at: prefix + "/" + PrefixService.wineUpdateTimestamp)
        if timestamp != timestampText {
            writeTimestamp(prefix)
            runWineInf(prefix)
        }
        let hostName = state.withLock { $0.hostName }
        if value(in: prefix, .user, #"Software\Wine\Network"#, "UseDnsComputerName") != .string("N") {
            updateHives(prefix) {
                $0.system.set(#"System\CurrentControlSet\Control\ComputerName\ComputerName"#, "ComputerName",
                              .string(hostName))
            }
        }
    }

    private func writeTimestamp(_ prefix: String) {
        fileSystem.addFile(prefix + "/" + PrefixService.wineUpdateTimestamp, timestampText)
    }

    private func runWineInf(_ prefix: String) {
        state.withLock { $0.updates += 1 }
        let driveC = prefix + "/drive_c"
        for directory in ["windows/system32", "windows/syswow64", "windows/temp", "Program Files (x86)",
                          "users/\(userName)/AppData/Local", "users/\(userName)/Saved Games", "users/Public"] {
            fileSystem.addDirectory("\(driveC)/\(directory)")
        }
        let system32 = driveC + "/windows/system32"
        fileSystem.addFile(system32 + "/nvapi64.dll", "Wine's nvapi64 stub")
        fileSystem.addFile(system32 + "/lsteamclient.dll", "Wine's copy of a builtin")

        // shell32's folder registration: SHGetFolderPath(CSIDL_FLAG_CREATE) links only folders that do not exist.
        let profile = "\(driveC)/users/\(userName)"
        for (folder, target) in [("Desktop", "Desktop"), ("Documents", "Documents"), ("Downloads", "Downloads"),
                                 ("Music", "Music"), ("Pictures", "Pictures"), ("Videos", "Movies")] {
            let path = "\(profile)/\(folder)"
            guard !fileSystem.isSymbolicLink(at: URL(filePath: path)),
                  !fileSystem.fileExists(at: URL(filePath: path)) else { continue }
            fileSystem.addLink(path, to: "\(macHome)/\(target)")
        }
    }

    private func vol(_ arguments: [String], prefix: String) -> ProcessOutput {
        var groups: [[String]] = [[]]
        for argument in arguments {
            if argument == "&" { groups.append([]) } else { groups[groups.count - 1].append(argument) }
        }
        var exitCode: Int32 = 0
        for group in groups {
            guard group.count == 4, group[0] == "vol", group[2] == ">", let drive = group[1].first,
                  let output = unixPath(group[3], prefix: prefix) else { return ProcessOutput(exitCode: 1) }
            let root = drive == "C" ? prefix + "/drive_c" : prefix + "/dosdevices/\(drive.lowercased()):"
            guard fileSystem.directoryExists(at: URL(filePath: root)) else {
                exitCode = 1
                continue
            }
            let serial = fileSystem.text(at: root + "/" + VolumeSerial.fileName)
                .flatMap(VolumeSerial.normalized) ?? (drive == "C" ? "43000000" : "58000000")
            let shown = serial.prefix(4) + "-" + serial.suffix(4)
            fileSystem.addFile(output, "Volume in drive \(drive) has no label.\r\nVolume Serial Number is \(shown)\r\n\r\n")
        }
        return ProcessOutput(exitCode: exitCode)
    }

    /// `C:\windows\temp\x.reg` -> `<prefix>/drive_c/windows/temp/x.reg`.
    private func unixPath(_ windowsPath: String, prefix: String) -> String? {
        guard windowsPath.uppercased().hasPrefix(#"C:\"#) else { return nil }
        return prefix + "/drive_c/" + windowsPath.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
    }

    private func updateHives(_ prefix: String, _ change: (inout PrefixHives) -> Void) {
        let hives = state.withLock { state in
            var hives = state.hives[prefix] ?? PrefixHives()
            change(&hives)
            state.hives[prefix] = hives
            return hives
        }
        fileSystem.addFile(prefix + "/system.reg", hives.system.rendered(relativeTo: #"\\Machine"#))
        fileSystem.addFile(prefix + "/user.reg", hives.user.rendered(relativeTo: #"REGISTRY\\User\\S-1-5-21-0-0-0-1000"#))
    }
}
