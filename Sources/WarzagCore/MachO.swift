import Foundation

/// One architecture slice of a Mach-O file, as far as Warzag needs to tell runtime hosts apart.
public enum MachOArchitecture: Sendable, Equatable, Hashable, CustomStringConvertible {
    case x86_64
    case arm64
    case arm64e
    case i386
    /// Anything else, by its `cputype`.
    case other(cpuType: Int32)

    static let cpuArchABI64: Int32 = 0x0100_0000
    static let cpuTypeX86: Int32 = 7
    static let cpuTypeARM: Int32 = 12
    /// `CPU_SUBTYPE_ARM64E`, compared without the capability bits (`CPU_SUBTYPE_MASK`).
    static let subtypeARM64E: Int32 = 2

    init(cpuType: Int32, cpuSubtype: Int32) {
        switch cpuType {
        case Self.cpuTypeX86 | Self.cpuArchABI64: self = .x86_64
        case Self.cpuTypeX86: self = .i386
        case Self.cpuTypeARM | Self.cpuArchABI64:
            self = (cpuSubtype & 0x00FF_FFFF) == Self.subtypeARM64E ? .arm64e : .arm64
        default: self = .other(cpuType: cpuType)
        }
    }

    public var description: String {
        switch self {
        case .x86_64: "x86_64"
        case .arm64: "arm64"
        case .arm64e: "arm64e"
        case .i386: "i386"
        case .other(let type): "cputype \(type)"
        }
    }
}

/// Reads the architectures of a thin or universal Mach-O file from its first bytes (`mach_header(_64)`, `fat_header`
/// with `fat_arch` or `fat_arch_64` entries). Nothing else of the file is interpreted.
public enum MachO {
    /// How many bytes `architectures(header:)` needs at most: a universal header with 32 slices.
    public static let headerReadLength = 8 + 32 * 32
    static let maximumSlices: UInt32 = 32

    /// The file's architectures, or nil when `header` does not start a Mach-O file (or is cut short).
    public static func architectures(header: Data) -> [MachOArchitecture]? {
        let bytes = [UInt8](header.prefix(headerReadLength))
        guard bytes.count >= 8 else { return nil }
        let bigEndianMagic = UInt32(bigEndianBytes: bytes, at: 0)
        switch bigEndianMagic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // Universal binaries are big-endian throughout. 0xCAFEBABE is also a Java class file, whose second word
            // is a version number in the 40s-60s: more slices than any real universal binary has.
            let wide = bigEndianMagic == 0xCAFE_BABF
            let count = UInt32(bigEndianBytes: bytes, at: 4)
            guard count > 0, count <= maximumSlices else { return nil }
            let entrySize = wide ? 32 : 20
            var slices: [MachOArchitecture] = []
            for index in 0..<Int(count) {
                let offset = 8 + index * entrySize
                guard offset + 8 <= bytes.count else { return nil }
                slices.append(MachOArchitecture(cpuType: Int32(bitPattern: UInt32(bigEndianBytes: bytes, at: offset)),
                                                cpuSubtype: Int32(bitPattern: UInt32(bigEndianBytes: bytes, at: offset + 4))))
            }
            return slices
        case 0xFEED_FACE, 0xFEED_FACF:
            // A thin file written big-endian (PowerPC era).
            guard bytes.count >= 12 else { return nil }
            return [MachOArchitecture(cpuType: Int32(bitPattern: UInt32(bigEndianBytes: bytes, at: 4)),
                                      cpuSubtype: Int32(bitPattern: UInt32(bigEndianBytes: bytes, at: 8)))]
        case 0xCEFA_EDFE, 0xCFFA_EDFE:
            // MH_MAGIC / MH_MAGIC_64 stored little-endian: every Apple silicon and Intel binary.
            guard bytes.count >= 12 else { return nil }
            return [MachOArchitecture(cpuType: Int32(bitPattern: UInt32(littleEndianBytes: bytes, at: 4)),
                                      cpuSubtype: Int32(bitPattern: UInt32(littleEndianBytes: bytes, at: 8)))]
        default:
            return nil
        }
    }
}

extension UInt32 {
    init(bigEndianBytes bytes: [UInt8], at offset: Int) {
        self = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(littleEndianBytes bytes: [UInt8], at offset: Int) {
        self = bytes[offset..<(offset + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
