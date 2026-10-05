// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

/// Fork: API keys live in the login keychain, one item per provider, never in
/// preferences or the chat files.
enum AIChatKeychain {
    private static let service = "com.vorssaint.ai-chat"

    private static func query(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    static func key(for provider: AIProvider) -> String? {
        var item: CFTypeRef?
        var search = query(provider)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func setKey(_ key: String?, for provider: AIProvider) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(provider) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(provider) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(provider)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Vorssaint AI Chat (\(provider.title))"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
