import Foundation
import Security

/// The anonymous ID (FR-29): a random UUID in the Keychain, this device only
/// and never synced, so it survives reinstalling the app. Keychain calls run
/// off the main actor.
actor AnonymousIDStore {
    private let service = "io.github.bigmanmike7.linemapapp"
    private let account = "anonymous-id"

    /// The stored ID, or a new one saved now.
    func load() throws -> UUID {
        if let existing = try read() {
            return existing
        }
        let id = UUID()
        try save(id)
        return id
    }

    private var identity: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private func read() throws -> UUID? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return UUID(uuidString: text)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private func save(_ id: UUID) throws {
        let data = Data(id.uuidString.utf8)
        var add = identity
        add[kSecValueData] = data
        // Device-only and not synced to iCloud (FR-29).
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable] = false

        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        case let status:
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: Error {
    let status: OSStatus
}

/// The install ID (FR-30): regular app storage, so it's new on every install.
enum InstallID {
    private static let key = "installId"

    static func load(from defaults: UserDefaults = .standard) -> UUID {
        if let text = defaults.string(forKey: key), let id = UUID(uuidString: text) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }
}

/// The device model identifier, e.g. "iPhone15,2".
enum DeviceInfo {
    static var model: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : String(identifier.prefix(64))
    }
}
