import Foundation

public struct CompoundFileError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public var description: String { "not a readable compound file: \(reason)" }

    init(_ reason: String) {
        self.reason = reason
    }
}

/// A read-only view of a Compound File Binary file ([MS-CFB]), the container of Windows Installer packages: storages
/// (folders) and streams (files) in FAT-style sector chains. Only what MSI signature checking needs.
///
/// Malformed files throw `CompoundFileError`. Nothing is read outside `data`, and no size from the file is trusted
/// before it has been checked against the file's own size.
public struct CompoundFile: Sendable {
    public enum EntryType: UInt8, Sendable {
        case storage = 1
        case stream = 2
        case root = 5
    }

    /// One directory entry, with its fields as stored (the MSI signature digest hashes some of them raw).
    public struct Entry: Sendable, Equatable {
        public let index: Int
        /// The name in UTF-16LE including its terminating NUL, exactly `nameLength` bytes of the entry.
        public let rawName: [UInt8]
        public let name: String
        public let type: EntryType
        public let clsid: [UInt8]
        public let stateBits: [UInt8]
        public let creationTime: [UInt8]
        public let modifiedTime: [UInt8]
        /// The size field's eight bytes as stored.
        public let rawSize: [UInt8]
        public let startSector: UInt32
        /// The stream's size (the low 32 bits in version-3 files, whose high half may hold garbage).
        public let size: UInt64
        /// Direct children of a storage or the root, in directory order.
        public internal(set) var children: [Int]

        let left: UInt32
        let right: UInt32
        let child: UInt32
    }

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let noStream: UInt32 = 0xFFFF_FFFF
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let maximumRegularSector: UInt32 = 0xFFFF_FFFA
    /// How deep storages may nest. Packages use one or two levels; the MSI digest recurses, so a crafted package
    /// nesting thousands would overflow the stack.
    static let maximumStorageDepth = 64

    public let data: Data
    public let majorVersion: Int
    let sectorShift: Int
    let miniSectorShift: Int
    let miniStreamCutoff: UInt64
    let fat: [UInt32]
    let miniFAT: [UInt32]
    let miniStream: Data
    public private(set) var entries: [Entry]

    public var root: Entry { entries[0] }
    var sectorSize: Int { 1 << sectorShift }

    public init(data: Data) throws(CompoundFileError) {
        // Copy-free slices of a possibly memory-mapped file start at index 0 from here on.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        guard data.count >= 512, Array(data.prefix(8)) == Self.signature else {
            throw CompoundFileError("no compound-file signature")
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 { Self.littleEndian32(data, at: offset) }
        let major = Int(u16(0x1A))
        let shift = Int(u16(0x1E))
        let miniShift = Int(u16(0x20))
        guard u16(0x1C) == 0xFFFE else { throw CompoundFileError("unexpected byte order") }
        guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else {
            throw CompoundFileError("version \(major) with \(1 << min(shift, 30))-byte sectors")
        }
        guard miniShift == 6 else { throw CompoundFileError("mini sectors of \(1 << min(miniShift, 30)) bytes") }
        let cutoff = UInt64(u32(0x38))
        guard cutoff == 4096 else { throw CompoundFileError("mini stream cutoff \(cutoff)") }
        majorVersion = major
        sectorShift = shift
        miniSectorShift = miniShift
        miniStreamCutoff = cutoff
        let sectorSize = 1 << shift
        let sectorCount = max(0, (data.count - sectorSize) / sectorSize) + 1
        let entriesPerSector = sectorSize / 4

        // The FAT's own sectors: 109 in the header, the rest in a chain of DIFAT sectors. There cannot be more of them
        // than sectors in the file; that bound also ends a DIFAT chain that loops back on itself.
        let fatSectorCount = Int(u32(0x2C))
        guard fatSectorCount <= sectorCount else {
            throw CompoundFileError("the header lists more FAT sectors than the file has")
        }
        var fatSectors: [UInt32] = []
        for index in 0..<109 where fatSectors.count < fatSectorCount {
            fatSectors.append(u32(0x4C + index * 4))
        }
        var difat = u32(0x44)
        var difatSectorsLeft = Int(u32(0x48))
        while fatSectors.count < fatSectorCount, difatSectorsLeft > 0 {
            // The whole sector must be in the file: `sectorCount` also counts a last sector cut short.
            guard difat <= Self.maximumRegularSector, (Int(difat) + 2) << shift <= data.count else {
                throw CompoundFileError("the DIFAT chain leaves the file")
            }
            let base = (Int(difat) + 1) << shift
            for index in 0..<(entriesPerSector - 1) where fatSectors.count < fatSectorCount {
                fatSectors.append(u32(base + index * 4))
            }
            difat = u32(base + (entriesPerSector - 1) * 4)
            difatSectorsLeft -= 1
        }
        guard fatSectors.count == fatSectorCount else { throw CompoundFileError("the DIFAT lists too few FAT sectors") }
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectorCount * entriesPerSector)
        for sector in fatSectors {
            guard sector <= Self.maximumRegularSector, Int(sector) < sectorCount,
                  (Int(sector) + 2) << shift <= data.count else {
                throw CompoundFileError("a FAT sector lies outside the file")
            }
            let base = (Int(sector) + 1) << shift
            for index in 0..<entriesPerSector { fat.append(u32(base + index * 4)) }
        }
        self.fat = fat

        func chain(_ start: UInt32, in table: [UInt32], limit: Int) throws(CompoundFileError) -> [UInt32] {
            var sectors: [UInt32] = []
            var sector = start
            while sector != Self.endOfChain {
                guard sector <= Self.maximumRegularSector, Int(sector) < table.count, sectors.count < limit else {
                    throw CompoundFileError("a sector chain loops or leaves the file")
                }
                sectors.append(sector)
                sector = table[Int(sector)]
            }
            return sectors
        }
        func readChain(_ start: UInt32) throws(CompoundFileError) -> Data {
            var result = Data()
            for sector in try chain(start, in: fat, limit: sectorCount) {
                let offset = (Int(sector) + 1) << shift
                guard offset + sectorSize <= data.count else { throw CompoundFileError("a sector lies outside the file") }
                result.append(data[offset..<(offset + sectorSize)])
            }
            return result
        }

        // The directory: 128-byte entries in a regular sector chain.
        let directory = try readChain(u32(0x30))
        var entries: [Entry] = []
        for offset in stride(from: 0, to: directory.count - 127, by: 128) {
            let raw = [UInt8](directory[offset..<(offset + 128)])
            guard let type = EntryType(rawValue: raw[0x42]) else {
                entries.append(Entry.empty(index: entries.count))
                continue
            }
            let nameLength = Int(UInt16(raw[0x40]) | UInt16(raw[0x41]) << 8)
            guard nameLength >= 2, nameLength <= 64, nameLength % 2 == 0 else {
                throw CompoundFileError("entry \(entries.count) has a name of \(nameLength) bytes")
            }
            func le32(_ at: Int) -> UInt32 { Self.littleEndian32(raw, at: at) }
            let low = UInt64(le32(0x78))
            let high = UInt64(le32(0x7C))
            let units = stride(from: 0, to: nameLength - 2, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
            entries.append(Entry(
                index: entries.count, rawName: Array(raw[0..<nameLength]),
                name: String(decoding: units, as: UTF16.self), type: type, clsid: Array(raw[0x50..<0x60]),
                stateBits: Array(raw[0x60..<0x64]), creationTime: Array(raw[0x64..<0x6C]),
                modifiedTime: Array(raw[0x6C..<0x74]), rawSize: Array(raw[0x78..<0x80]), startSector: le32(0x74),
                size: major == 3 ? low : (high << 32 | low), children: [], left: le32(0x44), right: le32(0x48),
                child: le32(0x4C)))
        }
        guard let first = entries.first, first.type == .root else { throw CompoundFileError("no root entry") }

        // Each storage's children form a red-black tree through the left and right sibling links.
        var claimed = Set([0])
        func siblings(from start: UInt32) throws(CompoundFileError) -> [Int] {
            var result: [Int] = []
            var stack = [start]
            while let next = stack.popLast() {
                guard next != Self.noStream else { continue }
                let index = Int(next)
                guard index < entries.count, entries[index].isAllocated else {
                    throw CompoundFileError("a directory link points at no entry")
                }
                guard claimed.insert(index).inserted else { throw CompoundFileError("the directory tree loops") }
                result.append(index)
                stack.append(entries[index].right)
                stack.append(entries[index].left)
            }
            return result.sorted()
        }
        var pending = [(index: 0, depth: 0)]
        while let (parent, depth) = pending.popLast() {
            let children = try siblings(from: entries[parent].child)
            entries[parent].children = children
            let storages = children.filter { entries[$0].type == .storage }
            if !storages.isEmpty, depth >= Self.maximumStorageDepth {
                throw CompoundFileError("storages are nested more than \(Self.maximumStorageDepth) deep")
            }
            pending += storages.map { (index: $0, depth: depth + 1) }
        }
        self.entries = entries

        // Small streams live in the mini stream (the root entry's own stream), in 64-byte mini sectors.
        let miniFATBytes = try readChain(u32(0x3C))
        miniFAT = stride(from: 0, to: miniFATBytes.count - 3, by: 4).map { Self.littleEndian32(miniFATBytes, at: $0) }
        let rootStream = first.startSector == Self.endOfChain ? Data() : try readChain(first.startSector)
        guard UInt64(rootStream.count) >= first.size else { throw CompoundFileError("the mini stream is truncated") }
        miniStream = rootStream.prefix(Int(first.size))
    }

    static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2]) << 16
        let b3 = UInt32(bytes[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1]) << 8
        let b2 = UInt32(data[index + 2]) << 16
        let b3 = UInt32(data[index + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    public func children(of entry: Entry) -> [Entry] {
        entry.children.map { entries[$0] }
    }

    /// The stream's size, once checked to be no larger than the whole file: only then is anything allocated for it,
    /// or the size (64 bits in version 4) turned into an `Int`.
    func checkedSize(of entry: Entry) throws(CompoundFileError) -> Int {
        guard entry.size <= UInt64(data.count) else {
            throw CompoundFileError("\(entry.name) claims \(entry.size) bytes, more than the whole file")
        }
        return Int(entry.size)
    }

    /// The stream's contents in contiguous pieces, in order; together exactly `entry.size` bytes.
    public func forEachSlice(of entry: Entry, _ body: (Data) throws -> Void) throws {
        guard entry.type == .stream else { throw CompoundFileError("\(entry.name) is not a stream") }
        var remaining = try checkedSize(of: entry)
        guard remaining > 0 else { return }
        if entry.size < miniStreamCutoff {
            let miniSize = 1 << miniSectorShift
            var sector = entry.startSector
            var steps = 0
            while remaining > 0 {
                guard sector <= Self.maximumRegularSector, Int(sector) < miniFAT.count, steps <= miniFAT.count else {
                    throw CompoundFileError("\(entry.name)'s mini sector chain is broken")
                }
                let offset = Int(sector) << miniSectorShift
                let length = min(miniSize, remaining)
                guard offset + length <= miniStream.count else {
                    throw CompoundFileError("\(entry.name) lies outside the mini stream")
                }
                try body(miniStream[(miniStream.startIndex + offset)..<(miniStream.startIndex + offset + length)])
                remaining -= length
                sector = miniFAT[Int(sector)]
                steps += 1
            }
            return
        }
        // Regular sectors, read in runs of consecutive sectors.
        var sector = entry.startSector
        var steps = 0
        while remaining > 0 {
            guard sector <= Self.maximumRegularSector, Int(sector) < fat.count, steps <= fat.count else {
                throw CompoundFileError("\(entry.name)'s sector chain is broken")
            }
            var run = 1
            while run * sectorSize < remaining, fat[Int(sector) + run - 1] == sector + UInt32(run),
                  Int(sector) + run < fat.count {
                run += 1
            }
            let offset = (Int(sector) + 1) << sectorShift
            let length = min(run * sectorSize, remaining)
            guard offset + length <= data.count else { throw CompoundFileError("\(entry.name) runs past the file") }
            try body(data[offset..<(offset + length)])
            remaining -= length
            sector = fat[Int(sector) + run - 1]
            steps += run
        }
    }

    public func contents(of entry: Entry) throws -> Data {
        var result = Data()
        result.reserveCapacity(try checkedSize(of: entry))
        try forEachSlice(of: entry) { result.append($0) }
        return result
    }
}

extension CompoundFile.Entry {
    /// An unused directory slot (no name; never part of the tree).
    static func empty(index: Int) -> Self {
        Self(index: index, rawName: [], name: "", type: .stream, clsid: [], stateBits: [], creationTime: [],
             modifiedTime: [], rawSize: [], startSector: CompoundFile.endOfChain, size: 0, children: [],
             left: CompoundFile.noStream, right: CompoundFile.noStream, child: CompoundFile.noStream)
    }

    var isAllocated: Bool { !rawName.isEmpty }
}
