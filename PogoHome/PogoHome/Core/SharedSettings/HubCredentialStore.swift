import Foundation
import Security

/// What this device received when it paired with one hub: its device id, its bearer token, and the
/// SHA-256 of the hub's TLS certificate, pinned for every later request. One per `hub_id`, so two
/// hubs never share a credential.
nonisolated struct HubCredential: Codable, Hashable, Sendable {
    let hubID: String
    let deviceID: String
    let token: String
    let certificateSHA256: String
    let pairedAt: Date
}

nonisolated protocol HubCredentialStoring: Sendable {
    func credential(forHubID hubID: String) throws -> HubCredential?
    func save(_ credential: HubCredential) throws
    func deleteCredential(forHubID hubID: String) throws
}

nonisolated enum HubCredentialStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case damaged

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return String(localized: "허브 인증 정보를 키체인에서 처리하지 못했습니다. (\(Int(status)))", comment: "Keychain error; the argument is an OSStatus number")
        case .damaged:
            return String(localized: "키체인의 허브 인증 정보가 손상되었습니다. 허브에 다시 연결하세요.", comment: "Keychain item could not be decoded")
        }
    }
}

/// The real store: one generic-password Keychain item per hub, readable only by this app on this
/// device after its first unlock, never synchronized (each device pairs and gets its own token).
nonisolated final class KeychainHubCredentialStore: HubCredentialStoring {
    private let service: String

    init(service: String = "com.junsoona.PogoHome.hub-credential") {
        self.service = service
    }

    private func baseQuery(hubID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hubID.lowercased(),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func credential(forHubID hubID: String) throws -> HubCredential? {
        var query = baseQuery(hubID: hubID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HubCredentialStoreError.keychain(status)
        }
        guard let credential = try? JSONDecoder().decode(HubCredential.self, from: data),
              credential.hubID.lowercased() == hubID.lowercased() else {
            throw HubCredentialStoreError.damaged
        }
        return credential
    }

    func save(_ credential: HubCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(hubID: credential.hubID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HubCredentialStoreError.keychain(status) }
    }

    func deleteCredential(forHubID hubID: String) throws {
        let status = SecItemDelete(baseQuery(hubID: hubID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HubCredentialStoreError.keychain(status)
        }
    }
}

/// For tests and previews.
nonisolated final class InMemoryHubCredentialStore: HubCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: HubCredential]

    init(_ credentials: [HubCredential] = []) {
        self.credentials = Dictionary(uniqueKeysWithValues: credentials.map { ($0.hubID.lowercased(), $0) })
    }

    func credential(forHubID hubID: String) throws -> HubCredential? {
        lock.withLock { credentials[hubID.lowercased()] }
    }

    func save(_ credential: HubCredential) throws {
        lock.withLock { credentials[credential.hubID.lowercased()] = credential }
    }

    func deleteCredential(forHubID hubID: String) throws {
        lock.withLock { _ = credentials.removeValue(forKey: hubID.lowercased()) }
    }
}
