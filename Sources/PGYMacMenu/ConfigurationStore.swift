import Foundation

final class ConfigurationStore {
    private enum Keys {
        static let apiKeyProfiles = "api_key_profiles"
        static let updateTemplates = "update_templates"
        static let preferences = "preferences"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(service: "com.egan.PGYMacMenu")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func loadAPIKeyProfiles() -> [APIKeyProfile] {
        loadRecords().map { record in
            APIKeyProfile(
                id: record.id,
                name: record.name,
                apiKey: keychain.read(account: apiKeyAccount(record.id)),
                password: keychain.read(account: passwordAccount(record.id)),
                updateTemplate: record.updateTemplate
            )
        }
    }

    func saveAPIKeyProfile(_ profile: APIKeyProfile) {
        let normalized = APIKeyProfile(
            id: profile.id,
            name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            password: profile.password.trimmingCharacters(in: .whitespacesAndNewlines),
            updateTemplate: profile.updateTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var records = loadRecords()
        records.removeAll { $0.id == normalized.id }
        records.append(APIKeyProfileRecord(
            id: normalized.id,
            name: normalized.name,
            updateTemplate: normalized.updateTemplate
        ))
        saveRecords(records)
        keychain.save(normalized.apiKey, account: apiKeyAccount(normalized.id))
        keychain.save(normalized.password, account: passwordAccount(normalized.id))
    }

    func deleteAPIKeyProfile(id: UUID) {
        var records = loadRecords()
        records.removeAll { $0.id == id }
        saveRecords(records)
        keychain.delete(account: apiKeyAccount(id))
        keychain.delete(account: passwordAccount(id))
    }

    func loadUpdateTemplates() -> [UpdateTemplate] {
        guard let data = defaults.data(forKey: Keys.updateTemplates),
              let value = try? decoder.decode([UpdateTemplate].self, from: data) else {
            return []
        }
        return value
    }

    func saveUpdateTemplate(_ template: UpdateTemplate) {
        var templates = loadUpdateTemplates()
        let normalized = UpdateTemplate(
            id: template.id,
            name: template.name.trimmingCharacters(in: .whitespacesAndNewlines),
            content: template.content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        templates.removeAll { $0.id == normalized.id }
        templates.append(normalized)
        saveUpdateTemplates(templates)
    }

    func deleteUpdateTemplate(id: UUID) {
        var templates = loadUpdateTemplates()
        templates.removeAll { $0.id == id }
        saveUpdateTemplates(templates)
    }

    func loadPreferences() -> AppPreferences {
        guard let data = defaults.data(forKey: Keys.preferences),
              let value = try? decoder.decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        return value
    }

    func savePreferences(_ preferences: AppPreferences) {
        if let data = try? encoder.encode(preferences) {
            defaults.set(data, forKey: Keys.preferences)
        }
    }

    private func loadRecords() -> [APIKeyProfileRecord] {
        guard let data = defaults.data(forKey: Keys.apiKeyProfiles),
              let value = try? decoder.decode([APIKeyProfileRecord].self, from: data) else {
            return []
        }
        return value
    }

    private func saveRecords(_ records: [APIKeyProfileRecord]) {
        if let data = try? encoder.encode(records) {
            defaults.set(data, forKey: Keys.apiKeyProfiles)
        }
    }

    private func saveUpdateTemplates(_ templates: [UpdateTemplate]) {
        if let data = try? encoder.encode(templates) {
            defaults.set(data, forKey: Keys.updateTemplates)
        }
    }

    private func apiKeyAccount(_ id: UUID) -> String {
        "api-key-\(id.uuidString)"
    }

    private func passwordAccount(_ id: UUID) -> String {
        "password-\(id.uuidString)"
    }
}
