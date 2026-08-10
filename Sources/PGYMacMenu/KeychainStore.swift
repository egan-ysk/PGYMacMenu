import Foundation
import Security

enum KeychainStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "钥匙串操作失败：\(message)"
        case .invalidUTF8:
            return "钥匙串中的文本数据无效"
        }
    }
}

enum KeychainAccessibility {
    case afterFirstUnlock
    case afterFirstUnlockThisDeviceOnly

    fileprivate var value: CFString {
        switch self {
        case .afterFirstUnlock:
            return kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

final class KeychainStore: @unchecked Sendable {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func read(account: String) throws -> String? {
        guard let data = try readData(account: account) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidUTF8
        }
        return value
    }

    func readData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainStoreError.unexpectedStatus(errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func save(
        _ value: String,
        account: String,
        accessibility: KeychainAccessibility = .afterFirstUnlock
    ) throws {
        try save(Data(value.utf8), account: account, accessibility: accessibility)
    }

    func save(
        _ data: Data,
        account: String,
        accessibility: KeychainAccessibility = .afterFirstUnlock
    ) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.value
        ]

        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
