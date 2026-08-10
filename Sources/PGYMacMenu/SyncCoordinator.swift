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
        relativePath: String = "PGYMacMenu.sync",
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

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 WebDAV 同步"
        case .incompleteSettings:
            return "请完整填写 WebDAV 用户名和密码"
        case .invalidLocalMetadata:
            return "本机同步元数据无效"
        case .remoteFileDisappeared:
            return "远端同步文件曾经存在但现在已丢失，已停止自动上传"
        case .rollbackDetected:
            return "检测到远端同步数据回退，已停止自动覆盖"
        case .remoteDatasetChanged:
            return "远端同步文件已被替换为另一个数据集"
        case .concurrentUpdates:
            return "远端数据正在被其他设备频繁修改，请稍后重试"
        case .verificationFailed:
            return "上传后的远端数据校验失败，未清除待同步状态"
        }
    }
}

actor SyncCoordinator {
    typealias ClientFactory = @Sendable (WebDAVConfiguration) throws -> WebDAVClient

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

    private enum Accounts {
        static let bootstrap = "webdav.bootstrap.v1"
        static let legacyAnchor = "webdav.anchor.v1"

        static func anchor(endpointIdentity: String) -> String {
            let digest = SyncCrypto.sha256Hex(Data(endpointIdentity.utf8))
            return "webdav.anchor.v2.\(digest)"
        }
    }

    private let store: ConfigurationStore
    private let keychain: KeychainStore
    private let notificationCenter: NotificationCenter
    private let clientFactory: ClientFactory
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private var status: SyncCoordinatorStatus = .notConfigured
    private var debounceTask: Task<Void, Never>?
    private var activeSync: ActiveSync?
    private var resyncRequested = false

    init(
        store: ConfigurationStore,
        keychain: KeychainStore = KeychainStore(service: "com.egan.PGYMacMenu.sync"),
        notificationCenter: NotificationCenter = .default,
        clientFactory: @escaping ClientFactory = { try WebDAVClient(configuration: $0) }
    ) {
        self.store = store
        self.keychain = keychain
        self.notificationCenter = notificationCenter
        self.clientFactory = clientFactory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        debounceTask?.cancel()
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
            } else if let anchor = try loadAnchor(for: bootstrap.settings) {
                setStatus(.lastSuccess(anchor.lastSuccess))
            } else {
                setStatus(.pending)
            }
            try await synchronize()
        } catch is CancellationError {
            return
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
        try await withTransientRetry { try await client.testConnection() }
        if let resource = try await withTransientRetry({ try await client.download() }) {
            let document = try SyncCrypto.decryptDocument(
                from: resource.data,
                passphrase: settings.encryptionPassphrase
            )
            let hash = try SyncCrypto.documentHash(document)
            if let anchor = try loadAnchor(for: settings) {
                try validateRemote(document: document, hash: hash, against: anchor)
            }
        }
    }

    func saveSettings(_ settings: WebDAVSyncSettings) async throws {
        let settings = try settings.validated()
        await cancelSyncWork()
        try await testConnection(settings)
        await cancelSyncWork()

        let bootstrap = Bootstrap(settings: settings)
        try keychain.save(
            encoder.encode(bootstrap),
            account: Accounts.bootstrap,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        setStatus(.pending)
        try await synchronize()
    }

    func removeSettings() async throws {
        await cancelSyncWork()
        try keychain.delete(account: Accounts.bootstrap)
        setStatus(.notConfigured)
    }

    func scheduleLocalChange() {
        debounceTask?.cancel()
        guard (try? loadBootstrap()) != nil else {
            setStatus(.notConfigured)
            return
        }
        setStatus(.pending)
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                try await self?.synchronize()
            } catch is CancellationError {
                return
            } catch {
                await self?.setFailure(error)
            }
        }
    }

    func applicationDidBecomeActive() async {
        guard (try? loadBootstrap()) != nil else {
            setStatus(.notConfigured)
            return
        }
        do {
            try await synchronize()
        } catch is CancellationError {
            return
        } catch {
            setStatus(.failed(sanitizedMessage(for: error)))
        }
    }

    func synchronizeNow() async throws {
        guard try loadBootstrap() != nil else {
            throw SyncCoordinatorError.notConfigured
        }
        debounceTask?.cancel()
        debounceTask = nil
        try await synchronize()
    }

    func flushPendingChanges() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        guard store.hasPendingSyncChanges() else {
            return true
        }
        guard (try? loadBootstrap()) != nil else {
            return false
        }
        do {
            try await synchronize()
            return !store.hasPendingSyncChanges()
        } catch {
            setStatus(.failed(sanitizedMessage(for: error)))
            return false
        }
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
        debounceTask?.cancel()
        debounceTask = nil
        resyncRequested = false

        while let activeSync {
            activeSync.task.cancel()
            _ = try? await activeSync.task.value
            if self.activeSync?.id == activeSync.id {
                self.activeSync = nil
            }
            debounceTask?.cancel()
            debounceTask = nil
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
                    try await client.upload(encrypted, condition: .matching(remote.strongETag))
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
        let delays: [UInt64] = [0, 1, 2, 4]
        var lastError: Error?
        for delay in delays {
            try Task.checkCancellation()
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
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

    private func isTransient(_ error: Error) -> Bool {
        guard let error = error as? WebDAVError else { return false }
        switch error {
        case .transportFailure, .locked, .rateLimited, .serverError:
            return true
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
