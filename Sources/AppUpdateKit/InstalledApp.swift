import Darwin
import Foundation
import RuntimeKit
import WarzagCore

/// A Warzag.app on disk, as far as updating it goes: where it is, its identity, version and build, and the app feed its
/// Info.plist names. The app describes its own bundle; warzagctl the bundle it ships in (`Contents/Helpers/warzagctl`)
/// or the one `--app` names.
public struct InstalledApp: Equatable, Sendable {
    public var bundle: URL
    /// CFBundleShortVersionString; "0" when there is none (a development run).
    public var version: String
    /// CFBundleVersion; "0" when there is none, which every published build is newer than.
    public var build: String
    /// CFBundleIdentifier, nil when there is none.
    public var identifier: String?
    /// The app feed its Info.plist names (`AppFeed`), nil for none.
    public var feed: URL?
    /// LSMinimumSystemVersion, nil when there is none.
    public var minimumMacOS: String?

    public init(bundle: URL, version: String, build: String, identifier: String? = AppManifest.bundleIdentifier,
                feed: URL? = nil, minimumMacOS: String? = nil) {
        self.bundle = bundle
        self.version = version
        self.build = build
        self.identifier = identifier
        self.feed = feed
        self.minimumMacOS = minimumMacOS
    }

    /// Reads `<bundle>/Contents/Info.plist`. Nothing is verified: this is the copy that runs, or the one to replace.
    public static func read(_ bundle: URL, fileSystem: any FileSystem = LocalFileSystem(),
                            allowsLoopbackHTTP: Bool = AppFeed.allowsLoopbackHTTP) -> InstalledApp {
        let info = BundleInfo.read(bundle, fileSystem: fileSystem) ?? [:]
        return InstalledApp(bundle: bundle, version: info["CFBundleShortVersionString"] as? String ?? "0",
                            build: info["CFBundleVersion"] as? String ?? "0",
                            identifier: info["CFBundleIdentifier"] as? String,
                            feed: AppFeed.url(in: info, allowsLoopbackHTTP: allowsLoopbackHTTP),
                            minimumMacOS: info["LSMinimumSystemVersion"] as? String)
    }

    /// The app bundle a program ships in: `<X>.app` for `<X>.app/Contents/Helpers/<tool>` and
    /// `<X>.app/Contents/MacOS/<program>`; nil for a program anywhere else (a development build of warzagctl).
    public static func bundle(containing executable: URL) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard components.count >= 4, ["Helpers", "MacOS"].contains(components[components.count - 2]),
              components[components.count - 3] == "Contents", components[components.count - 4].hasSuffix(".app") else {
            return nil
        }
        return executable.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// A bundle's Info.plist as a dictionary.
enum BundleInfo {
    static func read(_ bundle: URL, fileSystem: any FileSystem) -> [String: Any]? {
        guard let data = try? fileSystem.contents(of: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// Whether an installed Warzag can be replaced where it is, asked before Warzag quits for an update.
public protocol AppLocationInspecting: Sendable {
    /// Why `bundle` cannot be replaced in place (a sentence for Warzag.log and warzagctl), or nil when it can.
    func obstacle(replacing bundle: URL) -> String?
}

/// The real Mac: the bundle must be in /Applications or ~/Applications (or a folder inside one) once links are
/// resolved, so neither App Translocation's temporary copy nor a mounted disk image; on a writable volume, in a folder
/// this user may change, and neither the bundle nor its folder locked.
public struct LiveAppLocationInspector: AppLocationInspecting {
    public var applicationFolders: [URL]

    /// `home` is the user's real home (its Applications folder counts), whatever WARZAG_HOME says.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        applicationFolders = [URL(filePath: "/Applications", directoryHint: .isDirectory),
                              home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    public func obstacle(replacing bundle: URL) -> String? {
        let path = Self.resolved(bundle)
        if path.contains("/AppTranslocation/") {
            return "macOS runs this copy from a temporary location (App Translocation); move Warzag into Applications "
                + "with Finder"
        }
        guard applicationFolders.map(Self.resolved).contains(where: { path.hasPrefix($0 + "/") }) else {
            return "\(bundle.plainPath) is not in an Applications folder"
        }
        if (try? URL(filePath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "the volume holding \(bundle.plainPath) is read-only"
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard access(folder, W_OK) == 0 else { return "this user may not change \(folder)" }
        let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        for item in [path, folder] {
            var info = stat()
            if lstat(item, &info) == 0, info.st_flags & locked != 0 { return "\(item) is locked" }
        }
        return nil
    }

    /// The path with every link resolved (/tmp is /private/tmp), or as it is when it does not exist.
    static func resolved(_ url: URL) -> String {
        guard let real = realpath(url.plainPath, nil) else { return url.standardizedFileURL.plainPath }
        defer { free(real) }
        return String(cString: real)
    }
}
