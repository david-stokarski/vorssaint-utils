// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: chats saved one file each, owner-only, under Application Support.
/// Attached images sit beside them in `Attachments`, one file each, named in
/// the chat by file name only.
enum AIChatStore {
    static var directory: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("AIChats", isDirectory: true)
    }

    static var attachmentsDirectory: URL? {
        directory?.appendingPathComponent("Attachments", isDirectory: true)
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

    static func delete(_ conversation: AIChatConversation) {
        deleteFiles(of: conversation.messages.flatMap { $0.attachments ?? [] })
        guard let url = url(for: conversation.id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Attachments

    /// Writes an image that is about to be attached and returns its
    /// attachment, or nil when the disk refused it.
    static func saveImage(_ image: AIChatImage, title: String,
                          origin: AIChatAttachment.Origin) -> AIChatAttachment? {
        guard let folder = attachmentsDirectory, PrivateFileStore.createDirectory(at: folder) else { return nil }
        let id = UUID()
        let file = "\(id.uuidString).\(image.mediaType == "image/png" ? "png" : "jpg")"
        guard PrivateFileStore.write(image.data, to: folder.appendingPathComponent(file)) else { return nil }
        return AIChatAttachment(id: id, kind: .image, origin: origin, title: title,
                                file: file, mediaType: image.mediaType)
    }

    /// Only a bare file name inside the folder is honored, whatever an
    /// edited chat file says.
    static func fileURL(for attachment: AIChatAttachment) -> URL? {
        guard let file = attachment.file, !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") else { return nil }
        return attachmentsDirectory?.appendingPathComponent(file)
    }

    static func image(for attachment: AIChatAttachment) -> AIChatImage? {
        guard attachment.kind == .image, let url = fileURL(for: attachment),
              let data = try? Data(contentsOf: url) else { return nil }
        return AIChatImage(mediaType: attachment.mediaType ?? "image/jpeg", data: data)
    }

    static func deleteFiles(of attachments: [AIChatAttachment]) {
        for url in attachments.compactMap(fileURL) { try? FileManager.default.removeItem(at: url) }
    }

    /// Images attached to a question that was never sent, or left by a chat
    /// deleted while the app was not looking.
    static func removeFiles(notIn referenced: Set<String>) {
        guard let folder = attachmentsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// The models of one provider or endpoint, as the picker groups them.
struct AIModelGroup: Identifiable {
    let id: String
    let title: String
    let choices: [AIModelChoice]
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
    /// What the window's next question carries, shown as chips above it.
    @Published private(set) var attachments: [AIChatAttachment] = []
    /// A passing sentence above the message field: why an attachment did not
    /// happen, mostly.
    @Published var notice: String?
    @Published private(set) var isAttaching = false
    /// The island's own message field, kept here so it survives the island closing.
    @Published var islandDraft = ""
    @Published var showsSettings = false
    @Published private(set) var keyedProviders: Set<AIProvider> = []
    @Published private(set) var endpoints: [AIEndpoint] = []
    @Published private(set) var keyedEndpoints: Set<UUID> = []
    /// Model ids by source id (`anthropic`, `openai`, `compatible.<uuid>`).
    @Published private(set) var models: [String: [String]] = [:]
    @Published private(set) var modelErrors: [String: String] = [:]
    @Published private(set) var refreshingSources: Set<String> = []
    /// Bumped to put the caret back in the message field.
    @Published private(set) var focusRequest = 0

    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var noticeTimer: Timer?
    private var hasLoaded = false
    private var refreshedSources: Set<String> = []
    private var keepsAppRegular = false

    var selected: AIChatConversation? {
        conversations.first { $0.id == selectedID }
    }

    var isStreaming: Bool { streamingID != nil }

    /// Whether any model can be asked: a provider with a key, or an endpoint.
    var hasSource: Bool { !keyedProviders.isEmpty || !endpoints.isEmpty }

    /// The island stays open while a question is half typed or a reply is
    /// still arriving, wherever the pointer goes.
    var holdsIsland: Bool {
        isStreaming || !islandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Window

    func show() {
        AIChatContext.shared.start()
        loadIfNeeded()
        reloadEndpoints()
        if window == nil { window = makeWindow() }
        if selected == nil { newChat() }
        if !keepsAppRegular {
            keepsAppRegular = true
            WindowActivationPolicy.retain()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusRequest += 1
        for provider in keyedProviders where !refreshedSources.contains(provider.rawValue) {
            refreshModels(for: provider)
        }
        for endpoint in endpoints where !refreshedSources.contains(endpoint.sourceID) {
            refreshModels(for: endpoint)
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
        guard let model = selected?.model, AIChatClient.setupProblem(for: model) == nil else {
            draft = question
            showsSettings = true
            return
        }
        if send(question) { draft = "" }
    }

    /// "Ask about selection": the text selected in the app in front, attached
    /// to a fresh chat, with the caret waiting for the question.
    func askAboutSelection() {
        AIChatContext.shared.start()
        AIChatContext.shared.attachSelection { [weak self] result in
            guard let self else { return }
            self.show()
            self.newChat()
            self.handle(result)
        }
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
        // Nothing is pending yet, so every image no saved chat names is left over.
        AIChatStore.removeFiles(notIn: Set(conversations.flatMap { chat in
            chat.messages.flatMap { ($0.attachments ?? []).compactMap(\.file) }
        }))
        reloadEndpoints()
        reloadKeys()
        for provider in AIProvider.builtIn {
            let cached = cachedModels(provider.rawValue)
            models[provider.rawValue] = cached.isEmpty ? provider.fallbackModels : cached
        }
    }

    private func cachedModels(_ source: String) -> [String] {
        UserDefaults.standard.string(forKey: DefaultsKey.aiChatModelCache(source: source))?
            .split(separator: ",").map(String.init) ?? []
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
        if let chat = conversations.first(where: { $0.id == id }) { AIChatStore.delete(chat) }
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first?.id }
        if selectedID == nil { newChat() }
    }

    func deleteAll() {
        stop()
        for chat in conversations { AIChatStore.delete(chat) }
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

    // MARK: - Attachments

    func attachSelection() {
        AIChatContext.shared.attachSelection { [weak self] in self?.handle($0) }
    }

    func attachFrontWindow() {
        guard !isAttaching else { return }
        isAttaching = true
        Task { @MainActor [weak self] in
            let result = await AIChatContext.shared.attachFrontWindow()
            self?.isAttaching = false
            self?.handle(result)
        }
    }

    func attachArea() {
        guard !isAttaching else { return }
        isAttaching = true
        AIChatContext.shared.attachArea { [weak self] result in
            self?.isAttaching = false
            self?.handle(result)
            // The capture surface took the keyboard; the chat gets it back.
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Files dropped on the chat, or pasted into it.
    func attach(files: [URL]) {
        for url in files { handle(AIChatContext.shared.attachFile(url)) }
    }

    func attach(image: CGImage, title: String) {
        handle(AIChatContext.shared.attachImage(image, title: title, origin: .paste))
    }

    func attach(text: String, title: String) {
        handle(.attached(.text(text, title: title, origin: .paste)))
    }

    func removeAttachment(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        AIChatStore.deleteFiles(of: [attachments.remove(at: index)])
    }

    private func handle(_ result: AIChatContext.Result) {
        switch result {
        case .attached(let attachment):
            // The same selection twice is one attachment.
            if attachment.kind == .text,
               attachments.contains(where: { $0.kind == .text && $0.text == attachment.text }) { break }
            attachments.append(attachment)
            notice = nil
        case .nothing(let message):
            show(notice: message)
        case .cancelled:
            break
        }
        focusRequest += 1
    }

    private func show(notice message: String) {
        notice = message
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.notice = nil
        }
    }

    // MARK: - Sending

    /// The window's composer: the draft and its attachments, cleared once sent.
    func sendDraft() {
        guard send(draft, attachments: attachments) else { return }
        draft = ""
        attachments = []
    }

    /// False when nothing was sent, so the caller keeps what was typed.
    @discardableResult
    func send(_ text: String, attachments: [AIChatAttachment] = []) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !attachments.isEmpty, !isStreaming else { return false }
        loadIfNeeded()
        if selected == nil { newChat() }
        guard let id = selectedID else { return false }
        update(id) { chat in
            if chat.messages.isEmpty, chat.title.isEmpty {
                chat.title = AIChatSupport.title(from: question.isEmpty ? (attachments.first?.title ?? "") : question)
            }
            chat.messages.append(AIChatMessage(role: .user, text: question,
                                               attachments: attachments.isEmpty ? nil : attachments))
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
        let problem = AIChatClient.setupProblem(for: choice)
        if problem != nil, choice.provider != .compatible {
            showsSettings = true
            return
        }
        let turns = AIChatAttachments.turns(from: chat.messages, imageData: AIChatStore.image(for:))
        let system = UserDefaults.standard.string(forKey: DefaultsKey.aiChatSystemPrompt) ?? ""
        let reply = AIChatMessage(role: .assistant, text: "", model: choice.model)
        update(id) { chat in
            chat.messages.append(reply)
            chat.updated = Date()
        }
        moveToTop(id)
        if let problem {
            finishStream(id, reply: reply.id, failure: problem)
            return
        }
        streamingID = id
        task = Task { @MainActor [weak self] in
            var failure: String?
            var pending = ""
            var received = false
            do {
                var lastFlush = Date()
                for try await piece in AIChatClient.stream(choice, system: system, turns: turns) {
                    pending += piece
                    received = received || !piece.isEmpty
                    if Date().timeIntervalSince(lastFlush) > 0.05 {
                        self?.appendText(pending, to: reply.id, in: id)
                        pending = ""
                        lastFlush = Date()
                    }
                }
                if Task.isCancelled {
                    failure = "Stopped."
                } else if !received {
                    failure = "The model sent back an empty reply."
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    failure = "Stopped."
                } else {
                    failure = error.localizedDescription
                }
            }
            self?.appendText(pending, to: reply.id, in: id)
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
        keyedProviders = Set(AIProvider.builtIn.filter { AIChatKeychain.hasKey(for: $0) })
        keyedEndpoints = Set(endpoints.filter { AIChatKeychain.hasKey(for: $0) }.map(\.id))
    }

    @discardableResult
    func setKey(_ key: String?, for provider: AIProvider) -> Bool {
        let saved = AIChatKeychain.setKey(key, for: provider)
        reloadKeys()
        if saved, keyedProviders.contains(provider) { refreshModels(for: provider) }
        return saved
    }

    func refreshModels(for provider: AIProvider) {
        guard keyedProviders.contains(provider) || AIChatKeychain.hasKey(for: provider) else { return }
        let source = provider.rawValue
        refreshedSources.insert(source)
        refreshingSources.insert(source)
        Task { @MainActor [weak self] in
            do {
                let ids = try await AIChatClient.listModels(for: provider)
                self?.receive(ids, for: source)
            } catch {
                self?.modelErrors[source] = error.localizedDescription
            }
            self?.refreshingSources.remove(source)
        }
    }

    private func receive(_ ids: [String], for source: String) {
        modelErrors[source] = nil
        guard !ids.isEmpty else { return }
        models[source] = ids
        UserDefaults.standard.set(ids.joined(separator: ","), forKey: DefaultsKey.aiChatModelCache(source: source))
        adoptAsDefaultIfAlone(source)
    }

    /// With no provider key at all, a default on Claude or GPT can never
    /// answer; the first endpoint with a model becomes the default instead,
    /// so a Mac running only Ollama works without a trip to a picker.
    private func adoptAsDefaultIfAlone(_ source: String) {
        guard keyedProviders.isEmpty, AIChatSupport.defaultModel().provider != .compatible,
              let endpoint = endpoints.first(where: { $0.sourceID == source }),
              let model = models(of: endpoint).first else { return }
        let choice = AIModelChoice(endpoint: endpoint.id, model: model)
        UserDefaults.standard.set(choice.storageValue, forKey: DefaultsKey.aiChatDefaultModel)
        if let chat = selected, chat.messages.isEmpty, chat.model.provider != .compatible {
            setModel(choice, for: chat.id)
        }
    }

    // MARK: - Endpoints

    /// Re-read from preferences: a settings backup may have replaced them.
    func reloadEndpoints() {
        let stored = AIChatSupport.endpoints()
        if stored != endpoints {
            endpoints = stored
            for endpoint in stored where models[endpoint.sourceID] == nil {
                models[endpoint.sourceID] = cachedModels(endpoint.sourceID)
            }
        }
        keyedEndpoints = Set(endpoints.filter { AIChatKeychain.hasKey(for: $0) }.map(\.id))
    }

    private func persistEndpoints() {
        UserDefaults.standard.set(AIChatSupport.encodeEndpoints(endpoints), forKey: DefaultsKey.aiChatEndpoints)
    }

    @discardableResult
    func addEndpoint(_ preset: AIEndpointPreset) -> AIEndpoint {
        reloadEndpoints()
        var endpoint = AIEndpoint(preset: preset)
        let names = Set(endpoints.map(\.displayName))
        var number = 2
        while names.contains(endpoint.displayName) {
            endpoint.name = "\(preset == .custom ? "Custom Server" : preset.title) \(number)"
            number += 1
        }
        endpoints.append(endpoint)
        persistEndpoints()
        if !preset.needsKey { refreshModels(for: endpoint) }
        return endpoint
    }

    func updateEndpoint(_ endpoint: AIEndpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }),
              endpoints[index] != endpoint else { return }
        let addressChanged = endpoints[index].normalizedBaseURL != endpoint.normalizedBaseURL
        endpoints[index] = endpoint
        persistEndpoints()
        if addressChanged { refreshModels(for: endpoint) }
        adoptAsDefaultIfAlone(endpoint.sourceID)
    }

    func removeEndpoint(_ id: UUID) {
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { return }
        AIChatKeychain.setKey(nil, for: endpoint)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.aiChatModelCache(source: endpoint.sourceID))
        models[endpoint.sourceID] = nil
        modelErrors[endpoint.sourceID] = nil
        endpoints.removeAll { $0.id == id }
        keyedEndpoints.remove(id)
        persistEndpoints()
        // Chats on it keep their choice and say the endpoint is gone; the
        // default goes back to Claude.
        if UserDefaults.standard.string(forKey: DefaultsKey.aiChatDefaultModel)?
            .hasPrefix(endpoint.sourceID + ":") == true {
            UserDefaults.standard.set(AIModelChoice.fallbackDefault.storageValue, forKey: DefaultsKey.aiChatDefaultModel)
        }
    }

    @discardableResult
    func setKey(_ key: String?, for endpoint: AIEndpoint) -> Bool {
        let saved = AIChatKeychain.setKey(key, for: endpoint)
        reloadKeys()
        if saved { refreshModels(for: endpoint) }
        return saved
    }

    func refreshModels(for endpoint: AIEndpoint) {
        let source = endpoint.sourceID
        refreshedSources.insert(source)
        refreshingSources.insert(source)
        Task { @MainActor [weak self] in
            do {
                let ids = try await AIChatClient.listModels(for: endpoint)
                self?.receive(ids, for: source)
                if ids.isEmpty, endpoint.manualModels.isEmpty {
                    self?.modelErrors[source] = "The server listed no models. Type the model names below."
                }
            } catch {
                self?.modelErrors[source] = error.localizedDescription
            }
            self?.refreshingSources.remove(source)
        }
    }

    /// The models an endpoint offers: the hand-typed list when there is one,
    /// otherwise what it last listed, with its default model first.
    func models(of endpoint: AIEndpoint) -> [String] {
        var ids = endpoint.manualModels
        if ids.isEmpty { ids = models[endpoint.sourceID] ?? [] }
        let preferred = endpoint.defaultModel.trimmingCharacters(in: .whitespaces)
        if !preferred.isEmpty {
            ids.removeAll { $0 == preferred }
            ids.insert(preferred, at: 0)
        }
        return ids
    }

    // MARK: - Choosing a model

    /// The provider or endpoint a model belongs to, by name.
    func sourceTitle(for choice: AIModelChoice) -> String {
        guard choice.provider == .compatible else { return choice.provider.title }
        return endpoints.first { $0.id == choice.endpointID }?.displayName ?? "Removed endpoint"
    }

    /// Every model a chat can switch to, grouped by where it lives: providers
    /// with a key (or both, while nothing is set up), then each endpoint, plus
    /// whatever the chat already uses.
    func groups(including current: AIModelChoice?) -> [AIModelGroup] {
        loadIfNeeded()
        let providers = hasSource ? AIProvider.builtIn.filter(keyedProviders.contains) : AIProvider.builtIn
        var groups = providers.map { provider in
            AIModelGroup(id: provider.rawValue, title: provider.title,
                         choices: (models[provider.rawValue] ?? provider.fallbackModels)
                            .map { AIModelChoice(provider: provider, model: $0) })
        }
        groups += endpoints.map { endpoint in
            AIModelGroup(id: endpoint.sourceID, title: endpoint.displayName,
                         choices: models(of: endpoint).map { AIModelChoice(endpoint: endpoint.id, model: $0) })
        }
        if let current, !groups.contains(where: { $0.choices.contains(current) }) {
            if let index = groups.firstIndex(where: { $0.id == current.sourceID }) {
                groups[index] = AIModelGroup(id: groups[index].id, title: groups[index].title,
                                             choices: [current] + groups[index].choices)
            } else {
                groups.append(AIModelGroup(id: current.sourceID, title: sourceTitle(for: current), choices: [current]))
            }
        }
        return groups
    }
}

/// Fork: "Ask AI About Selection", a global shortcut that opens AI Chat with
/// the selection of the app in front attached. Off until switched on.
final class AIChatSelectionHotkey: ObservableObject {
    static let shared = AIChatSelectionHotkey()

    @Published private(set) var registrationFailed = false
    private let hotkey = QuickToolHotkey(id: 1300)

    private init() {
        hotkey.onPress = { AIChatService.shared.askAboutSelection() }
    }

    func syncWithPreferences() {
        let enabled = AppFeature.aiChat.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.aiChatSelectionShortcutEnabled)
        registrationFailed = !hotkey.sync(enabled: enabled,
                                          shortcut: GlobalShortcutRole.aiChatSelection.savedShortcut,
                                          storageKey: DefaultsKey.aiChatSelectionShortcut)
    }
}

#if VORSSAINT_DEVELOPMENT
extension AIChatService {
    /// Developer builds only: a text and an image chip, for checking the
    /// composer without granting any permission.
    func attachDevSample() {
        attach(text: "func greet() {\n    print(\"Hello\")\n}", title: "Sample selection")
        let width = 640, height = 320
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 220, y: 60, width: 200, height: 200))
        if let image = context.makeImage() { attach(image: image, title: "Sample image") }
    }
}
#endif
