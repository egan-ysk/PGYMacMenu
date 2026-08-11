import Foundation
import XCTest
@testable import PGYMacMenu

final class SyncCoordinatorTests: XCTestCase {
    func testManualSyncCreatesRetriesRestoresAndProtectsMissingRemote() async throws {
        let namespace = "SyncCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defaults.removePersistentDomain(forName: namespace)
        let configurationKeychain = KeychainStore(service: "\(namespace).configuration")
        let syncKeychain = KeychainStore(service: "\(namespace).sync")
        try configurationKeychain.deleteAll()
        try syncKeychain.deleteAll()
        defer {
            defaults.removePersistentDomain(forName: namespace)
            try? configurationKeychain.deleteAll()
            try? syncKeychain.deleteAll()
        }

        let transport = StatefulWebDAVTransport(actualFilename: "PGYMacMenu.sync")
        let factory: SyncCoordinator.ClientFactory = { configuration in
            try WebDAVClient(configuration: configuration, transport: transport)
        }
        let store = ConfigurationStore(defaults: defaults, keychain: configurationKeychain)
        let profile = APIKeyProfile(
            name: "Production",
            apiKey: "secret-api-key",
            password: "install-password",
            updateTemplate: "Release notes"
        )
        try store.saveAPIKeyProfile(profile)
        let coordinator = SyncCoordinator(
            store: store,
            keychain: syncKeychain,
            clientFactory: factory
        )
        let settings = WebDAVSyncSettings(
            rootURL: "https://dav.example.com/root/",
            username: "user",
            webDAVPassword: "webdav-password",
            encryptionPassphrase: "correct horse battery"
        )

        try await coordinator.saveSettings(settings)

        XCTAssertTrue(store.hasPendingSyncChanges())
        let requestsAfterSave = await transport.requestCount
        XCTAssertEqual(requestsAfterSave, 0)
        await coordinator.prepareOnLaunch()
        await coordinator.applicationDidBecomeActive()
        await coordinator.scheduleLocalChange()
        let passiveFlush = await coordinator.flushPendingChanges()
        let requestsAfterPassiveLifecycle = await transport.requestCount
        XCTAssertFalse(passiveFlush)
        XCTAssertEqual(requestsAfterPassiveLifecycle, 0)

        try await coordinator.synchronizeNow()
        XCTAssertFalse(store.hasPendingSyncChanges())
        let initialPutCount = await transport.actualPutCount
        XCTAssertEqual(initialPutCount, 1)
        let firstRemoteValue = await transport.actualResource()
        let firstRemote = try XCTUnwrap(firstRemoteValue)
        let firstDocument = try SyncCrypto.decryptDocument(
            from: firstRemote.data,
            passphrase: settings.encryptionPassphrase
        )
        XCTAssertEqual(firstDocument.apiKeyProfiles.first?.value?.apiKey, profile.apiKey)

        try store.saveUpdateTemplate(UpdateTemplate(name: "Concurrent", content: "Merged"))
        await transport.failNextConditionalUpload()
        try await coordinator.synchronizeNow()
        XCTAssertFalse(store.hasPendingSyncChanges())
        let conditionalAttempts = await transport.actualConditionalPutAttempts
        XCTAssertGreaterThanOrEqual(conditionalAttempts, 2)

        try store.saveUpdateTemplate(UpdateTemplate(name: "Manual", content: "Explicit only"))
        let requestCountBeforePassiveLifecycle = await transport.requestCount
        await coordinator.scheduleLocalChange()
        await coordinator.applicationDidBecomeActive()
        let dirtyFlush = await coordinator.flushPendingChanges()
        let requestCountAfterPassiveLifecycle = await transport.requestCount
        XCTAssertFalse(dirtyFlush)
        XCTAssertTrue(store.hasPendingSyncChanges())
        XCTAssertEqual(requestCountAfterPassiveLifecycle, requestCountBeforePassiveLifecycle)

        try await coordinator.synchronizeNow()
        XCTAssertFalse(store.hasPendingSyncChanges())

        defaults.removePersistentDomain(forName: namespace)
        let reinstalledStore = ConfigurationStore(defaults: defaults, keychain: configurationKeychain)
        let reinstalledCoordinator = SyncCoordinator(
            store: reinstalledStore,
            keychain: syncKeychain,
            clientFactory: factory
        )

        let requestCountBeforeLaunch = await transport.requestCount
        await reinstalledCoordinator.prepareOnLaunch()

        XCTAssertTrue(reinstalledStore.loadAPIKeyProfiles().isEmpty)
        XCTAssertTrue(reinstalledStore.loadUpdateTemplates().isEmpty)
        XCTAssertFalse(reinstalledStore.hasPendingSyncChanges())
        let requestCountAfterLaunch = await transport.requestCount
        XCTAssertEqual(requestCountAfterLaunch, requestCountBeforeLaunch)

        try await reinstalledCoordinator.synchronizeNow()
        XCTAssertEqual(reinstalledStore.loadAPIKeyProfiles().first?.apiKey, profile.apiKey)
        XCTAssertEqual(reinstalledStore.loadUpdateTemplates().count, 2)
        XCTAssertFalse(reinstalledStore.hasPendingSyncChanges())

        await transport.removeActualResource()
        do {
            try await reinstalledCoordinator.synchronizeNow()
            XCTFail("A previously observed remote file must not be recreated after a 404")
        } catch let error as SyncCoordinatorError {
            XCTAssertEqual(error, .remoteFileDisappeared)
        }
        let finalPutCount = await transport.actualPutCount
        XCTAssertEqual(finalPutCount, 3)
    }
}

private actor StatefulWebDAVTransport: WebDAVTransport {
    private struct Resource {
        var data: Data
        var etag: String
    }

    private let actualFilename: String
    private var resources: [URL: Resource] = [:]
    private var etagSequence = 0
    private var conditionalFailuresRemaining = 0
    private(set) var requestCount = 0
    private(set) var actualPutCount = 0
    private(set) var actualConditionalPutAttempts = 0

    init(actualFilename: String) {
        self.actualFilename = actualFilename
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> WebDAVTransportResponse {
        requestCount += 1
        let url = try XCTUnwrap(request.url)
        switch request.httpMethod {
        case "MKCOL":
            return WebDAVTransportResponse(statusCode: 201)
        case "GET":
            guard let resource = resources[url] else {
                return WebDAVTransportResponse(statusCode: 404)
            }
            return WebDAVTransportResponse(
                data: resource.data,
                statusCode: 200,
                headers: ["ETag": resource.etag],
                url: url
            )
        case "PUT":
            let isActual = url.lastPathComponent == actualFilename
            let existed = resources[url] != nil
            if request.value(forHTTPHeaderField: "If-None-Match") == "*", resources[url] != nil {
                return WebDAVTransportResponse(statusCode: 412)
            }
            if let expected = request.value(forHTTPHeaderField: "If-Match") {
                if isActual {
                    actualConditionalPutAttempts += 1
                    if conditionalFailuresRemaining > 0 {
                        conditionalFailuresRemaining -= 1
                        return WebDAVTransportResponse(statusCode: 412)
                    }
                }
                guard resources[url]?.etag == expected else {
                    return WebDAVTransportResponse(statusCode: 412)
                }
            }
            etagSequence += 1
            resources[url] = Resource(
                data: request.httpBody ?? Data(),
                etag: "\"etag-\(etagSequence)\""
            )
            if isActual { actualPutCount += 1 }
            // Deliberately omit ETag: the client must verify with a following GET.
            return WebDAVTransportResponse(statusCode: existed ? 204 : 201)
        case "DELETE":
            guard let existing = resources[url] else {
                return WebDAVTransportResponse(statusCode: 404)
            }
            if let expected = request.value(forHTTPHeaderField: "If-Match"),
               expected != "*", expected != existing.etag {
                return WebDAVTransportResponse(statusCode: 412)
            }
            resources.removeValue(forKey: url)
            return WebDAVTransportResponse(statusCode: 204)
        default:
            return WebDAVTransportResponse(statusCode: 405)
        }
    }

    func failNextConditionalUpload() {
        conditionalFailuresRemaining = 1
    }

    func actualResource() -> (data: Data, etag: String)? {
        resources.first { $0.key.lastPathComponent == actualFilename }
            .map { ($0.value.data, $0.value.etag) }
    }

    func removeActualResource() {
        resources = resources.filter { $0.key.lastPathComponent != actualFilename }
    }
}
