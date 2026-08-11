import Foundation
import XCTest
@testable import PGYMacMenu

final class SyncCoordinatorAppendOnlyTests: XCTestCase {
    func testManualLifecycleDoesNotAccessNetworkUntilSynchronizeNow() async throws {
        let fixture = try ManualSyncFixture()
        defer { fixture.cleanup() }

        try fixture.store.saveUpdateTemplate(
            UpdateTemplate(name: "Pending", content: "Manual only")
        )

        try await fixture.coordinator.saveSettings(fixture.settings)
        await fixture.coordinator.prepareOnLaunch()
        await fixture.coordinator.applicationDidBecomeActive()
        await fixture.coordinator.scheduleLocalChange()
        let didFlush = await fixture.coordinator.flushPendingChanges()
        let requestsBeforeManualSync = await fixture.transport.requestCount
        let statusBeforeManualSync = await fixture.coordinator.currentStatus()

        XCTAssertEqual(requestsBeforeManualSync, 0)
        XCTAssertFalse(didFlush)
        XCTAssertTrue(fixture.store.hasPendingSyncChanges())
        XCTAssertEqual(statusBeforeManualSync, .pending)

        do {
            try await fixture.coordinator.synchronizeNow()
            XCTFail("The transport deliberately rejects the explicit synchronization")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .authenticationFailed)
        }

        let requestsAfterManualSync = await fixture.transport.requestCount
        XCTAssertEqual(requestsAfterManualSync, 1)
        XCTAssertTrue(fixture.store.hasPendingSyncChanges())
    }

    func testConnectionUsesOnlyTemporaryProbeResources() async throws {
        let transport = AppendOnlyStatefulTransport(etagMode: .strong)
        let device = try AppendOnlyTestDevice(transport: transport)
        defer { device.cleanup() }

        try await device.coordinator.testConnection(device.settings)

        let permanentRequestCount = await transport.permanentSyncResourceRequestCount
        let immutableRequestCount = await transport.immutableCollectionRequestCount
        let temporaryProbeMethods = await transport.temporaryProbeMethods
        XCTAssertEqual(permanentRequestCount, 0)
        XCTAssertEqual(immutableRequestCount, 0)
        XCTAssertEqual(Set(temporaryProbeMethods), Set(["PUT", "GET", "DELETE"]))
        XCTAssertEqual(temporaryProbeMethods.first, "PUT")
    }

    func testStrongETagLegacyEndpointSynchronizesWhenCollectionPROPFINDReturns501() async throws {
        let transport = AppendOnlyStatefulTransport(
            etagMode: .strong,
            immutableCollectionListingStatusCode: 501
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Legacy profile"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()

        let storedLegacy = await transport.resource(
            named: WebDAVConfiguration.defaultRelativePath
        )
        let immutablePUTCount = await transport.immutableObjectPUTCount
        let legacyPUTCount = await transport.legacyPUTCount
        let immutableListingCount = await transport.immutableCollectionListingRequestCount
        XCTAssertNotNil(storedLegacy)
        XCTAssertEqual(immutablePUTCount, 0)
        XCTAssertEqual(legacyPUTCount, 1)
        XCTAssertEqual(immutableListingCount, 1)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testCollectionPROPFIND403IsNotTreatedAsLegacyFallback() async throws {
        let transport = AppendOnlyStatefulTransport(
            etagMode: .strong,
            immutableCollectionListingStatusCode: 403
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Pending profile"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("A forbidden immutable collection listing must fail closed")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .forbidden)
        }

        let legacyPUTCount = await transport.legacyPUTCount
        let immutableListingCount = await transport.immutableCollectionListingRequestCount
        XCTAssertEqual(legacyPUTCount, 0)
        XCTAssertEqual(immutableListingCount, 1)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testSavingSettingsClearsConditionalCreateAttestation() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Pending profile"
        )
        defer { device.cleanup() }

        try await device.coordinator.testConnection(device.settings)
        try await device.coordinator.saveSettings(device.settings)
        await transport.setConditionalCreateSafety(false)

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("Saving settings must require conditional-create safety to be attested again")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeConditionalCreate)
        }

        let genesis = await transport.resource(named: ImmutableSyncSnapshotLayout.genesisFileName)
        XCTAssertNil(genesis)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testWeakETagAndUnsafeLockFallBackToImmutableSnapshots() async throws {
        let transport = AppendOnlyStatefulTransport(lockBehavior: .acceptsConcurrentExclusiveLocks)
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Production"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()

        XCTAssertFalse(device.store.hasPendingSyncChanges())
        let legacyPUTCount = await transport.legacyPUTCount
        XCTAssertEqual(legacyPUTCount, 0)
        let storedGenesis = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let genesisData = try XCTUnwrap(storedGenesis)
        let genesis = try ImmutableSyncSnapshotCrypto.decryptGenesis(
            genesisData,
            passphrase: device.settings.encryptionPassphrase
        )
        XCTAssertEqual(genesis.document.apiKeyProfiles.first?.value?.name, "Production")
    }

    func testUnsafeConditionalCreateFailsClosedWithoutPublishingGenesis() async throws {
        let transport = AppendOnlyStatefulTransport(safelyEnforcesConditionalCreate: false)
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Pending"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("A server that overwrites create-only resources must be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeConditionalCreate)
        }

        XCTAssertTrue(device.store.hasPendingSyncChanges())
        let legacyPUTCount = await transport.legacyPUTCount
        XCTAssertEqual(legacyPUTCount, 0)
        let genesis = await transport.resource(named: ImmutableSyncSnapshotLayout.genesisFileName)
        XCTAssertNil(genesis)
    }

    func testJianguoyunStyleUnsafeConditionalCreateUsesAtomicMoveImmutableSnapshots() async throws {
        let transport = AppendOnlyStatefulTransport(
            etagMode: .missing,
            lockBehavior: .acceptsConcurrentExclusiveLocks,
            safelyEnforcesConditionalCreate: false,
            atomicMoveBehavior: .safelyPreventsOverwrite
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        defer { device.cleanup() }

        try await device.coordinator.testConnection(device.settings)
        let movesAfterConnectionTest = await transport.atomicMoveRequestCount
        let legacyPUTsAfterConnectionTest = await transport.legacyPUTCount
        XCTAssertGreaterThan(movesAfterConnectionTest, 0)
        XCTAssertEqual(legacyPUTsAfterConnectionTest, 0)

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()

        let initialGenesis = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let legacyAfterInitialSync = await transport.resource(
            named: WebDAVConfiguration.defaultRelativePath
        )
        let legacyPUTsAfterInitialSync = await transport.legacyPUTCount
        XCTAssertNotNil(initialGenesis)
        XCTAssertNil(legacyAfterInitialSync)
        XCTAssertEqual(legacyPUTsAfterInitialSync, 0)
        XCTAssertFalse(device.store.hasPendingSyncChanges())

        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Ongoing", content: "Published through MOVE")
        )
        let movesBeforeOngoingSync = await transport.atomicMoveRequestCount
        try await device.coordinator.synchronizeNow()

        let movesAfterOngoingSync = await transport.atomicMoveRequestCount
        let legacyAfterOngoingSync = await transport.resource(
            named: WebDAVConfiguration.defaultRelativePath
        )
        let legacyPUTsAfterOngoingSync = await transport.legacyPUTCount
        XCTAssertGreaterThan(movesAfterOngoingSync, movesBeforeOngoingSync)
        XCTAssertNil(legacyAfterOngoingSync)
        XCTAssertEqual(legacyPUTsAfterOngoingSync, 0)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testUnsafeAtomicMoveLeavesChangesDirtyWithoutLegacyOverwrite() async throws {
        let transport = AppendOnlyStatefulTransport(
            etagMode: .missing,
            lockBehavior: .acceptsConcurrentExclusiveLocks,
            safelyEnforcesConditionalCreate: false,
            atomicMoveBehavior: .overwritesExistingDestination
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Pending"
        )
        defer { device.cleanup() }

        let originalLegacyData = Data("existing legacy payload must remain intact".utf8)
        let rootURL = try XCTUnwrap(URL(string: device.settings.rootURL))
        await transport.seedLegacyResource(originalLegacyData, rootURL: rootURL)
        try await device.coordinator.saveSettings(device.settings)
        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("An unsafe MOVE must not be used to publish immutable snapshots")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        let legacy = await transport.resource(named: WebDAVConfiguration.defaultRelativePath)
        let genesis = await transport.resource(named: ImmutableSyncSnapshotLayout.genesisFileName)
        let legacyPUTCount = await transport.legacyPUTCount
        let moveCount = await transport.atomicMoveRequestCount
        XCTAssertEqual(legacy, originalLegacyData)
        XCTAssertNil(genesis)
        XCTAssertEqual(legacyPUTCount, 0)
        XCTAssertGreaterThan(moveCount, 0)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testAtomicMoveCreateReadbackTransientFailureRetriesIntoCollisionWithoutOverwrite() async throws {
        let failures: [AppendOnlyStatefulTransport.ImmutableFormalReadFailure] = [
            .serverError,
            .transport
        ]

        for failure in failures {
            let transport = AppendOnlyStatefulTransport(
                etagMode: .missing,
                lockBehavior: .acceptsConcurrentExclusiveLocks,
                safelyEnforcesConditionalCreate: false,
                atomicMoveBehavior: .safelyPreventsOverwrite,
                immutableFormalReadFailures: [failure]
            )
            let device = try AppendOnlyTestDevice(
                transport: transport,
                initialProfileName: "Retry collision",
                retryDelaysNanoseconds: [0, 1_000_000]
            )
            defer { device.cleanup() }

            try await device.coordinator.saveSettings(device.settings)
            try await device.coordinator.synchronizeNow()
            try await device.coordinator.synchronizeNow()

            let genesisMoveAttempts = await transport.genesisAtomicMoveCount
            let successfulGenesisMoves = await transport.genesisSuccessfulAtomicMoveCount
            let legacyPUTCount = await transport.legacyPUTCount
            let storedGenesisData = await transport.resource(
                named: ImmutableSyncSnapshotLayout.genesisFileName
            )
            let genesisData = try XCTUnwrap(storedGenesisData)
            let genesis = try ImmutableSyncSnapshotCrypto.decryptGenesis(
                genesisData,
                passphrase: device.settings.encryptionPassphrase
            )
            let formalObjectCount = (await transport.immutableObjectNames()).count

            XCTAssertEqual(genesisMoveAttempts, 2)
            XCTAssertEqual(successfulGenesisMoves, 1)
            XCTAssertEqual(formalObjectCount, 1)
            XCTAssertEqual(legacyPUTCount, 0)
            XCTAssertEqual(
                try device.store.syncSnapshot().document.datasetID,
                genesis.datasetID
            )
            XCTAssertFalse(device.store.hasPendingSyncChanges())
        }
    }

    func testFreshClientReattestsAtomicMoveBeforePublishingImmutableSuccessor() async throws {
        let transport = AppendOnlyStatefulTransport(
            etagMode: .missing,
            lockBehavior: .acceptsConcurrentExclusiveLocks,
            safelyEnforcesConditionalCreate: false,
            atomicMoveBehavior: .safelyPreventsOverwrite
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let probeMovesBefore = await transport.atomicMoveProbeMoveCount
        let immutableNamesBefore = await transport.immutableObjectNames()

        await transport.setAtomicMoveBehavior(.overwritesExistingDestination)
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Pending", content: "Must not use stale MOVE proof")
        )
        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("A fresh client must re-attest atomic MOVE before writing")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        let probeMovesAfter = await transport.atomicMoveProbeMoveCount
        let immutableNamesAfter = await transport.immutableObjectNames()
        let legacyPUTCount = await transport.legacyPUTCount
        XCTAssertGreaterThan(probeMovesAfter, probeMovesBefore)
        XCTAssertEqual(immutableNamesAfter, immutableNamesBefore)
        XCTAssertEqual(legacyPUTCount, 0)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testHiddenAnchoredCarrierFailsClosedAndKeepsLocalChangesDirty() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "First object", content: "Anchor this carrier")
        )
        try await device.coordinator.synchronizeNow()

        let objectNames = await transport.immutableObjectNames()
        let anchoredObjectName = try XCTUnwrap(
            objectNames.last(where: { $0 != ImmutableSyncSnapshotLayout.genesisFileName })
        )
        await transport.hideFromListings(name: anchoredObjectName)
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Still pending", content: "Must not publish")
        )
        let PUTsBeforeFailure = await transport.immutableObjectPUTCount
        let MKCOLsBeforeFailure = await transport.immutableCollectionMKCOLCount

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("Hiding a previously anchored immutable carrier must be treated as rollback")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .rollbackDetected)
        }

        let PUTsAfterFailure = await transport.immutableObjectPUTCount
        let MKCOLsAfterFailure = await transport.immutableCollectionMKCOLCount
        XCTAssertEqual(PUTsAfterFailure, PUTsBeforeFailure)
        XCTAssertEqual(MKCOLsAfterFailure, MKCOLsBeforeFailure)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testReencryptedGenesisWithSameNameFailsPinnedHashValidationWithoutWriting() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()

        let storedOriginalData = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let originalData = try XCTUnwrap(storedOriginalData)
        let originalGenesis = try ImmutableSyncSnapshotCrypto.decryptGenesis(
            originalData,
            passphrase: device.settings.encryptionPassphrase
        )
        let replacement = try ImmutableSyncSnapshotCrypto.encrypt(
            originalGenesis,
            passphrase: device.settings.encryptionPassphrase
        )
        XCTAssertNotEqual(replacement.data, originalData)
        let didReplace = await transport.replaceImmutableGenesis(with: replacement.data)
        XCTAssertTrue(didReplace)

        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Still pending", content: "Must not publish")
        )
        let PUTsBeforeFailure = await transport.totalPUTCount
        let MKCOLsBeforeFailure = await transport.totalMKCOLCount

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("Replacing the pinned genesis payload must be treated as rollback")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .rollbackDetected)
        }

        let PUTsAfterFailure = await transport.totalPUTCount
        let MKCOLsAfterFailure = await transport.totalMKCOLCount
        XCTAssertEqual(PUTsAfterFailure, PUTsBeforeFailure)
        XCTAssertEqual(MKCOLsAfterFailure, MKCOLsBeforeFailure)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testMissingAnchoredRepositoryFailsBeforeRecreatingCollection() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        await transport.removeImmutableRepository()
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Still pending", content: "Must not recreate repository")
        )
        let PUTsBeforeFailure = await transport.immutableObjectPUTCount
        let MKCOLsBeforeFailure = await transport.immutableCollectionMKCOLCount

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("A missing anchored repository must be treated as rollback")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .rollbackDetected)
        }

        let PUTsAfterFailure = await transport.immutableObjectPUTCount
        let MKCOLsAfterFailure = await transport.immutableCollectionMKCOLCount
        XCTAssertEqual(PUTsAfterFailure, PUTsBeforeFailure)
        XCTAssertEqual(MKCOLsAfterFailure, MKCOLsBeforeFailure)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testOrphanImmutableObjectWithoutGenesisFailsClosedBeforeWriting() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Still pending"
        )
        defer { device.cleanup() }

        let rootURL = try XCTUnwrap(URL(string: device.settings.rootURL))
        let orphanName = String(repeating: "a", count: 64) + ".pgy"
        await transport.seedImmutableObject(Data("orphan".utf8), named: orphanName, rootURL: rootURL)
        try await device.coordinator.saveSettings(device.settings)
        let PUTsBeforeFailure = await transport.totalPUTCount
        let MKCOLsBeforeFailure = await transport.totalMKCOLCount

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("An object without genesis must make the immutable repository invalid")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .immutableRepositoryInvalid)
        }

        let PUTsAfterFailure = await transport.totalPUTCount
        let MKCOLsAfterFailure = await transport.totalMKCOLCount
        XCTAssertEqual(PUTsAfterFailure, PUTsBeforeFailure)
        XCTAssertEqual(MKCOLsAfterFailure, MKCOLsBeforeFailure)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
        let storedGenesis = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        XCTAssertNil(storedGenesis)
    }

    func testGenesisListingRetriesEventualVisibilityWithoutRepeatingCreate() async throws {
        let transport = AppendOnlyStatefulTransport(
            genesisListingOmissionsAfterCreate: 2
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial",
            retryDelaysNanoseconds: [0, 1_000_000, 2_000_000, 4_000_000]
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()

        let genesisCreateCount = await transport.genesisCreateOnlyPUTCount
        let omissionCount = await transport.genesisListingOmissionResponseCount
        XCTAssertEqual(genesisCreateCount, 1)
        XCTAssertEqual(omissionCount, 2)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
        let storedGenesis = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        XCTAssertNotNil(storedGenesis)
    }

    func testImmutableObjectReadRetriesEventualVisibilityWithoutRepeatingCreate() async throws {
        let transport = AppendOnlyStatefulTransport(
            immutableObjectRead404ResponsesAfterCreate: 2
        )
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial",
            retryDelaysNanoseconds: [0, 1_000_000, 2_000_000, 4_000_000]
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Eventually visible", content: "Read after create")
        )
        let immutablePUTsBeforeSync = await transport.immutableObjectPUTCount

        try await device.coordinator.synchronizeNow()

        let immutablePUTsAfterSync = await transport.immutableObjectPUTCount
        let delayed404Count = await transport.immutableObjectRead404ResponseCount
        XCTAssertEqual(immutablePUTsAfterSync - immutablePUTsBeforeSync, 1)
        XCTAssertEqual(delayed404Count, 2)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testListedGenesisReadRetriesEventual404() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial",
            retryDelaysNanoseconds: [0, 1_000_000, 2_000_000, 4_000_000]
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        await transport.delayNextGenesisReads(count: 1)
        let pending = UpdateTemplate(name: "Pending", content: "After listed genesis")
        try device.store.saveUpdateTemplate(pending)

        try await device.coordinator.synchronizeNow()

        let delayed404Count = await transport.genesisRead404ResponseCount
        XCTAssertEqual(delayed404Count, 1)
        XCTAssertTrue(device.store.loadUpdateTemplates().contains(where: { $0.id == pending.id }))
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testListedImmutableObjectReadRetriesEventual404() async throws {
        let transport = AppendOnlyStatefulTransport()
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial",
            retryDelaysNanoseconds: [0, 1_000_000, 2_000_000, 4_000_000]
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Existing object", content: "Already listed")
        )
        try await device.coordinator.synchronizeNow()

        await transport.delayNextImmutableObjectReads(count: 1)
        let pending = UpdateTemplate(name: "Pending", content: "After listed object")
        try device.store.saveUpdateTemplate(pending)
        try await device.coordinator.synchronizeNow()

        let delayed404Count = await transport.immutableObjectRead404ResponseCount
        XCTAssertEqual(delayed404Count, 1)
        XCTAssertTrue(device.store.loadUpdateTemplates().contains(where: { $0.id == pending.id }))
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testConcurrentDevicesPublishBranchesAndEventuallyMergeBothChanges() async throws {
        let transport = AppendOnlyStatefulTransport()
        let first = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        let second = try AppendOnlyTestDevice(transport: transport)
        defer {
            first.cleanup()
            second.cleanup()
        }

        try await first.coordinator.saveSettings(first.settings)
        try await first.coordinator.synchronizeNow()
        try await second.coordinator.saveSettings(second.settings)
        try await second.coordinator.synchronizeNow()

        let firstTemplate = UpdateTemplate(name: "First device", content: "First branch")
        let secondTemplate = UpdateTemplate(name: "Second device", content: "Second branch")
        try first.store.saveUpdateTemplate(firstTemplate)
        try second.store.saveUpdateTemplate(secondTemplate)

        await transport.armNextTwoRepositoryListingsAsBarrier()
        async let firstSync: Void = first.coordinator.synchronizeNow()
        async let secondSync: Void = second.coordinator.synchronizeNow()
        try await firstSync
        try await secondSync

        try await first.coordinator.synchronizeNow()
        try await second.coordinator.synchronizeNow()

        let expectedIDs: Set<UUID> = [firstTemplate.id, secondTemplate.id]
        let firstIDs = Set(first.store.loadUpdateTemplates().map(\.id))
        let secondIDs = Set(second.store.loadUpdateTemplates().map(\.id))
        XCTAssertTrue(expectedIDs.isSubset(of: firstIDs))
        XCTAssertTrue(expectedIDs.isSubset(of: secondIDs))
        XCTAssertFalse(first.store.hasPendingSyncChanges())
        XCTAssertFalse(second.store.hasPendingSyncChanges())
    }

    func testTwoNewDevicesRaceGenesisCreationAndConvergeWithoutOverwrite() async throws {
        let transport = AppendOnlyStatefulTransport()
        let first = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "First device"
        )
        let second = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Second device"
        )
        defer {
            first.cleanup()
            second.cleanup()
        }

        let firstProfileID = try XCTUnwrap(first.store.loadAPIKeyProfiles().first?.id)
        let secondProfileID = try XCTUnwrap(second.store.loadAPIKeyProfiles().first?.id)
        let expectedProfileIDs: Set<UUID> = [firstProfileID, secondProfileID]
        try await first.coordinator.saveSettings(first.settings)
        try await second.coordinator.saveSettings(second.settings)

        await transport.armNextTwoRepositoryListingsAndGenesisCreatesAsBarriers()
        async let firstSync: Void = first.coordinator.synchronizeNow()
        async let secondSync: Void = second.coordinator.synchronizeNow()
        try await firstSync
        try await secondSync

        let genesisCreateAttempts = await transport.genesisCreateOnlyPUTCount
        let successfulGenesisCreates = await transport.genesisSuccessfulCreateCount
        XCTAssertEqual(genesisCreateAttempts, 2)
        XCTAssertEqual(successfulGenesisCreates, 1)

        let storedWinnerGenesisData = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let winnerGenesisData = try XCTUnwrap(storedWinnerGenesisData)
        let winnerGenesis = try ImmutableSyncSnapshotCrypto.decryptGenesis(
            winnerGenesisData,
            passphrase: first.settings.encryptionPassphrase
        )
        XCTAssertEqual(try first.store.syncSnapshot().document.datasetID, winnerGenesis.datasetID)
        XCTAssertEqual(try second.store.syncSnapshot().document.datasetID, winnerGenesis.datasetID)

        try await first.coordinator.synchronizeNow()
        try await second.coordinator.synchronizeNow()

        let firstProfileIDs = Set(first.store.loadAPIKeyProfiles().map(\.id))
        let secondProfileIDs = Set(second.store.loadAPIKeyProfiles().map(\.id))
        XCTAssertTrue(expectedProfileIDs.isSubset(of: firstProfileIDs))
        XCTAssertTrue(expectedProfileIDs.isSubset(of: secondProfileIDs))
        XCTAssertFalse(first.store.hasPendingSyncChanges())
        XCTAssertFalse(second.store.hasPendingSyncChanges())

        var remoteObjectContainsBothProfiles = false
        let objectNames = await transport.immutableObjectNames().filter {
            $0 != ImmutableSyncSnapshotLayout.genesisFileName
        }
        for name in objectNames {
            let storedEncryptedData = await transport.resource(named: name)
            let encryptedData = try XCTUnwrap(storedEncryptedData)
            let snapshot = try ImmutableSyncSnapshotCrypto.decryptObject(
                encryptedData,
                fileName: name,
                passphrase: first.settings.encryptionPassphrase,
                expectedDatasetID: winnerGenesis.datasetID
            )
            let profileIDs = Set(snapshot.document.apiKeyProfiles.map(\.id))
            if expectedProfileIDs.isSubset(of: profileIDs) {
                remoteObjectContainsBothProfiles = true
            }
        }
        XCTAssertTrue(remoteObjectContainsBothProfiles)
        let finalGenesisData = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let finalSuccessfulGenesisCreates = await transport.genesisSuccessfulCreateCount
        let finalLegacyPUTCount = await transport.legacyPUTCount
        XCTAssertEqual(finalGenesisData, winnerGenesisData)
        XCTAssertEqual(finalSuccessfulGenesisCreates, 1)
        XCTAssertEqual(finalLegacyPUTCount, 0)
    }

    func testTwoNewDevicesRaceAtomicMoveGenesisCreationAndConvergeWithoutLegacyOverwrite() async throws {
        let transport = AppendOnlyStatefulTransport(
            etagMode: .missing,
            lockBehavior: .acceptsConcurrentExclusiveLocks,
            safelyEnforcesConditionalCreate: false,
            atomicMoveBehavior: .safelyPreventsOverwrite
        )
        let first = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "First device"
        )
        let second = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Second device"
        )
        defer {
            first.cleanup()
            second.cleanup()
        }

        let firstProfileID = try XCTUnwrap(first.store.loadAPIKeyProfiles().first?.id)
        let secondProfileID = try XCTUnwrap(second.store.loadAPIKeyProfiles().first?.id)
        let expectedProfileIDs: Set<UUID> = [firstProfileID, secondProfileID]
        try await first.coordinator.saveSettings(first.settings)
        try await second.coordinator.saveSettings(second.settings)

        await transport.armNextTwoRepositoryListingsAndGenesisMovesAsBarriers()
        async let firstSync: Void = first.coordinator.synchronizeNow()
        async let secondSync: Void = second.coordinator.synchronizeNow()
        try await firstSync
        try await secondSync

        let genesisMoveAttempts = await transport.genesisAtomicMoveCount
        let successfulGenesisMoves = await transport.genesisSuccessfulAtomicMoveCount
        XCTAssertEqual(genesisMoveAttempts, 2)
        XCTAssertEqual(successfulGenesisMoves, 1)

        let storedWinnerGenesisData = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let winnerGenesisData = try XCTUnwrap(storedWinnerGenesisData)
        let winnerGenesis = try ImmutableSyncSnapshotCrypto.decryptGenesis(
            winnerGenesisData,
            passphrase: first.settings.encryptionPassphrase
        )
        XCTAssertEqual(try first.store.syncSnapshot().document.datasetID, winnerGenesis.datasetID)
        XCTAssertEqual(try second.store.syncSnapshot().document.datasetID, winnerGenesis.datasetID)

        try await first.coordinator.synchronizeNow()
        try await second.coordinator.synchronizeNow()

        let firstProfileIDs = Set(first.store.loadAPIKeyProfiles().map(\.id))
        let secondProfileIDs = Set(second.store.loadAPIKeyProfiles().map(\.id))
        XCTAssertTrue(expectedProfileIDs.isSubset(of: firstProfileIDs))
        XCTAssertTrue(expectedProfileIDs.isSubset(of: secondProfileIDs))
        XCTAssertFalse(first.store.hasPendingSyncChanges())
        XCTAssertFalse(second.store.hasPendingSyncChanges())

        var remoteObjectContainsBothProfiles = false
        let objectNames = await transport.immutableObjectNames().filter {
            $0 != ImmutableSyncSnapshotLayout.genesisFileName
        }
        for name in objectNames {
            let storedEncryptedData = await transport.resource(named: name)
            let encryptedData = try XCTUnwrap(storedEncryptedData)
            let snapshot = try ImmutableSyncSnapshotCrypto.decryptObject(
                encryptedData,
                fileName: name,
                passphrase: first.settings.encryptionPassphrase,
                expectedDatasetID: winnerGenesis.datasetID
            )
            let profileIDs = Set(snapshot.document.apiKeyProfiles.map(\.id))
            if expectedProfileIDs.isSubset(of: profileIDs) {
                remoteObjectContainsBothProfiles = true
            }
        }
        XCTAssertTrue(remoteObjectContainsBothProfiles)
        let finalGenesisData = await transport.resource(
            named: ImmutableSyncSnapshotLayout.genesisFileName
        )
        let finalSuccessfulGenesisMoves = await transport.genesisSuccessfulAtomicMoveCount
        let finalLegacyPUTCount = await transport.legacyPUTCount
        XCTAssertEqual(finalGenesisData, winnerGenesisData)
        XCTAssertEqual(finalSuccessfulGenesisMoves, 1)
        XCTAssertEqual(finalLegacyPUTCount, 0)
    }

    func testHiddenObservedNonCarrierBranchFailsClosedWithoutWriting() async throws {
        let transport = AppendOnlyStatefulTransport()
        let first = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Initial"
        )
        let second = try AppendOnlyTestDevice(transport: transport)
        defer {
            first.cleanup()
            second.cleanup()
        }

        try await first.coordinator.saveSettings(first.settings)
        try await first.coordinator.synchronizeNow()
        try await second.coordinator.saveSettings(second.settings)
        try await second.coordinator.synchronizeNow()

        try first.store.saveUpdateTemplate(
            UpdateTemplate(name: "First branch", content: "First device")
        )
        try second.store.saveUpdateTemplate(
            UpdateTemplate(name: "Second branch", content: "Second device")
        )
        await transport.armNextTwoRepositoryListingsAsBarrier()
        async let firstBranchSync: Void = first.coordinator.synchronizeNow()
        async let secondBranchSync: Void = second.coordinator.synchronizeNow()
        try await firstBranchSync
        try await secondBranchSync

        let branchNames = Set(await transport.immutableObjectNames()).subtracting([
            ImmutableSyncSnapshotLayout.genesisFileName
        ])
        XCTAssertEqual(branchNames.count, 2)

        try await first.coordinator.synchronizeNow()
        let namesAfterMerge = Set(await transport.immutableObjectNames()).subtracting([
            ImmutableSyncSnapshotLayout.genesisFileName
        ])
        let mergedCarrierName = try XCTUnwrap(namesAfterMerge.subtracting(branchNames).first)
        XCTAssertEqual(namesAfterMerge.subtracting(branchNames).count, 1)
        let storedMergedCarrier = await transport.resource(named: mergedCarrierName)
        let mergedCarrierData = try XCTUnwrap(storedMergedCarrier)
        let mergedCarrier = try ImmutableSyncSnapshotCrypto.decryptObject(
            mergedCarrierData,
            fileName: mergedCarrierName,
            passphrase: first.settings.encryptionPassphrase
        )
        let parentBranchName = try XCTUnwrap(mergedCarrier.parent?.relativePath)
        let hiddenBranchName = try XCTUnwrap(
            branchNames.first(where: { $0 != parentBranchName })
        )
        XCTAssertNotEqual(hiddenBranchName, mergedCarrierName)
        await transport.hideFromListings(name: hiddenBranchName)

        try first.store.saveUpdateTemplate(
            UpdateTemplate(name: "Still pending", content: "Must not publish")
        )
        let PUTsBeforeFailure = await transport.totalPUTCount
        let MKCOLsBeforeFailure = await transport.totalMKCOLCount

        do {
            try await first.coordinator.synchronizeNow()
            XCTFail("Hiding any previously observed branch must be treated as rollback")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .rollbackDetected)
        }

        let PUTsAfterFailure = await transport.totalPUTCount
        let MKCOLsAfterFailure = await transport.totalMKCOLCount
        XCTAssertEqual(PUTsAfterFailure, PUTsBeforeFailure)
        XCTAssertEqual(MKCOLsAfterFailure, MKCOLsBeforeFailure)
        XCTAssertTrue(first.store.hasPendingSyncChanges())
        XCTAssertTrue(namesAfterMerge.contains(mergedCarrierName))
    }

    func testLegacySingleFileMigratesWithoutOverwriteAndAppendModeRemainsSticky() async throws {
        let transport = AppendOnlyStatefulTransport(etagMode: .strong)
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Legacy profile"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let storedLegacy = await transport.resource(
            named: WebDAVConfiguration.defaultRelativePath
        )
        let legacyBeforeMigration = try XCTUnwrap(storedLegacy)

        await transport.setETagMode(.weak)
        let migratedTemplate = UpdateTemplate(name: "Migrated", content: "Append-only")
        try device.store.saveUpdateTemplate(migratedTemplate)
        try await device.coordinator.synchronizeNow()

        let legacyAfterMigration = await transport.resource(
            named: WebDAVConfiguration.defaultRelativePath
        )
        XCTAssertEqual(legacyAfterMigration, legacyBeforeMigration)
        XCTAssertFalse(device.store.hasPendingSyncChanges())

        await transport.setETagMode(.strong)
        let stickyTemplate = UpdateTemplate(name: "Sticky", content: "Never rewrite genesis")
        try device.store.saveUpdateTemplate(stickyTemplate)
        let legacyPUTsBeforeStickySync = await transport.legacyPUTCount
        try await device.coordinator.synchronizeNow()

        let legacyPUTsAfterStickySync = await transport.legacyPUTCount
        let legacyAfterStickySync = await transport.resource(
            named: WebDAVConfiguration.defaultRelativePath
        )
        XCTAssertEqual(legacyPUTsAfterStickySync, legacyPUTsBeforeStickySync)
        XCTAssertEqual(legacyAfterStickySync, legacyBeforeMigration)
        let liveTemplateIDs = Set(device.store.loadUpdateTemplates().map(\.id))
        XCTAssertTrue(liveTemplateIDs.contains(migratedTemplate.id))
        XCTAssertTrue(liveTemplateIDs.contains(stickyTemplate.id))
    }

    func testAnchoredLegacyRejectsImmutableGenesisFromDifferentDatasetWithoutWriting() async throws {
        let transport = AppendOnlyStatefulTransport(etagMode: .strong)
        let device = try AppendOnlyTestDevice(
            transport: transport,
            initialProfileName: "Legacy profile"
        )
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let trustedDatasetID = try device.store.syncSnapshot().document.datasetID

        let foreignTemplateID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let foreignDatasetID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        XCTAssertNotEqual(foreignDatasetID, trustedDatasetID)
        let foreignDocument = SyncDocument(
            datasetID: foreignDatasetID,
            generation: 1,
            updateTemplates: [
                VersionedRecord(
                    id: foreignTemplateID,
                    order: 0,
                    revision: HLCRevision(wallTimeMilliseconds: 1_700_000_000_000),
                    writerDeviceID: "foreign-device",
                    value: SyncUpdateTemplateValue(
                        name: "Foreign template",
                        content: "Must not be imported"
                    )
                )
            ]
        )
        let foreignGenesis = try ImmutableSyncSnapshot.genesis(document: foreignDocument)
        let encryptedGenesis = try ImmutableSyncSnapshotCrypto.encrypt(
            foreignGenesis,
            passphrase: device.settings.encryptionPassphrase
        )
        let rootURL = try XCTUnwrap(URL(string: device.settings.rootURL))
        await transport.seedImmutableGenesis(encryptedGenesis.data, rootURL: rootURL)

        let pendingTemplate = UpdateTemplate(name: "Local pending", content: "Keep dirty")
        try device.store.saveUpdateTemplate(pendingTemplate)
        let PUTsBeforeFailure = await transport.totalPUTCount
        let MKCOLsBeforeFailure = await transport.totalMKCOLCount

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("An immutable genesis from another dataset must be rejected")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .remoteDatasetChanged)
        }

        let PUTsAfterFailure = await transport.totalPUTCount
        let MKCOLsAfterFailure = await transport.totalMKCOLCount
        let localSnapshot = try device.store.syncSnapshot()
        let localTemplateIDs = Set(device.store.loadUpdateTemplates().map(\.id))
        XCTAssertEqual(PUTsAfterFailure, PUTsBeforeFailure)
        XCTAssertEqual(MKCOLsAfterFailure, MKCOLsBeforeFailure)
        XCTAssertEqual(localSnapshot.document.datasetID, trustedDatasetID)
        XCTAssertTrue(localTemplateIDs.contains(pendingTemplate.id))
        XCTAssertFalse(localTemplateIDs.contains(foreignTemplateID))
        XCTAssertTrue(localSnapshot.isDirty)
    }
}

private struct ManualSyncFixture {
    let namespace: String
    let defaults: UserDefaults
    let configurationKeychain: KeychainStore
    let syncKeychain: KeychainStore
    let store: ConfigurationStore
    let transport: RejectingCountingTransport
    let coordinator: SyncCoordinator
    let settings: WebDAVSyncSettings

    init() throws {
        namespace = "SyncCoordinatorAppendOnlyTests.manual.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defaults.removePersistentDomain(forName: namespace)
        configurationKeychain = KeychainStore(service: "\(namespace).configuration")
        syncKeychain = KeychainStore(service: "\(namespace).sync")
        try configurationKeychain.deleteAll()
        try syncKeychain.deleteAll()

        let store = ConfigurationStore(defaults: defaults, keychain: configurationKeychain)
        let transport = RejectingCountingTransport()
        self.store = store
        self.transport = transport
        coordinator = SyncCoordinator(
            store: store,
            keychain: syncKeychain,
            clientFactory: { configuration in
                try WebDAVClient(configuration: configuration, transport: transport)
            }
        )
        settings = WebDAVSyncSettings(
            rootURL: "https://dav.example.com/root/",
            username: "user",
            webDAVPassword: "application-password",
            encryptionPassphrase: "correct horse battery"
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: namespace)
        try? configurationKeychain.deleteAll()
        try? syncKeychain.deleteAll()
    }
}

private final class AppendOnlyTestDevice {
    let namespace: String
    let defaults: UserDefaults
    let configurationKeychain: KeychainStore
    let syncKeychain: KeychainStore
    let store: ConfigurationStore
    let coordinator: SyncCoordinator
    let settings: WebDAVSyncSettings

    init(
        transport: AppendOnlyStatefulTransport,
        initialProfileName: String? = nil,
        retryDelaysNanoseconds: [UInt64] = [
            0,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000
        ]
    ) throws {
        namespace = "SyncCoordinatorAppendOnlyTests.device.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defaults.removePersistentDomain(forName: namespace)
        configurationKeychain = KeychainStore(service: "\(namespace).configuration")
        syncKeychain = KeychainStore(service: "\(namespace).sync")
        try configurationKeychain.deleteAll()
        try syncKeychain.deleteAll()

        let store = ConfigurationStore(defaults: defaults, keychain: configurationKeychain)
        self.store = store
        if let initialProfileName {
            try store.saveAPIKeyProfile(APIKeyProfile(
                name: initialProfileName,
                apiKey: "test-api-key",
                password: "test-install-password",
                updateTemplate: "test-release-notes"
            ))
        }
        coordinator = SyncCoordinator(
            store: store,
            keychain: syncKeychain,
            clientFactory: { configuration in
                try WebDAVClient(configuration: configuration, transport: transport)
            },
            retryDelaysNanoseconds: retryDelaysNanoseconds
        )
        settings = WebDAVSyncSettings(
            rootURL: "https://dav.example.com/root/",
            username: "user",
            webDAVPassword: "application-password",
            encryptionPassphrase: "correct horse battery"
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: namespace)
        try? configurationKeychain.deleteAll()
        try? syncKeychain.deleteAll()
    }
}

private actor RejectingCountingTransport: WebDAVTransport {
    private(set) var requestCount = 0

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> WebDAVTransportResponse {
        requestCount += 1
        return WebDAVTransportResponse(statusCode: 401, url: request.url)
    }
}

private actor AppendOnlyStatefulTransport: WebDAVTransport {
    enum ETagMode: Sendable {
        case strong
        case weak
        case missing
    }

    enum LockBehavior: Sendable {
        case unavailable
        case acceptsConcurrentExclusiveLocks
    }

    enum AtomicMoveBehavior: Sendable {
        case unavailable
        case safelyPreventsOverwrite
        case overwritesExistingDestination
    }

    enum ImmutableFormalReadFailure: Sendable {
        case serverError
        case transport
    }

    private let actualFilename: String
    private var etagMode: ETagMode
    private let lockBehavior: LockBehavior
    private let immutableCollectionListingStatusCode: Int?
    private var safelyEnforcesConditionalCreate: Bool
    private var atomicMoveBehavior: AtomicMoveBehavior
    private var immutableFormalReadFailures: [ImmutableFormalReadFailure]
    private var genesisListingOmissionsRemaining: Int
    private let immutableObjectRead404ResponsesAfterCreate: Int
    private var resources: [URL: Data] = [:]
    private var collections: Set<URL> = []
    private var hiddenNames: Set<String> = []
    private var etagSequence = 0
    private var requests: [URLRequest] = []
    private var lockSequence = 0
    private var repositoryListingBarrierRemaining = 0
    private var repositoryListingBarrierWaiters: [CheckedContinuation<Void, Never>] = []
    private var genesisCreateBarrierRemaining = 0
    private var genesisCreateBarrierWaiters: [CheckedContinuation<Void, Never>] = []
    private var genesisMoveBarrierRemaining = 0
    private var genesisMoveBarrierWaiters: [CheckedContinuation<Void, Never>] = []
    private var successfulGenesisCreates = 0
    private var successfulGenesisMoves = 0
    private var objectRead404sRemaining: [URL: Int] = [:]
    private var genesisReadsToDelay = 0
    private var immutableObjectReadsToDelay = 0
    private var genesisListingOmissionResponses = 0
    private var genesisRead404Responses = 0
    private var immutableObjectRead404Responses = 0

    init(
        actualFilename: String = WebDAVConfiguration.defaultRelativePath,
        etagMode: ETagMode = .weak,
        lockBehavior: LockBehavior = .unavailable,
        immutableCollectionListingStatusCode: Int? = nil,
        safelyEnforcesConditionalCreate: Bool = true,
        atomicMoveBehavior: AtomicMoveBehavior = .unavailable,
        immutableFormalReadFailures: [ImmutableFormalReadFailure] = [],
        genesisListingOmissionsAfterCreate: Int = 0,
        immutableObjectRead404ResponsesAfterCreate: Int = 0
    ) {
        self.actualFilename = actualFilename
        self.etagMode = etagMode
        self.lockBehavior = lockBehavior
        self.immutableCollectionListingStatusCode = immutableCollectionListingStatusCode
        self.safelyEnforcesConditionalCreate = safelyEnforcesConditionalCreate
        self.atomicMoveBehavior = atomicMoveBehavior
        self.immutableFormalReadFailures = immutableFormalReadFailures
        genesisListingOmissionsRemaining = genesisListingOmissionsAfterCreate
        self.immutableObjectRead404ResponsesAfterCreate =
            immutableObjectRead404ResponsesAfterCreate
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> WebDAVTransportResponse {
        requests.append(request)
        let url = try XCTUnwrap(request.url)

        switch request.httpMethod {
        case "MKCOL":
            let collection = normalizedCollectionURL(url)
            if collections.contains(collection) {
                return response(statusCode: 405, url: url)
            }
            collections.insert(collection)
            return response(statusCode: 201, url: url)

        case "PROPFIND":
            let collection = normalizedCollectionURL(url)
            if request.value(forHTTPHeaderField: "Depth") == "1",
               collection.lastPathComponent == actualFilename + ".d",
               let immutableCollectionListingStatusCode {
                return response(statusCode: immutableCollectionListingStatusCode, url: url)
            }
            guard collections.contains(collection) else {
                return response(statusCode: 404, url: url)
            }
            let responseData = multiStatusXML(
                for: collection,
                includeChildren: request.value(forHTTPHeaderField: "Depth") == "1"
            )
            if request.value(forHTTPHeaderField: "Depth") == "1",
               collection.lastPathComponent == actualFilename + ".d" {
                await waitAtRepositoryListingBarrierIfNeeded()
            }
            return response(
                data: responseData,
                statusCode: 207,
                url: url
            )

        case "GET":
            if resources[url] != nil,
               isFormalImmutableChild(url),
               !immutableFormalReadFailures.isEmpty {
                let failure = immutableFormalReadFailures.removeFirst()
                switch failure {
                case .serverError:
                    return response(statusCode: 503, url: url)
                case .transport:
                    throw WebDAVError.transportFailure("synthetic immutable read failure")
                }
            }
            if resources[url] != nil,
               url.deletingLastPathComponent().lastPathComponent == actualFilename + ".d" {
                if url.lastPathComponent == ImmutableSyncSnapshotLayout.genesisFileName,
                   genesisReadsToDelay > 0 {
                    genesisReadsToDelay -= 1
                    genesisRead404Responses += 1
                    return response(statusCode: 404, url: url)
                }
                if url.lastPathComponent != ImmutableSyncSnapshotLayout.genesisFileName,
                   immutableObjectReadsToDelay > 0 {
                    immutableObjectReadsToDelay -= 1
                    immutableObjectRead404Responses += 1
                    return response(statusCode: 404, url: url)
                }
            }
            if let remaining = objectRead404sRemaining[url], remaining > 0 {
                objectRead404sRemaining[url] = remaining - 1
                immutableObjectRead404Responses += 1
                return response(statusCode: 404, url: url)
            }
            guard let data = resources[url] else {
                return response(statusCode: 404, url: url)
            }
            return response(
                data: data,
                statusCode: 200,
                headers: etagHeaders(),
                url: url
            )

        case "PUT":
            let isGenesisCreate = url.lastPathComponent == ImmutableSyncSnapshotLayout.genesisFileName
                && url.deletingLastPathComponent().lastPathComponent == actualFilename + ".d"
                && request.value(forHTTPHeaderField: "If-None-Match") == "*"
            let isImmutableObjectCreate = !isGenesisCreate
                && url.deletingLastPathComponent().lastPathComponent == actualFilename + ".d"
                && url.lastPathComponent.hasSuffix(".pgy")
                && request.value(forHTTPHeaderField: "If-None-Match") == "*"
            if isGenesisCreate {
                await waitAtGenesisCreateBarrierIfNeeded()
            }
            let existed = resources[url] != nil
            if request.value(forHTTPHeaderField: "If-None-Match") == "*", existed {
                guard !safelyEnforcesConditionalCreate else {
                    return response(statusCode: 412, url: url)
                }
            }
            if let expectedETag = request.value(forHTTPHeaderField: "If-Match"),
               expectedETag != etagHeaders()["ETag"] {
                return response(statusCode: 412, url: url)
            }
            resources[url] = request.httpBody ?? Data()
            etagSequence += 1
            if isGenesisCreate, !existed {
                successfulGenesisCreates += 1
            }
            if isImmutableObjectCreate, !existed,
               immutableObjectRead404ResponsesAfterCreate > 0 {
                objectRead404sRemaining[url] = immutableObjectRead404ResponsesAfterCreate
            }
            return response(statusCode: existed ? 204 : 201, url: url)

        case "MOVE":
            guard request.value(forHTTPHeaderField: "Overwrite") == "F",
                  let destinationValue = request.value(forHTTPHeaderField: "Destination"),
                  let destinationURL = URL(string: destinationValue),
                  let data = resources[url] else {
                return response(statusCode: 400, url: url)
            }
            let isGenesisMove = destinationURL.lastPathComponent
                == ImmutableSyncSnapshotLayout.genesisFileName
                && destinationURL.deletingLastPathComponent().lastPathComponent
                    == actualFilename + ".d"
            if isGenesisMove {
                await waitAtGenesisMoveBarrierIfNeeded()
            }
            switch atomicMoveBehavior {
            case .unavailable:
                return response(statusCode: 405, url: url)
            case .safelyPreventsOverwrite:
                guard resources[destinationURL] == nil else {
                    return response(statusCode: 409, url: url)
                }
                resources[destinationURL] = data
                resources.removeValue(forKey: url)
                if isGenesisMove {
                    successfulGenesisMoves += 1
                }
                return response(statusCode: 201, url: url)
            case .overwritesExistingDestination:
                let destinationExists = resources[destinationURL] != nil
                resources[destinationURL] = data
                resources.removeValue(forKey: url)
                if isGenesisMove, !destinationExists {
                    successfulGenesisMoves += 1
                }
                return response(statusCode: destinationExists ? 204 : 201, url: url)
            }

        case "DELETE":
            let collection = normalizedCollectionURL(url)
            if collections.contains(collection) {
                guard !resources.keys.contains(where: {
                    $0.deletingLastPathComponent() == collection
                }) else {
                    return response(statusCode: 409, url: url)
                }
                collections.remove(collection)
                return response(statusCode: 204, url: url)
            }
            guard resources.removeValue(forKey: url) != nil else {
                return response(statusCode: 404, url: url)
            }
            return response(statusCode: 204, url: url)

        case "LOCK":
            switch lockBehavior {
            case .unavailable:
                return response(statusCode: 405, url: url)
            case .acceptsConcurrentExclusiveLocks:
                lockSequence += 1
                let token = "opaquelocktoken:unsafe-\(lockSequence)"
                return lockResponse(token: token, url: url)
            }

        case "UNLOCK":
            return response(statusCode: 204, url: url)

        default:
            return response(statusCode: 405, url: url)
        }
    }

    var requestCount: Int {
        requests.count
    }

    var immutableObjectPUTCount: Int {
        requests.filter { request in
            request.httpMethod == "PUT"
                && request.url?.deletingLastPathComponent().lastPathComponent == actualFilename + ".d"
                && request.url?.lastPathComponent.hasSuffix(".pgy") == true
        }.count
    }

    var immutableCollectionMKCOLCount: Int {
        requests.filter { request in
            request.httpMethod == "MKCOL"
                && request.url?.lastPathComponent == actualFilename + ".d"
        }.count
    }

    var genesisCreateOnlyPUTCount: Int {
        requests.filter { request in
            request.httpMethod == "PUT"
                && request.url?.lastPathComponent == ImmutableSyncSnapshotLayout.genesisFileName
                && request.url?.deletingLastPathComponent().lastPathComponent == actualFilename + ".d"
                && request.value(forHTTPHeaderField: "If-None-Match") == "*"
        }.count
    }

    var genesisSuccessfulCreateCount: Int {
        successfulGenesisCreates
    }

    var genesisListingOmissionResponseCount: Int {
        genesisListingOmissionResponses
    }

    var genesisRead404ResponseCount: Int {
        genesisRead404Responses
    }

    var immutableObjectRead404ResponseCount: Int {
        immutableObjectRead404Responses
    }

    var totalPUTCount: Int {
        requests.filter { $0.httpMethod == "PUT" }.count
    }

    var totalMKCOLCount: Int {
        requests.filter { $0.httpMethod == "MKCOL" }.count
    }

    var atomicMoveRequestCount: Int {
        requests.filter { $0.httpMethod == "MOVE" }.count
    }

    var atomicMoveProbeMoveCount: Int {
        requests.filter { request in
            guard request.httpMethod == "MOVE", let url = request.url else {
                return false
            }
            return url.deletingLastPathComponent().lastPathComponent
                .hasPrefix("PGYMacMenu-move-probe-")
        }.count
    }

    var genesisAtomicMoveCount: Int {
        requests.filter { request in
            guard request.httpMethod == "MOVE",
                  let destinationValue = request.value(forHTTPHeaderField: "Destination"),
                  let destinationURL = URL(string: destinationValue) else {
                return false
            }
            return destinationURL.lastPathComponent == ImmutableSyncSnapshotLayout.genesisFileName
                && destinationURL.deletingLastPathComponent().lastPathComponent
                    == actualFilename + ".d"
        }.count
    }

    var genesisSuccessfulAtomicMoveCount: Int {
        successfulGenesisMoves
    }

    var legacyPUTCount: Int {
        requests.filter {
            $0.httpMethod == "PUT" && $0.url?.lastPathComponent == actualFilename
        }.count
    }

    var permanentSyncResourceRequestCount: Int {
        requests.filter { $0.url?.lastPathComponent == actualFilename }.count
    }

    var immutableCollectionRequestCount: Int {
        requests.filter { request in
            request.url?.pathComponents.contains(actualFilename + ".d") == true
        }.count
    }

    var immutableCollectionListingRequestCount: Int {
        requests.filter { request in
            request.httpMethod == "PROPFIND"
                && request.value(forHTTPHeaderField: "Depth") == "1"
                && request.url?.lastPathComponent == actualFilename + ".d"
        }.count
    }

    var temporaryProbeMethods: [String] {
        requests.compactMap { request in
            guard let name = request.url?.lastPathComponent,
                  name.hasPrefix("PGYMacMenu-probe-"),
                  name.hasSuffix(".tmp") else {
                return nil
            }
            return request.httpMethod
        }
    }

    func setETagMode(_ mode: ETagMode) {
        etagMode = mode
    }

    func setConditionalCreateSafety(_ isSafe: Bool) {
        safelyEnforcesConditionalCreate = isSafe
    }

    func setAtomicMoveBehavior(_ behavior: AtomicMoveBehavior) {
        atomicMoveBehavior = behavior
    }

    func delayNextGenesisReads(count: Int) {
        genesisReadsToDelay = max(count, 0)
    }

    func delayNextImmutableObjectReads(count: Int) {
        immutableObjectReadsToDelay = max(count, 0)
    }

    func armNextTwoRepositoryListingsAsBarrier() {
        repositoryListingBarrierRemaining = 2
        repositoryListingBarrierWaiters.removeAll()
    }

    func armNextTwoRepositoryListingsAndGenesisCreatesAsBarriers() {
        repositoryListingBarrierRemaining = 2
        repositoryListingBarrierWaiters.removeAll()
        genesisCreateBarrierRemaining = 2
        genesisCreateBarrierWaiters.removeAll()
    }

    func armNextTwoRepositoryListingsAndGenesisMovesAsBarriers() {
        repositoryListingBarrierRemaining = 2
        repositoryListingBarrierWaiters.removeAll()
        genesisMoveBarrierRemaining = 2
        genesisMoveBarrierWaiters.removeAll()
    }

    func hideFromListings(name: String) {
        hiddenNames.insert(name)
    }

    func showInListings(name: String) {
        hiddenNames.remove(name)
    }

    func removeImmutableRepository() {
        collections = collections.filter { $0.lastPathComponent != actualFilename + ".d" }
        resources = resources.filter {
            $0.key.deletingLastPathComponent().lastPathComponent != actualFilename + ".d"
        }
    }

    func resource(named name: String) -> Data? {
        resources.first { $0.key.lastPathComponent == name }?.value
    }

    func replaceImmutableGenesis(with data: Data) -> Bool {
        guard let genesisURL = resources.keys.first(where: {
            $0.lastPathComponent == ImmutableSyncSnapshotLayout.genesisFileName
                && $0.deletingLastPathComponent().lastPathComponent == actualFilename + ".d"
        }) else {
            return false
        }
        resources[genesisURL] = data
        etagSequence += 1
        return true
    }

    func immutableObjectNames() -> [String] {
        resources.keys
            .filter {
                $0.deletingLastPathComponent().lastPathComponent == actualFilename + ".d"
                    && $0.lastPathComponent.hasSuffix(".pgy")
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    func seedLegacyResource(_ data: Data, rootURL: URL) {
        let url = rootURL.appendingPathComponent(actualFilename, isDirectory: false)
        resources[url] = data
        etagSequence += 1
    }

    func seedImmutableGenesis(_ data: Data, rootURL: URL) {
        let resourceURL = rootURL.appendingPathComponent(actualFilename, isDirectory: false)
        let collectionURL = resourceURL.deletingLastPathComponent()
            .appendingPathComponent(actualFilename + ".d", isDirectory: true)
        collections.insert(collectionURL)
        resources[collectionURL.appendingPathComponent(
            ImmutableSyncSnapshotLayout.genesisFileName,
            isDirectory: false
        )] = data
        etagSequence += 1
    }

    func seedImmutableObject(_ data: Data, named name: String, rootURL: URL) {
        let resourceURL = rootURL.appendingPathComponent(actualFilename, isDirectory: false)
        let collectionURL = resourceURL.deletingLastPathComponent()
            .appendingPathComponent(actualFilename + ".d", isDirectory: true)
        collections.insert(collectionURL)
        resources[collectionURL.appendingPathComponent(name, isDirectory: false)] = data
        etagSequence += 1
    }

    private func waitAtRepositoryListingBarrierIfNeeded() async {
        guard repositoryListingBarrierRemaining > 0 else { return }
        repositoryListingBarrierRemaining -= 1
        if repositoryListingBarrierRemaining == 0 {
            let waiters = repositoryListingBarrierWaiters
            repositoryListingBarrierWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            repositoryListingBarrierWaiters.append(continuation)
        }
    }

    private func waitAtGenesisCreateBarrierIfNeeded() async {
        guard genesisCreateBarrierRemaining > 0 else { return }
        genesisCreateBarrierRemaining -= 1
        if genesisCreateBarrierRemaining == 0 {
            let waiters = genesisCreateBarrierWaiters
            genesisCreateBarrierWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            genesisCreateBarrierWaiters.append(continuation)
        }
    }

    private func waitAtGenesisMoveBarrierIfNeeded() async {
        guard genesisMoveBarrierRemaining > 0 else { return }
        genesisMoveBarrierRemaining -= 1
        if genesisMoveBarrierRemaining == 0 {
            let waiters = genesisMoveBarrierWaiters
            genesisMoveBarrierWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            genesisMoveBarrierWaiters.append(continuation)
        }
    }

    private func etagHeaders() -> [String: String] {
        switch etagMode {
        case .strong:
            return ["ETag": "\"etag-\(etagSequence)\""]
        case .weak:
            return ["ETag": "W/\"etag-\(etagSequence)\""]
        case .missing:
            return [:]
        }
    }

    private func isFormalImmutableChild(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().lastPathComponent == actualFilename + ".d" else {
            return false
        }
        return url.lastPathComponent == ImmutableSyncSnapshotLayout.genesisFileName
            || url.lastPathComponent.hasSuffix(".pgy")
    }

    private func multiStatusXML(for collection: URL, includeChildren: Bool) -> Data {
        var responses = [collectionResponse(href: collection.path, isCollection: true)]
        if includeChildren {
            var namesHiddenForThisResponse = hiddenNames
            let genesisURL = collection.appendingPathComponent(
                ImmutableSyncSnapshotLayout.genesisFileName,
                isDirectory: false
            )
            if resources[genesisURL] != nil, genesisListingOmissionsRemaining > 0 {
                genesisListingOmissionsRemaining -= 1
                genesisListingOmissionResponses += 1
                namesHiddenForThisResponse.insert(ImmutableSyncSnapshotLayout.genesisFileName)
            }
            responses += resources.keys
                .filter {
                    $0.deletingLastPathComponent() == collection
                        && !namesHiddenForThisResponse.contains($0.lastPathComponent)
                }
                .sorted { $0.absoluteString < $1.absoluteString }
                .map { collectionResponse(href: $0.path, isCollection: false) }
        }
        return Data(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                .appending("<D:multistatus xmlns:D=\"DAV:\">")
                .appending(responses.joined())
                .appending("</D:multistatus>")
                .utf8
        )
    }

    private func collectionResponse(href: String, isCollection: Bool) -> String {
        let resourceType = isCollection ? "<D:collection/>" : ""
        return """
        <D:response><D:href>\(href)</D:href><D:propstat><D:prop><D:resourcetype>\(resourceType)</D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        """
    }

    private func normalizedCollectionURL(_ url: URL) -> URL {
        guard !url.hasDirectoryPath else { return url }
        return url.appendingPathComponent("", isDirectory: true)
    }

    private func response(
        data: Data = Data(),
        statusCode: Int,
        headers: [String: String] = [:],
        url: URL
    ) -> WebDAVTransportResponse {
        WebDAVTransportResponse(
            data: data,
            statusCode: statusCode,
            headers: headers,
            url: url
        )
    }

    private func lockResponse(token: String, url: URL) -> WebDAVTransportResponse {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:timeout>Second-120</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>
        """
        return response(
            data: Data(body.utf8),
            statusCode: 200,
            headers: [
                "Lock-Token": "<\(token)>",
                "Timeout": "Second-120"
            ],
            url: url
        )
    }
}
