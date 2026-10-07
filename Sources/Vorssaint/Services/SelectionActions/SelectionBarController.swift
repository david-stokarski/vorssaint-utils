// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the floating bar and what its buttons do. The panel never becomes
/// key and never activates the app, so the app the text came from keeps
/// its focus, its selection and its caret; Replace pastes straight back
/// into it. A click or a key anywhere else, a scroll, Escape, another app
/// coming forward or a few untouched seconds put the bar away.
final class SelectionBarController {
    static let shared = SelectionBarController()

    let model = SelectionBarModel()

    private var panel: SelectionBarPanel?
    private var host: SelectionBarHostingView<SelectionBarRoot>?
    private var pointer = CGPoint.zero
    private var visibleFrame = CGRect.zero
    private var sourceApp: NSRunningApplication?
    private var isPreview = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var task: Task<Void, Never>?
    private var flashWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    // MARK: - Showing

    func show(text: String, editable: Bool, pointer: CGPoint, sourceApp: NSRunningApplication?, preview: Bool = false) {
        hide()
        let items = Self.items(for: text)
        guard !items.isEmpty else { return }
        isPreview = preview
        self.sourceApp = sourceApp
        self.pointer = pointer
        visibleFrame = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?
            .visibleFrame ?? NSScreen.pointerVisibleFrame
        model.reset(text: text, editable: editable, items: items)

        let panel = makePanel()
        self.panel = panel
        layout(initial: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()
        lastActivity = Date()
        startIdleTimer()
    }

    func hide() {
        task?.cancel()
        task = nil
        flashWork?.cancel()
        flashWork = nil
        removeMonitors()
        idleTimer?.invalidate()
        idleTimer = nil
        model.translationJob = nil
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        host = nil
        sourceApp = nil
    }

    private func makePanel() -> SelectionBarPanel {
        let panel = SelectionBarPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = SelectionBarHostingView(rootView: SelectionBarRoot(model: model, controller: self))
        host.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = host
        self.host = host
        return panel
    }

    /// Fits the panel to what it shows now: placed above the pointer the
    /// first time, then grown from the edge it was anchored on.
    func layout(initial: Bool = false) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let frame = initial || panel.frame.width <= 10
            ? SelectionBarPlacement.frame(size: size, pointer: pointer, visibleFrame: visibleFrame)
            : SelectionBarPlacement.resized(panel.frame, to: size, pointer: pointer, visibleFrame: visibleFrame)
        panel.setFrame(frame.integral, display: true)
        panel.invalidateShadow()
    }

    private static func items(for text: String) -> [SelectionBarModel.Item] {
        let custom = SelectionCustomAction.current()
        return SelectionActionOrder.current().compactMap { entry -> SelectionBarModel.Item? in
            guard entry.enabled else { return nil }
            if let id = entry.builtIn {
                guard SelectionActionOrder.isApplicable(id, to: text) else { return nil }
                return SelectionBarModel.Item(id: entry.key, title: id.title, symbol: id.symbolName, kind: .builtIn(id))
            }
            guard let action = custom.first(where: { $0.actionKey == entry.key }), action.isUsable else { return nil }
            return SelectionBarModel.Item(id: entry.key, title: action.name, symbol: action.kind.symbolName,
                                          kind: .custom(action))
        }
    }

    // MARK: - Dismissal

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] _ in
            self?.hide()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hide(); return nil }  // Escape
            } else if event.window !== self.panel {
                self.hide()
            }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, !self.isPreview else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != self.sourceApp?.processIdentifier { self.hide() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        globalMonitor = nil
        localMonitor = nil
        activationObserver = nil
    }

    /// The bar goes after a few seconds untouched; a pointer resting on it,
    /// or a result being read, keeps it.
    private func startIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if self.model.mode == .result || panel.frame.contains(NSEvent.mouseLocation) {
                self.lastActivity = Date()
                return
            }
            if Date().timeIntervalSince(self.lastActivity) > SelectionActionsSupport.dismissDelay() {
                self.hide()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    // MARK: - Actions

    func perform(_ item: SelectionBarModel.Item) {
        lastActivity = Date()
        switch item.kind {
        case .builtIn(let id): perform(id)
        case .custom(let action): perform(action)
        }
    }

    private func perform(_ id: SelectionActionID) {
        let text = model.text
        switch id {
        case .copy:
            Self.copyToPasteboard(text)
            flash("Copied")
        case .search:
            let defaults = UserDefaults.standard
            let url = SelectionSearchEngine.searchURL(
                for: text, engine: SelectionSearchEngine.current(in: defaults),
                customTemplate: defaults.string(forKey: DefaultsKey.selectionActionsCustomSearchURL) ?? "")
            hide()
            if let url { NSWorkspace.shared.open(url) }
        case .openURL:
            let url = SelectionURL.url(from: text)
            hide()
            if let url { NSWorkspace.shared.open(url) }
        case .changeCase:
            setMode(.cases)
        case .cleanWhitespace:
            apply(SelectionText.cleanWhitespace(text), title: id.title, symbol: id.symbolName)
        case .count:
            setMode(.count(SelectionText.countSummary(text)))
        case .translate:
            translate()
        case .rewrite, .fixGrammar, .shorter, .friendlier, .explain:
            runAI(title: id.title, symbol: id.symbolName, template: id.aiPrompt ?? SelectionPromptTemplate.placeholder,
                  replaces: id.resultReplacesSelection)
        case .sendToChat:
            hide()
            Self.sendToChat(text, result: nil)
        }
    }

    private func perform(_ action: SelectionCustomAction) {
        switch action.kind {
        case .aiPrompt:
            runAI(title: action.name, symbol: action.kind.symbolName, template: action.value, replaces: action.replaces)
        case .shortcut:
            runProcess(title: action.name, symbol: action.kind.symbolName, replaces: action.replaces) { text in
                Self.runShortcut(named: action.value, input: text)
            }
        case .script:
            let links = CommandBarLinks.decode(UserDefaults.standard.data(forKey: DefaultsKey.commandBarLinks))
            guard let link = links.first(where: { $0.id.uuidString == action.value && $0.kind == .script }) else {
                beginResult(title: action.name, symbol: action.kind.symbolName, replaces: false)
                finishResult(.failure(SelectionAIError.failed("That Command Bar script is no longer saved.")))
                return
            }
            runProcess(title: action.name, symbol: action.kind.symbolName, replaces: action.replaces) { text in
                let path = (link.destination as NSString).expandingTildeInPath
                let (status, output) = Shell.run(path, [text], timeout: 30, maxOutputBytes: 256 * 1024)
                return (status, output)
            }
        }
    }

    func chooseCase(_ style: SelectionCase) {
        apply(SelectionText.changeCase(model.text, to: style, locale: .current), title: style.title,
              symbol: SelectionActionID.changeCase.symbolName)
    }

    func back() { setMode(.actions) }

    func hover(_ title: String?) {
        lastActivity = Date()
        if model.hovered != title { model.hovered = title }
    }

    private func setMode(_ mode: SelectionBarModel.Mode) {
        model.hovered = nil
        model.mode = mode
        DispatchQueue.main.async { self.layout() }
    }

    private func flash(_ message: String) {
        model.flash = message
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// A transform goes straight back over an editable selection; anything
    /// else shows the result to copy.
    private func apply(_ result: String, title: String, symbol: String) {
        if model.editable, !isPreview {
            replace(with: result)
            return
        }
        beginResult(title: title, symbol: symbol, replaces: model.editable)
        finishResult(.success(result))
    }

    // MARK: - Results

    private func beginResult(title: String, symbol: String, replaces: Bool) {
        task?.cancel()
        model.resultTitle = title
        model.resultSymbol = symbol
        model.resultText = ""
        model.error = nil
        model.needsAISetup = false
        model.canReplace = replaces && model.editable
        model.isWorking = true
        setMode(.result)
    }

    private func finishResult(_ result: Result<String, Error>) {
        model.isWorking = false
        switch result {
        case .success(let text):
            model.resultText = text
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case SelectionAIError.notConfigured = error { model.needsAISetup = true }
            model.error = error.localizedDescription
        }
    }

    private func runAI(title: String, symbol: String, template: String, replaces: Bool) {
        let engine = SelectionAI.engine
        guard engine.isConfigured else {
            hide()
            engine.openSettings()
            return
        }
        let language = SelectionTranslation.name(
            for: SelectionTranslation.targetCode(saved: UserDefaults.standard.string(forKey: DefaultsKey.selectionActionsTranslateTarget)))
        let prompt = SelectionPromptTemplate.render(template, text: model.text, language: language)
        let system = replaces ? SelectionPromptTemplate.transformSystem : SelectionPromptTemplate.explainSystem
        beginResult(title: title, symbol: symbol, replaces: replaces)
        let model = model
        task = Task { @MainActor [weak self] in
            do {
                let reply = try await engine.stream(system: system, prompt: prompt) { chunk in
                    model.resultText += chunk
                }
                self?.finishResult(.success(replaces ? SelectionPromptTemplate.cleanedReply(reply)
                                                      : reply.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                self?.finishResult(.failure(error))
            }
        }
    }

    private func runProcess(title: String, symbol: String, replaces: Bool,
                            _ work: @escaping (String) -> (status: Int32, output: String)) {
        beginResult(title: title, symbol: symbol, replaces: replaces)
        let text = model.text
        let generation = UUID()
        model.jobID = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, output) = work(text)
            DispatchQueue.main.async {
                guard let self, self.model.jobID == generation, self.isVisible else { return }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if status == 0 {
                    self.finishResult(.success(trimmed.isEmpty ? "Done." : trimmed))
                    if trimmed.isEmpty { self.model.canReplace = false }
                } else {
                    self.finishResult(.failure(SelectionAIError.failed(trimmed.isEmpty ? "It stopped with status \(status)." : trimmed)))
                }
            }
        }
    }

    private static func runShortcut(named name: String, input: String) -> (status: Int32, output: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vorssaint-Selection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let inURL = folder.appendingPathComponent("input.txt")
            let outURL = folder.appendingPathComponent("output.txt")
            try input.write(to: inURL, atomically: true, encoding: .utf8)
            let (status, log) = Shell.run("/usr/bin/shortcuts",
                                          ["run", name, "--input-path", inURL.path, "--output-path", outURL.path,
                                           "--output-type", "public.plain-text"],
                                          timeout: 60, maxOutputBytes: 64 * 1024)
            let output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            return (status, status == 0 ? output : log)
        } catch {
            return (1, error.localizedDescription)
        }
    }

    // MARK: - Translation

    private func translate() {
        let code = SelectionTranslation.targetCode(
            saved: UserDefaults.standard.string(forKey: DefaultsKey.selectionActionsTranslateTarget))
        let title = "Translate to \(SelectionTranslation.name(for: code))"
        if #available(macOS 15.0, *), SelectionTranslationRunner.isAvailable {
            beginResult(title: title, symbol: SelectionActionID.translate.symbolName, replaces: true)
            model.translationJob = SelectionTranslationJob(text: model.text, target: code)
            return
        }
        translateWithAI(title: title, code: code)
    }

    private func translateWithAI(title: String, code: String) {
        runAI(title: title, symbol: SelectionActionID.translate.symbolName,
              template: SelectionPromptTemplate.translatePrompt(language: SelectionTranslation.name(for: code)),
              replaces: true)
    }

    /// Apple's translation answered, or couldn't; without it the AI does.
    func translationFinished(_ job: SelectionTranslationJob, _ result: Result<String, Error>) {
        guard model.translationJob?.id == job.id else { return }
        model.translationJob = nil
        switch result {
        case .success(let text):
            finishResult(.success(text))
        case .failure(let error):
            if SelectionAI.engine.isConfigured {
                translateWithAI(title: model.resultTitle, code: job.target)
            } else {
                finishResult(.failure(SelectionAIError.failed(
                    "macOS couldn't translate this (\(error.localizedDescription)). Add an AI key in AI Chat to translate with AI instead.")))
                model.needsAISetup = true
            }
        }
    }

    // MARK: - Result buttons

    func copyResult() {
        guard !model.resultText.isEmpty else { return }
        Self.copyToPasteboard(model.resultText)
        model.mode = .actions
        flash("Copied")
        DispatchQueue.main.async { self.layout() }
    }

    func replaceWithResult() {
        guard model.canReplace, !model.resultText.isEmpty else { return }
        replace(with: model.resultText)
    }

    func sendResultToChat() {
        let text = model.text
        let result = model.resultText
        hide()
        Self.sendToChat(text, result: result.isEmpty ? nil : result)
    }

    func openAISettings() {
        hide()
        SelectionAI.engine.openSettings()
    }

    private func replace(with text: String) {
        let source = sourceApp
        let preview = isPreview
        hide()
        guard !preview else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source?.processIdentifier else {
            NSSound.beep()
            return
        }
        TransientPaste.shared.paste(text, transient: true, didFail: { NSSound.beep() })
    }

    private static func copyToPasteboard(_ text: String) {
        GeneralPasteboardAccess.shared.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private static func sendToChat(_ text: String, result: String?) {
        let chat = AIChatService.shared
        chat.show()
        chat.newChat()
        chat.draft = result.map { "\(text)\n\n---\n\n\($0)\n\n" } ?? "\(text)\n\n"
    }

    // MARK: - Developer preview

    #if VORSSAINT_DEVELOPMENT
    /// Shows the bar at the center of the screen with the pointer, as if
    /// `text` had just been selected, without asking Accessibility.
    func devPreview(_ text: String) {
        let frame = NSScreen.pointerVisibleFrame
        show(text: text.isEmpty ? "The quick brown fox jumps over the lazy dog." : text, editable: false,
             pointer: CGPoint(x: frame.midX, y: frame.midY), sourceApp: nil, preview: true)
    }

    /// The result view with a canned reply, so it can be seen without AI.
    func devPreviewResult(_ text: String) {
        devPreview(text)
        guard isVisible else { return }
        model.editable = true
        beginResult(title: SelectionActionID.rewrite.title, symbol: SelectionActionID.rewrite.symbolName, replaces: true)
        finishResult(.success("A preview reply. Nothing was sent anywhere: this is what a rewrite of the selection looks like, ready to copy, paste over the selection, or carry into AI Chat."))
    }
    #endif
}

/// Never key, never main: clicking it leaves the other app's window in
/// charge of the keyboard and the selection.
final class SelectionBarPanel: OverlayPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons answer the first click, though the panel is never key.
final class SelectionBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
