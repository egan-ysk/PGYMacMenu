import Foundation
import XCTest
@testable import PGYMacMenu

private final class FailingUserDefaults: UserDefaults {
    var shouldFailSynchronization = false

    override func synchronize() -> Bool {
        shouldFailSynchronization ? false : super.synchronize()
    }
}

final class ConfigurationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychain: KeychainStore!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        keychain = KeychainStore(service: suiteName)
        try keychain.deleteAll()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try keychain.deleteAll()
        defaults = nil
        keychain = nil
        suiteName = nil
    }

    func testSecretsStayInKeychainAndDeleteBecomesTombstone() throws {
        let store = ConfigurationStore(defaults: defaults, keychain: keychain)
        let profile = APIKeyProfile(
            name: "Production",
            apiKey: "PLAINTEXT-API-KEY-MARKER",
            password: "PLAINTEXT-PASSWORD-MARKER",
            updateTemplate: "Release notes"
        )

        try store.saveAPIKeyProfile(profile)

        XCTAssertEqual(store.loadAPIKeyProfiles(), [profile])
        let defaultsData = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }
        let defaultsText = defaultsData.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(defaultsText.contains(profile.apiKey))
        XCTAssertFalse(defaultsText.contains(profile.password))

        let beforeDelete = try store.syncSnapshot()
        XCTAssertTrue(beforeDelete.isDirty)
        XCTAssertEqual(beforeDelete.document.apiKeyProfiles.first?.value?.apiKey, profile.apiKey)

        try store.deleteAPIKeyProfile(id: profile.id)

        XCTAssertTrue(store.loadAPIKeyProfiles().isEmpty)
        let afterDelete = try store.syncSnapshot()
        XCTAssertEqual(afterDelete.document.apiKeyProfiles.count, 1)
        XCTAssertTrue(try XCTUnwrap(afterDelete.document.apiKeyProfiles.first).isTombstone)
        XCTAssertTrue(afterDelete.hasPortableData)
    }

    func testVerifiedRemotePreferencesPreserveMachineLocalPaths() throws {
        let store = ConfigurationStore(defaults: defaults, keychain: keychain)
        try store.savePreferences(AppPreferences(
            aaptPath: "/local/aapt",
            androidSDKPath: "/local/android-sdk",
            quitAfterSuccessfulUpload: false,
            allowMenuBarRunning: false,
            showMenuBarIcon: false
        ))
        let snapshot = try store.syncSnapshot()
        let remotePreferences = VersionedRecord(
            id: SyncDocument.preferencesRecordID,
            order: 0,
            revision: HLCRevision(wallTimeMilliseconds: Int64.max - 1),
            writerDeviceID: UUID().uuidString,
            value: SyncPreferencesValue(
                quitAfterSuccessfulUpload: true,
                allowMenuBarRunning: true,
                showMenuBarIcon: true
            )
        )
        let remote = SyncDocument(
            datasetID: snapshot.document.datasetID,
            generation: 4,
            preferences: remotePreferences
        )

        XCTAssertTrue(try store.applyVerifiedDocument(
            remote,
            expectedLocalGeneration: snapshot.localGeneration,
            markClean: true
        ))

        let preferences = store.loadPreferences()
        XCTAssertEqual(preferences.aaptPath, "/local/aapt")
        XCTAssertEqual(preferences.androidSDKPath, "/local/android-sdk")
        XCTAssertTrue(preferences.quitAfterSuccessfulUpload)
        XCTAssertTrue(preferences.allowMenuBarRunning)
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertFalse(store.hasPendingSyncChanges())
    }

    func testSavingDefaultPortablePreferencesCreatesAnExplicitSyncRecord() throws {
        let store = ConfigurationStore(defaults: defaults, keychain: keychain)

        try store.savePreferences(AppPreferences(aaptPath: "/local/aapt"))

        let snapshot = try store.syncSnapshot()
        XCTAssertNotNil(snapshot.document.preferences)
        XCTAssertTrue(snapshot.hasPortableData)
        XCTAssertTrue(snapshot.isDirty)
    }

    func testRemoteSecretOnlyChangePublishesAPIProfileCategory() throws {
        let store = ConfigurationStore(defaults: defaults, keychain: keychain)
        let profile = APIKeyProfile(name: "Production", apiKey: "old-key", password: "old-password")
        try store.saveAPIKeyProfile(profile)
        let snapshot = try store.syncSnapshot()
        var remote = snapshot.document
        let current = try XCTUnwrap(remote.apiKeyProfiles.first)
        remote.apiKeyProfiles[0] = VersionedRecord(
            id: current.id,
            order: current.order,
            revision: HLCRevision.next(local: current.revision),
            writerDeviceID: UUID().uuidString,
            value: SyncAPIKeyProfileValue(
                name: profile.name,
                apiKey: "new-key",
                password: "new-password",
                updateTemplate: profile.updateTemplate
            )
        )

        let notification = expectation(forNotification: .configurationStoreDidChange, object: store) { notification in
            (notification.userInfo?["source"] as? String) == ConfigurationChangeSource.remote.rawValue
                && (notification.userInfo?["categories"] as? [String])?.contains(
                    ConfigurationChangeCategory.apiKeyProfiles.rawValue
                ) == true
        }
        XCTAssertTrue(try store.applyVerifiedDocument(
            remote,
            expectedLocalGeneration: snapshot.localGeneration,
            markClean: true
        ))
        wait(for: [notification], timeout: 1)
        XCTAssertEqual(store.loadAPIKeyProfiles().first?.apiKey, "new-key")
    }

    func testLegacyDataMigratesOnlyAfterSecretsAreReadable() throws {
        let encoder = JSONEncoder()
        let profileID = UUID()
        let templateID = UUID()
        defaults.set(
            try encoder.encode([APIKeyProfileRecord(id: profileID, name: "Legacy", updateTemplate: "Legacy notes")]),
            forKey: "api_key_profiles"
        )
        defaults.set(
            try encoder.encode([UpdateTemplate(id: templateID, name: "Template", content: "Content")]),
            forKey: "update_templates"
        )
        defaults.set(
            try encoder.encode(AppPreferences(aaptPath: "/legacy/aapt", allowMenuBarRunning: true)),
            forKey: "preferences"
        )
        try keychain.save("legacy-api-key", account: "api-key-\(profileID.uuidString)")
        try keychain.save("", account: "password-\(profileID.uuidString)")

        let store = ConfigurationStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(store.loadAPIKeyProfiles().first?.apiKey, "legacy-api-key")
        XCTAssertEqual(store.loadUpdateTemplates().first?.id, templateID)
        XCTAssertEqual(store.loadPreferences().aaptPath, "/legacy/aapt")
        XCTAssertNil(defaults.object(forKey: "api_key_profiles"))
        XCTAssertNil(try keychain.read(account: "api-key-\(profileID.uuidString)"))
        XCTAssertTrue(try store.syncSnapshot().isDirty)
    }

    func testCorruptLegacyValueFailsClosedWithoutDeletingOriginalData() throws {
        let encoder = JSONEncoder()
        let profileID = UUID()
        let profiles = [
            APIKeyProfileRecord(id: profileID, name: "Legacy", updateTemplate: "Legacy notes")
        ]
        let encodedProfiles = try encoder.encode(profiles)
        let corruptTemplates = Data("not-valid-json".utf8)
        defaults.set(encodedProfiles, forKey: "api_key_profiles")
        defaults.set(corruptTemplates, forKey: "update_templates")
        try keychain.save("legacy-api-key", account: "api-key-\(profileID.uuidString)")

        let store = ConfigurationStore(defaults: defaults, keychain: keychain)
        XCTAssertThrowsError(try store.syncSnapshot()) { error in
            guard case ConfigurationStoreError.invalidManifest = error else {
                return XCTFail("Expected invalid manifest, got \(error)")
            }
        }

        XCTAssertEqual(defaults.data(forKey: "api_key_profiles"), encodedProfiles)
        XCTAssertEqual(defaults.data(forKey: "update_templates"), corruptTemplates)
        XCTAssertNil(defaults.object(forKey: "configuration_manifest_v2"))
        XCTAssertEqual(
            try keychain.read(account: "api-key-\(profileID.uuidString)"),
            "legacy-api-key"
        )
    }

    func testFailedManifestCommitRestoresPreviousGeneration() throws {
        let failingSuite = "ConfigurationStoreTests.FailingDefaults.\(UUID().uuidString)"
        let failingDefaults = try XCTUnwrap(FailingUserDefaults(suiteName: failingSuite))
        failingDefaults.removePersistentDomain(forName: failingSuite)
        let failingKeychain = KeychainStore(service: failingSuite)
        try failingKeychain.deleteAll()
        defer {
            failingDefaults.shouldFailSynchronization = false
            failingDefaults.removePersistentDomain(forName: failingSuite)
            try? failingKeychain.deleteAll()
        }

        let original = APIKeyProfile(name: "Production", apiKey: "old-key", password: "old-password")
        let store = ConfigurationStore(defaults: failingDefaults, keychain: failingKeychain)
        try store.saveAPIKeyProfile(original)

        failingDefaults.shouldFailSynchronization = true
        let replacement = APIKeyProfile(
            id: original.id,
            name: original.name,
            apiKey: "new-key",
            password: "new-password"
        )
        XCTAssertThrowsError(try store.saveAPIKeyProfile(replacement)) { error in
            guard case ConfigurationStoreError.persistenceFailed = error else {
                return XCTFail("Expected persistence failure, got \(error)")
            }
        }

        XCTAssertEqual(store.loadAPIKeyProfiles(), [original])
        failingDefaults.shouldFailSynchronization = false
        let reopened = ConfigurationStore(defaults: failingDefaults, keychain: failingKeychain)
        XCTAssertEqual(reopened.loadAPIKeyProfiles(), [original])
    }
}
