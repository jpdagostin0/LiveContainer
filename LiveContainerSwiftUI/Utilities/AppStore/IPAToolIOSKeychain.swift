//
//  IPAToolIOSKeychain.swift
//  LiveContainerSwiftUI
//
//  Persistent identity and credentials for the embedded ipatool-ios client.
//

import Foundation
import Security

@MainActor
final class IPAToolIOSKeychain {
    static let shared = IPAToolIOSKeychain()

    private let service = "com.kdt.livecontainer.ipatool-ios"
    private let accountKey = "apple-account"
    private let guidKey = "device-guid"

    private init() {}

    func deviceGUID() throws -> String {
        if let data = try data(for: guidKey),
            let value = String(data: data, encoding: .utf8),
            value.count == 12
        {
            return value
        }

        var bytes = [UInt8](repeating: 0, count: 6)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw IPAToolIOSError.keychain(status)
        }

        // Locally administered, unicast identity. Keep it stable for Store cookies.
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        let guid = bytes.map { String(format: "%02X", $0) }.joined()
        try set(Data(guid.utf8), for: guidKey)
        return guid
    }

    func save(account: IPAToolIOSAccount) throws {
        try set(try JSONEncoder().encode(account), for: accountKey)
    }

    func loadAccount() throws -> IPAToolIOSAccount? {
        guard let data = try data(for: accountKey) else {
            return nil
        }
        return try JSONDecoder().decode(IPAToolIOSAccount.self, from: data)
    }

    func removeAccount() throws {
        let status = SecItemDelete(baseQuery(for: accountKey) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IPAToolIOSError.keychain(status)
        }
    }

    private func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw IPAToolIOSError.keychain(status)
        }
        return data
    }

    private func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "LiveContainer App Store",
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw IPAToolIOSError.keychain(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw IPAToolIOSError.keychain(addStatus)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
