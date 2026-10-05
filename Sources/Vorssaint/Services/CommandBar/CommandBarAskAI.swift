// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: a search that finds nothing becomes a question for the default
/// model, asked in the AI Chat window.
extension CommandBarService {
    var askAIOffered: Bool {
        guard AppFeature.aiChat.isAvailable, case .search = mode, rows.isEmpty,
              UserDefaults.standard.bool(forKey: DefaultsKey.commandBarAskAI) else { return false }
        return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func askAI() {
        let question = query
        hide()
        // The bar's own fade has to finish before the chat takes focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            AIChatService.shared.ask(question)
        }
    }
}
