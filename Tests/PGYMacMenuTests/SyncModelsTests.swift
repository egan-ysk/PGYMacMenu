import Foundation
import XCTest
@testable import PGYMacMenu

final class SyncModelsTests: XCTestCase {
    private let datasetID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testHLCAdvancesPastLocalObservedAndWallClock() {
        XCTAssertEqual(
            HLCRevision.next(
                local: .init(wallTimeMilliseconds: 100, counter: 2),
                observed: .init(wallTimeMilliseconds: 100, counter: 4),
                nowMilliseconds: 99
            ),
            HLCRevision(wallTimeMilliseconds: 100, counter: 5)
        )
        XCTAssertEqual(
            HLCRevision.next(
                local: .init(wallTimeMilliseconds: 100, counter: 8),
                observed: nil,
                nowMilliseconds: 101
            ),
            HLCRevision(wallTimeMilliseconds: 101, counter: 0)
        )
        XCTAssertEqual(
            HLCRevision.next(
                local: .init(wallTimeMilliseconds: 100, counter: 8),
                observed: .init(wallTimeMilliseconds: 102, counter: 3),
                nowMilliseconds: 101
            ),
            HLCRevision(wallTimeMilliseconds: 102, counter: 4)
        )
    }

    func testHLCMovesWallClockWhenCounterOverflows() {
        XCTAssertEqual(
            HLCRevision.next(
                local: .init(wallTimeMilliseconds: 100, counter: .max),
                nowMilliseconds: 100
            ),
            HLCRevision(wallTimeMilliseconds: 101, counter: 0)
        )
    }

    func testMergeUnionsIndependentRecordsAndHasCanonicalOrder() throws {
        let first = profile(id: firstID, order: 20, revision: 1, writer: "device-a", name: "A")
        let second = profile(id: secondID, order: 10, revision: 1, writer: "device-b", name: "B")
        let lhs = document(profiles: [first])
        let rhs = document(profiles: [second])

        let forward = try lhs.merged(with: rhs)
        let reverse = try rhs.merged(with: lhs)

        XCTAssertEqual(forward.apiKeyProfiles.map(\.id), [secondID, firstID])
        XCTAssertEqual(try forward.canonicalData(), try reverse.canonicalData())
    }

    func testNewerRevisionAndWriterBreakTiesDeterministically() throws {
        let old = profile(id: firstID, order: 4, revision: 10, writer: "device-z", name: "old")
        let new = profile(id: firstID, order: 4, revision: 11, writer: "device-a", name: "new")
        let newerMerged = try document(profiles: [old]).merged(with: document(profiles: [new]))
        XCTAssertEqual(newerMerged.apiKeyProfiles.first?.value?.name, "new")

        let writerA = profile(id: firstID, order: 4, revision: 11, writer: "device-a", name: "A")
        let writerB = profile(id: firstID, order: 4, revision: 11, writer: "device-b", name: "B")
        let writerMerged = try document(profiles: [writerB]).merged(with: document(profiles: [writerA]))
        XCTAssertEqual(writerMerged.apiKeyProfiles.first?.value?.name, "B")
    }

    func testExactClockConflictIsCommutativeAndAssociative() throws {
        let a = profile(id: firstID, order: 3, revision: 7, writer: "same", name: "A")
        let b = profile(id: firstID, order: 2, revision: 7, writer: "same", name: "B")
        let c = profile(id: firstID, order: 1, revision: 7, writer: "same", name: "C")
        let first = document(profiles: [a])
        let second = document(profiles: [b])
        let third = document(profiles: [c])

        let forward = try first.merged(with: second)
        let reverse = try second.merged(with: first)
        XCTAssertEqual(try forward.canonicalData(), try reverse.canonicalData())

        let leftAssociated = try forward.merged(with: third)
        let rightAssociated = try first.merged(with: second.merged(with: third))
        XCTAssertEqual(try leftAssociated.canonicalData(), try rightAssociated.canonicalData())
        XCTAssertEqual(leftAssociated.apiKeyProfiles.first?.order, 1)
    }

    func testTombstonePermanentlyWinsAndRetainsImmutableEarliestOrder() throws {
        let live = profile(id: firstID, order: 5, revision: 10, writer: "offline", name: "live")
        let tombstone = VersionedRecord<SyncAPIKeyProfileValue>.tombstone(
            id: firstID,
            order: 8,
            revision: .init(wallTimeMilliseconds: 11),
            writerDeviceID: "deleting-device"
        )
        let futureLive = profile(id: firstID, order: 30, revision: 999, writer: "offline", name: "resurrected")

        let deleted = try document(profiles: [live]).merged(with: document(profiles: [tombstone]))
        XCTAssertTrue(try XCTUnwrap(deleted.apiKeyProfiles.first).isTombstone)
        XCTAssertEqual(deleted.apiKeyProfiles.first?.order, 5)

        let mergedAgain = try deleted.merged(with: document(profiles: [futureLive]))
        XCTAssertTrue(try XCTUnwrap(mergedAgain.apiKeyProfiles.first).isTombstone)
        XCTAssertEqual(mergedAgain.apiKeyProfiles.first?.order, 5)
    }

    func testPreferencesInvariantIsEnforcedByInitializerAndDecoder() throws {
        let value = SyncPreferencesValue(
            quitAfterSuccessfulUpload: true,
            allowMenuBarRunning: false,
            showMenuBarIcon: true
        )
        XCTAssertFalse(value.showMenuBarIcon)

        let invalidJSON = Data(#"{"quitAfterSuccessfulUpload":false,"allowMenuBarRunning":false,"showMenuBarIcon":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SyncPreferencesValue.self, from: invalidJSON)
        XCTAssertFalse(decoded.showMenuBarIcon)
    }

    func testDatasetMismatchAndUnsupportedVersionFailClosed() throws {
        let otherDataset = SyncDocument(datasetID: UUID())
        XCTAssertThrowsError(try document().merged(with: otherDataset)) { error in
            XCTAssertEqual(error as? SyncModelError, .datasetMismatch)
        }

        let unknown = SyncDocument(version: 2, datasetID: datasetID)
        XCTAssertThrowsError(try unknown.normalized()) { error in
            XCTAssertEqual(error as? SyncModelError, .unsupportedVersion(2))
        }

        let invalidPreferences = SyncDocument(
            datasetID: datasetID,
            preferences: VersionedRecord(
                id: UUID(),
                order: 0,
                revision: .init(wallTimeMilliseconds: 1),
                writerDeviceID: "device",
                value: SyncPreferencesValue(
                    quitAfterSuccessfulUpload: false,
                    allowMenuBarRunning: false,
                    showMenuBarIcon: false
                )
            )
        )
        XCTAssertThrowsError(try invalidPreferences.normalized()) { error in
            XCTAssertEqual(error as? SyncModelError, .invalidPreferencesRecord)
        }
    }

    func testDuplicateRecordIDsAreRejectedBeforeMerge() throws {
        let first = profile(id: firstID, order: 0, revision: 1, writer: "device-a", name: "A")
        let duplicate = profile(id: firstID, order: 1, revision: 2, writer: "device-b", name: "B")
        let malformed = document(profiles: [first, duplicate])

        XCTAssertThrowsError(try malformed.normalized()) { error in
            XCTAssertEqual(error as? SyncModelError, .duplicateRecordID)
        }
    }

    func testNextGenerationTracksPreviousHashWithoutChangingContent() throws {
        let source = SyncDocument(
            datasetID: datasetID,
            generation: 41,
            previousHash: "older",
            apiKeyProfiles: [profile(id: firstID, order: 0, revision: 1, writer: "device", name: "A")]
        )
        let next = try source.nextGeneration(previousHash: "remote-hash")

        XCTAssertEqual(next.generation, 42)
        XCTAssertEqual(next.previousHash, "remote-hash")
        XCTAssertEqual(next.apiKeyProfiles, source.apiKeyProfiles)
    }

    private func document(
        profiles: [VersionedRecord<SyncAPIKeyProfileValue>] = []
    ) -> SyncDocument {
        SyncDocument(datasetID: datasetID, apiKeyProfiles: profiles)
    }

    private func profile(
        id: UUID,
        order: Int64,
        revision: Int64,
        writer: String,
        name: String
    ) -> VersionedRecord<SyncAPIKeyProfileValue> {
        VersionedRecord(
            id: id,
            order: order,
            revision: .init(wallTimeMilliseconds: revision),
            writerDeviceID: writer,
            value: .init(name: name, apiKey: "key-\(name)", password: "password", updateTemplate: "template")
        )
    }
}
