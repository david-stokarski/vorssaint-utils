// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore

/// The drop that carries the Command Bar out of the Dynamic Island, in a
/// window of its own at the island's level. `CommandBarDropletMotion` works
/// out every frame once. Core Animation plays them, and the app only hears
/// when the drop has landed. The companion rides inside, live.
final class CommandBarDroplet {
    static let shared = CommandBarDroplet()

    private var panel: OverlayPanel?
    private let stage = CALayer()
    private let neck = CAShapeLayer()
    private let bead = CALayer()
    private let mascot = NotchMascotRig()
    private var generation = 0
    /// Where the last drop fell from, for the bar to rise back there.
    private var island: CGRect?
    /// A drop still on its way: closed meanwhile, the bar was never seen,
    /// so nothing rises back.
    private var falling = false

    private init() {
        stage.isGeometryFlipped = true
        neck.fillColor = NSColor.black.cgColor
        bead.backgroundColor = NSColor.black.cgColor
        bead.cornerCurve = .continuous
        for layer in [stage, neck, bead] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "cornerRadius": NSNull(),
                             "opacity": NSNull(), "frame": NSNull()]
        }
        stage.addSublayer(neck)
        stage.addSublayer(bead)
        stage.addSublayer(mascot.root)
    }

    /// Fork: the Command Bar's own setting turns the drop off as Reduce
    /// Motion does.
    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !CommandBarAnimation.animates()
    }

    /// Lets the drop fall from `island` into the bar's frame `bar`, both on
    /// screen. `revealed` runs once it has opened into the field, for the bar
    /// itself to take its place.
    func drop(from island: CGRect, into bar: CGRect, look: NotchMascotLook, barWindow: NSWindow? = nil,
              revealed: @escaping () -> Void) {
        cancel()
        self.island = island
        // The companion goes into the drop, and the island rests without it.
        NotchService.shared.setMascotInBar(true)
        guard !Self.reducesMotion else { revealed(); return }
        let current = generation
        falling = true
        let field = CGRect(x: bar.minX, y: bar.maxY - CommandBarView.fieldHeight,
                           width: bar.width, height: CommandBarView.fieldHeight)
        let area = Self.area(island: island, reaching: field)
        let local = Self.local(area)
        let edge = CommandBarDropletMotion.rootDepth
        let centerX = island.midX - area.minX
        let fieldRect = local(field)
        let icon = CGPoint(x: fieldRect.minX + 16 + CommandBarDropletMotion.mascotSize / 2, y: fieldRect.midY)
        let motion = CommandBarDropletMotion.drop(edge: edge, centerX: centerX, field: fieldRect, icon: icon)
            .scaled(by: CommandBarAnimation.speed())  // Fork
        let begin = CACurrentMediaTime()
        prepare(in: area, look: look, mood: .surprised)
        mascot.turn(to: .idle, at: begin + motion.landing)
        play(motion, edge: edge, centerX: centerX, begin: begin, completion: nil)
        if let barWindow { revealLive(barWindow, motion: motion, area: area, begin: begin) }  // Fork
        // The bar takes over once the shape has all but arrived, and the
        // drop fades through the last of its swing on top of it.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current else { return }
            self.falling = false
            self.unmaskLive()
            revealed()
            self.fadeOut(current)
        }
        let wait = CABasicAnimation(keyPath: "opacity")
        wait.fromValue = 1
        wait.toValue = 1
        wait.beginTime = begin
        wait.duration = max(0.01, motion.reveal)
        stage.add(wait, forKey: "reveal")
        CATransaction.commit()
    }

    /// Folds the bar at `bar` back into a drop that rises into the island.
    /// The bar's window is already gone. This draws its shape on the way.
    /// Fork: `bodyless` sends only the companion home, for a bar drawn in
    /// glass or blur, which a black drop cannot stand in for.
    func retract(from bar: CGRect, look: NotchMascotLook, mood: NotchMascotMood, bodyless: Bool = false) {
        let unseen = falling
        cancel()
        guard !unseen, !Self.reducesMotion, let island = NotchService.shared.commandBarDropSource() ?? island else {
            NotchService.shared.setMascotInBar(false)
            return
        }
        let current = generation
        let field = CGRect(x: bar.minX, y: bar.maxY - CommandBarView.fieldHeight,
                           width: bar.width, height: CommandBarView.fieldHeight)
        let area = Self.area(island: island, reaching: bar)
        let local = Self.local(area)
        let edge = CommandBarDropletMotion.rootDepth
        let centerX = island.midX - area.minX
        let fieldRect = local(field)
        let icon = CGPoint(x: fieldRect.minX + 16 + CommandBarDropletMotion.mascotSize / 2, y: fieldRect.midY)
        let motion = CommandBarDropletMotion.retract(edge: edge, centerX: centerX, bar: local(bar), field: fieldRect, icon: icon)
            .scaled(by: CommandBarAnimation.speed())  // Fork
        prepare(in: area, look: look, mood: mood)
        if bodyless {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bead.opacity = 0
            neck.opacity = 0
            CATransaction.commit()
        }
        play(motion, edge: edge, centerX: centerX, begin: CACurrentMediaTime()) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
            // Back in the island, it hops out to rest there again.
            NotchService.shared.setMascotInBar(false, homecoming: mood)
        }
    }

    /// Stops whatever is falling or rising and takes the window away.
    func cancel() {
        generation += 1
        falling = false
        unmaskLive()
        for layer in [stage, neck, bead, mascot.root] { layer.removeAllAnimations() }
        panel?.orderOut(nil)
    }

    // MARK: Drawing

    /// The window spans the island's lower edge, a little inside it, down to
    /// below the bar, with room around for the spring to swing.
    private static func area(island: CGRect, reaching target: CGRect) -> CGRect {
        let margin: CGFloat = 28
        let minX = min(island.minX, target.minX) - margin
        let maxX = max(island.maxX, target.maxX) + margin
        let top = island.minY + CommandBarDropletMotion.rootDepth
        let bottom = target.minY - margin
        return CGRect(x: minX, y: bottom, width: maxX - minX, height: max(1, top - bottom))
    }

    /// Screen rectangles in the window's own points, from its top left.
    private static func local(_ area: CGRect) -> (CGRect) -> CGRect {
        { rect in CGRect(x: rect.minX - area.minX, y: area.maxY - rect.maxY, width: rect.width, height: rect.height) }
    }

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Level with the island, so the drop grows out of its edge.
        panel.level = NotchPanel.normalLevel
        panel.collectionBehavior = NotchPanel.overlayCollectionBehavior
        let view = NSView(frame: panel.contentLayoutRect)
        let root = CALayer()
        root.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer = root
        view.wantsLayer = true
        root.addSublayer(stage)
        panel.contentView = view
        self.panel = panel
        return panel
    }

    private func prepare(in area: CGRect, look: NotchMascotLook, mood: NotchMascotMood) {
        let panel = ensurePanel()
        panel.sharingType = NotchSupport.showsInCaptures() ? .readOnly : .none
        panel.setFrame(area, display: false)
        let scale = NSScreen.screens.first { $0.frame.intersects(area) }?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(origin: .zero, size: area.size)
        stage.opacity = 1
        bead.opacity = 1
        neck.opacity = 1
        stage.contentsScale = scale
        neck.frame = stage.bounds
        neck.contentsScale = scale
        bead.contentsScale = scale
        mascot.configure(look: look, size: CommandBarDropletMotion.mascotSize, contentsScale: scale)
        mascot.reset(to: mood)
        CATransaction.commit()
        // Under the island: the drop grows out from behind its edge and rises
        // back behind it, as liquid it holds.
        NotchService.shared.orderBelowIsland(panel)
    }

    private func play(_ motion: CommandBarDropletMotion, edge: CGFloat, centerX: CGFloat, begin: CFTimeInterval,
                      completion: (() -> Void)?) {
        guard let last = motion.frames.last, motion.duration > 0 else { completion?(); return }
        let times = motion.keyTimes.map { NSNumber(value: $0) }
        func animation(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times
            animation.duration = motion.duration
            animation.beginTime = begin
            animation.calculationMode = .linear
            animation.fillMode = .backwards
            return animation
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion { CATransaction.setCompletionBlock(completion) }
        neck.add(animation("path", motion.frames.map {
            CommandBarDropletMotion.neckPath($0, edge: edge, centerX: centerX)
        }), forKey: "drop")
        bead.add(animation("bounds", motion.frames.map { NSValue(rect: CGRect(origin: .zero, size: $0.bead.size)) }),
                 forKey: "dropBounds")
        bead.add(animation("position", motion.frames.map { NSValue(point: CGPoint(x: $0.bead.midX, y: $0.bead.midY)) }),
                 forKey: "dropPosition")
        bead.add(animation("cornerRadius", motion.frames.map { NSNumber(value: Double($0.radius)) }), forKey: "dropRadius")
        // The island and the bar centre the companion's figure, not its box,
        // so each point the drop carries it to is the figure's own middle.
        let shift = NotchMascotGeometry.figureOffset(mascot.look) * mascot.size
        func figure(_ frame: CommandBarDropletFrame) -> CGPoint {
            CGPoint(x: frame.mascot.x, y: frame.mascot.y - shift * frame.mascotScale)
        }
        mascot.root.add(animation("position", motion.frames.map { NSValue(point: figure($0)) }), forKey: "dropPosition")
        mascot.root.add(animation("transform", motion.frames.map {
            NSValue(caTransform3D: CATransform3DMakeScale($0.mascotScale, $0.mascotScale, 1))
        }), forKey: "dropScale")
        // Where the last frame leaves everything, once the animations are gone.
        neck.path = CommandBarDropletMotion.neckPath(last, edge: edge, centerX: centerX)
        bead.bounds = CGRect(origin: .zero, size: last.bead.size)
        bead.position = CGPoint(x: last.bead.midX, y: last.bead.midY)
        bead.cornerRadius = last.radius
        mascot.root.position = figure(last)
        mascot.root.transform = CATransform3DMakeScale(last.mascotScale, last.mascotScale, 1)
        CATransaction.commit()
    }

    // MARK: Fork: the live bar opening with the drop

    /// The bar whose content view is masked while the drop opens.
    private weak var maskedView: NSView?
    private var maskTimer: Timer?

    /// Shows the real bar, already holding the keyboard, through a mask that
    /// follows the drop as it opens: across with the drop into the field, and
    /// down to the rest of the bar at the same pace. Typing during the drop
    /// shows up as the bar spreads, and the drop's own black bead gives way
    /// to it. Before the drop lands the mask is empty, so nothing shows early.
    private func revealLive(_ bar: NSWindow, motion: CommandBarDropletMotion, area: CGRect, begin: CFTimeInterval) {
        guard let host = bar.contentView, motion.duration > 0, motion.opening > 0,
              motion.frames.count == motion.keyTimes.count, !motion.frames.isEmpty else { return }
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        let barFrame = bar.frame
        // From the drop's points (top left of its area) to the bar's own,
        // top left too: the hosting view is flipped, so a bar growing
        // downward as results arrive keeps the mask on its field.
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: area.minX + rect.minX - barFrame.minX, y: barFrame.maxY - (area.maxY - rect.minY),
                   width: rect.width, height: rect.height)
        }
        // The widening, 0 to 1, read off the drop's own width, so the bar
        // grows downward at exactly the pace it grows across.
        guard let firstOpened = motion.frames.indices.first(where: {
            motion.keyTimes[$0] * motion.duration >= motion.opening
        }), let field = motion.frames.last?.bead else { return }
        let startWidth = motion.frames[firstOpened].bead.width
        let fieldBottom = local(field).maxY
        struct Step { var rect: CGRect; var radius: CGFloat; var spread: CGFloat; var opened: Bool }
        let steps = motion.frames.enumerated().map { index, frame -> Step in
            let opened = motion.keyTimes[index] * motion.duration >= motion.opening
            let spread = min(1, max(0, (frame.bead.width - startWidth) / max(1, field.width - startWidth)))
            return Step(rect: local(frame.bead), radius: frame.radius, spread: opened ? spread : 0, opened: opened)
        }
        let beadOpacity = steps.map { NSNumber(value: $0.opened ? 0 : 1) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = beadOpacity
        fade.keyTimes = motion.keyTimes.map { NSNumber(value: $0) }
        fade.duration = motion.duration
        fade.beginTime = begin
        fade.calculationMode = .discrete
        fade.fillMode = .backwards
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.cornerCurve = .continuous
        mask.actions = ["position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull()]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.bounds = .zero
        layer.mask = mask
        bead.add(fade, forKey: "openFade")
        bead.opacity = 0
        CATransaction.commit()
        // Driven frame by frame rather than by keyframes: the bar's own
        // height changes as its results arrive mid-drop, and the mask reads
        // it live so the bar always opens to what it holds now.
        maskTimer?.invalidate()
        let duration = motion.duration
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak host, weak mask, weak bar] _ in
            guard let host, let mask else { return }
            let share = min(1, max(0, (CACurrentMediaTime() - begin) / duration))
            let step = steps[min(steps.count - 1, Int((share * Double(steps.count - 1)).rounded()))]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if step.opened {
                var rect = step.rect
                rect.size.height += max(0, host.bounds.height - fieldBottom) * step.spread
                mask.bounds = CGRect(origin: .zero, size: rect.size)
                mask.position = CGPoint(x: rect.midX, y: rect.midY)
                mask.cornerRadius = step.radius
                // Glass and blur draw outside any layer mask, so the bar's
                // surface is told the same shape to fill, and the window
                // only shows once the drop has landed and starts to open.
                CommandBarReveal.shared.update(rect, radius: step.radius)
                if let bar, bar.alphaValue < 1 { bar.alphaValue = 1 }
            } else {
                mask.bounds = .zero
            }
            CATransaction.commit()
        }
        RunLoop.main.add(timer, forMode: .common)
        maskTimer = timer
        maskedView = host
        // Unseen while the companion falls; the timer shows it on landing.
        bar.alphaValue = 0
        CommandBarReveal.shared.update(.zero, radius: 0)
        CommandBarService.shared.setDropOpening(true)
    }

    private func unmaskLive() {
        maskTimer?.invalidate()
        maskTimer = nil
        CommandBarReveal.shared.update(nil, radius: 0)
        if let view = maskedView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.mask = nil
            CATransaction.commit()
        }
        maskedView = nil
        CommandBarService.shared.setDropOpening(false)
    }

    /// The bar is in place under the drop, and the drop fades off it.
    private func fadeOut(_ current: Int) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.14 / CommandBarAnimation.speed()  // Fork
        stage.add(fade, forKey: "fade")
        stage.opacity = 0
        CATransaction.commit()
    }
}
