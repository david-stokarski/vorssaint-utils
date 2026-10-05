// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: what a search with no results offers instead of a dead end. Drawn
/// like a selected result row, because Return runs it.
struct CommandBarAskAIRow: View {
    let query: String
    let ask: () -> Void
    @AppStorage(DefaultsKey.aiChatDefaultModel) private var defaultModel = AIModelChoice.fallbackDefault.storageValue

    var body: some View {
        Button(action: ask) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Ask AI: “\(query)”")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(AIModelChoice(storageValue: defaultModel)?.displayName ?? "Default model")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .padding(8)
        .accessibilityLabel("Ask AI: \(query)")
    }
}
