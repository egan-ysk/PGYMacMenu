import Foundation

extension Notification.Name {
    static let configurationStoreDidChange = Notification.Name("ConfigurationStoreDidChange")
}

enum ConfigurationChangeSource: String, Sendable {
    case local
    case remote
    case migration
}

enum ConfigurationChangeCategory: String, Codable, CaseIterable, Sendable {
    case apiKeyProfiles
    case updateTemplates
    case preferences
}

enum ConfigurationStoreError: LocalizedError {
    case invalidManifest
    case unsupportedManifestVersion(Int)
    case missingSecret(UUID)
    case deletedRecordCannotBeReused
    case generationOverflow
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "本机配置数据无效"
        case .unsupportedManifestVersion(let version):
            return "不支持的本机配置版本：\(version)"
        case .missingSecret:
            return "钥匙串中的 API 密钥数据不完整"
        case .deletedRecordCannotBeReused:
            return "已删除配置的标识不能重复使用"
        case .generationOverflow:
            return "本机配置版本号已达到上限"
        case .persistenceFailed:
            return "无法保存本机配置"
        }
    }
}

struct ConfigurationSyncSnapshot: Sendable {
    let document: SyncDocument
    let localGeneration: UInt64
    let isDirty: Bool
    let hasPortableData: Bool
}

final class ConfigurationStore: @unchecked Sendable {
    private enum Keys {
        static let manifest = "configuration_manifest_v2"
        static let apiKeyProfiles = "api_key_profiles"
        static let updateTemplates = "update_templates"
        static let preferences = "preferences"
        static let deviceIDAccount = "sync.device-id"

        static func secretsAccount(_ generation: UInt64) -> String {
            "configuration.secrets.v2.\(generation)"
        }
    }

    private struct ProfileMetadata: Codable, Hashable, Sendable {
        var name: String
        var updateTemplate: String
    }

    private struct SecretEntry: Codable, Hashable, Sendable {
        var id: UUID
        var apiKey: String
        var password: String
    }

    private struct SecretBlob: Codable, Hashable, Sendable {
        var schemaVersion: Int = 1
        var profiles: [SecretEntry]

        func value(for id: UUID) -> SecretEntry? {
            profiles.first { $0.id == id }
        }
    }

    private struct LocalManifest: Codable, Hashable, Sendable {
        var schemaVersion: Int = 2
        var datasetID: UUID
        var remoteGeneration: UInt64
        var secretGeneration: UInt64
        var localGeneration: UInt64
        var lastClock: HLCRevision?
        var dirty: Bool
        var profiles: [VersionedRecord<ProfileMetadata>]
        var templates: [VersionedRecord<SyncUpdateTemplateValue>]
        var preferences: VersionedRecord<SyncPreferencesValue>
        var preferencesWereExplicitlySet: Bool
        var aaptPath: String
        var androidSDKPath: String
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let notificationCenter: NotificationCenter
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(service: "com.egan.PGYMacMenu"),
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.notificationCenter = notificationCenter
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func loadAPIKeyProfiles() -> [APIKeyProfile] {
        (try? loadAPIKeyProfilesThrowing()) ?? []
    }

    func loadAPIKeyProfilesThrowing() throws -> [APIKeyProfile] {
        try withLock {
            let manifest = try loadOrMigrateManifest()
            let secrets = try loadSecrets(generation: manifest.secretGeneration)
            return try manifest.profiles.compactMap { record in
                guard let value = record.value else { return nil }
                guard let secret = secrets.value(for: record.id) else {
                    throw ConfigurationStoreError.missingSecret(record.id)
                }
                return APIKeyProfile(
                    id: record.id,
                    name: value.name,
                    apiKey: secret.apiKey,
                    password: secret.password,
                    updateTemplate: value.updateTemplate
                )
            }
        }
    }

    func saveAPIKeyProfile(_ profile: APIKeyProfile) throws {
        let changed = try withLock { () -> Bool in
            var manifest = try loadOrMigrateManifest()
            var secrets = try loadSecrets(generation: manifest.secretGeneration)
            let normalized = APIKeyProfile(
                id: profile.id,
                name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                password: profile.password.trimmingCharacters(in: .whitespacesAndNewlines),
                updateTemplate: profile.updateTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            let existingIndex = manifest.profiles.firstIndex { $0.id == normalized.id }
            if let existingIndex, manifest.profiles[existingIndex].isTombstone {
                throw ConfigurationStoreError.deletedRecordCannotBeReused
            }
            let existing = existingIndex.map { manifest.profiles[$0] }
            let newValue = ProfileMetadata(name: normalized.name, updateTemplate: normalized.updateTemplate)
            let oldSecret = secrets.value(for: normalized.id)
            guard existing?.value != newValue || oldSecret?.apiKey != normalized.apiKey || oldSecret?.password != normalized.password else {
                return false
            }

            let revision = tick(&manifest)
            let order = existing?.order ?? nextOrder(in: manifest.profiles.map(\.order))
            let record = VersionedRecord(
                id: normalized.id,
                order: order,
                revision: revision,
                writerDeviceID: try deviceID(),
                value: newValue
            )
            if let existingIndex {
                manifest.profiles[existingIndex] = record
            } else {
                manifest.profiles.append(record)
            }
            secrets.profiles.removeAll { $0.id == normalized.id }
            secrets.profiles.append(SecretEntry(id: normalized.id, apiKey: normalized.apiKey, password: normalized.password))
            try commitMutation(&manifest, secrets: secrets, marksDirty: true)
            return true
        }
        if changed { postChange(source: .local, categories: [.apiKeyProfiles]) }
    }

    func deleteAPIKeyProfile(id: UUID) throws {
        let changed = try withLock { () -> Bool in
            var manifest = try loadOrMigrateManifest()
            guard let index = manifest.profiles.firstIndex(where: { $0.id == id && !$0.isTombstone }) else {
                return false
            }
            var secrets = try loadSecrets(generation: manifest.secretGeneration)
            let existing = manifest.profiles[index]
            manifest.profiles[index] = .tombstone(
                id: id,
                order: existing.order,
                revision: tick(&manifest),
                writerDeviceID: try deviceID()
            )
            secrets.profiles.removeAll { $0.id == id }
            try commitMutation(&manifest, secrets: secrets, marksDirty: true)
            return true
        }
        if changed { postChange(source: .local, categories: [.apiKeyProfiles]) }
    }

    func loadUpdateTemplates() -> [UpdateTemplate] {
        (try? withLock {
            try loadOrMigrateManifest().templates.compactMap { record in
                record.value.map { UpdateTemplate(id: record.id, name: $0.name, content: $0.content) }
            }
        }) ?? []
    }

    func saveUpdateTemplate(_ template: UpdateTemplate) throws {
        let changed = try withLock { () -> Bool in
            var manifest = try loadOrMigrateManifest()
            let normalized = SyncUpdateTemplateValue(
                name: template.name.trimmingCharacters(in: .whitespacesAndNewlines),
                content: template.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let existingIndex = manifest.templates.firstIndex { $0.id == template.id }
            if let existingIndex, manifest.templates[existingIndex].isTombstone {
                throw ConfigurationStoreError.deletedRecordCannotBeReused
            }
            let existing = existingIndex.map { manifest.templates[$0] }
            guard existing?.value != normalized else { return false }
            let record = VersionedRecord(
                id: template.id,
                order: existing?.order ?? nextOrder(in: manifest.templates.map(\.order)),
                revision: tick(&manifest),
                writerDeviceID: try deviceID(),
                value: normalized
            )
            if let existingIndex {
                manifest.templates[existingIndex] = record
            } else {
                manifest.templates.append(record)
            }
            try commitMutation(&manifest, secrets: loadSecrets(generation: manifest.secretGeneration), marksDirty: true)
            return true
        }
        if changed { postChange(source: .local, categories: [.updateTemplates]) }
    }

    func deleteUpdateTemplate(id: UUID) throws {
        let changed = try withLock { () -> Bool in
            var manifest = try loadOrMigrateManifest()
            guard let index = manifest.templates.firstIndex(where: { $0.id == id && !$0.isTombstone }) else {
                return false
            }
            let existing = manifest.templates[index]
            manifest.templates[index] = .tombstone(
                id: id,
                order: existing.order,
                revision: tick(&manifest),
                writerDeviceID: try deviceID()
            )
            try commitMutation(&manifest, secrets: loadSecrets(generation: manifest.secretGeneration), marksDirty: true)
            return true
        }
        if changed { postChange(source: .local, categories: [.updateTemplates]) }
    }

    func loadPreferences() -> AppPreferences {
        (try? withLock {
            let manifest = try loadOrMigrateManifest()
            let synced = (manifest.preferencesWereExplicitlySet ? manifest.preferences.value : nil) ?? SyncPreferencesValue(
                quitAfterSuccessfulUpload: false,
                allowMenuBarRunning: false,
                showMenuBarIcon: false
            )
            return AppPreferences(
                aaptPath: manifest.aaptPath,
                androidSDKPath: manifest.androidSDKPath,
                quitAfterSuccessfulUpload: synced.quitAfterSuccessfulUpload,
                allowMenuBarRunning: synced.allowMenuBarRunning,
                showMenuBarIcon: synced.showMenuBarIcon
            )
        }) ?? AppPreferences()
    }

    func savePreferences(_ preferences: AppPreferences) throws {
        let result = try withLock { () -> (Bool, Bool) in
            var manifest = try loadOrMigrateManifest()
            let portable = SyncPreferencesValue(
                quitAfterSuccessfulUpload: preferences.quitAfterSuccessfulUpload,
                allowMenuBarRunning: preferences.allowMenuBarRunning,
                showMenuBarIcon: preferences.showMenuBarIcon
            )
            let portableChanged = !manifest.preferencesWereExplicitlySet || manifest.preferences.value != portable
            let localChanged = manifest.aaptPath != preferences.aaptPath || manifest.androidSDKPath != preferences.androidSDKPath
            guard portableChanged || localChanged else { return (false, false) }

            if portableChanged {
                manifest.preferences = VersionedRecord(
                    id: SyncDocument.preferencesRecordID,
                    order: 0,
                    revision: tick(&manifest),
                    writerDeviceID: try deviceID(),
                    value: portable
                )
                manifest.preferencesWereExplicitlySet = true
            }
            manifest.aaptPath = preferences.aaptPath
            manifest.androidSDKPath = preferences.androidSDKPath
            try commitMutation(
                &manifest,
                secrets: loadSecrets(generation: manifest.secretGeneration),
                marksDirty: portableChanged
            )
            return (true, portableChanged)
        }
        if result.0 { postChange(source: .local, categories: [.preferences]) }
    }

    func syncSnapshot() throws -> ConfigurationSyncSnapshot {
        try withLock {
            let manifest = try loadOrMigrateManifest()
            let secrets = try loadSecrets(generation: manifest.secretGeneration)
            let profiles = try manifest.profiles.map { record -> VersionedRecord<SyncAPIKeyProfileValue> in
                guard let metadata = record.value else {
                    return .tombstone(
                        id: record.id,
                        order: record.order,
                        revision: record.revision,
                        writerDeviceID: record.writerDeviceID
                    )
                }
                guard let secret = secrets.value(for: record.id) else {
                    throw ConfigurationStoreError.missingSecret(record.id)
                }
                return VersionedRecord(
                    id: record.id,
                    order: record.order,
                    revision: record.revision,
                    writerDeviceID: record.writerDeviceID,
                    value: SyncAPIKeyProfileValue(
                        name: metadata.name,
                        apiKey: secret.apiKey,
                        password: secret.password,
                        updateTemplate: metadata.updateTemplate
                    )
                )
            }
            let document = SyncDocument(
                datasetID: manifest.datasetID,
                generation: manifest.remoteGeneration,
                apiKeyProfiles: profiles,
                updateTemplates: manifest.templates,
                preferences: manifest.preferencesWereExplicitlySet ? manifest.preferences : nil
            )
            let hasPortableData = !profiles.isEmpty
                || !manifest.templates.isEmpty
                || manifest.preferencesWereExplicitlySet
            return ConfigurationSyncSnapshot(
                document: document,
                localGeneration: manifest.localGeneration,
                isDirty: manifest.dirty,
                hasPortableData: hasPortableData
            )
        }
    }

    /// Atomically stages every remote secret before switching the local manifest.
    /// A concurrent local edit makes the import a no-op so the coordinator can retry.
    @discardableResult
    func applyVerifiedDocument(
        _ document: SyncDocument,
        expectedLocalGeneration: UInt64,
        markClean: Bool
    ) throws -> Bool {
        let result = try withLock { () -> (Bool, Set<ConfigurationChangeCategory>) in
            let normalized = try document.normalized()
            var manifest = try loadOrMigrateManifest()
            guard manifest.localGeneration == expectedLocalGeneration else {
                return (false, [])
            }

            let oldProfiles = manifest.profiles
            let oldSecrets = try loadSecrets(generation: manifest.secretGeneration)
            let oldTemplates = manifest.templates
            let oldPreferences = manifest.preferences
            let oldPreferencesWereExplicitlySet = manifest.preferencesWereExplicitlySet
            var secretEntries: [SecretEntry] = []
            let profiles = normalized.apiKeyProfiles.map { record -> VersionedRecord<ProfileMetadata> in
                if let value = record.value {
                    secretEntries.append(SecretEntry(id: record.id, apiKey: value.apiKey, password: value.password))
                    return VersionedRecord(
                        id: record.id,
                        order: record.order,
                        revision: record.revision,
                        writerDeviceID: record.writerDeviceID,
                        value: ProfileMetadata(name: value.name, updateTemplate: value.updateTemplate)
                    )
                }
                return .tombstone(
                    id: record.id,
                    order: record.order,
                    revision: record.revision,
                    writerDeviceID: record.writerDeviceID
                )
            }

            manifest.datasetID = normalized.datasetID
            manifest.remoteGeneration = normalized.generation
            manifest.profiles = profiles
            manifest.templates = normalized.updateTemplates
            if let preferences = normalized.preferences {
                manifest.preferences = preferences
                manifest.preferencesWereExplicitlySet = true
            } else {
                manifest.preferencesWereExplicitlySet = false
            }
            if let observedClock = maximumRevision(in: normalized) {
                manifest.lastClock = max(manifest.lastClock ?? observedClock, observedClock)
            }
            manifest.dirty = markClean ? false : manifest.dirty
            try increment(&manifest.localGeneration)
            let newSecrets = SecretBlob(profiles: secretEntries)
            try commit(manifest: &manifest, secrets: newSecrets)

            var categories: Set<ConfigurationChangeCategory> = []
            if oldProfiles != manifest.profiles || oldSecrets != newSecrets {
                categories.insert(.apiKeyProfiles)
            }
            if oldTemplates != manifest.templates { categories.insert(.updateTemplates) }
            if oldPreferences != manifest.preferences
                || oldPreferencesWereExplicitlySet != manifest.preferencesWereExplicitlySet {
                categories.insert(.preferences)
            }
            return (true, categories)
        }
        if result.0, !result.1.isEmpty {
            postChange(source: .remote, categories: result.1)
        }
        return result.0
    }

    func hasPendingSyncChanges() -> Bool {
        (try? withLock { try loadOrMigrateManifest().dirty }) ?? false
    }

    private func loadOrMigrateManifest() throws -> LocalManifest {
        if let data = defaults.data(forKey: Keys.manifest) {
            guard let manifest = try? decoder.decode(LocalManifest.self, from: data) else {
                throw ConfigurationStoreError.invalidManifest
            }
            guard manifest.schemaVersion == 2 else {
                throw ConfigurationStoreError.unsupportedManifestVersion(manifest.schemaVersion)
            }
            return manifest
        }
        return try migrateLegacyData()
    }

    private func migrateLegacyData() throws -> LocalManifest {
        let legacyProfiles = try decodeLegacyValue(
            [APIKeyProfileRecord].self,
            forKey: Keys.apiKeyProfiles,
            defaultValue: []
        )
        let legacyTemplates = try decodeLegacyValue(
            [UpdateTemplate].self,
            forKey: Keys.updateTemplates,
            defaultValue: []
        )
        let legacyPreferences = try decodeLegacyValue(
            AppPreferences.self,
            forKey: Keys.preferences,
            defaultValue: AppPreferences()
        )
        let writer = try deviceID()
        var clock: HLCRevision?

        func revision() -> HLCRevision {
            let value = HLCRevision.next(local: clock)
            clock = value
            return value
        }

        var secretEntries: [SecretEntry] = []
        let profiles = try legacyProfiles.enumerated().map { index, record in
            guard let apiKey = try keychain.read(account: legacyAPIKeyAccount(record.id)) else {
                throw ConfigurationStoreError.missingSecret(record.id)
            }
            let password = try keychain.read(account: legacyPasswordAccount(record.id)) ?? ""
            secretEntries.append(SecretEntry(id: record.id, apiKey: apiKey, password: password))
            return VersionedRecord(
                id: record.id,
                order: Int64(index),
                revision: revision(),
                writerDeviceID: writer,
                value: ProfileMetadata(name: record.name, updateTemplate: record.updateTemplate)
            )
        }
        let templates = legacyTemplates.enumerated().map { index, template in
            VersionedRecord(
                id: template.id,
                order: Int64(index),
                revision: revision(),
                writerDeviceID: writer,
                value: SyncUpdateTemplateValue(name: template.name, content: template.content)
            )
        }
        let preferencesValue = SyncPreferencesValue(
            quitAfterSuccessfulUpload: legacyPreferences.quitAfterSuccessfulUpload,
            allowMenuBarRunning: legacyPreferences.allowMenuBarRunning,
            showMenuBarIcon: legacyPreferences.showMenuBarIcon
        )
        let defaultPreferences = SyncPreferencesValue(
            quitAfterSuccessfulUpload: false,
            allowMenuBarRunning: false,
            showMenuBarIcon: false
        )
        let preferencesRevision = preferencesValue == defaultPreferences
            ? HLCRevision(wallTimeMilliseconds: 0)
            : revision()
        let hasPortableData = !profiles.isEmpty || !templates.isEmpty || preferencesValue != defaultPreferences
        var manifest = LocalManifest(
            datasetID: UUID(),
            remoteGeneration: 0,
            secretGeneration: 0,
            localGeneration: 0,
            lastClock: clock,
            dirty: hasPortableData,
            profiles: profiles,
            templates: templates,
            preferences: VersionedRecord(
                id: SyncDocument.preferencesRecordID,
                order: 0,
                revision: preferencesRevision,
                writerDeviceID: writer,
                value: preferencesValue
            ),
            preferencesWereExplicitlySet: preferencesValue != defaultPreferences,
            aaptPath: legacyPreferences.aaptPath,
            androidSDKPath: legacyPreferences.androidSDKPath
        )
        manifest.lastClock = clock
        try commit(manifest: &manifest, secrets: SecretBlob(profiles: secretEntries))

        defaults.removeObject(forKey: Keys.apiKeyProfiles)
        defaults.removeObject(forKey: Keys.updateTemplates)
        defaults.removeObject(forKey: Keys.preferences)
        for record in legacyProfiles {
            try? keychain.delete(account: legacyAPIKeyAccount(record.id))
            try? keychain.delete(account: legacyPasswordAccount(record.id))
        }
        postChange(source: .migration, categories: Set(ConfigurationChangeCategory.allCases))
        return manifest
    }

    private func decodeLegacyValue<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        defaultValue: Value
    ) throws -> Value {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        guard let data = defaults.data(forKey: key),
              let value = try? decoder.decode(type, from: data) else {
            throw ConfigurationStoreError.invalidManifest
        }
        return value
    }

    private func loadSecrets(generation: UInt64) throws -> SecretBlob {
        guard generation > 0,
              let data = try keychain.readData(account: Keys.secretsAccount(generation)) else {
            throw ConfigurationStoreError.invalidManifest
        }
        guard let blob = try? decoder.decode(SecretBlob.self, from: data), blob.schemaVersion == 1 else {
            throw ConfigurationStoreError.invalidManifest
        }
        return blob
    }

    private func commitMutation(
        _ manifest: inout LocalManifest,
        secrets: SecretBlob,
        marksDirty: Bool
    ) throws {
        try increment(&manifest.localGeneration)
        manifest.dirty = manifest.dirty || marksDirty
        try commit(manifest: &manifest, secrets: secrets)
    }

    private func commit(manifest: inout LocalManifest, secrets: SecretBlob) throws {
        let oldSecretGeneration = manifest.secretGeneration
        let oldManifestData = defaults.data(forKey: Keys.manifest)
        var newSecretGeneration = oldSecretGeneration
        try increment(&newSecretGeneration)
        let secretData = try encoder.encode(secrets)
        try keychain.save(
            secretData,
            account: Keys.secretsAccount(newSecretGeneration),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        manifest.secretGeneration = newSecretGeneration

        let manifestData = try encoder.encode(manifest)
        defaults.set(manifestData, forKey: Keys.manifest)
        guard defaults.synchronize(), defaults.data(forKey: Keys.manifest) == manifestData else {
            if let oldManifestData {
                defaults.set(oldManifestData, forKey: Keys.manifest)
            } else {
                defaults.removeObject(forKey: Keys.manifest)
            }
            _ = defaults.synchronize()
            try? keychain.delete(account: Keys.secretsAccount(newSecretGeneration))
            manifest.secretGeneration = oldSecretGeneration
            throw ConfigurationStoreError.persistenceFailed
        }
        if oldSecretGeneration > 0 {
            try? keychain.delete(account: Keys.secretsAccount(oldSecretGeneration))
        }
    }

    private func tick(_ manifest: inout LocalManifest) -> HLCRevision {
        let revision = HLCRevision.next(local: manifest.lastClock)
        manifest.lastClock = revision
        return revision
    }

    private func deviceID() throws -> String {
        if let existing = try keychain.read(account: Keys.deviceIDAccount), UUID(uuidString: existing) != nil {
            return existing
        }
        let value = UUID().uuidString
        try keychain.save(value, account: Keys.deviceIDAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        return value
    }

    private func maximumRevision(in document: SyncDocument) -> HLCRevision? {
        let revisions = document.apiKeyProfiles.map(\.revision)
            + document.updateTemplates.map(\.revision)
            + [document.preferences?.revision].compactMap { $0 }
        return revisions.max()
    }

    private func nextOrder(in values: [Int64]) -> Int64 {
        guard let maximum = values.max(), maximum < Int64.max else {
            return values.isEmpty ? 0 : Int64.max
        }
        return maximum + 1
    }

    private func increment(_ value: inout UInt64) throws {
        guard value < UInt64.max else {
            throw ConfigurationStoreError.generationOverflow
        }
        value += 1
    }

    private func postChange(source: ConfigurationChangeSource, categories: Set<ConfigurationChangeCategory>) {
        let block = { [notificationCenter] in
            notificationCenter.post(
                name: .configurationStoreDidChange,
                object: self,
                userInfo: [
                    "source": source.rawValue,
                    "categories": categories.map(\.rawValue).sorted()
                ]
            )
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func legacyAPIKeyAccount(_ id: UUID) -> String {
        "api-key-\(id.uuidString)"
    }

    private func legacyPasswordAccount(_ id: UUID) -> String {
        "password-\(id.uuidString)"
    }
}
