// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore
import SwiftUI

// Fork: Claude at work shows Claude's own loader, four dots that swirl round
// a square, drawing in as they speed through each turn, instead of its mark
// breathing. Like the mark, it is native layer motion: no SwiftUI frames.

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
    private static let spinKey = "claude.swirl"
    private static let drawKey = "claude.draw"

    /// One turn, in seconds.
    static let period: CFTimeInterval = 1.3
    /// Dot diameter and the dots' distance from the centre, as shares of the
    /// loader's size.
    static let dotShare: CGFloat = 0.3
    static let spreadShare: CGFloat = 0.27
    /// How far in the dots draw at the fastest point of a turn.
    static let drawIn: CGFloat = 0.62

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

    /// The draw-in keyframes hold positions for one size, so a new size
    /// starts the motion over.
    private func restartMotion() {
        orbit.removeAnimation(forKey: Self.spinKey)
        for dot in dots { dot.removeAnimation(forKey: Self.drawKey) }
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
        guard moving else {
            orbit.removeAnimation(forKey: Self.spinKey)
            for dot in dots { dot.removeAnimation(forKey: Self.drawKey) }
            return
        }
        // Layout and snapshot updates keep the phase the dots are in.
        guard orbit.animation(forKey: Self.spinKey) == nil else { return }
        let now = orbit.convertTime(CACurrentMediaTime(), from: nil)

        // A quarter turn per beat, quick in the middle and settling at each
        // corner, so the square reads as swirling rather than spinning.
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = (0...4).map { -CGFloat($0) * .pi / 2 }
        spin.keyTimes = (0...4).map { NSNumber(value: Double($0) / 4) }
        spin.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1), count: 4)
        spin.duration = Self.period
        spin.repeatCount = .infinity
        spin.beginTime = now
        orbit.add(spin, forKey: Self.spinKey)

        // The dots draw toward the centre as they move, and open out again
        // at the corners; only their places move, never their size.
        let centre = CGPoint(x: size / 2, y: size / 2)
        for dot in dots {
            let corner = dot.position
            let drawn = CGPoint(x: centre.x + (corner.x - centre.x) * Self.drawIn,
                                y: centre.y + (corner.y - centre.y) * Self.drawIn)
            let draw = CAKeyframeAnimation(keyPath: "position")
            draw.values = [corner, drawn, corner].map { NSValue(point: $0) }
            draw.keyTimes = [0, 0.5, 1]
            draw.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                    CAMediaTimingFunction(name: .easeInEaseOut)]
            draw.duration = Self.period / 4
            draw.repeatCount = .infinity
            draw.beginTime = now
            dot.add(draw, forKey: Self.drawKey)
        }
    }
}
