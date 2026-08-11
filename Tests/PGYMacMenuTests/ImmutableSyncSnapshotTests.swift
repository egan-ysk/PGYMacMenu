import Foundation
import XCTest
@testable import PGYMacMenu

final class ImmutableSyncSnapshotTests: XCTestCase {
    private let passphrase = "immutable passphrase"
    private let datasetID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let genesisID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let successorID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testGenesisRoundTripIsCanonicalAndContainsNoPlaintextSecret() throws {
        let document = document(secret: "PRIVATE-API-KEY")
        let snapshot = try ImmutableSyncSnapshot.genesis(
            snapshotID: genesisID,
            document: document
        )

        let encrypted = try ImmutableSyncSnapshotCrypto.encrypt(snapshot, passphrase: passphrase)
        let decrypted = try ImmutableSyncSnapshotCrypto.decryptGenesis(
            encrypted.data,
            passphrase: passphrase,
            expectedEncryptedPayloadHash: encrypted.encryptedPayloadHash,
            expectedDatasetID: datasetID,
            expectedSnapshotID: genesisID
        )

        XCTAssertNil(snapshot.parent)
        XCTAssertEqual(decrypted, try snapshot.validated())
        XCTAssertEqual(try decrypted.canonicalData(), try snapshot.canonicalData())
        XCTAssertNil(String(data: encrypted.data, encoding: .utf8)?.range(of: "PRIVATE-API-KEY"))
    }

    func testSuccessorCarriesVerifiedGenesisReference() throws {
        let genesis = try ImmutableSyncSnapshot.genesis(
            snapshotID: genesisID,
            document: document()
        )
        let encryptedGenesis = try ImmutableSyncSnapshotCrypto.encrypt(genesis, passphrase: passphrase)
        let parent = try encryptedGenesis.carrierReference(kind: .genesis, snapshotID: genesisID)
        let successor = try ImmutableSyncSnapshot.successor(
            snapshotID: successorID,
            parent: parent,
            document: document(generation: 2)
        )

        XCTAssertEqual(successor.parent, parent)
        XCTAssertEqual(parent.relativePath, "genesis.pgy")

        let encrypted = try ImmutableSyncSnapshotCrypto.encrypt(successor, passphrase: passphrase)
        let decrypted = try ImmutableSyncSnapshotCrypto.decryptObject(
            encrypted.data,
            fileName: encrypted.objectFileName,
            passphrase: passphrase,
            expectedDatasetID: datasetID
        )
        XCTAssertEqual(decrypted, successor)
    }

    func testContentAddressedFileAndFlatPathRoundTrip() throws {
        let encrypted = try ImmutableSyncSnapshotCrypto.encrypt(
            .genesis(snapshotID: genesisID, document: document()),
            passphrase: passphrase
        )
        let hash = encrypted.encryptedPayloadHash

        XCTAssertEqual(encrypted.objectFileName, "\(hash).pgy")
        XCTAssertEqual(encrypted.objectRelativePath, "\(hash).pgy")
        XCTAssertEqual(
            try ImmutableSyncSnapshotLayout.encryptedPayloadHash(
                fromObjectFileName: encrypted.objectFileName
            ),
            hash
        )
        XCTAssertEqual(
            try ImmutableSyncSnapshotLayout.encryptedPayloadHash(
                fromObjectRelativePath: encrypted.objectRelativePath
            ),
            hash
        )
        XCTAssertEqual(
            ImmutableSyncSnapshotLayout.repositoryRelativePath(
                forLegacyRelativePath: "folder/PGYMacMenu.sync"
            ),
            "folder/PGYMacMenu.sync.d"
        )
    }

    func testObjectHashMismatchAndNonCanonicalNamesFailClosed() throws {
        let encrypted = try ImmutableSyncSnapshotCrypto.encrypt(
            .genesis(snapshotID: genesisID, document: document()),
            passphrase: passphrase
        )
        var tampered = encrypted.data
        tampered[tampered.startIndex] ^= 0x01

        XCTAssertThrowsError(
            try ImmutableSyncSnapshotCrypto.decryptObject(
                tampered,
                fileName: encrypted.objectFileName,
                passphrase: passphrase
            )
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .encryptedPayloadHashMismatch)
        }

        let uppercaseName = encrypted.objectFileName.uppercased()
        XCTAssertThrowsError(
            try ImmutableSyncSnapshotLayout.encryptedPayloadHash(fromObjectFileName: uppercaseName)
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .invalidObjectFileName)
        }

        XCTAssertThrowsError(
            try ImmutableSyncSnapshotLayout.encryptedPayloadHash(
                fromObjectRelativePath: "nested/\(encrypted.objectFileName)"
            )
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .invalidObjectRelativePath)
        }
    }

    func testDatasetSnapshotAndParentValidationFailClosed() throws {
        let snapshot = try ImmutableSyncSnapshot.genesis(
            snapshotID: genesisID,
            document: document()
        )
        XCTAssertThrowsError(try snapshot.validated(expectedDatasetID: UUID())) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .datasetMismatch)
        }
        XCTAssertThrowsError(try snapshot.validated(expectedSnapshotID: successorID)) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .snapshotIdentityMismatch)
        }

        let parent = try ImmutableSyncCarrierReference(
            kind: .object,
            snapshotID: successorID,
            encryptedPayloadHash: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(
            try ImmutableSyncSnapshot.successor(
                snapshotID: successorID,
                parent: parent,
                document: document()
            )
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .snapshotCannotReferenceItself)
        }

        XCTAssertThrowsError(
            try ImmutableSyncCarrierReference(
                kind: .object,
                snapshotID: genesisID,
                encryptedPayloadHash: "not-a-sha256"
            )
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .invalidEncryptedPayloadHash)
        }

        let parentlessObject = try ImmutableSyncSnapshotCrypto.encrypt(snapshot, passphrase: passphrase)
        XCTAssertThrowsError(
            try ImmutableSyncSnapshotCrypto.decryptObject(
                parentlessObject.data,
                fileName: parentlessObject.objectFileName,
                passphrase: passphrase
            )
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .objectMissingParent)
        }
    }

    func testAuthenticatedUnknownProtocolAndDatasetMismatchFailClosed() throws {
        let base = try ImmutableSyncSnapshot.genesis(
            snapshotID: genesisID,
            document: document()
        )
        let unsupported = WireSnapshot(
            protocolVersion: 2,
            datasetID: datasetID,
            snapshotID: genesisID,
            parent: nil,
            document: document()
        )
        let unsupportedData = try encryptedWireData(unsupported)
        XCTAssertThrowsError(
            try ImmutableSyncSnapshotCrypto.decrypt(unsupportedData, passphrase: passphrase)
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .unsupportedProtocolVersion(2))
        }

        let mismatched = WireSnapshot(
            protocolVersion: base.protocolVersion,
            datasetID: UUID(),
            snapshotID: base.snapshotID,
            parent: nil,
            document: base.document
        )
        let mismatchedData = try encryptedWireData(mismatched)
        XCTAssertThrowsError(
            try ImmutableSyncSnapshotCrypto.decrypt(mismatchedData, passphrase: passphrase)
        ) { error in
            XCTAssertEqual(error as? ImmutableSyncSnapshotError, .datasetMismatch)
        }
    }

    private func document(generation: UInt64 = 1, secret: String = "api-key") -> SyncDocument {
        SyncDocument(
            datasetID: datasetID,
            generation: generation,
            apiKeyProfiles: [
                VersionedRecord(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    order: 0,
                    revision: HLCRevision(wallTimeMilliseconds: 100),
                    writerDeviceID: "device-a",
                    value: SyncAPIKeyProfileValue(
                        name: "Production",
                        apiKey: secret,
                        password: "install-password",
                        updateTemplate: "Update"
                    )
                )
            ]
        )
    }

    private func encryptedWireData(_ snapshot: WireSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let envelope = try SyncCrypto.seal(
            encoder.encode(snapshot),
            passphrase: passphrase
        )
        return try SyncCrypto.encode(envelope)
    }
}

private struct WireSnapshot: Encodable {
    let protocolVersion: Int
    let datasetID: UUID
    let snapshotID: UUID
    let parent: ImmutableSyncCarrierReference?
    let document: SyncDocument
}
