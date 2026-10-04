// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: a dictation's surface, in the island or in its fallback panel. The
/// row holds stop, the waveform (or what is happening) and the microphone;
/// the words heard so far read below it, newest kept in view.
enum DictationLayout {
    static let width: CGFloat = 420
    static let rowHeight: CGFloat = 28
    static let spacing: CGFloat = 8
    static let horizontalInset: CGFloat = 20
    static let bottomInset: CGFloat = 14
    static let maxLines = 3
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font])
        let line = ceil(font.ascender - font.descender + font.leading)
        return min(ceil(rect.height), line * CGFloat(maxLines))
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

    func dictationSize(text: String) -> CGSize {
        let width = min(max(DictationLayout.width, cameraWidth + 180), screen.width - 24)
        return DictationLayout.size(text: text, width: width, top: dictationTopInset)
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
        DictationContent()
            .padding(.horizontal, DictationLayout.horizontalInset)
            .padding(.top, service.geometry.dictationTopInset)
            .padding(.bottom, DictationLayout.bottomInset)
            .frame(width: service.surfaceSize.width, height: service.surfaceSize.height, alignment: .top)
            .transition(.opacity)
    }
}

struct DictationContent: View {
    @ObservedObject private var dictation = DictationService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { dictation.phase == .finishing || dictation.phase == .polishing }

    var body: some View {
        VStack(alignment: .leading, spacing: DictationLayout.spacing) {
            HStack(spacing: 12) {
                stopButton
                center.frame(maxWidth: .infinity)
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dictation.isRecording ? .red : .white.opacity(0.4))
                    if let name = dictation.inputName {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .frame(maxWidth: 110, alignment: .trailing)
                    }
                }
                .help(dictation.inputName ?? "")
            }
            .frame(height: DictationLayout.rowHeight)
            if !dictation.transcript.isEmpty {
                Text(dictation.transcript)
                    .font(Font(DictationLayout.font))
                    .foregroundStyle(.white.opacity(dictation.isRecording ? 0.92 : 0.7))
                    .lineLimit(DictationLayout.maxLines)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dictation.transcript)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var center: some View {
        switch dictation.phase {
        case .finishing, .polishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text(dictation.phase == .polishing ? "Polishing…" : "Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            DictationWaveform(levels: dictation.levels)
                .frame(height: 18)
        }
    }

    private var stopButton: some View {
        Button {
            if dictation.isRecording { dictation.stop(paste: true) } else { dictation.cancel() }
        } label: {
            ZStack {
                Circle().fill(Color.red).frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.white).frame(width: 8, height: 8)
            }
            .contentShape(Circle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 11))
        .disabled(busy)
        .help(dictation.isRecording ? "Stop and paste (Return)" : "Dismiss")
        .accessibilityLabel(dictation.isRecording ? "Stop and paste" : "Dismiss")
    }
}

/// Live spectrum bars, mirrored around the middle.
struct DictationWaveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { proxy in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let width = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let level = CGFloat(max(0.05, min(1, levels.indices.contains(index) ? levels[index] : 0)))
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.5 + 0.5 * level))
                        .frame(width: width, height: max(3, level * proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeOut(duration: 0.08), value: levels)
        }
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
            let content = DictationContent()
                .padding(.horizontal, DictationLayout.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, DictationLayout.bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.92)))
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
