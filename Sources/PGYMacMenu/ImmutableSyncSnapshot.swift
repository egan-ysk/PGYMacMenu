import Foundation

public enum ImmutableSyncSnapshotError: LocalizedError, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case datasetMismatch
    case snapshotIdentityMismatch
    case snapshotCannotReferenceItself
    case genesisHasParent
    case objectMissingParent
    case invalidEncryptedPayloadHash
    case encryptedPayloadHashMismatch
    case invalidObjectFileName
    case invalidObjectRelativePath
    case invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let version):
            return "不支持的不可变同步快照版本：\(version)"
        case .datasetMismatch:
            return "不可变同步快照的数据集标识不一致"
        case .snapshotIdentityMismatch:
            return "不可变同步快照标识与预期不一致"
        case .snapshotCannotReferenceItself:
            return "不可变同步快照不能引用自身作为父快照"
        case .genesisHasParent:
            return "不可变同步仓库的起始快照不能包含父快照"
        case .objectMissingParent:
            return "不可变同步对象缺少父 carrier 引用"
        case .invalidEncryptedPayloadHash:
            return "不可变同步快照的密文哈希无效"
        case .encryptedPayloadHashMismatch:
            return "不可变同步快照的文件名与密文哈希不一致"
        case .invalidObjectFileName:
            return "不可变同步快照文件名无效"
        case .invalidObjectRelativePath:
            return "不可变同步快照相对路径无效"
        case .invalidSnapshot:
            return "解密后的不可变同步快照格式无效"
        }
    }
}

public enum ImmutableSyncCarrierKind: String, Codable, Hashable, Sendable {
    case genesis
    case object
}

/// Identifies the immutable remote carrier that a snapshot was based on.
/// The encrypted-payload hash binds both the AES-GCM envelope and its contents.
public struct ImmutableSyncCarrierReference: Codable, Hashable, Sendable {
    public let kind: ImmutableSyncCarrierKind
    public let snapshotID: UUID
    public let encryptedPayloadHash: String

    public init(
        kind: ImmutableSyncCarrierKind,
        snapshotID: UUID,
        encryptedPayloadHash: String
    ) throws {
        guard ImmutableSyncSnapshotLayout.isValidEncryptedPayloadHash(encryptedPayloadHash) else {
            throw ImmutableSyncSnapshotError.invalidEncryptedPayloadHash
        }
        self.kind = kind
        self.snapshotID = snapshotID
        self.encryptedPayloadHash = encryptedPayloadHash
    }

    public var relativePath: String {
        switch kind {
        case .genesis:
            return ImmutableSyncSnapshotLayout.genesisRelativePath
        case .object:
            return "\(encryptedPayloadHash).\(ImmutableSyncSnapshotLayout.objectFileExtension)"
        }
    }

    fileprivate func validated() throws -> ImmutableSyncCarrierReference {
        try ImmutableSyncCarrierReference(
            kind: kind,
            snapshotID: snapshotID,
            encryptedPayloadHash: encryptedPayloadHash
        )
    }
}

/// An encrypted, immutable, full-state synchronization snapshot.
///
/// Genesis has no parent. Every later snapshot points at the verified carrier
/// whose full document was used as the local merge base. The document remains
/// a complete `SyncDocument`, so independent branches can be merged record by
/// record without overwriting either carrier.
public struct ImmutableSyncSnapshot: Codable, Hashable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let datasetID: UUID
    public let snapshotID: UUID
    public let parent: ImmutableSyncCarrierReference?
    public let document: SyncDocument

    public init(
        protocolVersion: Int = ImmutableSyncSnapshot.currentProtocolVersion,
        datasetID: UUID,
        snapshotID: UUID = UUID(),
        parent: ImmutableSyncCarrierReference?,
        document: SyncDocument
    ) throws {
        self.protocolVersion = protocolVersion
        self.datasetID = datasetID
        self.snapshotID = snapshotID
        self.parent = parent
        self.document = document
        _ = try validated()
    }

    public static func genesis(
        snapshotID: UUID = UUID(),
        document: SyncDocument
    ) throws -> ImmutableSyncSnapshot {
        try ImmutableSyncSnapshot(
            datasetID: document.datasetID,
            snapshotID: snapshotID,
            parent: nil,
            document: document
        )
    }

    public static func successor(
        snapshotID: UUID = UUID(),
        parent: ImmutableSyncCarrierReference,
        document: SyncDocument
    ) throws -> ImmutableSyncSnapshot {
        try ImmutableSyncSnapshot(
            datasetID: document.datasetID,
            snapshotID: snapshotID,
            parent: parent,
            document: document
        )
    }

    public func validated(
        expectedDatasetID: UUID? = nil,
        expectedSnapshotID: UUID? = nil
    ) throws -> ImmutableSyncSnapshot {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ImmutableSyncSnapshotError.unsupportedProtocolVersion(protocolVersion)
        }
        guard datasetID == document.datasetID,
              expectedDatasetID.map({ $0 == datasetID }) ?? true else {
            throw ImmutableSyncSnapshotError.datasetMismatch
        }
        guard expectedSnapshotID.map({ $0 == snapshotID }) ?? true else {
            throw ImmutableSyncSnapshotError.snapshotIdentityMismatch
        }
        let parent = try parent?.validated()
        guard parent?.snapshotID != snapshotID else {
            throw ImmutableSyncSnapshotError.snapshotCannotReferenceItself
        }
        return ImmutableSyncSnapshot(
            uncheckedProtocolVersion: protocolVersion,
            datasetID: datasetID,
            snapshotID: snapshotID,
            parent: parent,
            document: try document.normalized()
        )
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(validated())
    }

    public func canonicalHash() throws -> String {
        SyncCrypto.sha256Hex(try canonicalData())
    }

    public func validatedAsGenesis() throws -> ImmutableSyncSnapshot {
        let snapshot = try validated()
        guard snapshot.parent == nil else {
            throw ImmutableSyncSnapshotError.genesisHasParent
        }
        return snapshot
    }

    public func validatedAsObject() throws -> ImmutableSyncSnapshot {
        let snapshot = try validated()
        guard snapshot.parent != nil else {
            throw ImmutableSyncSnapshotError.objectMissingParent
        }
        return snapshot
    }

    private init(
        uncheckedProtocolVersion: Int,
        datasetID: UUID,
        snapshotID: UUID,
        parent: ImmutableSyncCarrierReference?,
        document: SyncDocument
    ) {
        protocolVersion = uncheckedProtocolVersion
        self.datasetID = datasetID
        self.snapshotID = snapshotID
        self.parent = parent
        self.document = document
    }
}

public enum ImmutableSyncSnapshotLayout {
    public static let repositorySuffix = ".d"
    public static let genesisFileName = "genesis.pgy"
    public static let objectFileExtension = "pgy"

    public static var genesisRelativePath: String {
        genesisFileName
    }

    public static func repositoryRelativePath(forLegacyRelativePath relativePath: String) -> String {
        relativePath + repositorySuffix
    }

    public static func objectFileName(
        forEncryptedPayloadHash hash: String
    ) throws -> String {
        guard isValidEncryptedPayloadHash(hash) else {
            throw ImmutableSyncSnapshotError.invalidEncryptedPayloadHash
        }
        return "\(hash).\(objectFileExtension)"
    }

    /// Returns the content-addressed file path relative to the repository root.
    public static func objectRelativePath(
        forEncryptedPayloadHash hash: String
    ) throws -> String {
        try objectFileName(forEncryptedPayloadHash: hash)
    }

    public static func encryptedPayloadHash(
        fromObjectFileName fileName: String
    ) throws -> String {
        let suffix = ".\(objectFileExtension)"
        guard fileName.hasSuffix(suffix),
              fileName.utf8.count == 64 + suffix.utf8.count,
              !fileName.contains("/") else {
            throw ImmutableSyncSnapshotError.invalidObjectFileName
        }
        let hash = String(fileName.dropLast(suffix.count))
        guard isValidEncryptedPayloadHash(hash) else {
            throw ImmutableSyncSnapshotError.invalidObjectFileName
        }
        return hash
    }

    public static func encryptedPayloadHash(
        fromObjectRelativePath relativePath: String
    ) throws -> String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 1 else {
            throw ImmutableSyncSnapshotError.invalidObjectRelativePath
        }
        let hash: String
        do {
            hash = try encryptedPayloadHash(fromObjectFileName: String(components[0]))
        } catch {
            throw ImmutableSyncSnapshotError.invalidObjectRelativePath
        }
        return hash
    }

    public static func isValidEncryptedPayloadHash(_ hash: String) -> Bool {
        guard hash.utf8.count == 64 else { return false }
        return hash.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public struct ImmutableEncryptedSyncSnapshot: Equatable, Sendable {
    public let data: Data
    public let encryptedPayloadHash: String

    public init(data: Data) {
        self.data = data
        encryptedPayloadHash = SyncCrypto.sha256Hex(data)
    }

    public var objectFileName: String {
        "\(encryptedPayloadHash).\(ImmutableSyncSnapshotLayout.objectFileExtension)"
    }

    public var objectRelativePath: String {
        objectFileName
    }

    public func carrierReference(
        kind: ImmutableSyncCarrierKind,
        snapshotID: UUID
    ) throws -> ImmutableSyncCarrierReference {
        try ImmutableSyncCarrierReference(
            kind: kind,
            snapshotID: snapshotID,
            encryptedPayloadHash: encryptedPayloadHash
        )
    }
}

public enum ImmutableSyncSnapshotCrypto {
    public static func encrypt(
        _ snapshot: ImmutableSyncSnapshot,
        passphrase: String
    ) throws -> ImmutableEncryptedSyncSnapshot {
        let plaintext = try snapshot.canonicalData()
        guard plaintext.count <= SyncCrypto.maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
        let envelope = try SyncCrypto.seal(plaintext, passphrase: passphrase)
        return ImmutableEncryptedSyncSnapshot(data: try SyncCrypto.encode(envelope))
    }

    public static func decrypt(
        _ data: Data,
        passphrase: String,
        expectedEncryptedPayloadHash: String? = nil,
        expectedDatasetID: UUID? = nil,
        expectedSnapshotID: UUID? = nil
    ) throws -> ImmutableSyncSnapshot {
        if let expectedEncryptedPayloadHash {
            try verifyEncryptedPayloadHash(
                of: data,
                matches: expectedEncryptedPayloadHash
            )
        }
        let envelope = try SyncCrypto.decodeEnvelope(from: data)
        let plaintext = try SyncCrypto.open(envelope, passphrase: passphrase)
        guard plaintext.count <= SyncCrypto.maximumFileSize else {
            throw SyncCryptoError.fileTooLarge
        }
        let snapshot: ImmutableSyncSnapshot
        do {
            snapshot = try JSONDecoder().decode(ImmutableSyncSnapshot.self, from: plaintext)
        } catch {
            throw ImmutableSyncSnapshotError.invalidSnapshot
        }
        return try snapshot.validated(
            expectedDatasetID: expectedDatasetID,
            expectedSnapshotID: expectedSnapshotID
        )
    }

    public static func decryptObject(
        _ data: Data,
        fileName: String,
        passphrase: String,
        expectedDatasetID: UUID? = nil
    ) throws -> ImmutableSyncSnapshot {
        let expectedHash = try ImmutableSyncSnapshotLayout.encryptedPayloadHash(
            fromObjectFileName: fileName
        )
        return try decrypt(
            data,
            passphrase: passphrase,
            expectedEncryptedPayloadHash: expectedHash,
            expectedDatasetID: expectedDatasetID
        ).validatedAsObject()
    }

    public static func decryptGenesis(
        _ data: Data,
        passphrase: String,
        expectedEncryptedPayloadHash: String? = nil,
        expectedDatasetID: UUID? = nil,
        expectedSnapshotID: UUID? = nil
    ) throws -> ImmutableSyncSnapshot {
        try decrypt(
            data,
            passphrase: passphrase,
            expectedEncryptedPayloadHash: expectedEncryptedPayloadHash,
            expectedDatasetID: expectedDatasetID,
            expectedSnapshotID: expectedSnapshotID
        ).validatedAsGenesis()
    }

    public static func verifyEncryptedPayloadHash(
        of data: Data,
        matches expectedHash: String
    ) throws {
        guard ImmutableSyncSnapshotLayout.isValidEncryptedPayloadHash(expectedHash) else {
            throw ImmutableSyncSnapshotError.invalidEncryptedPayloadHash
        }
        guard SyncCrypto.sha256Hex(data) == expectedHash else {
            throw ImmutableSyncSnapshotError.encryptedPayloadHashMismatch
        }
    }
}
