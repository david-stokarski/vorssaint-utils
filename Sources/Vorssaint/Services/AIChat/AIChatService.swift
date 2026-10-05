// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: chats saved one file each, owner-only, under Application Support.
enum AIChatStore {
    static var directory: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("AIChats", isDirectory: true)
    }

    private static func url(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func loadAll() -> [AIChatConversation] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(AIChatConversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    @discardableResult
    static func save(_ conversation: AIChatConversation) -> Bool {
        guard let directory, let url = url(for: conversation.id),
              PrivateFileStore.createDirectory(at: directory),
              let data = try? encoder.encode(conversation) else { return false }
        return PrivateFileStore.write(data, to: url)
    }

    static func delete(_ id: UUID) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Fork: the AI Chat window and everything it talks to. One reply streams at
/// a time; text arrives in small batches so a long answer does not re-render
/// on every token.
final class AIChatService: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AIChatService()

    @Published private(set) var conversations: [AIChatConversation] = []
    @Published var selectedID: UUID?
    @Published private(set) var streamingID: UUID?
    @Published var draft = ""
    /// The island's own message field, kept here so it survives the island closing.
    @Published var islandDraft = ""
    @Published var showsSettings = false
    @Published private(set) var keyedProviders: Set<AIProvider> = []
    @Published private(set) var models: [AIProvider: [String]] = [:]
    @Published private(set) var modelErrors: [AIProvider: String] = [:]
    /// Bumped to put the caret back in the message field.
    @Published private(set) var focusRequest = 0

    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var hasLoaded = false
    private var refreshedProviders: Set<AIProvider> = []
    private var keepsAppRegular = false

    var selected: AIChatConversation? {
        conversations.first { $0.id == selectedID }
    }

    var isStreaming: Bool { streamingID != nil }

    /// The island stays open while a question is half typed or a reply is
    /// still arriving, wherever the pointer goes.
    var holdsIsland: Bool {
        isStreaming || !islandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Window

    func show() {
        loadIfNeeded()
        if window == nil { window = makeWindow() }
        if selected == nil { newChat() }
        if !keepsAppRegular {
            keepsAppRegular = true
            WindowActivationPolicy.retain()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusRequest += 1
        for provider in keyedProviders where !refreshedProviders.contains(provider) {
            refreshModels(for: provider)
        }
    }

    /// The Command Bar's way in: a fresh chat with the default model, asked
    /// straight away. Without a key for that model's provider the question
    /// waits in the field while the key is added.
    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        show()
        newChat()
        guard !question.isEmpty else { return }
        guard let model = selected?.model, keyedProviders.contains(model.provider) else {
            draft = question
            showsSettings = true
            return
        }
        if send(question) { draft = "" }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AIChatView(service: self))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "AI Chat"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.setContentSize(NSSize(width: 920, height: 660))
        window.delegate = self
        if !window.setFrameUsingName("VorssaintAIChat") { window.center() }
        window.setFrameAutosaveName("VorssaintAIChat")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if keepsAppRegular {
            keepsAppRegular = false
            WindowActivationPolicy.release()
        }
    }

    // MARK: - Chats

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        conversations = AIChatStore.loadAll()
        reloadKeys()
        for provider in AIProvider.allCases {
            let cached = UserDefaults.standard.string(forKey: DefaultsKey.aiChatModelCache(provider))?
                .split(separator: ",").map(String.init) ?? []
            models[provider] = cached.isEmpty ? provider.fallbackModels : cached
        }
    }

    /// An empty chat is reused rather than piling up untitled ones.
    func newChat() {
        loadIfNeeded()
        if let current = selected, current.messages.isEmpty {
            update(current.id) { $0.model = AIChatSupport.defaultModel() }
        } else if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selectedID = empty.id
            update(empty.id) { $0.model = AIChatSupport.defaultModel() }
        } else {
            let chat = AIChatConversation(model: AIChatSupport.defaultModel())
            conversations.insert(chat, at: 0)
            selectedID = chat.id
        }
        focusRequest += 1
    }

    func delete(_ id: UUID) {
        if streamingID == id { stop() }
        conversations.removeAll { $0.id == id }
        AIChatStore.delete(id)
        if selectedID == id { selectedID = conversations.first?.id }
        if selectedID == nil { newChat() }
    }

    func deleteAll() {
        stop()
        for chat in conversations { AIChatStore.delete(chat.id) }
        conversations = []
        selectedID = nil
        newChat()
    }

    func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        persist(id)
    }

    func setModel(_ choice: AIModelChoice, for id: UUID) {
        update(id) { $0.model = choice }
        persist(id)
    }

    private func update(_ id: UUID, _ change: (inout AIChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }

    /// Empty chats stay in memory only.
    private func persist(_ id: UUID) {
        guard let chat = conversations.first(where: { $0.id == id }), !chat.messages.isEmpty else { return }
        AIChatStore.save(chat)
    }

    // MARK: - Sending

    /// False when nothing was sent, so the caller keeps what was typed.
    @discardableResult
    func send(_ text: String) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return false }
        loadIfNeeded()
        if selected == nil { newChat() }
        guard let id = selectedID else { return false }
        update(id) { chat in
            if chat.messages.isEmpty, chat.title.isEmpty { chat.title = AIChatSupport.title(from: question) }
            chat.messages.append(AIChatMessage(role: .user, text: question))
        }
        stream(id)
        return true
    }

    /// Asks again for the last reply, dropping the one that failed or was stopped.
    func retry() {
        guard let id = selectedID, !isStreaming else { return }
        update(id) { chat in
            if chat.messages.last?.role == .assistant { chat.messages.removeLast() }
        }
        guard selected?.messages.last?.role == .user else { return }
        stream(id)
    }

    func stop() {
        task?.cancel()
    }

    private func stream(_ id: UUID) {
        guard let chat = conversations.first(where: { $0.id == id }) else { return }
        let choice = chat.model
        guard let key = AIChatKeychain.key(for: choice.provider) else {
            showsSettings = true
            return
        }
        let request = AIChatSupport.request(
            for: choice, apiKey: key,
            system: UserDefaults.standard.string(forKey: DefaultsKey.aiChatSystemPrompt) ?? "",
            messages: chat.messages)
        let reply = AIChatMessage(role: .assistant, text: "", model: choice.model)
        update(id) { chat in
            chat.messages.append(reply)
            chat.updated = Date()
        }
        moveToTop(id)
        streamingID = id
        task = Task { @MainActor [weak self] in
            var failure: String?
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    var body = ""
                    for try await line in bytes.lines {
                        body += line + "\n"
                        if body.count > 20_000 { break }
                    }
                    failure = AIChatSupport.errorMessage(fromBody: body, status: status)
                } else {
                    var pending = ""
                    var lastFlush = Date()
                    reading: for try await line in bytes.lines {
                        switch AIChatSupport.streamEvent(fromLine: line, provider: choice.provider) {
                        case .text(let text):
                            pending += text
                            if Date().timeIntervalSince(lastFlush) > 0.05 {
                                self?.appendText(pending, to: reply.id, in: id)
                                pending = ""
                                lastFlush = Date()
                            }
                        case .done:
                            break reading
                        case .failure(let message):
                            failure = message
                            break reading
                        case nil:
                            continue
                        }
                    }
                    self?.appendText(pending, to: reply.id, in: id)
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    failure = "Stopped."
                } else {
                    failure = error.localizedDescription
                }
            }
            self?.finishStream(id, reply: reply.id, failure: failure)
        }
    }

    private func appendText(_ text: String, to messageID: UUID, in id: UUID) {
        guard !text.isEmpty else { return }
        update(id) { chat in
            guard let index = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
            chat.messages[index].text += text
        }
    }

    private func finishStream(_ id: UUID, reply: UUID, failure: String?) {
        if let failure {
            update(id) { chat in
                guard let index = chat.messages.firstIndex(where: { $0.id == reply }) else { return }
                chat.messages[index].error = failure
            }
        }
        update(id) { $0.updated = Date() }
        streamingID = nil
        task = nil
        persist(id)
    }

    private func moveToTop(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let chat = conversations.remove(at: index)
        conversations.insert(chat, at: 0)
    }

    // MARK: - Providers

    func reloadKeys() {
        keyedProviders = Set(AIProvider.allCases.filter { AIChatKeychain.hasKey(for: $0) })
    }

    @discardableResult
    func setKey(_ key: String?, for provider: AIProvider) -> Bool {
        let saved = AIChatKeychain.setKey(key, for: provider)
        reloadKeys()
        if saved, keyedProviders.contains(provider) { refreshModels(for: provider) }
        return saved
    }

    func refreshModels(for provider: AIProvider) {
        guard let key = AIChatKeychain.key(for: provider) else { return }
        refreshedProviders.insert(provider)
        let request = AIChatSupport.modelsRequest(for: provider, apiKey: key)
        Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    self?.modelErrors[provider] = AIChatSupport.errorMessage(
                        fromBody: String(decoding: data, as: UTF8.self), status: status)
                    return
                }
                let ids = AIChatSupport.chatModels(fromListing: data, provider: provider)
                guard !ids.isEmpty else { return }
                self?.models[provider] = ids
                self?.modelErrors[provider] = nil
                UserDefaults.standard.set(ids.joined(separator: ","),
                                          forKey: DefaultsKey.aiChatModelCache(provider))
            } catch {
                self?.modelErrors[provider] = error.localizedDescription
            }
        }
    }

    /// Every model a chat can switch to: those of providers with a key, or all
    /// of them while none has one yet, plus whatever the chat already uses.
    func choices(including current: AIModelChoice?) -> [AIProvider: [AIModelChoice]] {
        loadIfNeeded()
        let providers = keyedProviders.isEmpty ? Set(AIProvider.allCases) : keyedProviders
        var result: [AIProvider: [AIModelChoice]] = [:]
        for provider in AIProvider.allCases where providers.contains(provider) {
            result[provider] = (models[provider] ?? provider.fallbackModels)
                .map { AIModelChoice(provider: provider, model: $0) }
        }
        if let current, !(result[current.provider]?.contains(current) ?? false) {
            result[current.provider, default: []].insert(current, at: 0)
        }
        return result
    }
}
