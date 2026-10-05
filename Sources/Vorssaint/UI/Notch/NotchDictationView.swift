// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: a dictation's surface, in the island or in its fallback panel. One
/// quiet row (the recording dot, whose ring fills as a pause runs toward
/// auto-stop; a slim waveform; the elapsed time) over the words heard so
/// far. Past twenty lines the oldest scroll off the top, so the newest words
/// are always in view. Clicking anywhere stops and pastes.
enum DictationLayout {
    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 22
    static let spacing: CGFloat = 8
    static let horizontalInset: CGFloat = 18
    static let bottomInset: CGFloat = 12
    static let maxLines = 20
    static let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let lineSpacing: CGFloat = 2

    /// The text's height at `width`, at most `maxLines` lines.
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        min(fullTextHeight(text, width: width), lineHeight * CGFloat(maxLines))
    }

    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + lineSpacing }

    static func fullTextHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font, .paragraphStyle: style])
        return ceil(rect.height)
    }

    /// `top` keeps the row clear of a camera housing.
    static func size(text: String, width: CGFloat, top: CGFloat) -> CGSize {
        let textHeight = textHeight(text, width: width - horizontalInset * 2)
        let height = top + rowHeight + (textHeight > 0 ? spacing + textHeight : 0) + bottomInset
        return CGSize(width: width, height: height)
    }
}

extension NotchGeometry {
    var dictationTopInset: CGFloat { floats ? 12 : safeContentTop + 4 }

    var dictationWidth: CGFloat { min(max(DictationLayout.width, cameraWidth + 180), screen.width - 24) }

    func dictationSize(text: String) -> CGSize {
        let size = DictationLayout.size(text: text, width: dictationWidth, top: dictationTopInset)
        return CGSize(width: size.width, height: min(size.height, screen.height - 48))
    }
}

extension NotchService {
    var dictationSurfaceSize: CGSize { geometry.dictationSize(text: DictationService.shared.transcript) }

    /// The island follows the transcript's height as it grows.
    func dictationContentChanged() {
        guard dictationPresented else { return }
        refreshPresentation()
    }
}

struct NotchDictationView: View {
    @ObservedObject var service: NotchService

    var body: some View {
        DictationContent(width: service.surfaceSize.width)
            .padding(.horizontal, DictationLayout.horizontalInset)
            .padding(.top, service.geometry.dictationTopInset)
            .padding(.bottom, DictationLayout.bottomInset)
            .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .top)
            .transition(.opacity)
    }
}

struct DictationContent: View {
    /// The surface's width, which the text wraps to inside its insets.
    let width: CGFloat
    @ObservedObject private var dictation = DictationService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DictationLayout.spacing) {
            row.frame(height: DictationLayout.rowHeight)
            if !dictation.transcript.isEmpty { transcript }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture {
            if dictation.isRecording { dictation.stop(paste: true) } else if case .error = dictation.phase { dictation.cancel() }
        }
        .help(dictation.isRecording ? "Click or press Return to paste · Esc to cancel" : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(dictation.isRecording ? "Dictating. Stop and paste" : "Dictation")
    }

    /// The whole text, bottom-aligned in a window of at most twenty lines:
    /// older lines leave over the top, fading as they go.
    private var transcript: some View {
        let textWidth = width - DictationLayout.horizontalInset * 2
        let full = DictationLayout.fullTextHeight(dictation.transcript, width: textWidth)
        let visible = DictationLayout.textHeight(dictation.transcript, width: textWidth)
        let overflows = full > visible + 1
        return Text(dictation.transcript)
            .font(Font(DictationLayout.font))
            .lineSpacing(DictationLayout.lineSpacing)
            .foregroundStyle(.white.opacity(dictation.isRecording ? 0.9 : 0.6))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: textWidth, alignment: .leading)
            .frame(height: visible, alignment: .bottom)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: overflows ? .clear : .black, location: 0),
                                       .init(color: .black, location: overflows ? min(0.25, 28 / max(visible, 1)) : 0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dictation.transcript)
    }

    @ViewBuilder private var row: some View {
        switch dictation.phase {
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .finishing, .polishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(.white)
                Text(dictation.phase == .polishing ? "Polishing" : "Transcribing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
        default:
            HStack(spacing: 0) {
                DictationRecordingDot(progress: dictation.silenceProgress)
                Spacer(minLength: 12)
                DictationWaveform(levels: dictation.levels)
                Spacer(minLength: 12)
                elapsed
            }
        }
    }

    @ViewBuilder private var elapsed: some View {
        if let start = dictation.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: 34, alignment: .trailing)
        } else {
            Color.clear.frame(width: 34)
        }
    }
}

/// A red dot that breathes while listening; its ring fills as a pause runs
/// out, so auto-stop never comes as a surprise.
struct DictationRecordingDot: View {
    let progress: Double
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 16, height: 16)
                .animation(.linear(duration: 0.1), value: progress)
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(breathing ? 0.55 : 1)
        }
        .frame(width: 34, alignment: .leading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityHidden(true)
    }
}

/// A few solid bars, mirrored around the middle, drawn like the island's
/// music bars so the two read as one family.
struct DictationWaveform: View {
    let levels: [Float]
    static let barWidth: CGFloat = 3
    static let height: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: Self.barWidth * 0.85) {
            ForEach(levels.indices, id: \.self) { index in
                let level = CGFloat(max(0, min(1, levels[index])))
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: Self.barWidth, height: max(Self.barWidth, Self.height * (0.12 + 0.88 * level)))
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

/// Fork: where a dictation shows while the island is off or unavailable: a
/// dark panel below the menu bar that never takes focus.
final class DictationHUD {
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let content = DictationContent(width: DictationLayout.width)
                .padding(.horizontal, DictationLayout.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, DictationLayout.bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background {
                    // The same see-through blur the island uses while dictating.
                    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                    if DictationSupport.translucent {
                        shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(0.4)))
                    } else {
                        shape.fill(Color.black.opacity(0.9))
                    }
                }
                .environment(\.colorScheme, .dark)
            panel.contentView = NSHostingView(rootView: content)
            self.panel = panel
        }
        resize()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func resize() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = DictationLayout.size(text: DictationService.shared.transcript, width: DictationLayout.width, top: 12)
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - 8 - size.height,
                              width: size.width, height: size.height), display: true)
    }
}
