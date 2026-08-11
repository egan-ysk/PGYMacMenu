import Foundation

extension Notification.Name {
    static let syncCoordinatorStatusDidChange = Notification.Name("SyncCoordinatorStatusDidChange")
}

struct WebDAVSyncSettings: Codable, Hashable, Sendable {
    var rootURL: String
    var relativePath: String
    var username: String
    var webDAVPassword: String
    var encryptionPassphrase: String

    init(
        rootURL: String,
        relativePath: String = WebDAVConfiguration.defaultRelativePath,
        username: String,
        webDAVPassword: String,
        encryptionPassphrase: String
    ) {
        self.rootURL = rootURL
        self.relativePath = relativePath
        self.username = username
        self.webDAVPassword = webDAVPassword
        self.encryptionPassphrase = encryptionPassphrase
    }

    func webDAVConfiguration() throws -> WebDAVConfiguration {
        guard let url = URL(string: rootURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WebDAVError.invalidRootURL
        }
        return try WebDAVConfiguration(
            rootURL: url,
            relativePath: relativePath.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: webDAVPassword
        )
    }

    func validated() throws -> WebDAVSyncSettings {
        let configuration = try webDAVConfiguration()
        guard !configuration.username.isEmpty, !configuration.password.isEmpty else {
            throw SyncCoordinatorError.incompleteSettings
        }
        _ = try SyncCrypto.seal(Data(), passphrase: encryptionPassphrase)
        return WebDAVSyncSettings(
            rootURL: configuration.rootURL.absoluteString,
            relativePath: configuration.relativePath,
            username: configuration.username,
            webDAVPassword: configuration.password,
            encryptionPassphrase: encryptionPassphrase.precomposedStringWithCanonicalMapping
        )
    }

    fileprivate var endpointIdentity: String {
        (try? webDAVConfiguration()).map {
            Self.lengthPrefixedIdentity([
                $0.rootURL.absoluteString,
                $0.relativePath,
                $0.username
            ])
        } ?? Self.lengthPrefixedIdentity([rootURL, relativePath, username])
    }

    fileprivate var legacyEndpointIdentity: String {
        (try? webDAVConfiguration()).map {
            "\($0.rootURL.absoluteString)|\($0.relativePath)|\($0.username)"
        } ?? "\(rootURL)|\(relativePath)|\(username)"
    }

    private static func lengthPrefixedIdentity(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

enum SyncCoordinatorStatus: Equatable, Sendable {
    case notConfigured
    case pending
    case syncing
    case lastSuccess(Date)
    case failed(String)
}

enum SyncCoordinatorError: LocalizedError, Equatable {
    case notConfigured
    case incompleteSettings
    case invalidLocalMetadata
    case remoteFileDisappeared
    case rollbackDetected
    case remoteDatasetChanged
    case concurrentUpdates
    case verificationFailed
    case immutableRepositoryTooLarge
    case immutableRepositoryInvalid

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 WebDAV 同步"
        case .incompleteSettings:
            return "请完整填写 WebDAV 用户名和密码"
        case .invalidLocalMetadata:
            return "本机同步元数据无效"
        case .remoteFileDisappeared:
            return "远端同步文件曾经存在但现在已丢失，已停止上传"
        case .rollbackDetected:
            return "检测到远端同步数据回退，已停止覆盖"
        case .remoteDatasetChanged:
            return "远端同步文件已被替换为另一个数据集"
        case .concurrentUpdates:
            return "远端数据正在被其他设备频繁修改，请稍后重试"
        case .verificationFailed:
            return "上传后的远端数据校验失败，未清除待同步状态"
        case .immutableRepositoryTooLarge:
            return "远端不可变快照数量或总大小超过安全限制，请改用新的同步文件路径"
        case .immutableRepositoryInvalid:
            return "远端不可变快照仓库不完整或已被修改，已停止同步"
        }
    }
}

actor SyncCoordinator {
    typealias ClientFactory = @Sendable (WebDAVConfiguration) throws -> WebDAVClient

    private enum WriteStrategy {
        case strongETag
        case exclusiveLock
        case immutableSnapshots
    }

    private struct ActiveSync {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct Bootstrap: Codable, Sendable {
        var schemaVersion: Int = 1
        var settings: WebDAVSyncSettings
    }

    private struct Anchor: Codable, Sendable {
        var schemaVersion: Int = 1
        var endpointIdentity: String
        var datasetID: UUID
        var generation: UInt64
        var documentHash: String
        var lastSuccess: Date
    }

    private struct ImmutableAnchor: Codable, Sendable {
        var schemaVersion: Int = 1
        var endpointIdentity: String
        var datasetID: UUID
        var genesisEncryptedPayloadHash: String
        var carrier: ImmutableSyncCarrierReference
        var carrierDocumentHash: String
        var observedObjectNames: [String]
        var lastSuccess: Date
    }

    private struct LoadedImmutableCarrier: Sendable {
        var fileName: String
        var reference: ImmutableSyncCarrierReference
        var snapshot: ImmutableSyncSnapshot
        var encryptedByteCount: Int
    }

    private enum Accounts {
        static let bootstrap = "webdav.bootstrap.v1"
        static let legacyAnchor = "webdav.anchor.v1"

        static func anchor(endpointIdentity: String) -> String {
            let digest = SyncCrypto.sha256Hex(Data(endpointIdentity.utf8))
            return "webdav.anchor.v2.\(digest)"
        }

        static func immutableAnchor(endpointIdentity: String) -> String {
            let digest = SyncCrypto.sha256Hex(Data(endpointIdentity.utf8))
            return "webdav.immutable-anchor.v1.\(digest)"
        }
    }

    private static let maximumImmutableObjectCount = 512
    private static let maximumImmutableDownloadBytes = 64 * 1_024 * 1_024

    private let store: ConfigurationStore
    private let keychain: KeychainStore
    private let notificationCenter: NotificationCenter
    private let clientFactory: ClientFactory
    private let retryDelaysNanoseconds: [UInt64]
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private var status: SyncCoordinatorStatus = .notConfigured
    private var activeSync: ActiveSync?
    private var resyncRequested = false
    private var strongETagAttestedEndpointIdentities: Set<String> = []
    private var exclusiveLockAttestedEndpointIdentities: Set<String> = []
    private var conditionalCreateAttestedEndpointIdentities: Set<String> = []
    private var immutableCreateAttestedEndpointIdentities: Set<String> = []

    init(
        store: ConfigurationStore,
        keychain: KeychainStore = KeychainStore(service: "com.egan.PGYMacMenu.sync"),
        notificationCenter: NotificationCenter = .default,
        clientFactory: @escaping ClientFactory = { try WebDAVClient(configuration: $0) },
        retryDelaysNanoseconds: [UInt64] = [
            0,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000
        ]
    ) {
        self.store = store
        self.keychain = keychain
        self.notificationCenter = notificationCenter
        self.clientFactory = clientFactory
        self.retryDelaysNanoseconds = retryDelaysNanoseconds.isEmpty
            ? [0]
            : retryDelaysNanoseconds
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        activeSync?.task.cancel()
    }

    func prepareOnLaunch() async {
        do {
            guard let bootstrap = try loadBootstrap() else {
                setStatus(.notConfigured)
                return
            }
            if store.hasPendingSyncChanges() {
                setStatus(.pending)
            } else if let anchor = try loadImmutableAnchor(for: bootstrap.settings) {
                setStatus(.lastSuccess(anchor.lastSuccess))
            } else if let anchor = try loadAnchor(for: bootstrap.settings) {
                setStatus(.lastSuccess(anchor.lastSuccess))
            } else {
                setStatus(.pending)
            }
        } catch {
            setStatus(.failed(sanitizedMessage(for: error)))
        }
    }

    func currentStatus() -> SyncCoordinatorStatus {
        status
    }

    func savedSettings() throws -> WebDAVSyncSettings? {
        try loadBootstrap()?.settings
    }

    func testConnection(_ settings: WebDAVSyncSettings) async throws {
        let settings = try settings.validated()
        let client = try clientFactory(settings.webDAVConfiguration())
        clearWriteAttestations(for: settings.endpointIdentity)
        _ = try await attestWriteStrategy(client: client, settings: settings)
    }

    func saveSettings(_ settings: WebDAVSyncSettings) async throws {
        let settings = try settings.validated()
        await cancelSyncWork()
        clearWriteAttestations(for: settings.endpointIdentity)

        let bootstrap = Bootstrap(settings: settings)
        try keychain.save(
            encoder.encode(bootstrap),
            account: Accounts.bootstrap,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        setStatus(.pending)
    }

    func removeSettings() async throws {
        await cancelSyncWork()
        try keychain.delete(account: Accounts.bootstrap)
        strongETagAttestedEndpointIdentities.removeAll()
        exclusiveLockAttestedEndpointIdentities.removeAll()
        conditionalCreateAttestedEndpointIdentities.removeAll()
        immutableCreateAttestedEndpointIdentities.removeAll()
        setStatus(.notConfigured)
    }

    func scheduleLocalChange() {
        guard let bootstrap = try? loadBootstrap() else {
            setStatus(.notConfigured)
            return
        }
        guard store.hasPendingSyncChanges() else {
            if let anchor = try? loadImmutableAnchor(for: bootstrap.settings) {
                setStatus(.lastSuccess(anchor.lastSuccess))
            } else if let anchor = try? loadAnchor(for: bootstrap.settings) {
                setStatus(.lastSuccess(anchor.lastSuccess))
            }
            return
        }
        setStatus(.pending)
    }

    func applicationDidBecomeActive() async {
        // Synchronization is intentionally manual. Activation must never start
        // network traffic or apply remote configuration behind the user's back.
    }

    func synchronizeNow() async throws {
        guard try loadBootstrap() != nil else {
            throw SyncCoordinatorError.notConfigured
        }
        try await synchronize()
    }

    func flushPendingChanges() async -> Bool {
        !store.hasPendingSyncChanges()
    }

    private func synchronize() async throws {
        if let joinedSync = activeSync {
            resyncRequested = true
            try await joinedSync.task.value
            if activeSync?.id == joinedSync.id, resyncRequested {
                activeSync = nil
                resyncRequested = false
                try await synchronize()
            } else if let replacement = activeSync, replacement.id != joinedSync.id {
                try await replacement.task.value
            }
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.runSyncSession()
        }
        activeSync = ActiveSync(id: id, task: task)
        do {
            try await task.value
            let shouldRestart = activeSync?.id == id && resyncRequested
            if activeSync?.id == id {
                activeSync = nil
            }
            if shouldRestart {
                resyncRequested = false
                try await synchronize()
            }
        } catch {
            if activeSync?.id == id {
                activeSync = nil
            }
            if !(error is CancellationError) {
                setStatus(.failed(sanitizedMessage(for: error)))
            }
            throw error
        }
    }

    private func runSyncSession() async throws {
        while true {
            resyncRequested = false
            do {
                try await performSync()
            } catch {
                try Task.checkCancellation()
                if error as? SyncCoordinatorError == .concurrentUpdates, resyncRequested {
                    continue
                }
                throw error
            }
            guard resyncRequested else { return }
        }
    }

    private func cancelSyncWork() async {
        resyncRequested = false

        while let activeSync {
            activeSync.task.cancel()
            _ = try? await activeSync.task.value
            if self.activeSync?.id == activeSync.id {
                self.activeSync = nil
            }
        }
        resyncRequested = false
    }

    private func performSync() async throws {
        guard let bootstrap = try loadBootstrap() else {
            throw SyncCoordinatorError.notConfigured
        }
        let settings = bootstrap.settings
        let client = try clientFactory(settings.webDAVConfiguration())
        setStatus(.syncing)

        let immutableAnchor = try loadImmutableAnchor(for: settings)
        let existingImmutableChildren = try await loadExistingImmutableChildren(client: client)
        if immutableAnchor != nil, existingImmutableChildren == nil {
            throw SyncCoordinatorError.rollbackDetected
        }
        if let existingImmutableChildren {
            let classified = try classifyImmutableChildren(existingImmutableChildren)
            if let immutableAnchor,
               !Set(immutableAnchor.observedObjectNames).isSubset(
                   of: Set(classified.objects.map(\.name))
               ) {
                throw SyncCoordinatorError.rollbackDetected
            }
            if classified.genesis == nil, !classified.objects.isEmpty {
                throw SyncCoordinatorError.immutableRepositoryInvalid
            }
        }
        if immutableAnchor != nil
            || existingImmutableChildren?.contains(where: {
                $0.name == ImmutableSyncSnapshotLayout.genesisFileName
            }) == true {
            try await synchronizeUsingImmutableSnapshots(
                client: client,
                settings: settings,
                initialChildren: existingImmutableChildren
            )
            return
        }

        for _ in 0..<3 {
            try Task.checkCancellation()
            let snapshot = try store.syncSnapshot()
            let anchor = try loadAnchor(for: settings)
            let remote = try await withTransientRetry { try await client.download() }
            try Task.checkCancellation()

            guard let remote else {
                if anchor != nil {
                    throw SyncCoordinatorError.remoteFileDisappeared
                }
                guard snapshot.hasPortableData || snapshot.isDirty else {
                    setStatus(.lastSuccess(Date()))
                    return
                }
                if try await shouldUseImmutableSnapshots(client: client, settings: settings) {
                    try await synchronizeUsingImmutableSnapshots(
                        client: client,
                        settings: settings,
                        initialChildren: existingImmutableChildren
                    )
                    return
                }
                try await ensureConditionalCreateIsAttested(client: client, settings: settings)
                do {
                    try await client.createParentCollections()
                    try Task.checkCancellation()
                    let candidate = try snapshot.document.nextGeneration(previousHash: nil)
                    let encrypted = try SyncCrypto.encrypt(
                        document: candidate,
                        passphrase: settings.encryptionPassphrase
                    )
                    _ = try await withTransientRetry {
                        try await client.upload(encrypted, condition: .createOnly)
                    }
                    try Task.checkCancellation()
                    if try await verifyAndApply(
                        target: candidate,
                        client: client,
                        settings: settings,
                        expectedLocalGeneration: snapshot.localGeneration
                    ) {
                        return
                    }
                } catch WebDAVError.preconditionFailed {
                    continue
                }
                continue
            }

            guard let remoteStrongETag = remote.strongETag else {
                do {
                    try await ensureExclusiveLockIsAttested(client: client, settings: settings)
                    if try await syncExistingUsingExclusiveLock(
                        snapshot: snapshot,
                        anchor: anchor,
                        client: client,
                        settings: settings
                    ) {
                        return
                    }
                    continue
                } catch WebDAVError.exclusiveLockUnavailable {
                    _ = try await attestImmutableSnapshots(
                        client: client,
                        settings: settings,
                        failure: .exclusiveLockUnavailable
                    )
                } catch WebDAVError.unsafeExclusiveLock {
                    _ = try await attestImmutableSnapshots(
                        client: client,
                        settings: settings,
                        failure: .unsafeExclusiveLock
                    )
                } catch WebDAVError.unsafeConditionalCreate {
                    _ = try await attestImmutableSnapshots(
                        client: client,
                        settings: settings,
                        failure: .unsafeConditionalCreate
                    )
                }
                try await synchronizeUsingImmutableSnapshots(
                    client: client,
                    settings: settings,
                    initialChildren: existingImmutableChildren,
                    initialLegacyResource: remote
                )
                return
            }

            let remoteDocument = try SyncCrypto.decryptDocument(
                from: remote.data,
                passphrase: settings.encryptionPassphrase
            )
            let remoteHash = try SyncCrypto.documentHash(remoteDocument)
            if let anchor {
                try validateRemote(document: remoteDocument, hash: remoteHash, against: anchor)
            }

            var localDocument = snapshot.document
            if localDocument.datasetID != remoteDocument.datasetID {
                localDocument.datasetID = remoteDocument.datasetID
            }
            localDocument.generation = remoteDocument.generation
            localDocument.previousHash = remoteDocument.previousHash

            let merged: SyncDocument
            if !snapshot.hasPortableData && !snapshot.isDirty {
                merged = remoteDocument
            } else {
                merged = try remoteDocument.merged(with: localDocument)
            }

            if try contentEquivalent(merged, remoteDocument) {
                try saveAnchor(
                    document: remoteDocument,
                    hash: remoteHash,
                    settings: settings
                )
                let applied = try store.applyVerifiedDocument(
                    remoteDocument,
                    expectedLocalGeneration: snapshot.localGeneration,
                    markClean: true
                )
                guard applied else { continue }
                setStatus(.lastSuccess(Date()))
                return
            }

            switch try await attestWriteStrategy(client: client, settings: settings) {
            case .strongETag:
                break
            case .exclusiveLock:
                if try await syncExistingUsingExclusiveLock(
                    snapshot: snapshot,
                    anchor: anchor,
                    client: client,
                    settings: settings
                ) {
                    return
                }
                continue
            case .immutableSnapshots:
                try await synchronizeUsingImmutableSnapshots(
                    client: client,
                    settings: settings,
                    initialChildren: existingImmutableChildren,
                    initialLegacyResource: remote
                )
                return
            }

            var uploadBase = merged
            uploadBase.generation = remoteDocument.generation
            uploadBase.previousHash = remoteDocument.previousHash
            let candidate = try uploadBase.nextGeneration(previousHash: remoteHash)
            let encrypted = try SyncCrypto.encrypt(
                document: candidate,
                passphrase: settings.encryptionPassphrase
            )
            do {
                _ = try await withTransientRetry {
                    try await client.upload(encrypted, condition: .matching(remoteStrongETag))
                }
                try Task.checkCancellation()
            } catch WebDAVError.preconditionFailed {
                continue
            }

            if try await verifyAndApply(
                target: candidate,
                client: client,
                settings: settings,
                expectedLocalGeneration: snapshot.localGeneration
            ) {
                return
            }
        }

        throw SyncCoordinatorError.concurrentUpdates
    }

    private func ensureExclusiveLockIsAttested(
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws {
        guard !exclusiveLockAttestedEndpointIdentities.contains(settings.endpointIdentity) else {
            return
        }
        try await withTransientRetry { try await client.verifyExclusiveLockSafety() }
        exclusiveLockAttestedEndpointIdentities.insert(settings.endpointIdentity)
    }

    private func ensureConditionalCreateIsAttested(
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws {
        if !client.hasConditionalCreateAttestation {
            try await withTransientRetry { try await client.verifyConditionalCreateSafety() }
        }
        conditionalCreateAttestedEndpointIdentities.insert(settings.endpointIdentity)
    }

    // Immutable carriers may be published with either a verified conditional
    // PUT or a verified same-collection MOVE with Overwrite: F. The client
    // keeps this proof per instance, so endpoint cache entries never suffice.
    private func ensureImmutableCreateIsAttested(
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws {
        if !client.hasImmutableCreateAttestation {
            try await withTransientRetry { try await client.verifyImmutableCreateSafety() }
        }
        immutableCreateAttestedEndpointIdentities.insert(settings.endpointIdentity)
    }

    private func attestWriteStrategy(
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws -> WriteStrategy {
        let endpointIdentity = settings.endpointIdentity
        if strongETagAttestedEndpointIdentities.contains(endpointIdentity) {
            return .strongETag
        }
        if exclusiveLockAttestedEndpointIdentities.contains(endpointIdentity) {
            return .exclusiveLock
        }
        if conditionalCreateAttestedEndpointIdentities.contains(endpointIdentity)
            || immutableCreateAttestedEndpointIdentities.contains(endpointIdentity) {
            return .immutableSnapshots
        }

        do {
            switch try await withTransientRetry({ try await client.testConnection() }) {
            case .strongETag:
                strongETagAttestedEndpointIdentities.insert(endpointIdentity)
                return .strongETag
            case .exclusiveLock:
                exclusiveLockAttestedEndpointIdentities.insert(endpointIdentity)
                return .exclusiveLock
            }
        } catch WebDAVError.unsafeConditionalUpdate {
            do {
                try await ensureExclusiveLockIsAttested(client: client, settings: settings)
                return .exclusiveLock
            } catch WebDAVError.exclusiveLockUnavailable {
                return try await attestImmutableSnapshots(
                    client: client,
                    settings: settings,
                    failure: .unsafeConditionalUpdate
                )
            } catch WebDAVError.unsafeExclusiveLock {
                return try await attestImmutableSnapshots(
                    client: client,
                    settings: settings,
                    failure: .unsafeConditionalUpdate
                )
            }
        } catch WebDAVError.exclusiveLockUnavailable {
            return try await attestImmutableSnapshots(
                client: client,
                settings: settings,
                failure: .exclusiveLockUnavailable
            )
        } catch WebDAVError.unsafeExclusiveLock {
            return try await attestImmutableSnapshots(
                client: client,
                settings: settings,
                failure: .unsafeExclusiveLock
            )
        } catch WebDAVError.unsafeConditionalCreate {
            return try await attestImmutableSnapshots(
                client: client,
                settings: settings,
                failure: .unsafeConditionalCreate
            )
        }
    }

    private func attestImmutableSnapshots(
        client: WebDAVClient,
        settings: WebDAVSyncSettings,
        failure: WebDAVError
    ) async throws -> WriteStrategy {
        do {
            try await ensureImmutableCreateIsAttested(client: client, settings: settings)
        } catch WebDAVError.methodNotAllowed {
            throw failure
        }
        return .immutableSnapshots
    }

    private func clearWriteAttestations(for endpointIdentity: String) {
        strongETagAttestedEndpointIdentities.remove(endpointIdentity)
        exclusiveLockAttestedEndpointIdentities.remove(endpointIdentity)
        conditionalCreateAttestedEndpointIdentities.remove(endpointIdentity)
        immutableCreateAttestedEndpointIdentities.remove(endpointIdentity)
    }

    private func shouldUseImmutableSnapshots(
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws -> Bool {
        switch try await attestWriteStrategy(client: client, settings: settings) {
        case .strongETag, .exclusiveLock:
            return false
        case .immutableSnapshots:
            return true
        }
    }

    private func loadExistingImmutableChildren(
        client: WebDAVClient
    ) async throws -> [WebDAVCollectionChild]? {
        do {
            return try await withTransientRetry { try await client.listImmutableChildren() }
        } catch WebDAVError.notFound {
            return nil
        } catch WebDAVError.methodNotAllowed {
            // A legacy single-file server can still be used when it provides a
            // strong ETag, even if it does not expose collection listing.
            return nil
        } catch WebDAVError.serverError(statusCode: 501) {
            // Some legacy WebDAV servers report PROPFIND as not implemented.
            // The strong-ETag single-file path remains safe on those servers.
            return nil
        }
    }

    private func synchronizeUsingImmutableSnapshots(
        client: WebDAVClient,
        settings: WebDAVSyncSettings,
        initialChildren: [WebDAVCollectionChild]? = nil,
        initialLegacyResource: WebDAVResource? = nil
    ) async throws {
        var suppliedChildren = initialChildren
        var suppliedLegacyResource = initialLegacyResource
        var collectionExists = initialChildren != nil

        for _ in 0..<3 {
            try Task.checkCancellation()
            let localSnapshot = try store.syncSnapshot()
            let immutableAnchor = try loadImmutableAnchor(for: settings)
            let linearAnchor = try loadAnchor(for: settings)

            if immutableAnchor != nil, !collectionExists {
                throw SyncCoordinatorError.rollbackDetected
            }
            if !collectionExists {
                _ = try await withTransientRetry { try await client.ensureImmutableCollection() }
                collectionExists = true
            }
            let children: [WebDAVCollectionChild]
            if let initial = suppliedChildren {
                children = initial
                suppliedChildren = nil
            } else {
                children = try await withTransientRetry { try await client.listImmutableChildren() }
            }

            let classified = try classifyImmutableChildren(children)
            if let immutableAnchor,
               !Set(immutableAnchor.observedObjectNames).isSubset(
                   of: Set(classified.objects.map(\.name))
               ) {
                throw SyncCoordinatorError.rollbackDetected
            }
            var genesisChild = classified.genesis
            if genesisChild == nil {
                guard classified.objects.isEmpty else {
                    throw SyncCoordinatorError.immutableRepositoryInvalid
                }
                guard immutableAnchor == nil else {
                    throw SyncCoordinatorError.rollbackDetected
                }
                let legacyResource: WebDAVResource?
                if let initial = suppliedLegacyResource {
                    legacyResource = initial
                    suppliedLegacyResource = nil
                } else {
                    legacyResource = try await withTransientRetry { try await client.download() }
                }
                if legacyResource == nil, linearAnchor != nil {
                    throw SyncCoordinatorError.remoteFileDisappeared
                }
                guard localSnapshot.hasPortableData || localSnapshot.isDirty || legacyResource != nil else {
                    setStatus(.lastSuccess(Date()))
                    return
                }

                var genesisDocument = try immutableGenesisDocument(
                    local: localSnapshot.document,
                    includeLocal: localSnapshot.hasPortableData || localSnapshot.isDirty,
                    legacyResource: legacyResource,
                    linearAnchor: linearAnchor,
                    settings: settings
                )
                genesisDocument.previousHash = nil
                genesisDocument = try genesisDocument.nextGeneration(previousHash: nil)
                let genesisSnapshot = try ImmutableSyncSnapshot.genesis(document: genesisDocument)
                let encryptedGenesis = try ImmutableSyncSnapshotCrypto.encrypt(
                    genesisSnapshot,
                    passphrase: settings.encryptionPassphrase
                )

                try await ensureImmutableCreateIsAttested(client: client, settings: settings)
                do {
                    _ = try await withTransientRetry {
                        try await client.createImmutableChild(
                            encryptedGenesis.data,
                            named: ImmutableSyncSnapshotLayout.genesisFileName
                        )
                    }
                } catch WebDAVError.preconditionFailed {
                    // Another device won genesis creation. Its dataset becomes
                    // authoritative and this local state is merged below.
                }
                let refreshed = try await withEventualVisibilityRetry {
                    let children = try await client.listImmutableChildren()
                    let refreshedClassification = try classifyImmutableChildren(children)
                    guard refreshedClassification.genesis == nil else {
                        return children
                    }
                    guard refreshedClassification.objects.isEmpty else {
                        throw SyncCoordinatorError.immutableRepositoryInvalid
                    }
                    return nil
                }
                guard let refreshed else {
                    throw SyncCoordinatorError.verificationFailed
                }
                genesisChild = try classifyImmutableChildren(refreshed).genesis
                suppliedChildren = refreshed
                continue
            }

            guard let genesisChild else {
                throw SyncCoordinatorError.immutableRepositoryInvalid
            }
            let loaded = try await loadImmutableCarriers(
                genesisChild: genesisChild,
                objectChildren: classified.objects,
                client: client,
                settings: settings
            )
            let genesis = loaded.genesis
            let carriers = loaded.carriers
            try validateImmutableGraph(genesis: genesis, carriers: carriers)

            if let immutableAnchor {
                try validateImmutableAnchor(
                    immutableAnchor,
                    genesis: genesis,
                    carriers: carriers,
                    currentObjectNames: Set(classified.objects.map(\.name)),
                    settings: settings
                )
            }

            var merged = genesis.snapshot.document
            for carrier in carriers.sorted(by: { $0.fileName < $1.fileName }) {
                merged = try merged.merged(with: carrier.snapshot.document)
            }

            if immutableAnchor == nil {
                let legacyResource: WebDAVResource?
                if let initial = suppliedLegacyResource {
                    legacyResource = initial
                    suppliedLegacyResource = nil
                } else {
                    legacyResource = try await withTransientRetry { try await client.download() }
                }
                if let legacyResource {
                    let legacyDocument = try SyncCrypto.decryptDocument(
                        from: legacyResource.data,
                        passphrase: settings.encryptionPassphrase
                    )
                    let legacyHash = try SyncCrypto.documentHash(legacyDocument)
                    if let linearAnchor {
                        try validateRemote(document: legacyDocument, hash: legacyHash, against: linearAnchor)
                    }
                    guard legacyDocument.datasetID == genesis.snapshot.datasetID else {
                        throw SyncCoordinatorError.remoteDatasetChanged
                    }
                    merged = try merged.merged(with: legacyDocument)
                } else if linearAnchor != nil {
                    throw SyncCoordinatorError.remoteFileDisappeared
                }
            }

            if localSnapshot.hasPortableData || localSnapshot.isDirty {
                var localDocument = localSnapshot.document
                localDocument.datasetID = genesis.snapshot.datasetID
                merged = try merged.merged(with: localDocument)
            }

            let allCarriers = [genesis] + carriers
            let anchoredCarrier = immutableAnchor.flatMap { anchor in
                allCarriers.first(where: { $0.reference == anchor.carrier })
            }
            if let anchoredCarrier,
               try !documentContent(merged, contains: anchoredCarrier.snapshot.document) {
                throw SyncCoordinatorError.rollbackDetected
            }

            var selectedCarrier = try selectEquivalentCarrier(
                for: merged,
                preferred: anchoredCarrier,
                from: allCarriers
            )
            var observedObjectNames = Set(classified.objects.map(\.name))

            if selectedCarrier == nil {
                guard observedObjectNames.count < Self.maximumImmutableObjectCount else {
                    throw SyncCoordinatorError.immutableRepositoryTooLarge
                }
                let parent = anchoredCarrier ?? genesis
                let parentDocumentHash = try SyncCrypto.documentHash(parent.snapshot.document)
                var candidateDocument = merged
                candidateDocument.generation = max(
                    candidateDocument.generation,
                    parent.snapshot.document.generation
                )
                candidateDocument = try candidateDocument.nextGeneration(
                    previousHash: parentDocumentHash
                )
                let candidateSnapshot = try ImmutableSyncSnapshot.successor(
                    parent: parent.reference,
                    document: candidateDocument
                )
                let encrypted = try ImmutableSyncSnapshotCrypto.encrypt(
                    candidateSnapshot,
                    passphrase: settings.encryptionPassphrase
                )
                let downloadedByteCount = allCarriers.reduce(0) {
                    $0 + $1.encryptedByteCount
                }
                guard downloadedByteCount <= Self.maximumImmutableDownloadBytes - encrypted.data.count else {
                    throw SyncCoordinatorError.immutableRepositoryTooLarge
                }
                try await ensureImmutableCreateIsAttested(client: client, settings: settings)
                do {
                    _ = try await withTransientRetry {
                        try await client.createImmutableChild(
                            encrypted.data,
                            named: encrypted.objectFileName
                        )
                    }
                } catch WebDAVError.preconditionFailed {
                    // A retry may encounter the exact content-addressed object.
                }
                guard let verifiedData = try await withEventualVisibilityRetry({
                    try await client.downloadImmutableChild(named: encrypted.objectFileName)
                }) else {
                    throw SyncCoordinatorError.verificationFailed
                }
                let verifiedSnapshot = try ImmutableSyncSnapshotCrypto.decryptObject(
                    verifiedData,
                    fileName: encrypted.objectFileName,
                    passphrase: settings.encryptionPassphrase,
                    expectedDatasetID: genesis.snapshot.datasetID
                )
                guard verifiedSnapshot.snapshotID == candidateSnapshot.snapshotID,
                      try documentContent(verifiedSnapshot.document, contains: parent.snapshot.document),
                      try contentEquivalent(verifiedSnapshot.document, candidateDocument) else {
                    throw SyncCoordinatorError.verificationFailed
                }
                let verifiedBlob = ImmutableEncryptedSyncSnapshot(data: verifiedData)
                let reference = try verifiedBlob.carrierReference(
                    kind: .object,
                    snapshotID: verifiedSnapshot.snapshotID
                )
                selectedCarrier = LoadedImmutableCarrier(
                    fileName: encrypted.objectFileName,
                    reference: reference,
                    snapshot: verifiedSnapshot,
                    encryptedByteCount: verifiedData.count
                )
                observedObjectNames.insert(encrypted.objectFileName)
            }

            guard let selectedCarrier else {
                throw SyncCoordinatorError.verificationFailed
            }
            guard observedObjectNames.count <= Self.maximumImmutableObjectCount else {
                throw SyncCoordinatorError.immutableRepositoryTooLarge
            }
            let selectedDocumentHash = try SyncCrypto.documentHash(selectedCarrier.snapshot.document)
            try saveImmutableAnchor(
                ImmutableAnchor(
                    endpointIdentity: settings.endpointIdentity,
                    datasetID: genesis.snapshot.datasetID,
                    genesisEncryptedPayloadHash: genesis.reference.encryptedPayloadHash,
                    carrier: selectedCarrier.reference,
                    carrierDocumentHash: selectedDocumentHash,
                    observedObjectNames: observedObjectNames.sorted(),
                    lastSuccess: Date()
                ),
                settings: settings
            )
            let applied = try store.applyVerifiedDocument(
                selectedCarrier.snapshot.document,
                expectedLocalGeneration: localSnapshot.localGeneration,
                markClean: true
            )
            guard applied else { continue }
            setStatus(.lastSuccess(Date()))
            return
        }

        throw SyncCoordinatorError.concurrentUpdates
    }

    private func classifyImmutableChildren(
        _ children: [WebDAVCollectionChild]
    ) throws -> (genesis: WebDAVCollectionChild?, objects: [WebDAVCollectionChild]) {
        var genesis: WebDAVCollectionChild?
        var objects: [WebDAVCollectionChild] = []
        for child in children {
            if child.name == ImmutableSyncSnapshotLayout.genesisFileName {
                guard genesis == nil else {
                    throw SyncCoordinatorError.immutableRepositoryInvalid
                }
                genesis = child
                continue
            }
            if child.name.hasSuffix(".\(ImmutableSyncSnapshotLayout.objectFileExtension)") {
                _ = try ImmutableSyncSnapshotLayout.encryptedPayloadHash(
                    fromObjectFileName: child.name
                )
                objects.append(child)
            }
        }
        guard objects.count <= Self.maximumImmutableObjectCount else {
            throw SyncCoordinatorError.immutableRepositoryTooLarge
        }
        return (genesis, objects)
    }

    private func immutableGenesisDocument(
        local: SyncDocument,
        includeLocal: Bool,
        legacyResource: WebDAVResource?,
        linearAnchor: Anchor?,
        settings: WebDAVSyncSettings
    ) throws -> SyncDocument {
        guard let legacyResource else {
            return local
        }
        let legacy = try SyncCrypto.decryptDocument(
            from: legacyResource.data,
            passphrase: settings.encryptionPassphrase
        )
        let legacyHash = try SyncCrypto.documentHash(legacy)
        if let linearAnchor {
            try validateRemote(document: legacy, hash: legacyHash, against: linearAnchor)
        }
        guard includeLocal else { return legacy }
        var reboundLocal = local
        reboundLocal.datasetID = legacy.datasetID
        return try legacy.merged(with: reboundLocal)
    }

    private func loadImmutableCarriers(
        genesisChild: WebDAVCollectionChild,
        objectChildren: [WebDAVCollectionChild],
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws -> (genesis: LoadedImmutableCarrier, carriers: [LoadedImmutableCarrier]) {
        guard let genesisData = try await withEventualVisibilityRetry({
            try await client.downloadImmutableChild(genesisChild)
        }) else {
            throw SyncCoordinatorError.immutableRepositoryInvalid
        }
        let genesisHash = SyncCrypto.sha256Hex(genesisData)
        let genesisSnapshot = try ImmutableSyncSnapshotCrypto.decryptGenesis(
            genesisData,
            passphrase: settings.encryptionPassphrase,
            expectedEncryptedPayloadHash: genesisHash
        )
        let genesisBlob = ImmutableEncryptedSyncSnapshot(data: genesisData)
        let genesisReference = try genesisBlob.carrierReference(
            kind: .genesis,
            snapshotID: genesisSnapshot.snapshotID
        )
        let genesis = LoadedImmutableCarrier(
            fileName: ImmutableSyncSnapshotLayout.genesisFileName,
            reference: genesisReference,
            snapshot: genesisSnapshot,
            encryptedByteCount: genesisData.count
        )

        var totalBytes = genesisData.count
        var carriers: [LoadedImmutableCarrier] = []
        var snapshotIDs: Set<UUID> = [genesisSnapshot.snapshotID]
        for child in objectChildren.sorted(by: { $0.name < $1.name }) {
            guard let data = try await withEventualVisibilityRetry({
                try await client.downloadImmutableChild(child)
            }) else {
                throw SyncCoordinatorError.immutableRepositoryInvalid
            }
            totalBytes += data.count
            guard totalBytes <= Self.maximumImmutableDownloadBytes else {
                throw SyncCoordinatorError.immutableRepositoryTooLarge
            }
            let snapshot = try ImmutableSyncSnapshotCrypto.decryptObject(
                data,
                fileName: child.name,
                passphrase: settings.encryptionPassphrase,
                expectedDatasetID: genesisSnapshot.datasetID
            )
            guard snapshotIDs.insert(snapshot.snapshotID).inserted else {
                throw SyncCoordinatorError.immutableRepositoryInvalid
            }
            let blob = ImmutableEncryptedSyncSnapshot(data: data)
            let reference = try blob.carrierReference(
                kind: .object,
                snapshotID: snapshot.snapshotID
            )
            carriers.append(LoadedImmutableCarrier(
                fileName: child.name,
                reference: reference,
                snapshot: snapshot,
                encryptedByteCount: data.count
            ))
        }
        return (genesis, carriers)
    }

    private func validateImmutableGraph(
        genesis: LoadedImmutableCarrier,
        carriers: [LoadedImmutableCarrier]
    ) throws {
        let all = [genesis] + carriers
        let byReference = Dictionary(uniqueKeysWithValues: all.map { ($0.reference, $0) })
        for carrier in carriers {
            guard let parentReference = carrier.snapshot.parent,
                  let parent = byReference[parentReference],
                  try documentContent(carrier.snapshot.document, contains: parent.snapshot.document) else {
                throw SyncCoordinatorError.immutableRepositoryInvalid
            }

            var visited: Set<ImmutableSyncCarrierReference> = [carrier.reference]
            var cursor = parent
            while cursor.reference.kind != .genesis {
                guard visited.insert(cursor.reference).inserted,
                      let nextReference = cursor.snapshot.parent,
                      let next = byReference[nextReference] else {
                    throw SyncCoordinatorError.immutableRepositoryInvalid
                }
                cursor = next
            }
            guard cursor.reference == genesis.reference else {
                throw SyncCoordinatorError.immutableRepositoryInvalid
            }
        }
    }

    private func validateImmutableAnchor(
        _ anchor: ImmutableAnchor,
        genesis: LoadedImmutableCarrier,
        carriers: [LoadedImmutableCarrier],
        currentObjectNames: Set<String>,
        settings: WebDAVSyncSettings
    ) throws {
        guard anchor.endpointIdentity == settings.endpointIdentity,
              anchor.datasetID == genesis.snapshot.datasetID,
              anchor.genesisEncryptedPayloadHash == genesis.reference.encryptedPayloadHash,
              Set(anchor.observedObjectNames).isSubset(of: currentObjectNames),
              let carrier = ([genesis] + carriers).first(where: { $0.reference == anchor.carrier }),
              try SyncCrypto.documentHash(carrier.snapshot.document) == anchor.carrierDocumentHash else {
            throw SyncCoordinatorError.rollbackDetected
        }
    }

    private func selectEquivalentCarrier(
        for document: SyncDocument,
        preferred: LoadedImmutableCarrier?,
        from carriers: [LoadedImmutableCarrier]
    ) throws -> LoadedImmutableCarrier? {
        if let preferred, try contentEquivalent(preferred.snapshot.document, document) {
            return preferred
        }
        for carrier in carriers.sorted(by: { $0.fileName > $1.fileName })
        where try contentEquivalent(carrier.snapshot.document, document) {
            return carrier
        }
        return nil
    }

    private func documentContent(_ observed: SyncDocument, contains target: SyncDocument) throws -> Bool {
        guard observed.datasetID == target.datasetID else { return false }
        var observedContent = observed
        var targetContent = target
        observedContent.generation = 0
        observedContent.previousHash = nil
        targetContent.generation = 0
        targetContent.previousHash = nil
        let merged = try targetContent.merged(with: observedContent)
        return try contentEquivalent(merged, observedContent)
    }

    private func syncExistingUsingExclusiveLock(
        snapshot: ConfigurationSyncSnapshot,
        anchor: Anchor?,
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws -> Bool {
        let lock = try await acquireExclusiveLockWithContentionRetry(client: client)
        do {
            try Task.checkCancellation()
            guard let lockedRemote = try await withTransientRetry({ try await client.download() }) else {
                throw SyncCoordinatorError.remoteFileDisappeared
            }
            try Task.checkCancellation()

            let remoteDocument = try SyncCrypto.decryptDocument(
                from: lockedRemote.data,
                passphrase: settings.encryptionPassphrase
            )
            let remoteHash = try SyncCrypto.documentHash(remoteDocument)
            if let anchor {
                try validateRemote(document: remoteDocument, hash: remoteHash, against: anchor)
            }

            var localDocument = snapshot.document
            if localDocument.datasetID != remoteDocument.datasetID {
                localDocument.datasetID = remoteDocument.datasetID
            }
            localDocument.generation = remoteDocument.generation
            localDocument.previousHash = remoteDocument.previousHash

            let merged: SyncDocument
            if !snapshot.hasPortableData && !snapshot.isDirty {
                merged = remoteDocument
            } else {
                merged = try remoteDocument.merged(with: localDocument)
            }

            let verifiedDocument: SyncDocument
            let verifiedHash: String
            if try contentEquivalent(merged, remoteDocument) {
                verifiedDocument = remoteDocument
                verifiedHash = remoteHash
            } else {
                var uploadBase = merged
                uploadBase.generation = remoteDocument.generation
                uploadBase.previousHash = remoteDocument.previousHash
                let candidate = try uploadBase.nextGeneration(previousHash: remoteHash)
                let encrypted = try SyncCrypto.encrypt(
                    document: candidate,
                    passphrase: settings.encryptionPassphrase
                )
                do {
                    _ = try await client.upload(encrypted, condition: .locked(lock))
                } catch WebDAVError.preconditionFailed {
                    try? await client.releaseExclusiveWriteLock(lock)
                    return false
                } catch WebDAVError.locked {
                    try? await client.releaseExclusiveWriteLock(lock)
                    return false
                }
                try Task.checkCancellation()
                (verifiedDocument, verifiedHash) = try await verifyLockedWrite(
                    target: candidate,
                    client: client,
                    settings: settings
                )
            }

            try await client.releaseExclusiveWriteLock(lock)
            try Task.checkCancellation()
            try saveAnchor(
                document: verifiedDocument,
                hash: verifiedHash,
                settings: settings
            )
            let applied = try store.applyVerifiedDocument(
                verifiedDocument,
                expectedLocalGeneration: snapshot.localGeneration,
                markClean: true
            )
            guard applied else { return false }
            setStatus(.lastSuccess(Date()))
            return true
        } catch {
            await releaseLockAfterFailure(lock, client: client)
            throw error
        }
    }

    private func acquireExclusiveLockWithContentionRetry(
        client: WebDAVClient
    ) async throws -> WebDAVWriteLock {
        let delays: [UInt64] = [0, 1, 2, 4]
        var lastError: Error?
        for delay in delays {
            try Task.checkCancellation()
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            do {
                return try await client.acquireExclusiveWriteLock()
            } catch WebDAVError.locked {
                lastError = WebDAVError.locked
            }
        }
        throw lastError ?? WebDAVError.unsafeExclusiveLock
    }

    private func verifyLockedWrite(
        target: SyncDocument,
        client: WebDAVClient,
        settings: WebDAVSyncSettings
    ) async throws -> (SyncDocument, String) {
        guard let resource = try await withTransientRetry({ try await client.download() }) else {
            throw SyncCoordinatorError.verificationFailed
        }
        try Task.checkCancellation()
        let verified = try SyncCrypto.decryptDocument(
            from: resource.data,
            passphrase: settings.encryptionPassphrase
        )
        let verifiedHash = try SyncCrypto.documentHash(verified)
        let targetHash = try SyncCrypto.documentHash(target)
        guard verified.generation == target.generation,
              verifiedHash == targetHash,
              try document(verified, contains: target) else {
            throw SyncCoordinatorError.verificationFailed
        }
        return (verified, verifiedHash)
    }

    private func releaseLockAfterFailure(
        _ lock: WebDAVWriteLock,
        client: WebDAVClient
    ) async {
        let cleanup = Task.detached(priority: .utility) {
            try? await client.releaseExclusiveWriteLock(lock)
        }
        _ = await cleanup.value
    }

    private func verifyAndApply(
        target: SyncDocument,
        client: WebDAVClient,
        settings: WebDAVSyncSettings,
        expectedLocalGeneration: UInt64
    ) async throws -> Bool {
        guard let verifiedResource = try await withTransientRetry({ try await client.download() }) else {
            throw SyncCoordinatorError.verificationFailed
        }
        try Task.checkCancellation()
        let verified = try SyncCrypto.decryptDocument(
            from: verifiedResource.data,
            passphrase: settings.encryptionPassphrase
        )
        let verifiedHash = try SyncCrypto.documentHash(verified)
        let targetHash = try SyncCrypto.documentHash(target)
        if verified.generation == target.generation {
            guard verifiedHash == targetHash else {
                throw SyncCoordinatorError.verificationFailed
            }
        } else if target.generation < UInt64.max,
                  verified.generation == target.generation + 1 {
            guard verified.previousHash == targetHash else {
                throw SyncCoordinatorError.verificationFailed
            }
        } else {
            throw SyncCoordinatorError.verificationFailed
        }
        guard try document(verified, contains: target) else {
            return false
        }
        try Task.checkCancellation()
        try saveAnchor(document: verified, hash: verifiedHash, settings: settings)
        let applied = try store.applyVerifiedDocument(
            verified,
            expectedLocalGeneration: expectedLocalGeneration,
            markClean: true
        )
        guard applied else { return false }
        try Task.checkCancellation()
        setStatus(.lastSuccess(Date()))
        return true
    }

    private func validateRemote(document: SyncDocument, hash: String, against anchor: Anchor) throws {
        guard document.datasetID == anchor.datasetID else {
            throw SyncCoordinatorError.remoteDatasetChanged
        }
        guard document.generation >= anchor.generation else {
            throw SyncCoordinatorError.rollbackDetected
        }
        if document.generation == anchor.generation {
            guard hash == anchor.documentHash else {
                throw SyncCoordinatorError.rollbackDetected
            }
        } else if anchor.generation < UInt64.max,
                  document.generation == anchor.generation + 1 {
            guard document.previousHash == anchor.documentHash else {
                throw SyncCoordinatorError.rollbackDetected
            }
        }
    }

    private func document(_ observed: SyncDocument, contains target: SyncDocument) throws -> Bool {
        guard observed.datasetID == target.datasetID,
              observed.generation >= target.generation else {
            return false
        }
        var observedContent = observed
        var targetContent = target
        observedContent.generation = 0
        observedContent.previousHash = nil
        targetContent.generation = 0
        targetContent.previousHash = nil
        let merged = try targetContent.merged(with: observedContent)
        return try contentEquivalent(merged, observedContent)
    }

    private func contentEquivalent(_ lhs: SyncDocument, _ rhs: SyncDocument) throws -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.generation = 0
        lhs.previousHash = nil
        rhs.generation = 0
        rhs.previousHash = nil
        return try lhs.canonicalData() == rhs.canonicalData()
    }

    private func withTransientRetry<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for delay in retryDelaysNanoseconds {
            try Task.checkCancellation()
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            } catch {
                guard isTransient(error) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? WebDAVError.transportFailure("请求失败")
    }

    private func withEventualVisibilityRetry<T: Sendable>(
        _ operation: () async throws -> T?
    ) async throws -> T? {
        var lastError: Error?
        for delay in retryDelaysNanoseconds {
            try Task.checkCancellation()
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                if let result = try await operation() {
                    try Task.checkCancellation()
                    return result
                }
                lastError = nil
            } catch {
                guard isTransient(error) else { throw error }
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        return nil
    }

    private func isTransient(_ error: Error) -> Bool {
        guard let error = error as? WebDAVError else { return false }
        switch error {
        case .transportFailure, .locked, .rateLimited:
            return true
        case .serverError(let statusCode):
            return statusCode != 501
        case .httpStatus(let statusCode):
            return statusCode == 408
        default:
            return false
        }
    }

    private func loadBootstrap() throws -> Bootstrap? {
        guard let data = try keychain.readData(account: Accounts.bootstrap) else {
            return nil
        }
        guard let bootstrap = try? decoder.decode(Bootstrap.self, from: data),
              bootstrap.schemaVersion == 1 else {
            throw SyncCoordinatorError.invalidLocalMetadata
        }
        return bootstrap
    }

    private func loadAnchor(for settings: WebDAVSyncSettings) throws -> Anchor? {
        let endpointIdentity = settings.endpointIdentity
        let account = Accounts.anchor(endpointIdentity: endpointIdentity)
        if let data = try keychain.readData(account: account) {
            let anchor = try decodeAnchor(data)
            guard anchor.endpointIdentity == endpointIdentity else {
                throw SyncCoordinatorError.invalidLocalMetadata
            }
            return anchor
        }

        guard let legacyData = try keychain.readData(account: Accounts.legacyAnchor) else {
            return nil
        }
        let legacyAnchor = try decodeAnchor(legacyData)
        guard legacyAnchor.endpointIdentity == endpointIdentity
                || legacyAnchor.endpointIdentity == settings.legacyEndpointIdentity else {
            return nil
        }

        let migratedAnchor = Anchor(
            endpointIdentity: endpointIdentity,
            datasetID: legacyAnchor.datasetID,
            generation: legacyAnchor.generation,
            documentHash: legacyAnchor.documentHash,
            lastSuccess: legacyAnchor.lastSuccess
        )
        try keychain.save(
            encoder.encode(migratedAnchor),
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        try? keychain.delete(account: Accounts.legacyAnchor)
        return migratedAnchor
    }

    private func decodeAnchor(_ data: Data) throws -> Anchor {
        guard let anchor = try? decoder.decode(Anchor.self, from: data),
              anchor.schemaVersion == 1 else {
            throw SyncCoordinatorError.invalidLocalMetadata
        }
        return anchor
    }

    private func loadImmutableAnchor(for settings: WebDAVSyncSettings) throws -> ImmutableAnchor? {
        let account = Accounts.immutableAnchor(endpointIdentity: settings.endpointIdentity)
        guard let data = try keychain.readData(account: account) else {
            return nil
        }
        guard let anchor = try? decoder.decode(ImmutableAnchor.self, from: data),
              anchor.schemaVersion == 1,
              anchor.endpointIdentity == settings.endpointIdentity,
              ImmutableSyncSnapshotLayout.isValidEncryptedPayloadHash(
                anchor.genesisEncryptedPayloadHash
              ),
              Set(anchor.observedObjectNames).count == anchor.observedObjectNames.count,
              anchor.observedObjectNames.count <= Self.maximumImmutableObjectCount,
              anchor.observedObjectNames.allSatisfy({
                (try? ImmutableSyncSnapshotLayout.encryptedPayloadHash(
                    fromObjectFileName: $0
                )) != nil
              }) else {
            throw SyncCoordinatorError.invalidLocalMetadata
        }
        return anchor
    }

    private func saveAnchor(document: SyncDocument, hash: String, settings: WebDAVSyncSettings) throws {
        let anchor = Anchor(
            endpointIdentity: settings.endpointIdentity,
            datasetID: document.datasetID,
            generation: document.generation,
            documentHash: hash,
            lastSuccess: Date()
        )
        try keychain.save(
            encoder.encode(anchor),
            account: Accounts.anchor(endpointIdentity: settings.endpointIdentity),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    private func saveImmutableAnchor(
        _ anchor: ImmutableAnchor,
        settings: WebDAVSyncSettings
    ) throws {
        guard anchor.endpointIdentity == settings.endpointIdentity else {
            throw SyncCoordinatorError.invalidLocalMetadata
        }
        try keychain.save(
            encoder.encode(anchor),
            account: Accounts.immutableAnchor(endpointIdentity: settings.endpointIdentity),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    private func setFailure(_ error: Error) {
        setStatus(.failed(sanitizedMessage(for: error)))
    }

    private func sanitizedMessage(for error: Error) -> String {
        if case WebDAVError.transportFailure = error {
            return "WebDAV 网络连接失败，请检查网络和服务器地址"
        }
        return (error as? LocalizedError)?.errorDescription ?? "同步失败，请稍后重试"
    }

    private func setStatus(_ newStatus: SyncCoordinatorStatus) {
        guard status != newStatus else { return }
        status = newStatus
        let post = { [notificationCenter] in
            notificationCenter.post(
                name: .syncCoordinatorStatusDidChange,
                object: nil,
                userInfo: ["status": newStatus]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async { [notificationCenter] in
                notificationCenter.post(
                    name: .syncCoordinatorStatusDidChange,
                    object: nil,
                    userInfo: ["status": newStatus]
                )
            }
        }
    }
}
