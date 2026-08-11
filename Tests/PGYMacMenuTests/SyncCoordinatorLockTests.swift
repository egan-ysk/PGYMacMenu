import Foundation
import XCTest
@testable import PGYMacMenu

final class SyncCoordinatorLockTests: XCTestCase {
    func testWeakETagUsesExclusiveLockAfterInitialCreate() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .weak)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let baselineLockCount = await transport.actualLockRequestCount

        let template = UpdateTemplate(name: "Locked update", content: "Preserved")
        try device.store.saveUpdateTemplate(template)
        try await device.coordinator.synchronizeNow()

        XCTAssertFalse(device.store.hasPendingSyncChanges())
        let finalLockCount = await transport.actualLockRequestCount
        let lockedPutCount = await transport.actualLockedPutCount
        XCTAssertGreaterThan(finalLockCount, baselineLockCount)
        XCTAssertGreaterThan(lockedPutCount, 0)
        let storedRemoteData = await transport.actualResourceData()
        let remoteData = try XCTUnwrap(storedRemoteData)
        let remote = try SyncCrypto.decryptDocument(
            from: remoteData,
            passphrase: device.settings.encryptionPassphrase
        )
        XCTAssertEqual(
            remote.updateTemplates.first(where: { $0.id == template.id })?.value?.content,
            template.content
        )
    }

    func testMissingETagLockFailureKeepsLocalChangesDirty() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .missing)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let template = UpdateTemplate(name: "Pending", content: "Retry later")
        try device.store.saveUpdateTemplate(template)
        await transport.failNextActualLock(statusCode: 405)

        do {
            try await device.coordinator.synchronizeNow()
            XCTFail("A server without a usable lock must reject the update")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .exclusiveLockUnavailable)
        }

        XCTAssertTrue(device.store.hasPendingSyncChanges())
        let storedRemoteData = await transport.actualResourceData()
        let remoteData = try XCTUnwrap(storedRemoteData)
        let remote = try SyncCrypto.decryptDocument(
            from: remoteData,
            passphrase: device.settings.encryptionPassphrase
        )
        XCTAssertNil(remote.updateTemplates.first(where: { $0.id == template.id }))
    }

    func testStrongETagPathDoesNotIssueLockRequests() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .strong)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        try device.store.saveUpdateTemplate(
            UpdateTemplate(name: "Strong ETag", content: "Conditional PUT")
        )
        try await device.coordinator.synchronizeNow()

        let lockRequestCount = await transport.actualLockRequestCount
        let lockedPutCount = await transport.actualLockedPutCount
        let ifMatchPutCount = await transport.actualIfMatchPutCount
        XCTAssertEqual(lockRequestCount, 0)
        XCTAssertEqual(lockedPutCount, 0)
        XCTAssertGreaterThan(ifMatchPutCount, 0)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testUnsafeStrongETagFallsBackToStrictExclusiveLock() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .strong)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let restartedCoordinator = coordinator(for: device, transport: transport)
        await transport.setConditionalUpdateSafety(false)
        let template = UpdateTemplate(name: "Locked fallback", content: "Preserved")
        try device.store.saveUpdateTemplate(template)
        let lockedPUTsBefore = await transport.actualLockedPutCount
        let matchingPUTsBefore = await transport.actualIfMatchPutCount

        try await restartedCoordinator.synchronizeNow()

        let lockedPUTsAfter = await transport.actualLockedPutCount
        let matchingPUTsAfter = await transport.actualIfMatchPutCount
        let probeIfMatchCount = await transport.probeIfMatchPutCount
        let immutablePUTCount = await transport.immutableObjectPUTCount
        XCTAssertGreaterThan(lockedPUTsAfter, lockedPUTsBefore)
        XCTAssertEqual(matchingPUTsAfter, matchingPUTsBefore)
        XCTAssertGreaterThan(probeIfMatchCount, 0)
        XCTAssertEqual(immutablePUTCount, 0)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testUnsafeStrongETagAndLockMigrateToImmutableSnapshots() async throws {
        let transport = LockingCoordinatorTransport(
            etagMode: .strong,
            supportsCollections: true
        )
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let storedLegacyBefore = await transport.actualResourceData()
        let legacyBefore = try XCTUnwrap(storedLegacyBefore)
        let restartedCoordinator = coordinator(for: device, transport: transport)
        await transport.setConditionalUpdateSafety(false)
        await transport.allowNextProbeUnprotectedPUTWhileLocked()
        let template = UpdateTemplate(name: "Append fallback", content: "Preserved")
        try device.store.saveUpdateTemplate(template)
        let actualPUTsBefore = await transport.actualPutRequestCount

        try await restartedCoordinator.synchronizeNow()

        let legacyAfter = await transport.actualResourceData()
        let actualPUTsAfter = await transport.actualPutRequestCount
        let immutablePUTCount = await transport.immutableObjectPUTCount
        XCTAssertEqual(legacyAfter, legacyBefore)
        XCTAssertEqual(actualPUTsAfter, actualPUTsBefore)
        XCTAssertGreaterThan(immutablePUTCount, 0)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
        let liveTemplateIDs = Set(device.store.loadUpdateTemplates().map(\.id))
        XCTAssertTrue(liveTemplateIDs.contains(template.id))
    }

    func testManualSyncAttestsStrongETagWhenConnectionTestWasSkipped() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .strong)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        let probesBeforeSync = await transport.probeIfMatchPutCount
        XCTAssertEqual(probesBeforeSync, 0)

        try await device.coordinator.synchronizeNow()

        let probesAfterSync = await transport.probeIfMatchPutCount
        XCTAssertGreaterThan(probesAfterSync, 0)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testSavingAfterConnectionTestRequiresStrongETagReattestation() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .strong)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.testConnection(device.settings)
        let probesAfterTest = await transport.probeIfMatchPutCount
        XCTAssertGreaterThan(probesAfterTest, 0)

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()

        let probesAfterSync = await transport.probeIfMatchPutCount
        XCTAssertGreaterThan(probesAfterSync, probesAfterTest)
        XCTAssertFalse(device.store.hasPendingSyncChanges())
    }

    func testRestartDoesNotReattestWeakETagEndpointUntilManualSync() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .weak)
        let device = try makeDevice(transport: transport, initialProfileName: "Initial")
        defer { device.cleanup() }

        try await device.coordinator.saveSettings(device.settings)
        try await device.coordinator.synchronizeNow()
        let pendingTemplate = UpdateTemplate(name: "Pending after restart", content: "Keep dirty")
        try device.store.saveUpdateTemplate(pendingTemplate)

        let storedRemoteBeforeRestart = await transport.actualResourceData()
        let remoteBeforeRestart = try XCTUnwrap(storedRemoteBeforeRestart)
        let actualPUTsBeforeRestart = await transport.actualPutRequestCount
        let actualLOCKsBeforeRestart = await transport.actualLockRequestCount
        let probeLOCKsBeforeRestart = await transport.probeLockRequestCount
        await transport.allowNextProbeUnprotectedPUTWhileLocked()

        let restartedCoordinator = SyncCoordinator(
            store: device.store,
            keychain: device.syncKeychain,
            clientFactory: { configuration in
                try WebDAVClient(configuration: configuration, transport: transport)
            }
        )
        await restartedCoordinator.prepareOnLaunch()

        XCTAssertTrue(device.store.hasPendingSyncChanges())
        let status = await restartedCoordinator.currentStatus()
        XCTAssertEqual(status, .pending)

        let actualPUTsAfterRestart = await transport.actualPutRequestCount
        let actualLOCKsAfterRestart = await transport.actualLockRequestCount
        let probeLOCKsAfterRestart = await transport.probeLockRequestCount
        XCTAssertEqual(actualPUTsAfterRestart, actualPUTsBeforeRestart)
        XCTAssertEqual(actualLOCKsAfterRestart, actualLOCKsBeforeRestart)
        XCTAssertEqual(probeLOCKsAfterRestart, probeLOCKsBeforeRestart)
        let remoteAfterRestart = await transport.actualResourceData()
        XCTAssertEqual(remoteAfterRestart, remoteBeforeRestart)

        do {
            try await restartedCoordinator.synchronizeNow()
            XCTFail("The unsafe lock probe must fail once manual sync is requested")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeExclusiveLock)
        }
        let probeLOCKsAfterManualSync = await transport.probeLockRequestCount
        XCTAssertGreaterThan(probeLOCKsAfterManualSync, probeLOCKsBeforeRestart)
        XCTAssertTrue(device.store.hasPendingSyncChanges())
    }

    func testTwoDevicesWithWeakETagsSerializeAndMergeAfterLockAcquisition() async throws {
        let transport = LockingCoordinatorTransport(etagMode: .weak)
        let first = try makeDevice(transport: transport, initialProfileName: "Initial")
        let second = try makeDevice(transport: transport)
        defer {
            first.cleanup()
            second.cleanup()
        }

        try await first.coordinator.saveSettings(first.settings)
        try await first.coordinator.synchronizeNow()
        try await second.coordinator.saveSettings(second.settings)
        try await second.coordinator.synchronizeNow()

        let firstTemplate = UpdateTemplate(name: "First device", content: "First change")
        let secondTemplate = UpdateTemplate(name: "Second device", content: "Second change")
        try first.store.saveUpdateTemplate(firstTemplate)
        try second.store.saveUpdateTemplate(secondTemplate)

        await transport.armNextTwoActualGETsAsBarrier()
        await transport.holdNextActualLockUntilConflict()
        let firstSync = Task { try await first.coordinator.synchronizeNow() }
        let secondSync = Task { try await second.coordinator.synchronizeNow() }
        try await firstSync.value
        try await secondSync.value

        XCTAssertFalse(first.store.hasPendingSyncChanges())
        XCTAssertFalse(second.store.hasPendingSyncChanges())
        let maximumConcurrentLocks = await transport.maximumConcurrentActualLocks
        let rejectedLockCount = await transport.rejectedActualLockCount
        XCTAssertEqual(maximumConcurrentLocks, 1)
        XCTAssertGreaterThan(rejectedLockCount, 0)

        let storedRemoteData = await transport.actualResourceData()
        let remoteData = try XCTUnwrap(storedRemoteData)
        let remote = try SyncCrypto.decryptDocument(
            from: remoteData,
            passphrase: first.settings.encryptionPassphrase
        )
        let liveTemplateIDs = Set(remote.updateTemplates.compactMap { record in
            record.value == nil ? nil : record.id
        })
        XCTAssertTrue(liveTemplateIDs.contains(firstTemplate.id))
        XCTAssertTrue(liveTemplateIDs.contains(secondTemplate.id))
    }

    private func makeDevice(
        transport: LockingCoordinatorTransport,
        initialProfileName: String? = nil
    ) throws -> LockTestDevice {
        let namespace = "SyncCoordinatorLockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defaults.removePersistentDomain(forName: namespace)
        let configurationKeychain = KeychainStore(service: "\(namespace).configuration")
        let syncKeychain = KeychainStore(service: "\(namespace).sync")
        try configurationKeychain.deleteAll()
        try syncKeychain.deleteAll()

        let store = ConfigurationStore(defaults: defaults, keychain: configurationKeychain)
        if let initialProfileName {
            try store.saveAPIKeyProfile(APIKeyProfile(
                name: initialProfileName,
                apiKey: "test-api-key",
                password: "test-install-password",
                updateTemplate: "test-release-notes"
            ))
        }
        let coordinator = SyncCoordinator(
            store: store,
            keychain: syncKeychain,
            clientFactory: { configuration in
                try WebDAVClient(configuration: configuration, transport: transport)
            }
        )
        return LockTestDevice(
            namespace: namespace,
            defaults: defaults,
            configurationKeychain: configurationKeychain,
            syncKeychain: syncKeychain,
            store: store,
            coordinator: coordinator
        )
    }

    private func coordinator(
        for device: LockTestDevice,
        transport: LockingCoordinatorTransport
    ) -> SyncCoordinator {
        SyncCoordinator(
            store: device.store,
            keychain: device.syncKeychain,
            clientFactory: { configuration in
                try WebDAVClient(configuration: configuration, transport: transport)
            }
        )
    }
}

private final class LockTestDevice {
    let namespace: String
    let defaults: UserDefaults
    let configurationKeychain: KeychainStore
    let syncKeychain: KeychainStore
    let store: ConfigurationStore
    let coordinator: SyncCoordinator
    let settings = WebDAVSyncSettings(
        rootURL: "https://dav.example.com/root/",
        username: "test-user",
        webDAVPassword: "test-webdav-password",
        encryptionPassphrase: "correct horse battery"
    )

    init(
        namespace: String,
        defaults: UserDefaults,
        configurationKeychain: KeychainStore,
        syncKeychain: KeychainStore,
        store: ConfigurationStore,
        coordinator: SyncCoordinator
    ) {
        self.namespace = namespace
        self.defaults = defaults
        self.configurationKeychain = configurationKeychain
        self.syncKeychain = syncKeychain
        self.store = store
        self.coordinator = coordinator
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: namespace)
        try? configurationKeychain.deleteAll()
        try? syncKeychain.deleteAll()
    }
}

private actor LockingCoordinatorTransport: WebDAVTransport {
    enum ETagMode: Sendable {
        case strong
        case weak
        case missing
    }

    private struct Resource: Sendable {
        var data: Data
        var revision: Int
    }

    private let actualFilename = WebDAVConfiguration.defaultRelativePath
    private let etagMode: ETagMode
    private let supportsCollections: Bool
    private var safelyEnforcesConditionalUpdate: Bool
    private var resources: [URL: Resource] = [:]
    private var collections: Set<URL> = []
    private var activeLocks: [URL: String] = [:]
    private var revisionSequence = 0
    private var lockSequence = 0
    private var nextActualLockFailure: Int?
    private var allowUnsafeProbePUT = false

    private(set) var actualLockRequestCount = 0
    private(set) var probeLockRequestCount = 0
    private(set) var rejectedActualLockCount = 0
    private(set) var actualPutRequestCount = 0
    private(set) var actualLockedPutCount = 0
    private(set) var actualIfMatchPutCount = 0
    private(set) var probeIfMatchPutCount = 0
    private(set) var immutableObjectPUTCount = 0
    private(set) var maximumConcurrentActualLocks = 0

    private var actualGETBarrierTarget = 0
    private var actualGETBarrierArrivals = 0
    private var actualGETBarrierWaiters: [CheckedContinuation<WebDAVTransportResponse, Never>] = []

    private var shouldHoldNextActualLock = false
    private var heldActualLockResponse: CheckedContinuation<WebDAVTransportResponse, Never>?

    init(
        etagMode: ETagMode,
        supportsCollections: Bool = false,
        safelyEnforcesConditionalUpdate: Bool = true
    ) {
        self.etagMode = etagMode
        self.supportsCollections = supportsCollections
        self.safelyEnforcesConditionalUpdate = safelyEnforcesConditionalUpdate
    }

    func armNextTwoActualGETsAsBarrier() {
        precondition(actualGETBarrierTarget == 0)
        actualGETBarrierTarget = 2
        actualGETBarrierArrivals = 0
    }

    func holdNextActualLockUntilConflict() {
        precondition(heldActualLockResponse == nil)
        shouldHoldNextActualLock = true
    }

    func failNextActualLock(statusCode: Int) {
        nextActualLockFailure = statusCode
    }

    func allowNextProbeUnprotectedPUTWhileLocked() {
        allowUnsafeProbePUT = true
    }

    func setConditionalUpdateSafety(_ isSafe: Bool) {
        safelyEnforcesConditionalUpdate = isSafe
    }

    func actualResourceData() -> Data? {
        resources.first(where: { $0.key.lastPathComponent == actualFilename })?.value.data
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> WebDAVTransportResponse {
        guard let url = request.url else {
            throw WebDAVError.invalidResponse
        }
        let method = request.httpMethod ?? ""
        let isActual = url.lastPathComponent == actualFilename

        switch method {
        case "MKCOL":
            let collection = normalizedCollectionURL(url)
            if collection.lastPathComponent.hasSuffix(".d"), !supportsCollections {
                return response(statusCode: 405, url: url)
            }
            if collections.contains(collection) {
                return response(statusCode: 405, url: url)
            }
            collections.insert(collection)
            return response(statusCode: 201, url: url)
        case "PROPFIND":
            let collection = normalizedCollectionURL(url)
            guard collections.contains(collection) else {
                return response(statusCode: 404, url: url)
            }
            return response(
                data: multiStatusXML(
                    for: collection,
                    includeChildren: request.value(forHTTPHeaderField: "Depth") == "1"
                ),
                statusCode: 207,
                url: url
            )
        case "GET":
            guard let resource = resources[url] else {
                return response(statusCode: 404, url: url)
            }
            let result = response(
                data: resource.data,
                statusCode: 200,
                headers: etagHeaders(for: resource),
                url: url
            )
            if isActual, actualGETBarrierTarget > 0 {
                return await passActualGETBarrier(with: result)
            }
            return result
        case "PUT":
            return handlePUT(request, url: url, isActual: isActual)
        case "DELETE":
            return handleDELETE(request, url: url)
        case "LOCK":
            return await handleLOCK(url: url, isActual: isActual)
        case "UNLOCK":
            return handleUNLOCK(request, url: url)
        default:
            return response(statusCode: 405, url: url)
        }
    }

    private func handlePUT(
        _ request: URLRequest,
        url: URL,
        isActual: Bool
    ) -> WebDAVTransportResponse {
        let lockCondition = request.value(forHTTPHeaderField: "If")
        if isActual {
            actualPutRequestCount += 1
        }
        if let activeToken = activeLocks[url] {
            if !isActual, lockCondition == nil, allowUnsafeProbePUT {
                allowUnsafeProbePUT = false
            } else {
                guard lockCondition == "(\(activeToken))" else {
                    return response(statusCode: 423, url: url)
                }
            }
        } else if lockCondition != nil {
            return response(statusCode: 412, url: url)
        }

        if request.value(forHTTPHeaderField: "If-None-Match") == "*", resources[url] != nil {
            return response(statusCode: 412, url: url)
        }
        if let expected = request.value(forHTTPHeaderField: "If-Match") {
            if isActual {
                actualIfMatchPutCount += 1
            } else {
                probeIfMatchPutCount += 1
            }
            if safelyEnforcesConditionalUpdate,
               resources[url].map({ strongETag(for: $0) }) != expected {
                return response(statusCode: 412, url: url)
            }
        }

        let existed = resources[url] != nil
        revisionSequence += 1
        let resource = Resource(data: request.httpBody ?? Data(), revision: revisionSequence)
        resources[url] = resource
        if isActual, lockCondition != nil {
            actualLockedPutCount += 1
        }
        if url.deletingLastPathComponent().lastPathComponent == actualFilename + ".d",
           url.lastPathComponent.hasSuffix(".pgy") {
            immutableObjectPUTCount += 1
        }
        return response(
            statusCode: existed ? 204 : 201,
            headers: etagHeaders(for: resource),
            url: url
        )
    }

    private func handleDELETE(_ request: URLRequest, url: URL) -> WebDAVTransportResponse {
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
        guard let resource = resources[url] else {
            return response(statusCode: 404, url: url)
        }
        let lockCondition = request.value(forHTTPHeaderField: "If")
        if let activeToken = activeLocks[url] {
            guard lockCondition == "(\(activeToken))" else {
                return response(statusCode: 423, url: url)
            }
        } else if lockCondition != nil {
            return response(statusCode: 412, url: url)
        }
        if let expected = request.value(forHTTPHeaderField: "If-Match"),
           expected != "*", expected != strongETag(for: resource) {
            return response(statusCode: 412, url: url)
        }
        resources.removeValue(forKey: url)
        activeLocks.removeValue(forKey: url)
        return response(statusCode: 204, url: url)
    }

    private func handleLOCK(url: URL, isActual: Bool) async -> WebDAVTransportResponse {
        if isActual {
            actualLockRequestCount += 1
            if let failure = nextActualLockFailure {
                nextActualLockFailure = nil
                return response(statusCode: failure, url: url)
            }
        } else {
            probeLockRequestCount += 1
        }
        guard resources[url] != nil else {
            return response(statusCode: 404, url: url)
        }
        if activeLocks[url] != nil {
            if isActual {
                rejectedActualLockCount += 1
            }
            if let heldActualLockResponse {
                self.heldActualLockResponse = nil
                heldActualLockResponse.resume(returning: successfulLOCKResponse(
                    url: url,
                    token: activeLocks[url] ?? ""
                ))
            }
            return response(statusCode: 423, url: url)
        }

        lockSequence += 1
        let token = "<opaquelocktoken:test-\(lockSequence)>"
        activeLocks[url] = token
        if isActual {
            maximumConcurrentActualLocks = max(
                maximumConcurrentActualLocks,
                activeLocks.keys.filter { $0.lastPathComponent == actualFilename }.count
            )
        }
        let result = successfulLOCKResponse(url: url, token: token)
        if isActual, shouldHoldNextActualLock {
            shouldHoldNextActualLock = false
            return await withCheckedContinuation { continuation in
                heldActualLockResponse = continuation
            }
        }
        return result
    }

    private func handleUNLOCK(_ request: URLRequest, url: URL) -> WebDAVTransportResponse {
        guard let activeToken = activeLocks[url],
              request.value(forHTTPHeaderField: "Lock-Token") == activeToken else {
            return response(statusCode: 409, url: url)
        }
        activeLocks.removeValue(forKey: url)
        return response(statusCode: 204, url: url)
    }

    private func passActualGETBarrier(
        with response: WebDAVTransportResponse
    ) async -> WebDAVTransportResponse {
        actualGETBarrierArrivals += 1
        if actualGETBarrierArrivals == actualGETBarrierTarget {
            actualGETBarrierTarget = 0
            actualGETBarrierArrivals = 0
            let waiters = actualGETBarrierWaiters
            actualGETBarrierWaiters.removeAll()
            waiters.forEach { $0.resume(returning: response) }
            return response
        }
        return await withCheckedContinuation { continuation in
            actualGETBarrierWaiters.append(continuation)
        }
    }

    private func successfulLOCKResponse(url: URL, token: String) -> WebDAVTransportResponse {
        let href = token.dropFirst().dropLast()
        let body = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:timeout>Second-120</D:timeout><D:locktoken><D:href>\(href)</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>
            """.utf8
        )
        return response(
            data: body,
            statusCode: 200,
            headers: ["Lock-Token": token],
            url: url
        )
    }

    private func etagHeaders(for resource: Resource) -> [String: String] {
        switch etagMode {
        case .strong:
            return ["ETag": strongETag(for: resource)]
        case .weak:
            return ["ETag": "W/\(strongETag(for: resource))"]
        case .missing:
            return [:]
        }
    }

    private func strongETag(for resource: Resource) -> String {
        "\"etag-\(resource.revision)\""
    }

    private func normalizedCollectionURL(_ url: URL) -> URL {
        guard !url.hasDirectoryPath else { return url }
        return url.appendingPathComponent("", isDirectory: true)
    }

    private func multiStatusXML(for collection: URL, includeChildren: Bool) -> Data {
        var responses = [collectionResponse(href: collection.path, isCollection: true)]
        if includeChildren {
            responses += resources.keys
                .filter { $0.deletingLastPathComponent() == collection }
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
}
