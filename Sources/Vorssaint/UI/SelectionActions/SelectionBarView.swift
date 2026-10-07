// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Fork: what the Selection Actions panel shows. A row of icons with the
/// hovered one's name above it, the case choices, the counts, or a result
/// with Copy, Replace and Send to AI Chat.
final class SelectionBarModel: ObservableObject {
    enum Mode: Equatable {
        case actions, cases, result
        case count(String)
    }

    struct Item: Identifiable {
        enum Kind {
            case builtIn(SelectionActionID)
            case custom(SelectionCustomAction)
        }

        let id: String
        let title: String
        let symbol: String
        let kind: Kind
    }

    @Published var mode: Mode = .actions
    @Published var items: [Item] = []
    @Published var hovered: String?
    @Published var flash: String?

    @Published var resultTitle = ""
    @Published var resultSymbol = "sparkles"
    @Published var resultText = ""
    @Published var error: String?
    @Published var needsAISetup = false
    @Published var canReplace = false
    @Published var isWorking = false
    @Published var translationJob: SelectionTranslationJob?

    var text = ""
    var editable = false
    var jobID: UUID?

    func reset(text: String, editable: Bool, items: [Item]) {
        self.text = text
        self.editable = editable
        self.items = items
        mode = .actions
        hovered = nil
        flash = nil
        resultTitle = ""
        resultText = ""
        error = nil
        needsAISetup = false
        canReplace = false
        isWorking = false
        translationJob = nil
        jobID = nil
    }
}

struct SelectionTranslationJob: Equatable {
    let id = UUID()
    let text: String
    let target: String
}

struct SelectionBarRoot: View {
    @ObservedObject var model: SelectionBarModel
    unowned let controller: SelectionBarController

    var body: some View {
        Group {
            if model.mode == .result {
                SelectionResultView(model: model, controller: controller)
            } else {
                VStack(spacing: 4) {
                    // Room for the caption, which floats over it so a long
                    // name never resizes the panel under the pointer.
                    Color.clear
                        .frame(height: 18)
                        .overlay { caption.fixedSize() }
                    bar
                }
            }
        }
        .fixedSize()
    }

    /// The hovered button's name; tooltips don't show for an app in the
    /// background, and the bar never brings Vorssaint forward.
    private var caption: some View {
        Text(model.hovered ?? " ")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background {
                if model.hovered != nil {
                    SelectionBarBackground().clipShape(Capsule())
                }
            }
            .opacity(model.hovered == nil ? 0 : 1)
    }

    private var bar: some View {
        HStack(spacing: 2) {
            if let flash = model.flash {
                Label(flash, systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
            } else {
                switch model.mode {
                case .actions:
                    ForEach(model.items) { item in
                        SelectionBarButton(symbol: item.symbol, title: item.title, controller: controller) {
                            controller.perform(item)
                        }
                    }
                case .cases:
                    backButton
                    ForEach(SelectionCase.allCases) { style in
                        SelectionBarButton(label: style.shortTitle, title: style.title, controller: controller) {
                            controller.chooseCase(style)
                        }
                    }
                case .count(let summary):
                    backButton
                    Text(summary)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                case .result:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(SelectionBarBackground())
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var backButton: some View {
        SelectionBarButton(symbol: "chevron.left", title: "Back", controller: controller) { controller.back() }
    }
}

private struct SelectionBarButton: View {
    var symbol: String?
    var label: String?
    let title: String
    unowned let controller: SelectionBarController
    let action: () -> Void
    @State private var isHovering = false

    init(symbol: String, title: String, controller: SelectionBarController, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.controller = controller
        self.action = action
    }

    init(label: String, title: String, controller: SelectionBarController, action: @escaping () -> Void) {
        self.label = label
        self.title = title
        self.controller = controller
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                } else {
                    Text(label ?? "").font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, label == nil ? 0 : 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovering ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering in
            isHovering = hovering
            controller.hover(hovering ? title : nil)
        }
    }
}

private struct SelectionResultView: View {
    @ObservedObject var model: SelectionBarModel
    unowned let controller: SelectionBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: model.resultSymbol)
                    .foregroundStyle(.secondary)
                Text(model.resultTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Button { controller.hide() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ScrollView {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(model.resultText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 168)

            if let error = model.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.needsAISetup {
                        Spacer(minLength: 4)
                        Button("AI Settings…") { controller.openAISettings() }
                            .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 8) {
                Button { controller.sendResultToChat() } label: {
                    Label("Send to Chat", systemImage: "bubble.left.and.bubble.right")
                }
                Spacer()
                Button("Copy") { controller.copyResult() }
                    .disabled(model.isWorking || model.resultText.isEmpty)
                if model.canReplace {
                    Button("Replace") { controller.replaceWithResult() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || model.resultText.isEmpty)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 380)
        .background(SelectionBarBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .background {
            if let job = model.translationJob {
                SelectionTranslationHost(job: job, controller: controller)
            }
        }
    }

    private var displayText: String {
        if !model.resultText.isEmpty { return model.resultText }
        if model.isWorking { return model.translationJob == nil ? "Thinking…" : "Translating…" }
        return model.error == nil ? "Nothing came back." : ""
    }
}

/// The panel's material, kept active: the app is in the background while
/// the bar shows, and an inactive material would go flat and grey.
private struct SelectionBarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Translation

/// Runs Apple's on-device translation for one job, through the SwiftUI
/// hook macOS 15 offers for it.
private struct SelectionTranslationHost: View {
    let job: SelectionTranslationJob
    unowned let controller: SelectionBarController

    var body: some View {
        if #available(macOS 15.0, *) {
            SelectionTranslationRunner(job: job) { result in
                controller.translationFinished(job, result)
            }
        }
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
struct SelectionTranslationRunner: View {
    static let isAvailable = true

    let job: SelectionTranslationJob
    let finish: (Result<String, Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                let result: Result<String, Error>
                do {
                    result = .success(try await session.translate(job.text).targetText)
                } catch {
                    result = .failure(error)
                }
                await MainActor.run { finish(result) }
            }
            .onAppear {
                configuration = TranslationSession.Configuration(source: nil,
                                                                 target: Locale.Language(identifier: job.target))
            }
    }
}
#else
@available(macOS 15.0, *)
struct SelectionTranslationRunner: View {
    static let isAvailable = false

    let job: SelectionTranslationJob
    let finish: (Result<String, Error>) -> Void

    var body: some View { EmptyView() }
}
#endif
