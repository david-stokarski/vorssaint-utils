// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import SwiftUI

/// Fork: the Typing Test window, the test being typed and the kept results.
/// A clock runs only while a test is under way; results are kept in a small
/// file next to the app's other data.
final class TypingTestService: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TypingTestService()

    enum Page { case test, history }

    @Published private(set) var run: TypingTestRun
    @Published private(set) var mode: TypingTestMode
    @Published private(set) var results: [TypingTestResult] = []
    /// The test just finished, shown until the next one starts.
    @Published private(set) var lastResult: TypingTestResult?
    /// Whether the last result beat the best before it in its mode.
    @Published private(set) var lastWasBest = false
    @Published var page: Page = .test
    /// Bumped every tenth of a second while a test runs, for the countdown.
    @Published private(set) var now: Double = ProcessInfo.processInfo.systemUptime

    private var window: NSWindow?
    private var clock: Timer?
    private var hasLoaded = false
    private var keepsAppRegular = false

    private override init() {
        let mode = TypingTestMode.load(from: .standard)
        self.mode = mode
        run = TypingTestRun(mode: mode)
        super.init()
    }

    var summary: TypingTestSummary { TypingTestSummary(results) }

    // MARK: - Window

    func show() {
        loadIfNeeded()
        if window == nil { window = makeWindow() }
        if !keepsAppRegular {
            keepsAppRegular = true
            WindowActivationPolicy.retain()
        }
        page = .test
        if run.isStarted, !run.isFinished { restart() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: TypingTestView(service: self))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = TypingTestSupport.title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 720, height: 440)
        window.setContentSize(NSSize(width: 980, height: 580))
        window.delegate = self
        if !window.setFrameUsingName("VorssaintTypingTest") { window.center() }
        window.setFrameAutosaveName("VorssaintTypingTest")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // A test left half typed is not a result.
        if run.isStarted, !run.isFinished { restart() }
        stopClock()
        if keepsAppRegular {
            keepsAppRegular = false
            WindowActivationPolicy.release()
        }
    }

    /// The feature was turned off or uninstalled.
    func syncWithPreferences() {
        guard !AppFeature.typingTest.isAvailable else { return }
        window?.close()
        window = nil
        stopClock()
    }

    // MARK: - The test

    func setMode(_ next: TypingTestMode) {
        mode = next
        next.save(to: .standard)
        restart()
    }

    /// A fresh set of words in the current mode.
    func restart() {
        stopClock()
        run = TypingTestRun(mode: mode, avoiding: run.quote, avoidingCode: run.code)
        lastResult = nil
        lastWasBest = false
        page = .test
    }

    /// Return: the next test from a result; in code, the end of a line.
    func confirm() {
        if lastResult != nil {
            restart()
        } else if page == .test, run.mode.kind == .code {
            type("\n")
        }
    }

    /// Esc: stops a test being typed; anywhere else, leaves the window.
    func escape() {
        if page == .test, lastResult == nil, run.isStarted, !run.isFinished {
            restart()
        } else {
            window?.performClose(nil)
        }
    }

    func type(_ character: Character) {
        guard lastResult == nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        run.type(character, at: time)
        if run.isStarted, clock == nil { startClock() }
        finishIfDone()
    }

    func deleteBackward(wholeWord: Bool) {
        guard lastResult == nil else { return }
        run.deleteBackward(wholeWord: wholeWord, at: ProcessInfo.processInfo.systemUptime)
        finishIfDone()
    }

    private func startClock() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let time = ProcessInfo.processInfo.systemUptime
            self.now = time
            self.run.tick(at: time)
            self.finishIfDone()
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func finishIfDone() {
        guard run.isFinished, lastResult == nil, let result = run.result() else { return }
        stopClock()
        let previousBest = TypingTestSummary.best(in: result.mode, of: results)
        lastResult = result
        guard result.isWorthKeeping else { return }
        lastWasBest = previousBest.map { result.wpm > $0 } ?? true
        results.insert(result, at: 0)
        persist()
    }

    // MARK: - History

    func remove(_ result: TypingTestResult) {
        results.removeAll { $0.id == result.id }
        persist()
    }

    func clearHistory() {
        results = []
        persist()
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        results = TypingTestSupport.decode(Self.historyURL.flatMap { try? Data(contentsOf: $0) })
    }

    private func persist() {
        guard let url = Self.historyURL, let data = TypingTestSupport.encode(results) else { return }
        PrivateFileStore.createDirectory(at: url.deletingLastPathComponent())
        PrivateFileStore.write(data, to: url)
    }

    private static var historyURL: URL? {
        PrivateFileStore.containerURL?
            .appendingPathComponent("Typing Test", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
