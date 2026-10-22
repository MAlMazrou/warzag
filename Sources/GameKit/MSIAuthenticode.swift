import CryptoKit
import Foundation
import Security

/// What a verified Authenticode signature of a Windows Installer package says.
public struct MSISignature: Sendable, Equatable {
    /// The leaf certificate's subject CN and O.
    public var signerCommonName: String
    public var signerOrganization: String?
    /// "SHA-256", "SHA-384" or "SHA-512".
    public var digestAlgorithm: String
    /// The package digest the signature covers (hex), recomputed from the package and found equal.
    public var digest: String
    /// When a timestamp authority countersigned it (RFC 3161); the certificate chain is checked at this time.
    public var timestamp: Date?
    /// Subject summaries from the leaf to the anchor.
    public var chain: [String]
}

public enum MSISignatureError: Error, Equatable, CustomStringConvertible {
    case notAPackage(String)
    case unsigned
    case malformed(String)
    case unsupportedDigest(String)
    /// `\u{05}MsiDigitalSignatureEx` (the hash of the package's directory metadata) does not match the package.
    case metadataChanged
    /// The package's contents are not what was signed.
    case contentChanged
    case badSignature(String)
    case untrusted(String)
    case wrongSigner(String)
    case notForCodeSigning
    case badTimestamp(String)

    public var description: String {
        switch self {
        case .notAPackage(let reason): "not a Windows Installer package (\(reason))"
        case .unsigned: "the package carries no Authenticode signature"
        case .malformed(let reason): "the signature is malformed (\(reason))"
        case .unsupportedDigest(let name): "the signature uses \(name), which is not accepted"
        case .metadataChanged: "the package's directory metadata was changed after signing"
        case .contentChanged: "the package was changed after it was signed (digest mismatch)"
        case .badSignature(let reason): "the signature does not verify (\(reason))"
        case .untrusted(let reason): "the signing certificate is not trusted (\(reason))"
        case .wrongSigner(let name): "signed by \(name)"
        case .notForCodeSigning: "the signing certificate is not for code signing"
        case .badTimestamp(let reason): "the timestamp does not verify (\(reason))"
        }
    }
}

/// Authenticode for Windows Installer packages with CryptoKit and the Security framework, against the system's trust
/// store and without the network, so revocation is not checked. Only SHA-256 and stronger digests are accepted.
///
/// The package digest is computed as signtool and osslsigncode compute it (osslsigncode's msi.c) and must equal the
/// one in the signed `SpcIndirectDataContent`. `CMSDecoder` does not take Authenticode's PKCS#7 as it is: the content
/// is a bare SEQUENCE where CMS has an OCTET STRING, and the RFC 3161 countersignature is an unsigned attribute it
/// does not know. The signature covers neither, so the SignedData is re-encoded with the content detached and the
/// unsigned attributes left out. The chain is evaluated at the timestamp's time, as signing certificates expire long
/// before the packages they signed; the leaf must allow code signing and carry the expected CN.
public enum MSIAuthenticode {
    static let digitalSignature = utf16Name("\u{05}DigitalSignature")
    static let digitalSignatureEx = utf16Name("\u{05}MsiDigitalSignatureEx")
    static let rootEntry = utf16Name("Root Entry")
    /// SpcSipInfo's GUID for MSI packages, {000C10F1-0000-0000-C000-000000000046} in its stored byte order.
    static let msiSIP: [UInt8] = [0xF1, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00,
                                  0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]

    /// A name as directory entries store it: UTF-16LE with the terminating NUL.
    static func utf16Name(_ name: String) -> [UInt8] {
        name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
    }

    /// Verifies `package` (the whole .msi; a memory-mapped `Data` is fine) and returns what the signature says.
    public static func verify(_ package: Data, expectedSigner: String, now: Date = Date()) throws(MSISignatureError)
        -> MSISignature {
        let file: CompoundFile
        do {
            file = try CompoundFile(data: package)
        } catch {
            throw .notAPackage(error.reason)
        }
        let rootChildren = file.children(of: file.root)
        guard let signatureStream = rootChildren.first(where: { $0.rawName == digitalSignature && $0.type == .stream })
        else { throw .unsigned }
        let blob: [UInt8]
        do {
            blob = [UInt8](try file.contents(of: signatureStream))
        } catch {
            throw .malformed("\(error)")
        }
        let parsed: SignedPackage
        do {
            parsed = try SignedPackage(blob)
        } catch {
            throw error.unsupportedDigest.map(MSISignatureError.unsupportedDigest) ?? .malformed(error.reason)
        }

        let algorithm = parsed.digestAlgorithm
        var hasher = DigestBuilder(algorithm)
        do {
            if let ex = rootChildren.first(where: { $0.rawName == digitalSignatureEx && $0.type == .stream }) {
                var prehash = DigestBuilder(algorithm)
                try Self.prehash(file.root, in: file, isRoot: true, into: &prehash)
                let computed = prehash.finalize()
                guard try [UInt8](file.contents(of: ex)) == computed else { throw MSISignatureError.metadataChanged }
                hasher.update(computed)
            }
            try Self.hash(file.root, in: file, isRoot: true, into: &hasher)
        } catch let error as MSISignatureError {
            throw error
        } catch {
            throw .notAPackage("\(error)")
        }
        let digest = hasher.finalize()
        guard digest == parsed.signedDigest else { throw .contentChanged }

        let (signer, trust) = try verifySignedData(parsed.detachedSignedData, detachedContent: parsed.indirectDataContent)

        var timestamp: Date?
        if let token = parsed.timestampToken {
            timestamp = try verifyTimestamp(token, imprintOf: parsed.signatureValue, now: now)
        }

        let chain = try evaluate(trust, at: timestamp ?? now, what: "signing certificate")
        let subject: CertificateSubject
        do {
            subject = try CertificateSubject(signer)
        } catch {
            throw .malformed(error.reason)
        }
        guard subject.extendedKeyUsages.contains(OID.codeSigning) else { throw .notForCodeSigning }
        guard subject.commonName == expectedSigner else {
            throw .wrongSigner(subject.commonName ?? "an unnamed signer")
        }
        return MSISignature(signerCommonName: expectedSigner, signerOrganization: subject.organization,
                            digestAlgorithm: algorithm.name, digest: digest.map { String(format: "%02x", $0) }.joined(),
                            timestamp: timestamp, chain: chain)
    }

    // MARK: Digest

    /// Children in the order Microsoft's MSI digest visits them: raw names compared byte-wise over the shorter
    /// length (names include their NUL), the longer one last on a tie.
    static func digestOrder(_ entries: [CompoundFile.Entry]) -> [CompoundFile.Entry] {
        entries.sorted { lhs, rhs in
            let count = min(lhs.rawName.count, rhs.rawName.count)
            for index in 0..<count where lhs.rawName[index] != rhs.rawName[index] {
                return lhs.rawName[index] < rhs.rawName[index]
            }
            return lhs.rawName.count < rhs.rawName.count
        }
    }

    static func isSignatureStream(_ entry: CompoundFile.Entry) -> Bool {
        entry.rawName == digitalSignature || entry.rawName == digitalSignatureEx
    }

    static func hash(_ storage: CompoundFile.Entry, in file: CompoundFile, isRoot: Bool,
                     into hasher: inout DigestBuilder) throws {
        for child in digestOrder(file.children(of: storage)) where !(isRoot && isSignatureStream(child)) {
            switch child.type {
            case .stream:
                try file.forEachSlice(of: child) { hasher.update($0) }
            case .storage:
                try hash(child, in: file, isRoot: false, into: &hasher)
            case .root:
                throw CompoundFileError("the root entry appears inside a storage")
            }
        }
        hasher.update(storage.clsid)
    }

    static func prehash(_ storage: CompoundFile.Entry, in file: CompoundFile, isRoot: Bool,
                        into hasher: inout DigestBuilder) throws {
        metadata(storage, into: &hasher)
        for child in digestOrder(file.children(of: storage)) where !(isRoot && isSignatureStream(child)) {
            switch child.type {
            case .stream: metadata(child, into: &hasher)
            case .storage: try prehash(child, in: file, isRoot: false, into: &hasher)
            case .root: throw CompoundFileError("the root entry appears inside a storage")
            }
        }
    }

    static func metadata(_ entry: CompoundFile.Entry, into hasher: inout DigestBuilder) {
        if entry.rawName != rootEntry { hasher.update(entry.rawName.dropLast(2)) }
        if entry.type == .stream {
            hasher.update(entry.rawSize.prefix(4))
        } else {
            hasher.update(entry.clsid)
        }
        hasher.update(entry.stateBits)
        if entry.type != .root {
            hasher.update(entry.creationTime)
            hasher.update(entry.modifiedTime)
        }
    }

    // MARK: Signatures

    /// Runs `CMSDecoder` over a SignedData and returns the (single) signer's certificate and trust object, which is
    /// not evaluated yet.
    static func verifySignedData(_ signedData: [UInt8], detachedContent: [UInt8]?) throws(MSISignatureError)
        -> (SecCertificate, SecTrust) {
        var created: CMSDecoder?
        guard CMSDecoderCreate(&created) == errSecSuccess, let decoder = created else {
            throw .badSignature("CMSDecoderCreate failed")
        }
        let update = signedData.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard update == errSecSuccess else { throw .badSignature("the decoder refused the message (\(update))") }
        if let detachedContent {
            let status = CMSDecoderSetDetachedContent(decoder, Data(detachedContent) as CFData)
            guard status == errSecSuccess else { throw .badSignature("detached content refused (\(status))") }
        }
        let finalize = CMSDecoderFinalizeMessage(decoder)
        guard finalize == errSecSuccess else { throw .badSignature("the decoder could not finish (\(finalize))") }
        var signers = 0
        guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers == 1 else {
            throw .badSignature("\(signers) signers instead of one")
        }
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var certificateResult: OSStatus = 0
        let copy = CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trust,
                                              &certificateResult)
        guard copy == errSecSuccess, status == .valid else {
            throw .badSignature("signer status \(status.rawValue)")
        }
        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess, let certificate, let trust else {
            throw .badSignature("no signer certificate")
        }
        return (certificate, trust)
    }

    /// Verifies an RFC 3161 timestamp token over `signatureValue` and returns its time. `CMSDecoder` hashes only
    /// id-data content itself, so the token's TSTInfo bytes also go in as detached content, and the imprint and the
    /// time are read from those same bytes.
    static func verifyTimestamp(_ token: [UInt8], imprintOf signatureValue: [UInt8],
                                now: Date) throws(MSISignatureError) -> Date {
        let tstInfo: [UInt8]
        do throws(DERError) {
            let signedData = try DERNode(token).expect(DERNode.sequence).child(1, tag: 0xA0)
                .child(0, tag: DERNode.sequence)
            let encapsulated = try signedData.child(2, tag: DERNode.sequence)
            guard try encapsulated.child(0).objectIdentifier() == OID.tstInfo else { throw DERError("not a TSTInfo") }
            tstInfo = Array(try encapsulated.child(1, tag: 0xA0).child(0, tag: DERNode.octetString).value)
        } catch {
            throw .badTimestamp(error.reason)
        }
        var created: CMSDecoder?
        guard CMSDecoderCreate(&created) == errSecSuccess, let decoder = created else {
            throw .badTimestamp("CMSDecoderCreate failed")
        }
        let update = token.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard update == errSecSuccess,
              CMSDecoderSetDetachedContent(decoder, Data(tstInfo) as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw .badTimestamp("the decoder refused the token (\(update))")
        }
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var certificateResult: OSStatus = 0
        guard CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trust,
                                         &certificateResult) == errSecSuccess, status == .valid, let trust else {
            throw .badTimestamp("signer status \(status.rawValue)")
        }
        let info: TimestampInfo
        do {
            info = try TimestampInfo(tstInfo)
        } catch {
            throw .badTimestamp(error.reason)
        }
        guard let algorithm = DigestAlgorithm(oid: info.imprintAlgorithm) else {
            throw .badTimestamp("imprint algorithm \(info.imprintAlgorithm)")
        }
        var imprint = DigestBuilder(algorithm)
        imprint.update(signatureValue)
        guard imprint.finalize() == info.imprint else { throw .badTimestamp("it is for another signature") }
        guard info.time <= now.addingTimeInterval(300) else { throw .badTimestamp("it lies in the future") }
        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess, let certificate else {
            throw .badTimestamp("no signer certificate")
        }
        let subject: CertificateSubject
        do {
            subject = try CertificateSubject(certificate)
        } catch {
            throw .badTimestamp(error.reason)
        }
        guard subject.extendedKeyUsages.contains(OID.timeStamping) else {
            throw .badTimestamp("its certificate is not for time stamping")
        }
        do {
            _ = try evaluate(trust, at: info.time, what: "timestamp certificate")
        } catch {
            throw .badTimestamp(error.description)
        }
        return info.time
    }

    /// Evaluates `trust` against the system's anchors at `date`, without the network. Returns the chain's subjects.
    static func evaluate(_ trust: SecTrust, at date: Date, what: String) throws(MSISignatureError) -> [String] {
        SecTrustSetVerifyDate(trust, date as CFDate)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw .untrusted("\(what): \(error.map { CFErrorCopyDescription($0) as String } ?? "rejected")")
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return chain.map { SecCertificateCopySubjectSummary($0) as String? ?? "?" }
    }
}

// MARK: - Digests

enum DigestAlgorithm: Sendable, Equatable {
    case sha256, sha384, sha512

    init?(oid: String) {
        switch oid {
        case OID.sha256: self = .sha256
        case OID.sha384: self = .sha384
        case OID.sha512: self = .sha512
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .sha256: "SHA-256"
        case .sha384: "SHA-384"
        case .sha512: "SHA-512"
        }
    }
}

/// An incremental hash of one of the accepted algorithms.
struct DigestBuilder {
    private var sha256: SHA256?
    private var sha384: SHA384?
    private var sha512: SHA512?

    init(_ algorithm: DigestAlgorithm) {
        switch algorithm {
        case .sha256: sha256 = SHA256()
        case .sha384: sha384 = SHA384()
        case .sha512: sha512 = SHA512()
        }
    }

    mutating func update<Bytes: DataProtocol>(_ bytes: Bytes) {
        for region in bytes.regions {
            region.withUnsafeBytes { buffer in
                sha256?.update(bufferPointer: buffer)
                sha384?.update(bufferPointer: buffer)
                sha512?.update(bufferPointer: buffer)
            }
        }
    }

    func finalize() -> [UInt8] {
        if let sha256 { return Array(sha256.finalize()) }
        if let sha384 { return Array(sha384.finalize()) }
        return Array(sha512!.finalize())
    }
}

// MARK: - Structures

/// The parts of the package's PKCS#7 SignedData the verification needs.
struct SignedPackage {
    let digestAlgorithm: DigestAlgorithm
    /// The package digest inside the signed SpcIndirectDataContent.
    let signedDigest: [UInt8]
    /// The SpcIndirectDataContent's value bytes: what Authenticode's messageDigest attribute is the hash of.
    let indirectDataContent: [UInt8]
    /// The SignedData re-encoded with the content detached and without unsigned attributes, for `CMSDecoder`.
    let detachedSignedData: [UInt8]
    /// The signer's signature value (what a timestamp's message imprint is the hash of).
    let signatureValue: [UInt8]
    /// The RFC 3161 timestamp token (a ContentInfo), if any.
    let timestampToken: [UInt8]?

    init(_ blob: [UInt8]) throws(DERError) {
        let contentInfo = try DERNode(blob).expect(DERNode.sequence)
        guard try contentInfo.child(0).objectIdentifier() == OID.signedData else { throw DERError("not a SignedData") }
        let signedData = try contentInfo.child(1, tag: 0xA0).child(0, tag: DERNode.sequence)
        let parts = try signedData.children()
        guard parts.count >= 4 else { throw DERError("SignedData is too short") }
        let encapsulated = try parts[2].expect(DERNode.sequence)
        guard try encapsulated.child(0).objectIdentifier() == OID.spcIndirectData else {
            throw DERError("the signed content is not SpcIndirectDataContent")
        }
        let indirect = try encapsulated.child(1, tag: 0xA0).child(0, tag: DERNode.sequence)
        indirectDataContent = Array(indirect.value)

        // SpcIndirectDataContent: data (the SIP, MSI's), messageDigest (DigestInfo).
        let sip = try indirect.child(0, tag: DERNode.sequence)
        guard try sip.child(0).objectIdentifier() == OID.spcSIPInfo else { throw DERError("no SpcSipInfo") }
        let sipInfo = try sip.child(1, tag: DERNode.sequence)
        guard Array(try sipInfo.child(1, tag: DERNode.octetString).value) == MSIAuthenticode.msiSIP else {
            throw DERError("the signature is not for a Windows Installer package")
        }
        let digestInfo = try indirect.child(1, tag: DERNode.sequence)
        let digestOID = try digestInfo.child(0, tag: DERNode.sequence).child(0).objectIdentifier()
        guard let algorithm = DigestAlgorithm(oid: digestOID) else { throw DERError.unsupported(digest: digestOID) }
        digestAlgorithm = algorithm
        signedDigest = Array(try digestInfo.child(1, tag: DERNode.octetString).value)

        let signerInfos = try parts[parts.count - 1].expect(DERNode.set).children()
        guard signerInfos.count == 1 else { throw DERError("\(signerInfos.count) signers") }
        let signerInfo = try signerInfos[0].expect(DERNode.sequence)
        let signerParts = try signerInfo.children()
        // SignerInfo: version, sid, digestAlgorithm, ... The signer's own digest is held to the same standard as the
        // package digest: CMSDecoder would accept SHA-1 there.
        guard signerParts.count > 2 else { throw DERError("the SignerInfo is too short") }
        let signerDigestOID = try signerParts[2].expect(DERNode.sequence).child(0).objectIdentifier()
        guard DigestAlgorithm(oid: signerDigestOID) != nil else { throw DERError.unsupported(digest: signerDigestOID) }
        guard let value = signerParts.first(where: { $0.tag == DERNode.octetString }) else {
            throw DERError("no signature value")
        }
        signatureValue = Array(value.value)
        var token: [UInt8]?
        if let unsigned = signerParts.first(where: { $0.tag == 0xA1 }) {
            for attribute in try unsigned.children() {
                let attribute = try attribute.expect(DERNode.sequence)
                if try attribute.child(0).objectIdentifier() == OID.rfc3161Timestamp {
                    token = Array(try attribute.child(1, tag: DERNode.set).child(0, tag: DERNode.sequence).encoded)
                }
            }
        }
        timestampToken = token

        // The same SignedData with the content detached and the unsigned attributes gone.
        var signerInfoValue: [UInt8] = []
        for part in signerParts where part.tag != 0xA1 { signerInfoValue += part.encoded }
        var signedDataValue: [UInt8] = []
        for (index, part) in parts.enumerated() {
            if index == 2 {
                signedDataValue += DEREncoder.element(DERNode.sequence, try encapsulated.child(0).encoded)
            } else if index == parts.count - 1 {
                signedDataValue += DEREncoder.element(DERNode.set, DEREncoder.element(DERNode.sequence, signerInfoValue))
            } else {
                signedDataValue += part.encoded
            }
        }
        detachedSignedData = DEREncoder.element(DERNode.sequence, Array(try contentInfo.child(0).encoded)
            + DEREncoder.element(0xA0, DEREncoder.element(DERNode.sequence, signedDataValue)))
    }
}

/// An RFC 3161 TSTInfo: what was timestamped and when.
struct TimestampInfo {
    let imprintAlgorithm: String
    let imprint: [UInt8]
    let time: Date

    init(_ bytes: [UInt8]) throws(DERError) {
        let info = try DERNode(bytes).expect(DERNode.sequence)
        let imprint = try info.child(2, tag: DERNode.sequence)
        imprintAlgorithm = try imprint.child(0, tag: DERNode.sequence).child(0).objectIdentifier()
        self.imprint = Array(try imprint.child(1, tag: DERNode.octetString).value)
        time = try info.child(4, tag: DERNode.generalizedTime).time()
    }
}

/// The subject names and extended key usages of a certificate.
struct CertificateSubject {
    var commonName: String?
    var organization: String?
    var extendedKeyUsages: Set<String> = []

    init(_ certificate: SecCertificate) throws(DERError) {
        let bytes = [UInt8](SecCertificateCopyData(certificate) as Data)
        let tbs = try DERNode(bytes).expect(DERNode.sequence).child(0, tag: DERNode.sequence)
        let fields = try tbs.children()
        // [0] version, serial, signature algorithm, issuer, validity, subject, key, then optional [1] [2] [3].
        let offset = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count > offset + 5 else { throw DERError("certificate is too short") }
        for set in try fields[offset + 4].expect(DERNode.sequence).children() {
            for attribute in try set.children() {
                let oid = try attribute.child(0).objectIdentifier()
                let text = String(decoding: try attribute.child(1).value, as: UTF8.self)
                if oid == OID.commonName, commonName == nil { commonName = text }
                if oid == OID.organizationName, organization == nil { organization = text }
            }
        }
        if let extensions = fields.first(where: { $0.tag == 0xA3 }) {
            for extensionNode in try extensions.child(0, tag: DERNode.sequence).children() {
                let parts = try extensionNode.children()
                guard let first = parts.first, try first.objectIdentifier() == OID.extendedKeyUsage,
                      let value = parts.last, value.tag == DERNode.octetString else { continue }
                let usages = try DERNode(Array(value.value)).expect(DERNode.sequence).children()
                for usage in usages { extendedKeyUsages.insert(try usage.objectIdentifier()) }
            }
        }
    }
}
