// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore
import SwiftUI

// Fork: Claude at work shows Claude's own loader, four dots on a slow loop
// of moves (see NotchClaudeSwirl), instead of its mark breathing. Like the
// mark, it is native layer motion: no SwiftUI frames.

struct NotchClaudeLoader: View {
    var size: CGFloat
    var tint: Color

    var body: some View {
        NotchClaudeLoaderBridge(size: size, tint: NSColor(tint))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct NotchClaudeLoaderBridge: NSViewRepresentable {
    let size: CGFloat
    let tint: NSColor

    func makeNSView(context: Context) -> NotchClaudeLoaderView { NotchClaudeLoaderView() }
    func updateNSView(_ view: NotchClaudeLoaderView, context: Context) { view.configure(size: size, tint: tint) }
    static func dismantleNSView(_ view: NotchClaudeLoaderView, coordinator: ()) { view.stop() }
}

final class NotchClaudeLoaderView: NSView {
    private let orbit = CALayer()
    private var dots: [CAShapeLayer] = []
    private var size: CGFloat = 0
    private var tint: NSColor = .orange
    private var stopped = false
    private var visibilityObserver: NSObjectProtocol?
    private static let motionKey = "claude.loop"

    /// Dot diameter and the square's half-width, as shares of the size.
    static let dotShare: CGFloat = 0.26
    static let spreadShare: CGFloat = 0.25
    /// Samples per second of the loop handed to Core Animation.
    static let samplesPerSecond = 40.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(orbit)
        for _ in 0..<4 {
            let dot = CAShapeLayer()
            orbit.addSublayer(dot)
            dots.append(dot)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(size: CGFloat, tint: NSColor) {
        stopped = false
        let changed = size != self.size || tint != self.tint
        self.size = size
        self.tint = tint
        if changed {
            layoutDots()
            restartMotion()
        }
        updateMotion()
    }

    func stop() {
        stopped = true
        updateMotion()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                self?.updateMotion()
            }
        }
        layoutDots()
        updateMotion()
    }

    override func layout() {
        super.layout()
        layoutDots()
        updateMotion()
    }

    /// The keyframes hold positions for one size, so a new size starts the
    /// loop over.
    private func restartMotion() {
        for dot in dots { dot.removeAnimation(forKey: Self.motionKey) }
    }

    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }

    private func layoutDots() {
        guard size > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        orbit.frame = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        let diameter = size * Self.dotShare
        let spread = size * Self.spreadShare
        let corners = [CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: -1)]
        for (dot, corner) in zip(dots, corners) {
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.fillColor = tint.cgColor
            dot.position = CGPoint(x: size / 2 + corner.x * spread, y: size / 2 + corner.y * spread)
        }
    }

    private func updateMotion() {
        let moving = !stopped && !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
        guard moving, size > 0 else {
            restartMotion()
            return
        }
        // Layout and snapshot updates keep the phase the dots are in.
        guard dots.first?.animation(forKey: Self.motionKey) == nil else { return }
        let now = orbit.convertTime(CACurrentMediaTime(), from: nil)
        let period = NotchClaudeSwirl.period
        let count = max(8, Int(period * Self.samplesPerSecond))
        let times = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        let spread = size * Self.spreadShare
        let centre = CGPoint(x: size / 2, y: size / 2)
        for (index, dot) in dots.enumerated() {
            let poses = (0...count).map { NotchClaudeSwirl.pose(dot: index, at: Double($0) / Double(count)) }
            func track(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = times
                animation.calculationMode = .linear
                return animation
            }
            let group = CAAnimationGroup()
            group.animations = [
                track("position", poses.map {
                    NSValue(point: CGPoint(x: centre.x + CGFloat($0.x) * spread,
                                           y: centre.y + CGFloat($0.y) * spread))
                }),
                track("transform.scale", poses.map { $0.scale }),
                track("opacity", poses.map { $0.opacity }),
                // The dot passing behind draws under the others.
                track("zPosition", poses.map { -$0.depth * 10 }),
            ]
            group.duration = period
            group.repeatCount = .infinity
            group.beginTime = now
            dot.add(group, forKey: Self.motionKey)
        }
    }
}
