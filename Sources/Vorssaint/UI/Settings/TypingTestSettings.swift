// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: Settings › Typing Test. The way in, what has been typed so far, and
/// how to give it a shortcut from the Command Bar.
struct TypingTestSettings: View {
    @ObservedObject private var service = TypingTestService.shared
    @State private var confirmsClear = false

    var body: some View {
        let summary = service.summary
        Form {
            Section {
                Button {
                    service.show()
                } label: {
                    Label("Open Typing Test", systemImage: "keyboard")
                }
                Text("A minimal typing speed test: timed (15, 30, 60 or 120 seconds), by word count (10, 25, 50 or 100), on a real passage, or on code. Tab starts over, Esc stops a test or closes the window, and ⌥⌫ deletes a word. Quote mode types real passages from public-domain books and speeches; code mode types snippets in Swift, Python, JavaScript, Go and Rust, shown as an editor shows them, with indentation filled in for you. Every finished test is kept for your averages and bests.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("To open it with a shortcut, open the Command Bar, find Typing Test and choose Give it a shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(TypingTestSupport.title)
            }

            Section("Your results") {
                LabeledContent("Tests", value: "\(summary.tests)")
                LabeledContent("Average", value: summary.tests == 0 ? "–" : "\(Int(summary.averageWPM.rounded())) wpm")
                LabeledContent("Last \(TypingTestSummary.recentCount)",
                               value: summary.tests == 0 ? "–" : "\(Int(summary.recentWPM.rounded())) wpm")
                LabeledContent("Best", value: summary.tests == 0 ? "–" : "\(Int(summary.bestWPM.rounded())) wpm")
                HStack {
                    Button("Show History") {
                        service.show()
                        service.page = .history
                    }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmsClear = true }
                        .disabled(summary.tests == 0)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { service.loadIfNeeded() }
        .confirmationDialog("Clear all \(summary.tests) tests?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { service.clearHistory() }
        } message: {
            Text("Averages and bests start over. This can't be undone.")
        }
    }
}
