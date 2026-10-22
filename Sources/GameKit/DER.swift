import Foundation

/// A malformed or unexpected DER structure.
public struct DERError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    /// Set when the structure is fine but names a digest algorithm that is not accepted ("SHA-1", or its OID).
    var unsupportedDigest: String?
    public var description: String { "malformed signature data: \(reason)" }

    init(_ reason: String) {
        self.reason = reason
    }

    /// A digest algorithm Warzag does not accept (anything below SHA-256).
    static func unsupported(digest oid: String) -> DERError {
        let name = oid == OID.sha1 ? "SHA-1" : "digest \(oid)"
        var error = DERError(name)
        error.unsupportedDigest = name
        return error
    }
}

/// One DER element (tag, length, value) inside a byte buffer, read without copying. Only what Authenticode needs:
/// single-byte tags, definite lengths up to four length bytes.
struct DERNode: Sendable, Equatable {
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let null: UInt8 = 0x05
    static let generalizedTime: UInt8 = 0x18
    static let utcTime: UInt8 = 0x17

    let bytes: [UInt8]
    let tag: UInt8
    /// Offset of the tag byte.
    let start: Int
    let valueStart: Int
    let end: Int

    /// The element at `offset` of `bytes`, which must end no later than `limit`.
    init(_ bytes: [UInt8], at offset: Int = 0, limit: Int? = nil) throws(DERError) {
        let limit = limit ?? bytes.count
        guard offset + 2 <= limit else { throw DERError("truncated element at \(offset)") }
        self.bytes = bytes
        tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { throw DERError("multi-byte tag at \(offset)") }
        var index = offset + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), index + count <= limit else { throw DERError("bad length at \(offset)") }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard index + length <= limit else { throw DERError("element at \(offset) runs past its parent") }
        start = offset
        valueStart = index
        end = index + length
    }

    var isConstructed: Bool { tag & 0x20 != 0 }
    var value: ArraySlice<UInt8> { bytes[valueStart..<end] }
    /// The whole element, tag and length included.
    var encoded: ArraySlice<UInt8> { bytes[start..<end] }

    /// The elements inside a constructed element.
    func children() throws(DERError) -> [DERNode] {
        guard isConstructed else { throw DERError("element at \(start) is not constructed") }
        var result: [DERNode] = []
        var offset = valueStart
        while offset < end {
            let child = try DERNode(bytes, at: offset, limit: end)
            result.append(child)
            offset = child.end
        }
        return result
    }

    /// The child at `index`, which must have `tag` when given.
    func child(_ index: Int, tag expected: UInt8? = nil) throws(DERError) -> DERNode {
        let all = try children()
        guard index < all.count else { throw DERError("element at \(start) has no child \(index)") }
        let node = all[index]
        if let expected, node.tag != expected {
            throw DERError(String(format: "expected tag %02x at %d, found %02x", expected, node.start, node.tag))
        }
        return node
    }

    func expect(_ expected: UInt8) throws(DERError) -> DERNode {
        guard tag == expected else {
            throw DERError(String(format: "expected tag %02x at %d, found %02x", expected, start, tag))
        }
        return self
    }

    /// An OBJECT IDENTIFIER in dotted form.
    func objectIdentifier() throws(DERError) -> String {
        _ = try expect(Self.objectIdentifier)
        let value = Array(value)
        guard let first = value.first else { throw DERError("empty object identifier") }
        var parts = [first < 80 ? Int(first) / 40 : 2, first < 80 ? Int(first) % 40 : Int(first) - 80]
        var current = 0
        for byte in value.dropFirst() {
            current = current << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(current)
                current = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// A GeneralizedTime (`YYYYMMDDhhmmssZ`, optionally with fractional seconds) or UTCTime.
    func time() throws(DERError) -> Date {
        let text = String(decoding: value, as: UTF8.self)
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        let digits = Array(text)
        func number(_ range: Range<Int>) throws(DERError) -> Int {
            guard range.upperBound <= digits.count, let value = Int(String(digits[range])) else {
                throw DERError("bad time \(text)")
            }
            return value
        }
        let base: Int
        switch tag {
        case Self.generalizedTime:
            components.year = try number(0..<4)
            base = 4
        case Self.utcTime:
            let year = try number(0..<2)
            components.year = year < 50 ? 2000 + year : 1900 + year
            base = 2
        default:
            throw DERError("expected a time at \(start)")
        }
        components.month = try number(base..<(base + 2))
        components.day = try number((base + 2)..<(base + 4))
        components.hour = try number((base + 4)..<(base + 6))
        components.minute = try number((base + 6)..<(base + 8))
        components.second = try number((base + 8)..<(base + 10))
        guard text.hasSuffix("Z"), let date = Calendar(identifier: .gregorian).date(from: components) else {
            throw DERError("bad time \(text)")
        }
        return date
    }
}

/// Builds DER elements.
enum DEREncoder {
    static func length(_ count: Int) -> [UInt8] {
        guard count >= 0x80 else { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func element<Value: Collection<UInt8>>(_ tag: UInt8, _ value: Value) -> [UInt8] {
        [tag] + length(value.count) + Array(value)
    }
}

/// Object identifiers Authenticode uses.
enum OID {
    static let signedData = "1.2.840.113549.1.7.2"
    static let spcIndirectData = "1.3.6.1.4.1.311.2.1.4"
    static let spcSIPInfo = "1.3.6.1.4.1.311.2.1.30"
    static let rfc3161Timestamp = "1.3.6.1.4.1.311.3.3.1"
    static let tstInfo = "1.2.840.113549.1.9.16.1.4"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let sha384 = "2.16.840.1.101.3.4.2.2"
    static let sha512 = "2.16.840.1.101.3.4.2.3"
    static let sha1 = "1.3.14.3.2.26"
    static let extendedKeyUsage = "2.5.29.37"
    static let codeSigning = "1.3.6.1.5.5.7.3.3"
    static let timeStamping = "1.3.6.1.5.5.7.3.8"
    static let organizationName = "2.5.4.10"
    static let commonName = "2.5.4.3"
}
