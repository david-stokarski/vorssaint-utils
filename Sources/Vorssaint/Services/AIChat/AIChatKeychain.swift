// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

/// Fork: API keys live in the login keychain, one item per provider or
/// endpoint, never in preferences, a settings backup or the chat files. The
/// account is the source id: `anthropic`, `openai`, `compatible.<endpoint id>`.
enum AIChatKeychain {
    private static let service = "com.vorssaint.ai-chat"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // MARK: Built-in providers

    static func hasKey(for provider: AIProvider) -> Bool { hasKey(account: provider.rawValue) }
    static func key(for provider: AIProvider) -> String? { key(account: provider.rawValue) }

    @discardableResult
    static func setKey(_ key: String?, for provider: AIProvider) -> Bool {
        setKey(key, account: provider.rawValue, label: provider.title)
    }

    // MARK: Any source

    /// The key a model's requests carry: its provider's, or its endpoint's.
    static func key(for choice: AIModelChoice) -> String? { key(account: choice.sourceID) }

    static func hasKey(for endpoint: AIEndpoint) -> Bool { hasKey(account: endpoint.sourceID) }
    static func key(for endpoint: AIEndpoint) -> String? { key(account: endpoint.sourceID) }

    @discardableResult
    static func setKey(_ key: String?, for endpoint: AIEndpoint) -> Bool {
        setKey(key, account: endpoint.sourceID, label: endpoint.displayName)
    }

    /// Whether a key is saved, without reading it. Only the secret itself is
    /// behind the keychain's access prompt, so asking this never shows one.
    static func hasKey(account: String) -> Bool {
        var search = query(account)
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess
    }

    static func key(account: String) -> String? {
        var item: CFTypeRef?
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// An empty key removes the item.
    @discardableResult
    static func setKey(_ key: String?, account: String, label: String) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Vorssaint AI Chat (\(label))"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
