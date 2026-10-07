// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: what the Snap Wheel draws while it is held. Two panels made once
/// and kept hidden, so the first hold shows at once: the ring, sized to
/// itself, and the preview, covering the screen the window will land on.
/// Everything that moves is SwiftUI state changed inside a spring, so a
/// direction changed mid-flight bends toward the new one instead of
/// restarting.
final class SnapWheelOverlayModel: ObservableObject {
    @Published var appearance = SnapWheelAppearance()
    @Published var wheelShown = false
    @Published var slot: SnapWheelSlot?
    /// SwiftUI degrees (clockwise), kept continuous so turns take the short way.
    @Published var angle: Double = 0
    @Published var actionID: String?
    @Published var cycle: (index: Int, count: Int)?
    @Published var hasWindow = true
    /// In the preview panel's own coordinates (top-left origin).
    @Published var previewRect: CGRect = .zero
    @Published var previewShown = false

    var symbol: String? {
        guard hasWindow else { return "exclamationmark.triangle.fill" }
        guard let actionID else { return nil }
        switch actionID {
        case SnapWheelActionID.minimize: return "minus.rectangle"
        case SnapWheelActionID.hide: return "eye.slash"
        default: return WindowLayoutAction(rawValue: actionID)?.symbolName
        }
    }

    func select(_ slot: SnapWheelSlot?) {
        self.slot = slot
        if let mathAngle = slot?.angle {
            angle = SnapWheelGeometry.continuousAngle(from: angle, to: -mathAngle)
        }
    }
}

final class SnapWheelOverlay {
    static let shared = SnapWheelOverlay()

    let model = SnapWheelOverlayModel()
    private var wheelPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var previewScreenFrame: CGRect = .zero
    private var wheelCenter: CGPoint = .zero
    private var windowFrame: CGRect?
    private var hideGeneration = 0
    private static let wheelMargin: CGFloat = 40

    private var animation: Animation? { model.appearance.animation.preview }
    private var ringAnimation: Animation? { model.appearance.animation.ring }

    /// Builds both panels ahead of the first hold.
    func prepare() {
        if wheelPanel == nil {
            let panel = Self.makePanel(level: .popUpMenu)
            let host = NSHostingView(rootView: SnapWheelRingContainer(model: model))
            host.sizingOptions = []
            panel.contentView = host
            wheelPanel = panel
        }
        if previewPanel == nil {
            let panel = Self.makePanel(level: .statusBar)
            let host = NSHostingView(rootView: SnapWheelPreviewContainer(model: model))
            host.sizingOptions = []
            panel.contentView = host
            previewPanel = panel
        }
    }

    private static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        return panel
    }

    // MARK: - Showing

    /// `origin` is where the hold began, in AppKit coordinates.
    func show(origin: CGPoint, screen: NSScreen, appearance: SnapWheelAppearance,
              windowFrame: CGRect?, hasWindow: Bool) {
        prepare()
        hideGeneration += 1
        guard let wheelPanel, let previewPanel else { return }
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(origin, $0.frame, false) } ?? screen
        wheelCenter = appearance.placement == .screenCenter
            ? CGPoint(x: pointerScreen.visibleFrame.midX, y: pointerScreen.visibleFrame.midY)
            : origin
        self.windowFrame = windowFrame

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.appearance = appearance
            model.hasWindow = hasWindow
            model.slot = nil
            model.actionID = nil
            model.cycle = nil
            model.wheelShown = false
            model.previewShown = false
        }

        let side = appearance.size + Self.wheelMargin * 2
        wheelPanel.setFrame(CGRect(x: wheelCenter.x - side / 2, y: wheelCenter.y - side / 2,
                                   width: side, height: side), display: false)
        place(previewPanel, on: screen.frame)
        previewPanel.orderFrontRegardless()
        if appearance.showsWheel || !hasWindow { wheelPanel.orderFrontRegardless() }
        withAnimation(ringAnimation ?? .linear(duration: 0)) { model.wheelShown = true }
    }

    func update(slot: SnapWheelSlot?, actionID: String?, cycle: (index: Int, count: Int)?, previewFrame: NSRect?) {
        // The highlight only turns from one direction to another; coming
        // from nothing or the center it appears in place.
        if model.slot?.angle == nil, let mathAngle = slot?.angle {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.angle = -mathAngle }
        }
        withAnimation(ringAnimation) {
            model.select(slot)
            model.actionID = actionID
            model.cycle = cycle
        }
        guard model.appearance.previewEnabled, let previewFrame, let previewPanel else {
            withAnimation(animation.map { _ in .easeOut(duration: 0.14) }) { model.previewShown = false }
            return
        }
        let target = SnapWheelGeometry.inset(previewFrame, by: model.appearance.previewPadding)
        // A preview on another display (next or previous display) moves the
        // panel there and starts over.
        let center = CGPoint(x: target.midX, y: target.midY)
        if !previewScreenFrame.contains(center),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            place(previewPanel, on: screen.frame)
            model.previewShown = false
        }
        let local = localRect(target)
        if model.previewShown {
            withAnimation(animation) { model.previewRect = local }
            return
        }
        // First appearance: start where the preview is set to grow from.
        // Laying the view out commits that start, so the spring that follows
        // leaves from it rather than from wherever the last hold ended.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.previewRect = startRect(for: local) }
        previewPanel.contentView?.layoutSubtreeIfNeeded()
        withAnimation(animation) {
            model.previewRect = local
            model.previewShown = true
        }
    }

    /// Slides the ring to a new center.
    func moveWheel(to center: CGPoint) {
        guard let wheelPanel, wheelPanel.isVisible else { return }
        wheelCenter = center
        let side = wheelPanel.frame.width
        let frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        guard model.appearance.animation != .instant else { return wheelPanel.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            wheelPanel.animator().setFrame(frame, display: true)
        }
    }

    func hide(placed: Bool) {
        hideGeneration += 1
        let generation = hideGeneration
        let fade: Animation? = model.appearance.animation == .instant ? nil : .easeOut(duration: placed ? 0.12 : 0.16)
        withAnimation(fade) {
            model.wheelShown = false
            model.previewShown = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fade == nil ? 0 : 0.2)) { [weak self] in
            guard let self, generation == self.hideGeneration else { return }
            self.wheelPanel?.orderOut(nil)
            self.previewPanel?.orderOut(nil)
        }
    }

    // MARK: - Geometry

    private func place(_ panel: NSPanel, on frame: CGRect) {
        previewScreenFrame = frame
        panel.setFrame(frame, display: false)
    }

    private func localRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - previewScreenFrame.minX, y: previewScreenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func startRect(for target: CGRect) -> CGRect {
        switch model.appearance.previewStart {
        case .screenCenter:
            return CGRect(x: previewScreenFrame.width / 2, y: previewScreenFrame.height / 2, width: 0, height: 0)
        case .wheel:
            let local = localRect(CGRect(origin: wheelCenter, size: .zero))
            return CGRect(x: local.minX, y: local.minY, width: 0, height: 0)
        case .window:
            return windowFrame.map(localRect) ?? target
        case .target:
            return target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06)
        }
    }
}

// MARK: - Motion

extension SnapWheelAnimation {
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The preview travelling across the screen.
    var preview: Animation? {
        if reduceMotion, self != .instant { return .easeOut(duration: 0.12) }
        switch self {
        case .fluid: return .spring(response: 0.34, dampingFraction: 0.84)
        case .snappy: return .spring(response: 0.2, dampingFraction: 0.92)
        case .instant: return nil
        }
    }

    /// The ring: its highlight turning and its center changing. It has a
    /// short way to go and has to keep up with a flick of the hand, so it
    /// settles in well under a tenth of a second.
    var ring: Animation? {
        if reduceMotion, self != .instant { return .easeOut(duration: 0.06) }
        switch self {
        case .fluid: return .spring(response: 0.09, dampingFraction: 0.9)
        case .snappy: return .spring(response: 0.06, dampingFraction: 0.96)
        case .instant: return nil
        }
    }
}

// MARK: - Colors

extension SnapWheelAppearance {
    var accentColor: Color {
        switch colorMode {
        case .system: return Color(nsColor: .controlAccentColor)
        case .custom, .gradient: return Color(hexString: color) ?? Color(nsColor: .controlAccentColor)
        }
    }

    var accentStyle: AnyShapeStyle {
        guard colorMode == .gradient, let second = Color(hexString: gradientColor) else {
            return AnyShapeStyle(accentColor)
        }
        return AnyShapeStyle(LinearGradient(colors: [accentColor, second],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

extension Color {
    init?(hexString: String) {
        guard let value = ColorValue(text: hexString) else { return nil }
        self.init(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return SnapWheelSupport.hex(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }
}

// MARK: - The ring

private struct SnapWheelRingContainer: View {
    @ObservedObject var model: SnapWheelOverlayModel

    var body: some View {
        SnapWheelRingView(model: model)
            .scaleEffect(model.wheelShown ? 1 : 0.72)
            .opacity(model.wheelShown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The ring itself, shared with the settings page.
struct SnapWheelRingView: View {
    @ObservedObject var model: SnapWheelOverlayModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let appearance = model.appearance
        let size = appearance.size
        let thickness = appearance.ringThickness
        let ring = SnapWheelRingShape(cornerRadius: appearance.ringCornerRadius, thickness: thickness)
        let outline = RoundedRectangle(cornerRadius: appearance.ringCornerRadius, style: .continuous)
        let isCenter = model.slot == .center
        let isDirection = model.slot != nil && !isCenter && model.hasWindow

        ZStack {
            // A soft backing in the hole keeps the symbol readable over a
            // busy screen without hiding what is behind it.
            outline.inset(by: thickness)
                .fill(RadialGradient(colors: [.black.opacity(0.32), .black.opacity(0.12)], center: .center,
                                     startRadius: 0, endRadius: max(1, size / 2 - thickness)))
            base(ring: ring, appearance: appearance)

            SnapWheelWedge()
                .fill(appearance.accentStyle)
                .rotationEffect(.degrees(model.angle))
                .opacity(isDirection ? 1 : 0)
                .mask(ring)

            ring.fill(appearance.accentStyle)
                .opacity(isCenter && model.hasWindow ? 1 : 0)

            outline.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
            // Insetting a rounded rectangle also takes the inset off its radius.
            outline.inset(by: thickness)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)

            hub(inner: size - thickness * 2)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func base(ring: SnapWheelRingShape, appearance: SnapWheelAppearance) -> some View {
        if reduceTransparency || appearance.material == .solid {
            ring.fill(Color(white: 0.13, opacity: 0.94))
        } else if appearance.material == .glass {
#if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: ring)
            } else {
                frosted(ring: ring, appearance: appearance)
            }
#else
            frosted(ring: ring, appearance: appearance)
#endif
        } else {
            frosted(ring: ring, appearance: appearance)
        }
    }

    private func frosted(ring: SnapWheelRingShape, appearance: SnapWheelAppearance) -> some View {
        ZStack {
            SnapWheelBlur(mask: .ring(cornerRadius: appearance.ringCornerRadius, thickness: appearance.ringThickness))
            ring.fill(Color.black.opacity(0.18))
        }
    }

    @ViewBuilder
    private func hub(inner: CGFloat) -> some View {
        if inner >= 28, let symbol = model.symbol {
            VStack(spacing: max(2, inner * 0.06)) {
                Image(systemName: symbol)
                    .font(.system(size: min(26, inner * 0.36), weight: .semibold))
                    .foregroundStyle(model.hasWindow ? Color.white : Color.yellow)
                    // The system's replace effect takes about a third of a
                    // second; at five times the speed it keeps pace with the ring.
                    .contentTransition(.symbolEffect(.replace, options: .speed(5)))
                if let cycle = model.cycle, cycle.count > 1, inner >= 44 {
                    HStack(spacing: 3) {
                        ForEach(0..<min(cycle.count, 6), id: \.self) { index in
                            Circle()
                                .fill(Color.white.opacity(index == cycle.index ? 0.95 : 0.3))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// A rounded square or circle with a hole of the same shape.
struct SnapWheelRingShape: Shape {
    var cornerRadius: CGFloat
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let outer = Path(roundedRect: rect, cornerRadius: min(cornerRadius, rect.width / 2), style: .continuous)
        let innerRect = rect.insetBy(dx: thickness, dy: thickness)
        guard innerRect.width > 0, innerRect.height > 0 else { return outer }
        let inner = Path(roundedRect: innerRect,
                         cornerRadius: min(max(0, cornerRadius - thickness), innerRect.width / 2),
                         style: .continuous)
        return outer.subtracting(inner)
    }
}

/// One eighth of a turn, pointing right; rotated to the chosen direction.
private struct SnapWheelWedge: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(rect.width, rect.height)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: .degrees(-22.5), endAngle: .degrees(22.5),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - The preview

private struct SnapWheelPreviewContainer: View {
    @ObservedObject var model: SnapWheelOverlayModel

    var body: some View {
        GeometryReader { _ in
            SnapWheelPreviewView(appearance: model.appearance, size: model.previewRect.size)
                .frame(width: model.previewRect.width, height: model.previewRect.height)
                .offset(x: model.previewRect.minX, y: model.previewRect.minY)
                .opacity(model.previewShown ? 1 : 0)
        }
        .ignoresSafeArea()
    }
}

struct SnapWheelPreviewView: View {
    let appearance: SnapWheelAppearance
    var size: CGSize = .zero
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let radius = min(appearance.previewCornerRadius, min(size.width, size.height) / 2)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            material(shape: shape, radius: radius)
            shape.fill(appearance.accentColor.opacity(appearance.previewTint))
            if appearance.previewBorder > 0 {
                shape.strokeBorder(appearance.accentStyle, lineWidth: appearance.previewBorder)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func material(shape: RoundedRectangle, radius: CGFloat) -> some View {
        if reduceTransparency || appearance.previewMaterial == .tint {
            Color.clear
        } else if appearance.previewMaterial == .glass {
#if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.clear, in: shape)
            } else {
                SnapWheelBlur(mask: .roundedRect(cornerRadius: radius))
            }
#else
            SnapWheelBlur(mask: .roundedRect(cornerRadius: radius))
#endif
        } else {
            SnapWheelBlur(mask: .roundedRect(cornerRadius: radius))
        }
    }
}

// MARK: - Blur

/// The settings page draws the ring over its own picture, so its blur
/// samples the window instead of what is behind it.
private struct SnapWheelBlurWithinWindowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapWheelBlurWithinWindow: Bool {
        get { self[SnapWheelBlurWithinWindowKey.self] }
        set { self[SnapWheelBlurWithinWindowKey.self] = newValue }
    }
}

/// A behind-window blur clipped to its shape. The clip has to be the view's
/// own mask image: a SwiftUI mask does not reach the system's backdrop.
private struct SnapWheelBlur: NSViewRepresentable {
    enum Mask: Equatable {
        case ring(cornerRadius: CGFloat, thickness: CGFloat)
        case roundedRect(cornerRadius: CGFloat)
    }

    let mask: Mask
    @Environment(\.snapWheelBlurWithinWindow) private var withinWindow

    func makeNSView(context: Context) -> SnapWheelBlurView {
        let view = SnapWheelBlurView()
        view.material = .hudWindow
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: SnapWheelBlurView, context: Context) { view.shape = mask }
}

private final class SnapWheelBlurView: NSVisualEffectView {
    var shape: SnapWheelBlur.Mask? { didSet { if shape != oldValue { updateMask() } } }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        // A rounded rectangle stretches its corners, so only the ring, whose
        // hole depends on the size, is redrawn.
        if resized, case .ring = shape { updateMask() }
    }

    private func updateMask() {
        switch shape {
        case .roundedRect(let radius):
            // Drawn once and stretched between its corners, so the preview
            // can spring through every size without redrawing it.
            let side = radius * 2 + 1
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            image.resizingMode = .stretch
            maskImage = image
        case .ring(let cornerRadius, let thickness):
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { maskImage = nil; return }
            maskImage = NSImage(size: size, flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                let path = SnapWheelRingShape(cornerRadius: cornerRadius, thickness: thickness).path(in: rect)
                context.addPath(path.cgPath)
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
                return true
            }
        case nil:
            maskImage = nil
        }
    }
}

#if VORSSAINT_DEVELOPMENT
extension SnapWheelOverlay {
    /// Dev remote: the ring and preview for one direction, on the main
    /// screen, with no window and no Accessibility involved.
    func devPreview(_ request: String) {
        let parts = request.split(separator: ":")
        guard let screen = NSScreen.main, let first = parts.first,
              let slot = SnapWheelSlot(rawValue: String(first)) else { return }
        let step = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let actions = SnapWheelSlots.current()[slot] ?? []
        let origin = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        if !model.wheelShown {
            show(origin: origin, screen: screen, appearance: .current(), windowFrame: nil, hasWindow: true)
        }
        let action = actions.isEmpty ? nil : actions[step % actions.count]
        let frame = action.flatMap(WindowLayoutAction.init(rawValue:)).map {
            WindowLayoutGeometry.rect(for: $0, current: screen.visibleFrame.insetBy(dx: 300, dy: 200),
                                      visibleFrame: screen.visibleFrame, windowGap: WindowLayoutGaps.windowGap,
                                      screenGap: WindowLayoutGaps.screenGap, marginPercent: WindowLayoutMargin.percent)
        }
        update(slot: slot, actionID: action, cycle: actions.isEmpty ? nil : (step % actions.count, actions.count),
               previewFrame: frame)
    }
}
#endif
