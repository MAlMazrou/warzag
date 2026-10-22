import Foundation

/// Mac Driver options that are global to a prefix (winemac reads RetinaMode only from the global key).
public struct MacDriverSettings: Sendable, Equatable {
    /// The game sees native pixels (with LogPixels 192) instead of macOS points at 96 DPI.
    public var retinaMode: Bool
    /// Option keys act as Alt, so Windows Alt shortcuts work.
    public var optionAsAlt: Bool
    /// Opt-in "Command acts as Ctrl"; Wine warns unless Option-as-Alt is also on.
    public var commandAsControl: Bool

    public init(retinaMode: Bool, optionAsAlt: Bool = true, commandAsControl: Bool = false) {
        self.retinaMode = retinaMode
        self.optionAsAlt = optionAsAlt
        self.commandAsControl = commandAsControl
    }
}

/// Registry keys every Warzag prefix is seeded with.
///
/// Steam keys are not part of it: the runtime's bridge/prefix/steam.reg (Contents/share/warzag/bridge/steam.reg) is
/// the single source of truth for them, imported as-is next to this template (EngineKit's PrefixService).
public enum PrefixTemplate {
    /// Where the steam.exe shim and the steamclient64 forwarder live inside the prefix.
    public static let steamDirectory = #"C:\Program Files (x86)\Steam"#
    /// DLLs DE's CEF launcher must not load: dwrite and libglesv2 blank its window under Wine, and it must never
    /// see nvapi/NGX (DXMT's NVEXT path, for the game only).
    public static let launcherDisabledDLLs = ["dwrite", "libglesv2", "nvapi64", "nvngx"]

    public static func registry(macDriver: MacDriverSettings) -> RegistryFile {
        var file = RegistryFile()
        let yes = RegistryFile.Value.string("y")
        let no = RegistryFile.Value.string("n")

        let macDriverKey = #"Software\Wine\Mac Driver"#
        file.set(.currentUser, macDriverKey, "RetinaMode", macDriver.retinaMode ? yes : no)
        file.set(.currentUser, macDriverKey, "LeftOptionIsAlt", macDriver.optionAsAlt ? yes : no)
        file.set(.currentUser, macDriverKey, "RightOptionIsAlt", macDriver.optionAsAlt ? yes : no)
        if macDriver.commandAsControl {
            file.set(.currentUser, macDriverKey, "LeftCommandIsCtrl", yes)
            file.set(.currentUser, macDriverKey, "RightCommandIsCtrl", yes)
        }
        // LogPixels 192 with RetinaMode, so Windows UI keeps its size.
        file.set(.currentUser, #"Control Panel\Desktop"#, "LogPixels", .dword(macDriver.retinaMode ? 192 : 96))

        // An empty override string is Wine's "disabled".
        for dll in launcherDisabledDLLs {
            file.set(.currentUser, #"Software\Wine\AppDefaults\Launcher.exe\DllOverrides"#, dll, .string(""))
        }
        return file
    }
}
