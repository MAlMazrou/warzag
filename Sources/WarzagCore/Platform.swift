import Foundation

/// What a Mac needs to run Warzag.
public enum Platform {
    public static let minimumMacOS = VersionNumber(
        OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    /// Free space a fresh install needs on the library volume: the game's files plus caches and partial downloads.
    public static let minimumLibraryBytes: Int64 = 80_000_000_000
}
