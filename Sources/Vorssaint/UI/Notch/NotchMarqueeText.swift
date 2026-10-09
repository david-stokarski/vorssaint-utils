// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: one line of text that scrolls to its end when it does not fit,
/// instead of being cut short. Fonts and colours come from the environment,
/// as they would for a plain `Text`. Under Reduce Motion it truncates.
struct NotchMarqueeText: View {
    let text: String
    /// Seconds the line has left on screen, to pace the scroll.
    var remaining: Double?
    /// Where a line that fits sits; a line that scrolls starts at the leading edge.
    var alignment: Alignment = .leading
    @State private var fullWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: CGFloat { max(0, fullWidth - boxWidth) }

    var body: some View {
        // The one-line text sets the height and takes the width offered.
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(reduceMotion || overflow <= 0.5 ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                if !reduceMotion, overflow > 0.5 {
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: shift)
                        .frame(width: boxWidth, alignment: .leading)
                        .clipped()
                        .mask(fade)
                }
            }
            .background(alignment: .leading) {
                // Measures the whole line without taking part in layout.
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
            .task(id: MarqueeKey(text: text, overflow: overflow, reduceMotion: reduceMotion)) {
                await scroll()
            }
            .accessibilityLabel(text)
    }

    /// Soft edges where the line runs past the box: on the right until the
    /// end arrives, on the left once the start has gone.
    private var fade: some View {
        let edge: CGFloat = 14
        let width = max(1, boxWidth)
        let leading = shift < -0.5 ? min(0.5, edge / width) : 0
        let trailing = shift > -overflow + 0.5 ? max(0.5, 1 - edge / width) : 1
        return LinearGradient(stops: [
            .init(color: .black.opacity(leading > 0 ? 0 : 1), location: 0),
            .init(color: .black, location: leading),
            .init(color: .black, location: trailing),
            .init(color: .black.opacity(trailing < 1 ? 0 : 1), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    @MainActor private func scroll() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { shift = 0 }
        guard !reduceMotion,
              let duration = NotchLyricMarquee.duration(overflow: overflow, remaining: remaining) else { return }
        try? await Task.sleep(for: .seconds(NotchLyricMarquee.delay(remaining: remaining)))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: duration)) { shift = -overflow }
    }
}

private struct MarqueeKey: Equatable {
    let text: String
    let overflow: CGFloat
    let reduceMotion: Bool
}
