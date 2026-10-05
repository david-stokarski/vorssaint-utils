// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the island's see-through backgrounds. Frosted blurs what is behind
/// the island; Glass lays Liquid Glass over it. Either carries a black tint
/// the person sets, and stays solid black over a camera so the island still
/// meets the housing. Closed, the island rests in black; the material comes
/// in as it opens, following the same fade upstream's glass uses.
struct NotchFluidBackground: View {
    @ObservedObject var presentation: NotchBackdropPresentation
    let appearance: NotchSurfaceAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var openness: Double { presentation.usesGlass ? presentation.openness : 0 }

    var body: some View {
        let shape = NotchBackdropShape(contour: presentation.contour)
        let box = presentation.contour.boundingRect
        ZStack(alignment: .topLeading) {
            Color.black.opacity(reduceTransparency ? 1 : 1 - openness)
            if openness > 0, !reduceTransparency, !box.isNull, box.width > 0, box.height > 0 {
                Group {
                    material(shape: shape, box: box.integral)
                    LinearGradient(stops: tintStops(height: box.maxY), startPoint: .top, endPoint: .bottom)
                        .frame(height: box.maxY)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .mask(shape)
                }
                .opacity(openness)
            }
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func material(shape: NotchBackdropShape, box: CGRect) -> some View {
        switch appearance.material {
        case .glass:
#if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear
                    .glassEffect(.clear, in: shape)
                    .environment(\.appearsActive, true)
                    .materialActiveAppearance(.active)
            } else {
                frosted(box: box)
            }
#else
            frosted(box: box)
#endif
        default:
            frosted(box: box)
        }
    }

    /// The blur covers only the island's box; its mask is redrawn on every
    /// frame of a resize, and the stage can be as large as the display.
    private func frosted(box: CGRect) -> some View {
        NotchFluidMaterial(contour: presentation.contour.offsetBy(dx: -box.minX, dy: -box.minY).cgPath)
            .frame(width: box.width, height: box.height)
            .padding(EdgeInsets(top: box.minY, leading: box.minX, bottom: 0, trailing: 0))
    }

    private func tintStops(height: CGFloat) -> [Gradient.Stop] {
        guard height > 0 else { return [Gradient.Stop(color: .black.opacity(appearance.tint), location: 0)] }
        let strip = Double(presentation.stripHeight)
        let depths: [Double] = strip > 0 ? [0, strip, strip + 7, strip + 14, strip + 21, strip + 28, Double(height)]
                                         : [0, Double(height)]
        return depths.filter { $0 <= Double(height) }.map { depth in
            Gradient.Stop(color: .black.opacity(NotchSurfaceAppearance.overlay(atDepth: depth, strip: strip,
                                                                               tint: appearance.tint)),
                          location: depth / Double(height))
        }
    }
}

/// An `NSVisualEffectView` blurring behind the window inside the island's contour.
private struct NotchFluidMaterial: NSViewRepresentable {
    let contour: CGPath

    func makeNSView(context: Context) -> NotchFluidMaterialView {
        let view = NotchFluidMaterialView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NotchFluidMaterialView, context: Context) { view.contour = contour }
}

private final class NotchFluidMaterialView: NSVisualEffectView {
    var contour: CGPath? { didSet { if contour != oldValue { updateMask() } } }
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { updateMask() }
    }

    private func updateMask() {
        guard let contour, bounds.width > 0, bounds.height > 0 else { maskImage = nil; return }
        let size = bounds.size
        maskImage = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(contour)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
    }
}
