import Foundation

public enum RuntimeHostChannelError: Error, Equatable, CustomStringConvertible {
    /// Contents/Info.plist names something other than "n".
    case unknownDeclaration(String)
    /// Contents/MacOS/wine has no arm64 code.
    case notArm64(loader: String)
    /// Neither says which channel this is.
    case undetermined(String)

    public var description: String {
        switch self {
        case .unknownDeclaration(let value):
            "Info.plist's \(RuntimeChannel.infoPlistKey) is \"\(value)\", not n"
        case .notArm64(let loader): "Contents/MacOS/wine is \(loader), not arm64"
        case .undetermined(let reason): "cannot tell the host's channel: \(reason)"
        }
    }
}

/// Which channel a runtime host ("Warzag.app") was built for, from the host itself: the loader's Mach-O
/// architecture and the `WarzagRuntimeChannel` key of its Info.plist.
///
/// A loader without an arm64 slice is refused, and the key, when present, must name n. An arm64-only loader is enough
/// without the key; an unreadable or universal one needs it.
public enum RuntimeHostChannel {
    public static func channel(declared: String?, loader: [MachOArchitecture]?) throws(RuntimeHostChannelError)
        -> RuntimeChannel {
        var declaredChannel: RuntimeChannel?
        if let declared {
            guard let channel = RuntimeChannel(rawValue: declared) else { throw .unknownDeclaration(declared) }
            declaredChannel = channel
        }
        if let loader, !loader.isEmpty, !loader.contains(where: { $0 == .arm64 || $0 == .arm64e }) {
            throw .notArm64(loader: loader.map(\.description).joined(separator: "+"))
        }
        if let channel = loader.flatMap(Self.channel(of:)) ?? declaredChannel { return channel }
        throw .undetermined(loader.map { "Contents/MacOS/wine is \($0.map(\.description).joined(separator: "+"))" }
            ?? "Contents/MacOS/wine is not a Mach-O file and Info.plist has no \(RuntimeChannel.infoPlistKey)")
    }

    /// The channel a loader with these slices belongs to: arm64 (or arm64e) only is N.
    public static func channel(of loader: [MachOArchitecture]) -> RuntimeChannel? {
        guard !loader.isEmpty, loader.allSatisfy({ $0 == .arm64 || $0 == .arm64e }) else { return nil }
        return .n
    }

    /// Reads `<bundle>/Contents/Info.plist` and the first bytes of `<bundle>/Contents/MacOS/wine`.
    public static func detect(bundle: URL, fileSystem: any FileSystem) throws(RuntimeHostChannelError) -> RuntimeChannel {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        var declared: String?
        if let data = try? fileSystem.contents(of: contents.appending(path: "Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let value = plist[RuntimeChannel.infoPlistKey] {
                declared = (value as? String) ?? String(describing: value)
            }
        }
        let loader = (try? fileSystem.read(contents.appending(path: "MacOS/wine"), offset: 0,
                                           maxLength: MachO.headerReadLength))
            .flatMap(MachO.architectures(header:))
        return try channel(declared: declared, loader: loader)
    }
}
