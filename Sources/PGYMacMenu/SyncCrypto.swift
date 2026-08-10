import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum SyncCryptoError: LocalizedError, Equatable {
    case passphraseTooShort
    case passphraseTooLong
    case fileTooLarge
    case unsupportedEnvelopeVersion(Int)
    case unsupportedKDF
    case invalidKDFParameters
    case invalidEnvelope
    case randomGenerationFailed(OSStatus)
    case keyDerivationFailed(Int32)
    case authenticationFailed
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .passphraseTooShort:
            return "同步口令至少需要 12 个字符"
        case .passphraseTooLong:
            return "同步口令不能超过 1024 个 UTF-8 字节"
        case .fileTooLarge:
            return "同步文件超过 5 MiB 上限"
        case .unsupportedEnvelopeVersion(let version):
            return "不支持的加密文件版本：\(version)"
        case .unsupportedKDF:
            return "不支持的密钥派生算法"
        case .invalidKDFParameters:
            return "同步文件的密钥派生参数无效"
        case .invalidEnvelope:
            return "同步文件格式无效或已损坏"
        case .randomGenerationFailed:
            return "无法生成加密所需的安全随机数"
        case .keyDerivationFailed:
            return "无法派生同步加密密钥"
        case .authenticationFailed:
            return "同步口令不正确，或远端文件已损坏"
        case .invalidDocument:
            return "解密后的同步数据格式无效"
        }
    }
}

public struct EncryptedEnvelope: Codable, Hashable, Sendable {
    public struct KDFParameters: Codable, Hashable, Sendable {
        public var algorithm: String
        public var iterations: UInt32
        public var keyLength: Int

        public init(algorithm: String, iterations: UInt32, keyLength: Int) {
            self.algorithm = algorithm
            self.iterations = iterations
            self.keyLength = keyLength
        }
    }

    public var version: Int
    public var kdf: KDFParameters
    public var salt: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data

    public init(
        version: Int,
        kdf: KDFParameters,
        salt: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.version = version
        self.kdf = kdf
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public enum SyncCrypto {
    public static let envelopeVersion = 1
    public static let kdfAlgorithm = "PBKDF2-HMAC-SHA256"
    public static let pbkdf2Iterations: UInt32 = 600_000
    public static let keyByteCount = 32
    public static let saltByteCount = 16
    public static let nonceByteCount = 12
    public static let tagByteCount = 16
    public static let minimumPassphraseLength = 12
    public static let maximumPassphraseByteCount = 1_024
    public static let maximumFileSize = 5 * 1_024 * 1_024

    /// Produces the complete JSON payload written to WebDAV.
    public static func encrypt(document: SyncDocument, passphrase: String) throws -> Data {
        let plaintext = try document.canonicalData()
        guard plaintext.count <= maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
        let envelope = try seal(plaintext, passphrase: passphrase)
        return try encode(envelope)
    }

    /// Opens, authenticates and validates a WebDAV payload. Authentication or
    /// decoding failures never return partial plaintext.
    public static func decryptDocument(from data: Data, passphrase: String) throws -> SyncDocument {
        let envelope = try decodeEnvelope(from: data)
        let plaintext = try open(envelope, passphrase: passphrase)
        guard plaintext.count <= maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }

        do {
            let document = try JSONDecoder().decode(SyncDocument.self, from: plaintext)
            return try document.normalized()
        } catch let error as SyncModelError {
            throw error
        } catch {
            throw SyncCryptoError.invalidDocument
        }
    }

    public static func seal(_ plaintext: Data, passphrase: String) throws -> EncryptedEnvelope {
        try seal(
            plaintext,
            passphrase: passphrase,
            salt: randomData(count: saltByteCount),
            nonce: randomData(count: nonceByteCount)
        )
    }

    public static func open(_ envelope: EncryptedEnvelope, passphrase: String) throws -> Data {
        try validate(passphrase: passphrase)
        try validate(envelope: envelope)

        let key = try deriveKey(
            passphrase: passphrase,
            salt: envelope.salt,
            iterations: envelope.kdf.iterations,
            keyLength: envelope.kdf.keyLength
        )

        do {
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SyncCryptoError.authenticationFailed
        }
    }

    public static func encode(_ envelope: EncryptedEnvelope) throws -> Data {
        try validate(envelope: envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw SyncCryptoError.invalidEnvelope
        }
        guard data.count <= maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
        return data
    }

    public static func decodeEnvelope(from data: Data) throws -> EncryptedEnvelope {
        guard data.count <= maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
        let envelope: EncryptedEnvelope
        do {
            envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: data)
        } catch {
            throw SyncCryptoError.invalidEnvelope
        }
        try validate(envelope: envelope)
        return envelope
    }

    public static func documentHash(_ document: SyncDocument) throws -> String {
        sha256Hex(try document.canonicalData())
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Internal deterministic entry point for test vectors. Production callers
    /// use `seal(_:passphrase:)`, which always generates a fresh salt and nonce.
    static func seal(
        _ plaintext: Data,
        passphrase: String,
        salt: Data,
        nonce: Data
    ) throws -> EncryptedEnvelope {
        try validate(passphrase: passphrase)
        guard plaintext.count <= maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
        guard salt.count == saltByteCount, nonce.count == nonceByteCount else {
            throw SyncCryptoError.invalidEnvelope
        }

        let key = try deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: pbkdf2Iterations,
            keyLength: keyByteCount
        )

        do {
            let aesNonce = try AES.GCM.Nonce(data: nonce)
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)
            return EncryptedEnvelope(
                version: envelopeVersion,
                kdf: .init(
                    algorithm: kdfAlgorithm,
                    iterations: pbkdf2Iterations,
                    keyLength: keyByteCount
                ),
                salt: salt,
                nonce: nonce,
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            )
        } catch {
            throw SyncCryptoError.invalidEnvelope
        }
    }

    /// Exposed internally so XCTest can verify PBKDF2 against independent
    /// published-style vectors without exporting key material from the module.
    static func deriveKeyData(
        passphrase: String,
        salt: Data,
        iterations: UInt32 = pbkdf2Iterations,
        keyLength: Int = keyByteCount
    ) throws -> Data {
        try validate(passphrase: passphrase)
        guard salt.count == saltByteCount,
              iterations == pbkdf2Iterations,
              keyLength == keyByteCount else {
            throw SyncCryptoError.invalidKDFParameters
        }

        let password = try normalizedPassphraseData(passphrase)
        var derived = Data(count: keyLength)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw SyncCryptoError.keyDerivationFailed(status)
        }
        return derived
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: UInt32,
        keyLength: Int
    ) throws -> SymmetricKey {
        SymmetricKey(data: try deriveKeyData(
            passphrase: passphrase,
            salt: salt,
            iterations: iterations,
            keyLength: keyLength
        ))
    }

    private static func validate(passphrase: String) throws {
        _ = try normalizedPassphraseData(passphrase)
    }

    private static func normalizedPassphraseData(_ passphrase: String) throws -> Data {
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        guard normalized.count >= minimumPassphraseLength else {
            throw SyncCryptoError.passphraseTooShort
        }
        let data = Data(normalized.utf8)
        guard data.count <= maximumPassphraseByteCount else {
            throw SyncCryptoError.passphraseTooLong
        }
        return data
    }

    private static func validate(envelope: EncryptedEnvelope) throws {
        guard envelope.version == envelopeVersion else {
            throw SyncCryptoError.unsupportedEnvelopeVersion(envelope.version)
        }
        guard envelope.kdf.algorithm == kdfAlgorithm else {
            throw SyncCryptoError.unsupportedKDF
        }
        guard envelope.kdf.iterations == pbkdf2Iterations,
              envelope.kdf.keyLength == keyByteCount,
              envelope.salt.count == saltByteCount,
              envelope.nonce.count == nonceByteCount,
              envelope.tag.count == tagByteCount else {
            throw SyncCryptoError.invalidKDFParameters
        }
        guard envelope.ciphertext.count <= maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SyncCryptoError.randomGenerationFailed(status)
        }
        return data
    }
}
