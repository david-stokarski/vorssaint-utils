// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Fork: Live Wallpaper on every screen and the lock screen.
///
/// The desktop gets one window per screen at the desktop's own level, under
/// Finder's icons, on every Space, never taking a click. The lock screen gets
/// the same drift, transparent, in a Space of its own over the lock screen
/// (as the island's lock-screen player does), so the plain color macOS shows
/// there moves too. Both read one clock, so unlocking fades from one to the
/// other without a seam. The plain color is also set as the Mac's wallpaper,
/// for the lock screen, Mission Control and the moments Vorssaint isn't
/// running, and the previous picture comes back when the feature is off.
final class LiveWallpaperService: ObservableObject {
    static let shared = LiveWallpaperService()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let clock = LiveWallpaperClock(speed: 1)
    /// The run's place in the noise; each screen is offset from it.
    private let seed = SIMD2(Float.random(in: 0..<400), Float.random(in: 0..<400))
    private var desktop: [CGDirectDisplayID: (window: NSWindow, view: LiveWallpaperView)] = [:]
    private var lock: (space: NotchOverlaySpace, panels: [(window: NSPanel, view: LiveWallpaperView)])?
    /// Asks the session every few seconds while the lock-screen layer is up:
    /// drawn over everything, it must never outlive a missed unlock.
    private var lockWatchdog: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var isLocked = false
    private var displaysAsleep = false
    private var sessionActive = true
    private var registeredSessionHandler = false
    private var appliedStillKind: LiveWallpaperStyle.Kind?

    private init() {}

    private var defaults: UserDefaults { .standard }

    private var wantsRunning: Bool {
        AppFeature.liveWallpaper.isAvailable && defaults.bool(forKey: DefaultsKey.liveWallpaperEnabled)
    }

    /// The style for the current scene, mode, appearance, intensity and blur.
    var currentStyle: LiveWallpaperStyle {
        LiveWallpaperStyle(
            scene: LiveWallpaperScene.sanitized(defaults.string(forKey: DefaultsKey.liveWallpaperScene)),
            kind: LiveWallpaperMode.sanitized(defaults.string(forKey: DefaultsKey.liveWallpaperMode))
                .kind(darkAppearance: Self.systemIsDark))
            .adjusted(intensity: defaults.double(forKey: DefaultsKey.liveWallpaperIntensity),
                      blur: defaults.double(forKey: DefaultsKey.liveWallpaperBlur))
    }

    /// The system's own appearance; the app may force its windows into one.
    static var systemIsDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"]
            as? String == "Dark"
    }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        guard wantsRunning else {
            if isRunning || !desktop.isEmpty || lock != nil { tearDown(restoringWallpaper: true) }
            return
        }
        clock.setSpeed(LiveWallpaperSupport.clampedFactor(defaults.double(forKey: DefaultsKey.liveWallpaperSpeed)))
        if !isRunning {
            isRunning = true
            observe()
            isLocked = Self.screenIsLocked
        }
        rebuildDesktop()
        syncLockScreen()
        applySystemStill()
        updateAnimation()
    }

    /// Looks changed (mode, intensity, appearance): every view fades across.
    func refreshStyle(animated: Bool = true) {
        guard isRunning else { return }
        clock.setSpeed(LiveWallpaperSupport.clampedFactor(defaults.double(forKey: DefaultsKey.liveWallpaperSpeed)))
        let style = currentStyle
        desktop.values.forEach { $0.view.setStyle(style, animated: animated) }
        lock?.panels.forEach { $0.view.setStyle(style, animated: animated) }
        applySystemStill()
    }

    private func tearDown(restoringWallpaper: Bool) {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        desktop.values.forEach { $0.view.stop(); $0.window.orderOut(nil) }
        desktop.removeAll()
        hideLockScreen(fading: false)
        clock.pause()
        isRunning = false
        if restoringWallpaper { restorePreviousWallpaper() }
        appliedStillKind = nil
    }

    // MARK: - Desktop

    private func rebuildDesktop() {
        let style = currentStyle
        var keep: [CGDirectDisplayID: (window: NSWindow, view: LiveWallpaperView)] = [:]
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let id = screen.liveWallpaperDisplayID else { continue }
            if let existing = desktop.removeValue(forKey: id) {
                if existing.window.frame != screen.frame { existing.window.setFrame(screen.frame, display: true) }
                keep[id] = existing
                continue
            }
            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            guard let view = LiveWallpaperView(frame: bounds, style: style, clock: clock, opaque: true,
                                               seed: seed + Self.offset(for: index)) else {
                lastError = "Metal isn't available, so the wallpaper can't be drawn."
                continue
            }
            let window = LiveWallpaperWindow(contentRect: screen.frame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderBack(nil)
            keep[id] = (window, view)
            observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification, object: window) {
                [weak self] in self?.updateAnimation()
            }
        }
        // Screens that left.
        desktop.values.forEach { $0.view.stop(); $0.window.orderOut(nil) }
        desktop = keep
    }

    /// Each screen its own stretch of the same weather.
    private static func offset(for index: Int) -> SIMD2<Float> {
        SIMD2(Float(index) * 37.3, Float(index) * -21.7)
    }

    // MARK: - Lock screen

    private func syncLockScreen() {
        let wanted = isRunning && isLocked && sessionActive
            && defaults.bool(forKey: DefaultsKey.liveWallpaperLockScreen)
        if wanted, lock == nil { showLockScreen() }
        if !wanted, lock != nil { hideLockScreen(fading: !isLocked) }
    }

    private func showLockScreen() {
        guard let space = NotchOverlaySpace(absoluteLevel: LiveWallpaperSupport.lockScreenSpaceLevel) else { return }
        let style = currentStyle
        var panels: [(window: NSPanel, view: LiveWallpaperView)] = []
        for (index, screen) in NSScreen.screens.enumerated() {
            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            guard let view = LiveWallpaperView(frame: bounds, style: style, clock: clock, opaque: false,
                                               seed: seed + Self.offset(for: index)) else { continue }
            let panel = NotchLockScreenPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            // Under the island's own lock-screen panels in the same layer.
            panel.level = .normal
            panel.collectionBehavior = NotchPanel.overlayCollectionBehavior
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panels.append((panel, view))
        }
        guard !panels.isEmpty else { space.close(); return }
        // Joined before they are first shown, so they belong to that Space alone.
        for panel in panels { space.add(panel.window) }
        for panel in panels {
            panel.window.alphaValue = 0
            panel.window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                panel.window.animator().alphaValue = 1
            }
        }
        lock = (space, panels)
        // The session only says it is locked while it is, and only on the
        // macOS versions that say so at all: its silence counts once it spoke.
        var sessionSaidLocked = Self.screenIsLocked
        let watchdog = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Self.screenIsLocked {
                sessionSaidLocked = true
            } else if sessionSaidLocked {
                self.setLocked(false)
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        lockWatchdog = watchdog
    }

    private func hideLockScreen(fading: Bool) {
        lockWatchdog?.invalidate()
        lockWatchdog = nil
        guard let lock else { return }
        self.lock = nil
        let finish = {
            lock.panels.forEach { $0.view.stop(); $0.window.orderOut(nil) }
            lock.space.close()
        }
        guard fading else { finish(); return }
        // The desktop behind shows the same moment, so the fade is seamless.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            lock.panels.forEach { $0.window.animator().alphaValue = 0 }
        }, completionHandler: finish)
    }

    // MARK: - Animation

    private func updateAnimation() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let animate = LiveWallpaperSupport.shouldAnimate(enabled: isRunning, sessionActive: sessionActive,
                                                         displaysAsleep: displaysAsleep, lowPowerMode: lowPower)
        for entry in desktop.values {
            // Covered by full-screen apps or the lock screen, nobody sees it.
            entry.view.isAnimating = animate && !isLocked && entry.window.occlusionState.contains(.visible)
        }
        lock?.panels.forEach { $0.view.isAnimating = animate && isLocked }
        let anyAnimating = desktop.values.contains { $0.view.isAnimating }
            || (lock?.panels.contains { $0.view.isAnimating } ?? false)
        if anyAnimating { clock.run() } else { clock.pause() }
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.isRunning else { return }
            self.rebuildDesktop()
            if self.lock != nil { self.hideLockScreen(fading: false); self.syncLockScreen() }
            self.updateAnimation()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.displaysAsleep = true
            self?.updateAnimation()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.displaysAsleep = false
            self?.updateAnimation()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.updateAnimation()
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.setLocked(true)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.setLocked(false)
        }
        observe(distributed, Notification.Name("AppleInterfaceThemeChangedNotification")) { [weak self] in
            // The global domain is written just before this is posted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.refreshStyle() }
        }
        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.updateAnimation()
        }
        if !registeredSessionHandler {
            registeredSessionHandler = true
            SessionActivity.shared.onChange { [weak self] active in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sessionActive = active
                    self.syncLockScreen()
                    self.updateAnimation()
                }
            }
        }
        sessionActive = SessionActivity.shared.isActive
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                         _ handler: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in handler() }
        observers.append((center, token))
    }

    private func setLocked(_ locked: Bool) {
        guard isRunning, locked != isLocked || (!locked && lock != nil) else { return }
        isLocked = locked
        syncLockScreen()
        updateAnimation()
    }

    private static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: - The Mac's own wallpaper

    /// Sets the plain color of the current style as the wallpaper of every
    /// screen and Space, once per change of style.
    private func applySystemStill() {
        guard isRunning else { return }
        guard defaults.bool(forKey: DefaultsKey.liveWallpaperSetsSystem) else {
            // Turned off: the picture from before comes back.
            if appliedStillKind != nil || defaults.string(forKey: DefaultsKey.liveWallpaperPreviousImage) != nil {
                restorePreviousWallpaper()
                appliedStillKind = nil
            }
            return
        }
        let style = currentStyle
        guard appliedStillKind != style.kind || !systemShowsStill(for: style),
              let url = Self.writeStill(for: style) else { return }
        appliedStillKind = style.kind
        rememberPreviousWallpaper()
        setWallpaper(url)
    }

    private func systemShowsStill(for style: LiveWallpaperStyle) -> Bool {
        let name = LiveWallpaperSupport.stillFileName(for: style)
        return NSScreen.screens.allSatisfy { NSWorkspace.shared.desktopImageURL(for: $0)?.lastPathComponent == name }
    }

    private func rememberPreviousWallpaper() {
        guard defaults.string(forKey: DefaultsKey.liveWallpaperPreviousImage) == nil,
              let screen = NSScreen.main ?? NSScreen.screens.first,
              let current = NSWorkspace.shared.desktopImageURL(for: screen),
              !LiveWallpaperSupport.isOwnStill(current.path) else { return }
        defaults.set(current.path, forKey: DefaultsKey.liveWallpaperPreviousImage)
    }

    private func restorePreviousWallpaper() {
        guard let path = defaults.string(forKey: DefaultsKey.liveWallpaperPreviousImage) else { return }
        defaults.removeObject(forKey: DefaultsKey.liveWallpaperPreviousImage)
        // Only if the Mac still shows ours; a wallpaper chosen since stays.
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              LiveWallpaperSupport.isOwnStill(NSWorkspace.shared.desktopImageURL(for: screen)?.path),
              FileManager.default.fileExists(atPath: path) else { return }
        setWallpaper(URL(fileURLWithPath: path))
    }

    private func setWallpaper(_ url: URL) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
        // The AppKit call reaches the current Space only; the store reaches
        // every Space and the lock screen.
        Task.detached(priority: .utility) { WallpaperStore.setImageOnAllSpaces(url) }
    }

    /// A small plain picture of the style's color; macOS fills the screen.
    private static func writeStill(for style: LiveWallpaperStyle) -> URL? {
        guard let container = PrivateFileStore.containerURL else { return nil }
        let folder = container.appendingPathComponent("Live Wallpaper", isDirectory: true)
        let url = folder.appendingPathComponent(LiveWallpaperSupport.stillFileName(for: style))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard PrivateFileStore.createDirectory(at: folder) else { return nil }
        let side = 256
        let (r, g, b) = style.base.bytes
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              PrivateFileStore.write(data as Data, to: url) else { return nil }
        return url
    }
}

/// Never key, never main, never in the window cycle: it is the desktop.
private final class LiveWallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }
}

private extension NSScreen {
    var liveWallpaperDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
