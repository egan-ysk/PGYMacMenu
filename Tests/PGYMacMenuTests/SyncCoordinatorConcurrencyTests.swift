import Foundation
import XCTest
@testable import PGYMacMenu

final class SyncCoordinatorConcurrencyTests: XCTestCase {
    func testSavingNewEndpointCancelsSyncStartedDuringConnectionTest() async throws {
        try await withFixture { fixture in
            let oldSettings = fixture.settings(host: "old.example.com")
            let newSettings = fixture.settings(host: "new.example.com")
            try await fixture.coordinator.saveSettings(oldSettings)
            try fixture.store.saveUpdateTemplate(UpdateTemplate(name: "Pending", content: "Upload to new endpoint"))

            let probeKey = await fixture.transport.armBlock(
                host: "new.example.com",
                method: "GET",
                resource: .probe
            )
            let saveTask = Task {
                try await fixture.coordinator.saveSettings(newSettings)
            }
            await fixture.transport.waitUntilBlocked(probeKey)

            let oldDownloadKey = await fixture.transport.armBlock(
                host: "old.example.com",
                method: "GET",
                resource: .actual
            )
            let oldSyncTask = Task {
                try await fixture.coordinator.synchronizeNow()
            }
            await fixture.transport.waitUntilBlocked(oldDownloadKey)

            await fixture.transport.release(probeKey)
            await fixture.transport.waitUntilCancelled(oldDownloadKey)
            await fixture.transport.release(oldDownloadKey)

            do {
                try await oldSyncTask.value
                XCTFail("The old-endpoint sync should be cancelled before settings are replaced")
            } catch is CancellationError {
                // Expected: saveSettings forms a cancellation barrier before persisting the new endpoint.
            }
            try await saveTask.value

            let oldPutCount = await fixture.transport.actualPutCount(host: "old.example.com")
            let newPutCount = await fixture.transport.actualPutCount(host: "new.example.com")
            XCTAssertEqual(oldPutCount, 1)
            XCTAssertEqual(newPutCount, 1)
            XCTAssertFalse(fixture.store.hasPendingSyncChanges())

            let remoteResource = await fixture.transport.actualResourceData(host: "new.example.com")
            let remoteData = try XCTUnwrap(remoteResource)
            let document = try SyncCrypto.decryptDocument(
                from: remoteData,
                passphrase: newSettings.encryptionPassphrase
            )
            XCTAssertEqual(document.updateTemplates.first?.value?.name, "Pending")
            let savedSettings = try await fixture.coordinator.savedSettings()
            XCTAssertEqual(savedSettings?.rootURL, newSettings.rootURL)
        }
    }

    func testRemoveSettingsWaitsForInFlightSyncCancellation() async throws {
        try await withFixture { fixture in
            let settings = fixture.settings(host: "dav.example.com")
            try await fixture.coordinator.saveSettings(settings)
            try fixture.store.saveUpdateTemplate(UpdateTemplate(name: "Unsynced", content: "Must remain dirty"))

            let downloadKey = await fixture.transport.armBlock(
                host: "dav.example.com",
                method: "GET",
                resource: .actual
            )
            let syncTask = Task {
                try await fixture.coordinator.synchronizeNow()
            }
            await fixture.transport.waitUntilBlocked(downloadKey)

            let removalState = CompletionState()
            let removeTask = Task {
                try await fixture.coordinator.removeSettings()
                await removalState.markCompleted()
            }
            await fixture.transport.waitUntilCancelled(downloadKey)
            let completedBeforeRelease = await removalState.isCompleted
            XCTAssertFalse(completedBeforeRelease)

            await fixture.transport.release(downloadKey)
            try await removeTask.value
            do {
                try await syncTask.value
                XCTFail("The in-flight sync should finish as cancelled")
            } catch is CancellationError {
                // Expected.
            }

            let completedAfterRelease = await removalState.isCompleted
            let savedSettings = try await fixture.coordinator.savedSettings()
            let status = await fixture.coordinator.currentStatus()
            let putCount = await fixture.transport.actualPutCount(host: "dav.example.com")
            XCTAssertTrue(completedAfterRelease)
            XCTAssertNil(savedSettings)
            XCTAssertEqual(status, .notConfigured)
            XCTAssertTrue(fixture.store.hasPendingSyncChanges())
            XCTAssertEqual(putCount, 1)
        }
    }

    func testFlushCapturesMutationMadeDuringPostWriteVerification() async throws {
        try await withFixture { fixture in
            let settings = fixture.settings(host: "dav.example.com")
            try await fixture.coordinator.saveSettings(settings)

            var template = UpdateTemplate(name: "Release", content: "First revision")
            try fixture.store.saveUpdateTemplate(template)

            let uploadKey = await fixture.transport.armBlock(
                host: "dav.example.com",
                method: "PUT",
                resource: .actual
            )
            let syncTask = Task {
                try await fixture.coordinator.synchronizeNow()
            }
            await fixture.transport.waitUntilBlocked(uploadKey)

            let verificationKey = await fixture.transport.armBlock(
                host: "dav.example.com",
                method: "GET",
                resource: .actual
            )
            await fixture.transport.release(uploadKey)
            await fixture.transport.waitUntilBlocked(verificationKey)

            template.content = "Second revision"
            try fixture.store.saveUpdateTemplate(template)
            let flushTask = Task {
                await fixture.coordinator.flushPendingChanges()
            }

            await fixture.transport.release(verificationKey)
            try await syncTask.value
            let didFlush = await flushTask.value
            XCTAssertTrue(didFlush)

            XCTAssertFalse(fixture.store.hasPendingSyncChanges())
            let putCount = await fixture.transport.actualPutCount(host: "dav.example.com")
            XCTAssertEqual(putCount, 3)

            let storedRemoteData = await fixture.transport.actualResourceData(host: "dav.example.com")
            let remoteData = try XCTUnwrap(storedRemoteData)
            let document = try SyncCrypto.decryptDocument(
                from: remoteData,
                passphrase: settings.encryptionPassphrase
            )
            XCTAssertEqual(
                document.updateTemplates.first(where: { $0.id == template.id })?.value?.content,
                "Second revision"
            )
        }
    }

    func testFlushWithoutConfigurationKeepsPendingDataForNextLaunch() async throws {
        try await withFixture { fixture in
            XCTAssertTrue(fixture.store.hasPendingSyncChanges())

            let didFlush = await fixture.coordinator.flushPendingChanges()
            let savedSettings = try await fixture.coordinator.savedSettings()

            XCTAssertFalse(didFlush)
            XCTAssertTrue(fixture.store.hasPendingSyncChanges())
            XCTAssertNil(savedSettings)
            let putCount = await fixture.transport.actualPutCount(host: "dav.example.com")
            XCTAssertEqual(putCount, 0)
        }
    }

    func testFailedFlushKeepsDirtyStateAndLaterRetrySucceeds() async throws {
        try await withFixture { fixture in
            let settings = fixture.settings(host: "dav.example.com")
            try await fixture.coordinator.saveSettings(settings)
            let template = UpdateTemplate(name: "Pending", content: "Retry on next launch")
            try fixture.store.saveUpdateTemplate(template)
            await fixture.transport.respondNext(
                host: "dav.example.com",
                method: "GET",
                resource: .actual,
                statusCode: 403
            )

            let firstFlush = await fixture.coordinator.flushPendingChanges()

            XCTAssertFalse(firstFlush)
            XCTAssertTrue(fixture.store.hasPendingSyncChanges())
            let failedStatus = await fixture.coordinator.currentStatus()
            guard case .failed = failedStatus else {
                return XCTFail("Expected a failed status after the rejected flush")
            }

            let retryFlush = await fixture.coordinator.flushPendingChanges()

            XCTAssertTrue(retryFlush)
            XCTAssertFalse(fixture.store.hasPendingSyncChanges())
            let remoteData = await fixture.transport.actualResourceData(host: "dav.example.com")
            let document = try SyncCrypto.decryptDocument(
                from: XCTUnwrap(remoteData),
                passphrase: settings.encryptionPassphrase
            )
            XCTAssertEqual(
                document.updateTemplates.first(where: { $0.id == template.id })?.value?.content,
                template.content
            )
        }
    }

    func testRemoveSettingsPreservesAnchorForReplayDetection() async throws {
        try await withFixture { fixture in
            let settings = fixture.settings(host: "dav.example.com")
            try await fixture.coordinator.saveSettings(settings)
            let firstResource = await fixture.transport.actualResourceData(host: "dav.example.com")
            let firstGeneration = try XCTUnwrap(firstResource)

            try fixture.store.saveUpdateTemplate(UpdateTemplate(name: "Generation 2", content: "Newer"))
            try await fixture.coordinator.synchronizeNow()
            try await fixture.coordinator.removeSettings()

            await fixture.transport.replaceActualResource(
                host: "dav.example.com",
                data: firstGeneration
            )

            do {
                try await fixture.coordinator.saveSettings(settings)
                XCTFail("A replayed generation must be rejected after removing and re-entering settings")
            } catch let error as SyncCoordinatorError {
                XCTAssertEqual(error, .rollbackDetected)
            }
            let savedSettings = try await fixture.coordinator.savedSettings()
            XCTAssertNil(savedSettings)
        }
    }

    func testSwitchingEndpointsRetainsEachReplayAnchor() async throws {
        try await withFixture { fixture in
            let firstSettings = fixture.settings(host: "first.example.com")
            let secondSettings = fixture.settings(host: "second.example.com")
            try await fixture.coordinator.saveSettings(firstSettings)
            let firstResource = await fixture.transport.actualResourceData(host: "first.example.com")
            let firstGeneration = try XCTUnwrap(firstResource)

            try fixture.store.saveUpdateTemplate(UpdateTemplate(name: "Generation 2", content: "Newer"))
            try await fixture.coordinator.synchronizeNow()
            try await fixture.coordinator.saveSettings(secondSettings)

            await fixture.transport.replaceActualResource(
                host: "first.example.com",
                data: firstGeneration
            )
            do {
                try await fixture.coordinator.saveSettings(firstSettings)
                XCTFail("Switching endpoints must not discard the first endpoint's replay anchor")
            } catch let error as SyncCoordinatorError {
                XCTAssertEqual(error, .rollbackDetected)
            }
            let settingsAfterReplay = try await fixture.coordinator.savedSettings()
            XCTAssertEqual(settingsAfterReplay?.rootURL, secondSettings.rootURL)

            let firstPutCount = await fixture.transport.actualPutCount(host: "first.example.com")
            await fixture.transport.removeActualResource(host: "first.example.com")
            do {
                try await fixture.coordinator.saveSettings(firstSettings)
                XCTFail("A missing previously observed file must not be recreated after switching endpoints")
            } catch let error as SyncCoordinatorError {
                XCTAssertEqual(error, .remoteFileDisappeared)
            }
            let finalFirstPutCount = await fixture.transport.actualPutCount(host: "first.example.com")
            XCTAssertEqual(finalFirstPutCount, firstPutCount)
        }
    }

    func testLegacyGlobalAnchorMigratesToHashedEndpointAccount() async throws {
        try await withFixture { fixture in
            let settings = fixture.settings(host: "dav.example.com")
            try await fixture.coordinator.saveSettings(settings)
            let resourceData = await fixture.transport.actualResourceData(host: "dav.example.com")
            let resource = try XCTUnwrap(resourceData)
            let document = try SyncCrypto.decryptDocument(
                from: resource,
                passphrase: settings.encryptionPassphrase
            )
            let legacyAnchor = TestAnchor(
                endpointIdentity: try legacyEndpointIdentity(for: settings),
                datasetID: document.datasetID,
                generation: document.generation,
                documentHash: try SyncCrypto.documentHash(document),
                lastSuccess: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let scopedAccount = try scopedAnchorAccount(for: settings)
            try fixture.syncKeychain.delete(account: scopedAccount)
            try fixture.syncKeychain.save(
                JSONEncoder().encode(legacyAnchor),
                account: "webdav.anchor.v1",
                accessibility: .afterFirstUnlockThisDeviceOnly
            )

            try await fixture.coordinator.testConnection(settings)

            XCTAssertNil(try fixture.syncKeychain.readData(account: "webdav.anchor.v1"))
            let migratedData = try XCTUnwrap(
                fixture.syncKeychain.readData(account: scopedAccount)
            )
            let migrated = try JSONDecoder().decode(TestAnchor.self, from: migratedData)
            XCTAssertEqual(migrated.endpointIdentity, try endpointIdentity(for: settings))
            XCTAssertEqual(migrated.datasetID, document.datasetID)
            XCTAssertEqual(migrated.generation, document.generation)
        }
    }

    private func withFixture(
        _ body: (ConcurrencyFixture) async throws -> Void
    ) async throws {
        let namespace = "SyncCoordinatorConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defaults.removePersistentDomain(forName: namespace)
        let configurationKeychain = KeychainStore(service: "\(namespace).configuration")
        let syncKeychain = KeychainStore(service: "\(namespace).sync")
        try configurationKeychain.deleteAll()
        try syncKeychain.deleteAll()

        let transport = BlockingWebDAVTransport(actualFilename: "PGYMacMenu.sync")
        let store = ConfigurationStore(defaults: defaults, keychain: configurationKeychain)
        try store.saveAPIKeyProfile(APIKeyProfile(
            name: "Production",
            apiKey: "secret-api-key",
            password: "install-password",
            updateTemplate: "Release notes"
        ))
        let coordinator = SyncCoordinator(
            store: store,
            keychain: syncKeychain,
            clientFactory: { configuration in
                try WebDAVClient(configuration: configuration, transport: transport)
            }
        )
        let fixture = ConcurrencyFixture(
            store: store,
            coordinator: coordinator,
            transport: transport,
            syncKeychain: syncKeychain
        )

        do {
            try await body(fixture)
        } catch {
            defaults.removePersistentDomain(forName: namespace)
            try? configurationKeychain.deleteAll()
            try? syncKeychain.deleteAll()
            throw error
        }
        defaults.removePersistentDomain(forName: namespace)
        try configurationKeychain.deleteAll()
        try syncKeychain.deleteAll()
    }
}

private struct ConcurrencyFixture {
    let store: ConfigurationStore
    let coordinator: SyncCoordinator
    let transport: BlockingWebDAVTransport
    let syncKeychain: KeychainStore

    func settings(host: String) -> WebDAVSyncSettings {
        WebDAVSyncSettings(
            rootURL: "https://\(host)/root/",
            username: "user",
            webDAVPassword: "webdav-password",
            encryptionPassphrase: "correct horse battery"
        )
    }
}

private struct TestAnchor: Codable {
    var schemaVersion: Int = 1
    var endpointIdentity: String
    var datasetID: UUID
    var generation: UInt64
    var documentHash: String
    var lastSuccess: Date
}

private func endpointIdentity(for settings: WebDAVSyncSettings) throws -> String {
    let configuration = try settings.webDAVConfiguration()
    return [
        configuration.rootURL.absoluteString,
        configuration.relativePath,
        configuration.username
    ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
}

private func legacyEndpointIdentity(for settings: WebDAVSyncSettings) throws -> String {
    let configuration = try settings.webDAVConfiguration()
    return "\(configuration.rootURL.absoluteString)|\(configuration.relativePath)|\(configuration.username)"
}

private func scopedAnchorAccount(for settings: WebDAVSyncSettings) throws -> String {
    let digest = SyncCrypto.sha256Hex(Data(try endpointIdentity(for: settings).utf8))
    return "webdav.anchor.v2.\(digest)"
}

private actor CompletionState {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor BlockingWebDAVTransport: WebDAVTransport {
    enum ResourceKind: Hashable, Sendable {
        case actual
        case probe
    }

    struct BlockKey: Hashable, Sendable {
        let id: UUID
        let host: String
        let method: String
        let resource: ResourceKind
    }

    private struct Resource {
        var data: Data
        var etag: String
    }

    private let actualFilename: String
    private var resources: [URL: Resource] = [:]
    private var etagSequence = 0
    private var actualPutCounts: [String: Int] = [:]
    private var armedResponses: [(host: String, method: String, resource: ResourceKind, statusCode: Int)] = []

    private var armedBlocks: [BlockKey] = []
    private var blocked: Set<BlockKey> = []
    private var cancelled: Set<BlockKey> = []
    private var releasesRequested: Set<BlockKey> = []
    private var releaseContinuations: [BlockKey: CheckedContinuation<Void, Never>] = [:]
    private var blockedWaiters: [BlockKey: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [BlockKey: [CheckedContinuation<Void, Never>]] = [:]

    init(actualFilename: String) {
        self.actualFilename = actualFilename
    }

    func armBlock(host: String, method: String, resource: ResourceKind) -> BlockKey {
        let key = BlockKey(id: UUID(), host: host, method: method, resource: resource)
        armedBlocks.append(key)
        return key
    }

    func respondNext(host: String, method: String, resource: ResourceKind, statusCode: Int) {
        armedResponses.append((host, method, resource, statusCode))
    }

    func waitUntilBlocked(_ key: BlockKey) async {
        if blocked.contains(key) { return }
        await withCheckedContinuation { continuation in
            blockedWaiters[key, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ key: BlockKey) async {
        if cancelled.contains(key) { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: BlockKey) {
        if let continuation = releaseContinuations.removeValue(forKey: key) {
            continuation.resume()
        } else {
            releasesRequested.insert(key)
        }
    }

    func actualPutCount(host: String) -> Int {
        actualPutCounts[host, default: 0]
    }

    func actualResourceData(host: String) -> Data? {
        resources.first {
            $0.key.host == host && $0.key.lastPathComponent == actualFilename
        }?.value.data
    }

    func replaceActualResource(host: String, data: Data) {
        guard let url = resources.keys.first(where: {
            $0.host == host && $0.lastPathComponent == actualFilename
        }) else {
            return
        }
        etagSequence += 1
        resources[url] = Resource(data: data, etag: "\"etag-\(etagSequence)\"")
    }

    func removeActualResource(host: String) {
        resources = resources.filter {
            !($0.key.host == host && $0.key.lastPathComponent == actualFilename)
        }
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> WebDAVTransportResponse {
        let url = try XCTUnwrap(request.url)
        let method = request.httpMethod ?? ""
        let kind = resourceKind(for: url)
        if let responseIndex = armedResponses.firstIndex(where: {
            $0.host == url.host && $0.method == method && $0.resource == kind
        }) {
            let response = armedResponses.remove(at: responseIndex)
            return WebDAVTransportResponse(statusCode: response.statusCode, url: url)
        }
        if let blockIndex = armedBlocks.firstIndex(where: {
            $0.host == url.host && $0.method == method && $0.resource == kind
        }) {
            let key = armedBlocks.remove(at: blockIndex)
            await pause(key)
        }

        switch method {
        case "MKCOL":
            return WebDAVTransportResponse(statusCode: 201, url: url)
        case "GET":
            guard let resource = resources[url] else {
                return WebDAVTransportResponse(statusCode: 404, url: url)
            }
            return WebDAVTransportResponse(
                data: resource.data,
                statusCode: 200,
                headers: ["ETag": resource.etag],
                url: url
            )
        case "PUT":
            if request.value(forHTTPHeaderField: "If-None-Match") == "*", resources[url] != nil {
                return WebDAVTransportResponse(statusCode: 412, url: url)
            }
            if let expected = request.value(forHTTPHeaderField: "If-Match"),
               resources[url]?.etag != expected {
                return WebDAVTransportResponse(statusCode: 412, url: url)
            }
            let existed = resources[url] != nil
            etagSequence += 1
            let etag = "\"etag-\(etagSequence)\""
            resources[url] = Resource(data: request.httpBody ?? Data(), etag: etag)
            if kind == .actual {
                actualPutCounts[url.host ?? "", default: 0] += 1
            }
            return WebDAVTransportResponse(
                statusCode: existed ? 204 : 201,
                headers: ["ETag": etag],
                url: url
            )
        case "DELETE":
            guard let existing = resources[url] else {
                return WebDAVTransportResponse(statusCode: 404, url: url)
            }
            if let expected = request.value(forHTTPHeaderField: "If-Match"),
               expected != "*", expected != existing.etag {
                return WebDAVTransportResponse(statusCode: 412, url: url)
            }
            resources.removeValue(forKey: url)
            return WebDAVTransportResponse(statusCode: 204, url: url)
        default:
            return WebDAVTransportResponse(statusCode: 405, url: url)
        }
    }

    private func pause(_ key: BlockKey) async {
        blocked.insert(key)
        blockedWaiters.removeValue(forKey: key)?.forEach { $0.resume() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if releasesRequested.remove(key) != nil {
                    continuation.resume()
                } else {
                    releaseContinuations[key] = continuation
                }
            }
        } onCancel: {
            Task { await self.noteCancellation(key) }
        }
        blocked.remove(key)
    }

    private func noteCancellation(_ key: BlockKey) {
        cancelled.insert(key)
        cancellationWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    private func resourceKind(for url: URL) -> ResourceKind {
        url.lastPathComponent == actualFilename ? .actual : .probe
    }
}
