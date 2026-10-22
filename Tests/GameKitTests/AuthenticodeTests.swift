import CryptoKit
import Foundation
import Testing
@testable import GameKit

/// Writes small compound files with one FAT sector: version 3 (512-byte sectors) by default, version 4 (4096-byte
/// sectors and 64-bit stream sizes, like DE's Warframe.msi) with `version4`. Small streams go in the mini stream and
/// large ones in regular sectors, the way Windows Installer packages are laid out.
struct CompoundFileBuilder {
    final class Node {
        var name: String
        var type: UInt8
        var data: Data
        var clsid: [UInt8]
        var children: [Node]
        var index = 0

        init(_ name: String, type: UInt8, data: Data = Data(), clsid: [UInt8] = Array(repeating: 0, count: 16),
             children: [Node] = []) {
            self.name = name
            self.type = type
            self.data = data
            self.clsid = clsid
            self.children = children
        }

        static func stream(_ name: String, _ data: Data) -> Node { Node(name, type: 2, data: data) }
        static func storage(_ name: String, clsid: [UInt8], _ children: [Node]) -> Node {
            Node(name, type: 1, clsid: clsid, children: children)
        }
    }

    static let end: UInt32 = 0xFFFF_FFFE
    static let free: UInt32 = 0xFFFF_FFFF
    static let none: UInt32 = 0xFFFF_FFFF

    var root: Node
    /// Breaks the directory's sibling links into a loop (a malformed file).
    var loopTheTree = false
    /// Version 4: 4096-byte sectors (the header padded to one) and the size field's high half written too.
    var version4 = false

    var sectorSize: Int { version4 ? 4096 : 512 }

    func build() -> Data {
        let sectorSize = self.sectorSize
        var nodes: [Node] = []
        func collect(_ node: Node) {
            node.index = nodes.count
            nodes.append(node)
            node.children.forEach(collect)
        }
        collect(root)

        // Each storage's children as a balanced binary tree through left/right links.
        var left = [UInt32](repeating: Self.none, count: nodes.count)
        var right = left
        var child = left
        func tree(_ items: ArraySlice<Node>) -> UInt32 {
            guard !items.isEmpty else { return Self.none }
            let middle = items.startIndex + items.count / 2
            let node = items[middle]
            left[node.index] = tree(items[items.startIndex..<middle])
            right[node.index] = tree(items[(middle + 1)..<items.endIndex])
            return UInt32(node.index)
        }
        for node in nodes where node.type != 2 { child[node.index] = tree(ArraySlice(node.children)) }
        if loopTheTree, let last = nodes.last { right[last.index] = child[0] }

        // Sector 0 is the FAT, then the directory, the mini FAT, the mini stream and large streams.
        var fat = [UInt32](repeating: Self.free, count: sectorSize / 4)
        fat[0] = 0xFFFF_FFFD
        var sectors: [Data] = [Data()]
        func allocate(_ data: Data) -> UInt32 {
            guard !data.isEmpty else { return Self.end }
            let first = sectors.count
            var offset = 0
            while offset < data.count {
                var sector = data.subdata(in: offset..<min(data.count, offset + sectorSize))
                sector.append(Data(count: sectorSize - sector.count))
                sectors.append(sector)
                offset += sectorSize
            }
            for index in first..<sectors.count { fat[index] = index + 1 < sectors.count ? UInt32(index + 1) : Self.end }
            return UInt32(first)
        }

        var miniStream = Data()
        var miniFAT: [UInt32] = []
        var start = [UInt32](repeating: Self.end, count: nodes.count)
        var large: [(Int, Data)] = []
        for node in nodes where node.type == 2 {
            if node.data.count < 4096 {
                guard !node.data.isEmpty else { continue }
                let first = miniFAT.count
                var offset = 0
                while offset < node.data.count {
                    var piece = node.data.subdata(in: offset..<min(node.data.count, offset + 64))
                    piece.append(Data(count: 64 - piece.count))
                    miniStream.append(piece)
                    offset += 64
                    miniFAT.append(0)
                }
                for index in first..<miniFAT.count { miniFAT[index] = index + 1 < miniFAT.count ? UInt32(index + 1) : Self.end }
                start[node.index] = UInt32(first)
            } else {
                large.append((node.index, node.data))
            }
        }

        // The directory needs to know where everything starts, so it is laid out first with placeholders.
        let entriesPerDirectorySector = sectorSize / 128
        let directorySectors = (nodes.count + entriesPerDirectorySector - 1) / entriesPerDirectorySector
        let directoryStart = sectors.count
        for _ in 0..<directorySectors { sectors.append(Data(count: sectorSize)) }
        for index in directoryStart..<sectors.count { fat[index] = index + 1 < sectors.count ? UInt32(index + 1) : Self.end }
        var miniFATData = Data()
        for value in miniFAT { miniFATData += Self.le32(value) }
        let miniFATStart = allocate(miniFATData)
        let miniStreamStart = allocate(miniStream)
        start[0] = miniStreamStart
        for (index, data) in large { start[index] = allocate(data) }

        var directory = Data()
        for node in nodes {
            var entry = Data(count: 128)
            let units = Array(node.name.utf16) + [0]
            for (offset, unit) in units.enumerated() {
                entry[offset * 2] = UInt8(unit & 0xFF)
                entry[offset * 2 + 1] = UInt8(unit >> 8)
            }
            entry.replaceSubrange(0x40..<0x42, with: Self.le16(UInt16(units.count * 2)))
            entry[0x42] = node.type
            entry[0x43] = 1
            entry.replaceSubrange(0x44..<0x48, with: Self.le32(left[node.index]))
            entry.replaceSubrange(0x48..<0x4C, with: Self.le32(right[node.index]))
            entry.replaceSubrange(0x4C..<0x50, with: Self.le32(child[node.index]))
            entry.replaceSubrange(0x50..<0x60, with: node.clsid)
            entry.replaceSubrange(0x60..<0x64, with: Self.le32(UInt32(node.index)))
            if node.type == 1 { entry.replaceSubrange(0x64..<0x6C, with: Data(repeating: UInt8(node.index), count: 8)) }
            entry.replaceSubrange(0x74..<0x78, with: Self.le32(start[node.index]))
            let size = UInt64(node.type == 5 ? miniStream.count : node.data.count)
            entry.replaceSubrange(0x78..<0x80, with: Self.le32(UInt32(size & 0xFFFF_FFFF)) + Self.le32(UInt32(size >> 32)))
            directory += entry
        }
        directory.append(Data(count: directorySectors * sectorSize - directory.count))
        for index in 0..<directorySectors {
            sectors[directoryStart + index] = directory.subdata(in: (index * sectorSize)..<((index + 1) * sectorSize))
        }
        var fatData = Data()
        for value in fat { fatData += Self.le32(value) }
        sectors[0] = fatData

        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 16)
        header += Self.le16(0x3E) + Self.le16(version4 ? 4 : 3) + Self.le16(0xFFFE) + Self.le16(version4 ? 12 : 9)
        header += Self.le16(6) + Data(count: 6)
        header += Self.le32(version4 ? UInt32(directorySectors) : 0) + Self.le32(1) + Self.le32(UInt32(directoryStart))
        header += Self.le32(0) + Self.le32(4096)
        header += Self.le32(miniFATStart) + Self.le32(UInt32((miniFATData.count + sectorSize - 1) / sectorSize))
        header += Self.le32(Self.end) + Self.le32(0) + Self.le32(0)
        for _ in 1..<109 { header += Self.le32(Self.free) }
        header.append(Data(count: sectorSize - header.count))
        return sectors.reduce(header) { $0 + $1 }
    }

    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

@Suite struct CompoundFileTests {
    static let rootCLSID: [UInt8] = Array(0..<16)
    static let storageCLSID: [UInt8] = Array(100..<116)
    let large = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    func package(withSignatures: Bool = true) -> CompoundFileBuilder {
        var children: [CompoundFileBuilder.Node] = [
            .stream("\u{4840}\u{3F3F}Tables", Data("tables".utf8)),
            .stream("Big", large),
            .storage("Sub", clsid: Self.storageCLSID, [.stream("Inner", Data("inner".utf8)), .stream("Empty", Data())]),
            .stream("\u{05}SummaryInformation", Data(repeating: 7, count: 300)),
            .stream("A", Data("a".utf8)),
            .stream("AB", Data("ab".utf8)),
        ]
        if withSignatures {
            children += [.stream("\u{05}DigitalSignature", Data("pkcs7".utf8)),
                         .stream("\u{05}MsiDigitalSignatureEx", Data(repeating: 9, count: 32))]
        }
        return CompoundFileBuilder(root: CompoundFileBuilder.Node("Root Entry", type: 5, clsid: Self.rootCLSID,
                                                                  children: children))
    }

    @Test func aPackageIsReadBack() throws {
        let file = try CompoundFile(data: package().build())
        #expect(file.root.name == "Root Entry")
        #expect(file.root.clsid == Self.rootCLSID)
        let children = file.children(of: file.root)
        #expect(Set(children.map(\.name)) == ["\u{4840}\u{3F3F}Tables", "Big", "Sub", "\u{05}SummaryInformation", "A", "AB",
                                               "\u{05}DigitalSignature", "\u{05}MsiDigitalSignatureEx"])
        let big = try #require(children.first { $0.name == "Big" })
        #expect(big.size == 10_000)
        #expect(try file.contents(of: big) == large)
        let summary = try #require(children.first { $0.name == "\u{05}SummaryInformation" })
        #expect(try file.contents(of: summary) == Data(repeating: 7, count: 300))
        let sub = try #require(children.first { $0.name == "Sub" })
        #expect(sub.type == .storage && sub.clsid == Self.storageCLSID)
        let inner = file.children(of: sub)
        #expect(inner.map(\.name).sorted() == ["Empty", "Inner"])
        #expect(try file.contents(of: try #require(inner.first { $0.name == "Inner" })) == Data("inner".utf8))
        #expect(try file.contents(of: try #require(inner.first { $0.name == "Empty" })).isEmpty)
    }

    @Test func theDigestVisitsStreamsInMicrosoftsOrder() throws {
        let file = try CompoundFile(data: package().build())
        var builder = DigestBuilder(.sha256)
        try MSIAuthenticode.hash(file.root, in: file, isRoot: true, into: &builder)
        // Raw UTF-16LE names compared byte-wise: "\u{05}..." (0x05) first, then U+4840 (stored 0x40 0x48), then "A"
        // before "AB" (a prefix sorts first), "Big", "Sub". The signature streams are left out; each storage's CLSID
        // follows its children.
        var expected = SHA256()
        expected.update(data: Data(repeating: 7, count: 300))           // \u{05}SummaryInformation
        expected.update(data: Data("tables".utf8))                       // \u{4840}\u{3F3F}Tables (0x40 0x48 ...)
        expected.update(data: Data("a".utf8))                            // A
        expected.update(data: Data("ab".utf8))                           // AB
        expected.update(data: large)                                     // Big
        expected.update(data: Data("inner".utf8))                        // Sub/Inner (Empty adds nothing)
        expected.update(data: Data(Self.storageCLSID))                   // Sub's CLSID
        expected.update(data: Data(Self.rootCLSID))                      // the root's CLSID
        #expect(builder.finalize() == Array(expected.finalize()))

        let order = MSIAuthenticode.digestOrder(file.children(of: file.root)).map(\.name)
        #expect(order == ["\u{05}DigitalSignature", "\u{05}MsiDigitalSignatureEx", "\u{05}SummaryInformation",
                          "\u{4840}\u{3F3F}Tables", "A", "AB", "Big", "Sub"])
    }

    @Test func thePrehashCoversTheMetadata() throws {
        let file = try CompoundFile(data: package().build())
        var builder = DigestBuilder(.sha256)
        try MSIAuthenticode.prehash(file.root, in: file, isRoot: true, into: &builder)
        let first = builder.finalize()
        // Another state bit on one entry changes it; the signature streams' metadata does not count.
        var data = package().build()
        let entryOffset = 512 * 2 + 128 * 1  // sector 1 is the directory; entry 1 is the first child
        data[entryOffset + 0x60] ^= 0xFF
        let changed = try CompoundFile(data: data)
        var second = DigestBuilder(.sha256)
        try MSIAuthenticode.prehash(changed.root, in: changed, isRoot: true, into: &second)
        #expect(second.finalize() != first)
    }

    @Test func anUnsignedPackageIsSaidToBeUnsigned() {
        #expect(throws: MSISignatureError.unsigned) {
            try MSIAuthenticode.verify(package(withSignatures: false).build(), expectedSigner: "Digital Extremes Ltd.")
        }
        #expect(throws: MSISignatureError.malformed("truncated element at 0")) {
            let builder = package(withSignatures: false)
            builder.root.children.append(.stream("\u{05}DigitalSignature", Data([0x30])))
            _ = try MSIAuthenticode.verify(builder.build(), expectedSigner: "Digital Extremes Ltd.")
        }
    }

    @Test func malformedFilesAreRefused() {
        #expect(throws: CompoundFileError.self) { try CompoundFile(data: Data("not a compound file".utf8)) }
        var looping = package()
        looping.loopTheTree = true
        #expect(throws: CompoundFileError("the directory tree loops")) { try CompoundFile(data: looping.build()) }
        var truncated = package().build()
        truncated.removeLast(4000)
        #expect(throws: CompoundFileError.self) {
            let file = try CompoundFile(data: truncated)
            for entry in file.entries where entry.type == .stream { _ = try file.contents(of: entry) }
        }
        #expect(throws: MSISignatureError.self) {
            try MSIAuthenticode.verify(Data("PK\u{3}\u{4}".utf8) + Data(count: 600), expectedSigner: "x")
        }
    }

    /// Writes `value` little-endian at `offset` (a header field or a directory entry field).
    static func patch(_ data: inout Data, at offset: Int, _ value: UInt32) {
        data.replaceSubrange(offset..<(offset + 4), with: CompoundFileBuilder.le32(value))
    }

    /// Where directory entry `index` starts in a file from `CompoundFileBuilder` (its directory is contiguous).
    static func entryOffset(_ data: Data, _ index: Int, sectorSize: Int = 512) -> Int {
        (Int(CompoundFile.littleEndian32(data, at: 0x30)) + 1) * sectorSize + 128 * index
    }

    @Test func aVersion4PackageIsReadAndItsSixtyFourBitSizesAreChecked() throws {
        // DE's Warframe.msi is a version-4 file: 4096-byte sectors, and stream sizes of 64 bits.
        var builder = package()
        builder.version4 = true
        var data = builder.build()
        let file = try CompoundFile(data: data)
        #expect(file.majorVersion == 4)
        let big = try #require(file.entries.first { $0.name == "Big" })
        #expect(try file.contents(of: big) == large)
        var hasher = DigestBuilder(.sha256)
        try MSIAuthenticode.hash(file.root, in: file, isRoot: true, into: &hasher)
        // A size with its top bit set does not fit an Int: it must be checked before it is converted.
        Self.patch(&data, at: Self.entryOffset(data, big.index, sectorSize: 4096) + 0x7C, 0x8000_0000)
        let changed = try CompoundFile(data: data)
        let claimed = try #require(changed.entries.first { $0.name == "Big" })
        #expect(claimed.size == 0x8000_0000_0000_0000 | UInt64(large.count))
        #expect(throws: CompoundFileError("Big claims \(claimed.size) bytes, more than the whole file")) {
            _ = try changed.contents(of: claimed)
        }
        #expect(throws: CompoundFileError.self) { try changed.forEachSlice(of: claimed) { _ in } }
    }

    @Test func aDIFATSectorPastTheEndIsRefused() throws {
        // Enough sectors for 110 FAT sectors to be plausible, then a DIFAT sector one past the file's end (the sector
        // a size rounded up to whole sectors would have).
        let builder = CompoundFileBuilder(root: CompoundFileBuilder.Node("Root Entry", type: 5, children: [
            .stream("Huge", Data(count: 110 * 512)),
        ]))
        var data = builder.build()
        let sectors = (data.count - 512) / 512
        #expect(sectors >= 110)
        Self.patch(&data, at: 0x2C, 110)              // FAT sectors: one more than the header lists
        Self.patch(&data, at: 0x44, UInt32(sectors))  // the first DIFAT sector: not in the file
        Self.patch(&data, at: 0x48, 1)
        #expect(throws: CompoundFileError("the DIFAT chain leaves the file")) { try CompoundFile(data: data) }
    }

    @Test func moreFATSectorsThanTheFileHoldsAreRefused() throws {
        // A DIFAT sector that names itself as the next one, and a FAT sector count of 4 billion: the DIFAT walk would
        // collect entries until memory runs out. A file cannot have more FAT (or DIFAT) sectors than sectors.
        var data = package().build()
        let sectors = (data.count - 512) / 512
        let last = sectors - 1
        Self.patch(&data, at: 512 + last * 512 + 508, UInt32(last))
        Self.patch(&data, at: 0x2C, 0xFFFF_FFFF)
        Self.patch(&data, at: 0x44, UInt32(last))
        Self.patch(&data, at: 0x48, 0xFFFF_FFFF)
        #expect(throws: CompoundFileError("the header lists more FAT sectors than the file has")) {
            try CompoundFile(data: data)
        }
        // A DIFAT count that is never needed (all FAT sectors are in the header) is not read at all.
        var unused = package().build()
        Self.patch(&unused, at: 0x44, UInt32(last))
        Self.patch(&unused, at: 0x48, 0xFFFF_FFFF)
        #expect(try CompoundFile(data: unused).root.name == "Root Entry")
    }

    @Test func aStreamClaimingMoreBytesThanTheFileIsRefusedBeforeAnythingIsAllocated() throws {
        var data = package().build()
        let file = try CompoundFile(data: data)
        let big = try #require(file.entries.first { $0.name == "Big" })
        Self.patch(&data, at: Self.entryOffset(data, big.index) + 0x78, 0xFFFF_FFF0)
        let changed = try CompoundFile(data: data)
        let claimed = try #require(changed.entries.first { $0.name == "Big" })
        #expect(claimed.size == 0xFFFF_FFF0)
        #expect(throws: CompoundFileError("Big claims 4294967280 bytes, more than the whole file")) {
            _ = try changed.contents(of: claimed)
        }
        #expect(throws: CompoundFileError("Big claims 4294967280 bytes, more than the whole file")) {
            try changed.forEachSlice(of: claimed) { _ in }
        }
    }

    /// A minimal Authenticode SignedData for the parser (its signature is never valid): the MSI SIP, a DigestInfo with
    /// `contentDigest` and one SignerInfo whose own digest algorithm is `signerDigest`.
    static func signedData(contentDigest: [UInt8], signerDigest: [UInt8]) -> [UInt8] {
        func oid(_ bytes: [UInt8]) -> [UInt8] { DEREncoder.element(0x06, bytes) }
        func sequence(_ parts: [UInt8]...) -> [UInt8] { DEREncoder.element(0x30, parts.flatMap { $0 }) }
        let one = DEREncoder.element(0x02, [1])
        let null: [UInt8] = [0x05, 0x00]
        let spcIndirectData: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04]
        let spcSIPInfo: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x1E]
        let signedDataOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        let rsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let indirect = sequence(
            sequence(oid(spcSIPInfo), sequence(one, DEREncoder.element(0x04, MSIAuthenticode.msiSIP))),
            sequence(sequence(oid(contentDigest), null), DEREncoder.element(0x04, [UInt8](repeating: 0, count: 32))))
        let encapsulated = sequence(oid(spcIndirectData), DEREncoder.element(0xA0, indirect))
        let signerInfo = sequence(one, sequence(), sequence(oid(signerDigest), null), sequence(oid(rsa), null),
                                  DEREncoder.element(0x04, [1, 2, 3]))
        let signed = sequence(one, DEREncoder.element(0x31, []), encapsulated, DEREncoder.element(0x31, signerInfo))
        return sequence(oid(signedDataOID), DEREncoder.element(0xA0, signed))
    }

    static let sha256OID: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
    static let sha1OID: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A]

    @Test func onlySHA256AndStrongerDigestsAreAcceptedForThePackageAndTheSigner() throws {
        let strong = try SignedPackage(Self.signedData(contentDigest: Self.sha256OID, signerDigest: Self.sha256OID))
        #expect(strong.digestAlgorithm == .sha256)
        #expect(strong.signatureValue == [1, 2, 3])
        // SHA-1 for the signer's own digest (messageDigest and the signed attributes): CMSDecoder would take it.
        #expect(throws: DERError.unsupported(digest: OID.sha1)) {
            try SignedPackage(Self.signedData(contentDigest: Self.sha256OID, signerDigest: Self.sha1OID))
        }
        // Through the verifier, either one is reported as an unaccepted digest, not as a malformed signature.
        for (content, signer) in [(Self.sha1OID, Self.sha256OID), (Self.sha256OID, Self.sha1OID)] {
            let builder = package(withSignatures: false)
            builder.root.children.append(.stream("\u{05}DigitalSignature",
                                                 Data(Self.signedData(contentDigest: content, signerDigest: signer))))
            #expect(throws: MSISignatureError.unsupportedDigest("SHA-1")) {
                try MSIAuthenticode.verify(builder.build(), expectedSigner: "Digital Extremes Ltd.")
            }
        }
    }

    @Test func storagesNestedTooDeeplyAreRefused() throws {
        // The digest walks storages recursively; a crafted package nesting thousands of them would overflow the stack
        // of the thread verifying it. Real packages nest one or two levels.
        func nested(_ depth: Int) -> CompoundFileBuilder.Node {
            var node = CompoundFileBuilder.Node.stream("Leaf", Data("leaf".utf8))
            for level in 0..<depth { node = .storage("S\(level)", clsid: Array(repeating: 0, count: 16), [node]) }
            return CompoundFileBuilder.Node("Root Entry", type: 5, children: [node])
        }
        let deep = CompoundFileBuilder(root: nested(CompoundFile.maximumStorageDepth + 1)).build()
        #expect(throws: CompoundFileError("storages are nested more than \(CompoundFile.maximumStorageDepth) deep")) {
            try CompoundFile(data: deep)
        }
        let file = try CompoundFile(data: CompoundFileBuilder(root: nested(CompoundFile.maximumStorageDepth)).build())
        var builder = DigestBuilder(.sha256)
        try MSIAuthenticode.hash(file.root, in: file, isRoot: true, into: &builder)
    }
}

/// DE's real installer, read-only, when `WARZAG_WARFRAME_MSI` names a downloaded Warframe.msi.
@Suite struct RealInstallerAuthenticodeTests {
    static let path = ProcessInfo.processInfo.environment["WARZAG_WARFRAME_MSI"] ?? ""
    static let present = !path.isEmpty && FileManager.default.fileExists(atPath: path)
    static let download = URL(filePath: path)
    static let signer = InstallerExpectations.signer

    static func mapped() throws -> Data { try Data(contentsOf: download, options: .alwaysMapped) }

    @Test(.enabled(if: present))
    func theDownloadedInstallerIsSignedByDigitalExtremes() throws {
        let signature = try MSIAuthenticode.verify(try Self.mapped(), expectedSigner: Self.signer)
        #expect(signature.signerCommonName == "Digital Extremes Ltd.")
        #expect(signature.signerOrganization == "Digital Extremes Ltd.")
        #expect(signature.digestAlgorithm == "SHA-256")
        #expect(signature.chain.first == "Digital Extremes Ltd.")
        #expect(signature.chain.last == "DigiCert Trusted Root G4")
    }

    @Test(.enabled(if: present))
    func itStaysValidAfterTheCertificateExpires() throws {
        // The signing timestamp keeps the signature valid after the certificate expires.
        let later = ISO8601DateFormatter().date(from: "2031-01-01T00:00:00Z")!
        #expect(try MSIAuthenticode.verify(try Self.mapped(), expectedSigner: Self.signer, now: later)
            .signerCommonName == Self.signer)
        // A clock before the timestamp is wrong (or the timestamp is): refused.
        let signed = try #require(try MSIAuthenticode.verify(try Self.mapped(), expectedSigner: Self.signer).timestamp)
        #expect(throws: MSISignatureError.badTimestamp("it lies in the future")) {
            try MSIAuthenticode.verify(try Self.mapped(), expectedSigner: Self.signer, now: signed - 86_400)
        }
    }

    @Test(.enabled(if: present))
    func anotherSignerOrAChangedByteIsRefused() throws {
        let package = try Data(contentsOf: Self.download)
        #expect(throws: MSISignatureError.wrongSigner("Digital Extremes Ltd.")) {
            try MSIAuthenticode.verify(package, expectedSigner: "Someone Else Ltd.")
        }
        let file = try CompoundFile(data: package)
        let children = file.children(of: file.root)
        // One byte of the largest stream (the installer's cabinet).
        let largest = try #require(children.filter { $0.type == .stream }.max { $0.size < $1.size })
        var offset = 0
        try file.forEachSlice(of: largest) { slice in if offset == 0 { offset = slice.startIndex + 1000 } }
        var changed = package
        changed[offset] ^= 0x01
        #expect(throws: MSISignatureError.contentChanged) {
            try MSIAuthenticode.verify(changed, expectedSigner: Self.signer)
        }
        // One byte of the signature value itself.
        let signatureStream = try #require(children.first { $0.rawName == MSIAuthenticode.digitalSignature })
        let blob = try file.contents(of: signatureStream)
        let value = try SignedPackage([UInt8](blob)).signatureValue
        let position = try #require(blob.range(of: Data(value)))
        var signatureOffset = 0
        var seen = 0
        try file.forEachSlice(of: signatureStream) { slice in
            if signatureOffset == 0, position.lowerBound + 10 < seen + slice.count {
                signatureOffset = slice.startIndex + (position.lowerBound + 10 - seen)
            }
            seen += slice.count
        }
        var forged = package
        forged[signatureOffset] ^= 0x01
        #expect(throws: MSISignatureError.self) { try MSIAuthenticode.verify(forged, expectedSigner: Self.signer) }
    }

    @Test(.enabled(if: present))
    func theNativeVerifierTrustsIt() async {
        #expect(await NativeAuthenticodeVerifier().verify(Self.download, expectedSigner: Self.signer)
            == .trusted(signer: Self.signer))
    }
}
