import Foundation

/// A dotted numeric version ("15.0", "1.10.2"). A pre-release suffix ("1.1.0-b2") is ignored when comparing,
/// and missing components count as zero, so "15" == "15.0".
public struct VersionNumber: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let core = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        components = values
    }

    public init(_ version: OperatingSystemVersion) {
        components = [version.majorVersion, version.minorVersion, version.patchVersion]
    }

    /// "15.0", "26.5.1", "1.10": trailing zero components dropped, but always at least major.minor.
    public var description: String {
        var shown = components
        while shown.count > 2, shown.last == 0 { shown.removeLast() }
        if shown.count == 1 { shown.append(0) }
        return shown.map(String.init).joined(separator: ".")
    }

    private var trimmed: [Int] {
        var values = components
        while values.count > 1, values.last == 0 { values.removeLast() }
        return values
    }

    public static func == (lhs: VersionNumber, rhs: VersionNumber) -> Bool { lhs.trimmed == rhs.trimmed }

    public func hash(into hasher: inout Hasher) { hasher.combine(trimmed) }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
