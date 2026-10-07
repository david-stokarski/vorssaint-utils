// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: recording overlays, in the spirit of CleanShot X, KeyCastr and Screen
// Studio. Clicks, keystrokes and the camera are recorded next to the master as
// tracks of their own and drawn by the composer, so every one of them stays a
// choice in the editor and none is ever baked into the raw take. The pure
// decisions live here, where the tests compile them: preferences, the edit
// settings, chord formatting, the shortcuts-only filter, caption grouping and
// fading, click animation timing and the camera bubble's layout.

extension DefaultsKey {
    /// Record mouse presses so the editor can highlight them.
    static let recorderShowClicks = "recorderShowClicks"
    /// Record key presses so the editor can show them as captions.
    static let recorderShowKeystrokes = "recorderShowKeystrokes"
    /// `RecorderKeystrokeCapture` raw value: what a recording keeps of the keys.
    static let recorderKeystrokeCapture = "recorderKeystrokeCapture"
    /// Record the camera beside the screen for the bubble.
    static let recorderCamera = "recorderCamera"
}

enum RecorderOverlaySupport {
    static let title = "Overlays"

    /// Every overlay starts off, so a recording looks as it always did until
    /// the person asks for more.
    static let registeredDefaults: [String: Any] = [
        DefaultsKey.recorderShowClicks: false,
        DefaultsKey.recorderShowKeystrokes: false,
        DefaultsKey.recorderKeystrokeCapture: RecorderKeystrokeCapture.shortcuts.rawValue,
        DefaultsKey.recorderCamera: false,
    ]

    // Files kept next to the master. A take without them is simply a take
    // recorded before overlays existed, or with them switched off.
    static let takeClicksName = "clicks.json"
    static let takeKeystrokesName = "keystrokes.json"
    static let takeCameraName = "camera.mov"
}

/// What a recording keeps of the keyboard. Shortcuts-only never stores a
/// plain typed character, not even its timing in this track, so a password
/// typed during a recording cannot be recovered from the take.
enum RecorderKeystrokeCapture: String, CaseIterable, Codable {
    case shortcuts
    case all

    static func current(in defaults: UserDefaults = .standard) -> RecorderKeystrokeCapture {
        RecorderKeystrokeCapture(rawValue: defaults.string(forKey: DefaultsKey.recorderKeystrokeCapture) ?? "")
            ?? .shortcuts
    }
}

/// The overlays chosen before a recording starts, read once when it starts.
struct RecorderOverlayCaptureOptions: Equatable {
    var clicks: Bool
    var keystrokes: Bool
    var keystrokeCapture: RecorderKeystrokeCapture
    var camera: Bool

    static func current(in defaults: UserDefaults = .standard) -> RecorderOverlayCaptureOptions {
        RecorderOverlayCaptureOptions(
            clicks: defaults.bool(forKey: DefaultsKey.recorderShowClicks),
            keystrokes: defaults.bool(forKey: DefaultsKey.recorderShowKeystrokes),
            keystrokeCapture: RecorderKeystrokeCapture.current(in: defaults),
            camera: defaults.bool(forKey: DefaultsKey.recorderCamera))
    }
}

// MARK: - Edit settings

/// How the overlays look, as part of the edit document. Every field decodes
/// leniently, so an older or hand-edited document always opens.
struct RecorderOverlaySettings: Codable, Equatable {
    var clicks = Clicks()
    var keystrokes = Keystrokes()
    var camera = Camera()

    init(clicks: Clicks = Clicks(), keystrokes: Keystrokes = Keystrokes(), camera: Camera = Camera()) {
        self.clicks = clicks
        self.keystrokes = keystrokes
        self.camera = camera
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clicks = (try? container.decodeIfPresent(Clicks.self, forKey: .clicks)) ?? Clicks()
        keystrokes = (try? container.decodeIfPresent(Keystrokes.self, forKey: .keystrokes)) ?? Keystrokes()
        camera = (try? container.decodeIfPresent(Camera.self, forKey: .camera)) ?? Camera()
    }

    func sanitized() -> RecorderOverlaySettings {
        var next = self
        next.clicks.size = Self.clamp(clicks.size, Clicks.sizeRange, fallback: 1)
        next.keystrokes.size = Self.clamp(keystrokes.size, Keystrokes.sizeRange, fallback: 1)
        next.camera.size = Self.clamp(camera.size, Camera.sizeRange, fallback: Camera.defaultSize)
        return next
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    enum ClickStyle: String, CaseIterable, Codable {
        case ring, pulse, ripple
    }

    /// A few colors that read over any screen, rather than a free picker.
    enum Palette: String, CaseIterable, Codable {
        case yellow, blue, red, green, purple, white

        var rgb: (red: Double, green: Double, blue: Double) {
            switch self {
            case .yellow: return (1.0, 0.80, 0.0)
            case .blue: return (0.04, 0.52, 1.0)
            case .red: return (1.0, 0.27, 0.23)
            case .green: return (0.20, 0.84, 0.29)
            case .purple: return (0.69, 0.32, 0.87)
            case .white: return (1.0, 1.0, 1.0)
            }
        }

        /// The color a right click wears when it is told apart: the opposite
        /// family, so the two never read as the same press.
        var contrasting: Palette {
            switch self {
            case .blue, .purple: return .yellow
            case .yellow, .red, .green, .white: return .blue
            }
        }
    }

    enum PointerEffect: String, CaseIterable, Codable {
        case none, halo, spotlight
    }

    struct Clicks: Codable, Equatable {
        static let sizeRange = 0.5...2.0
        var enabled = true
        var style: ClickStyle = .ring
        var color: Palette = .yellow
        var size: Double = 1
        var distinctRightClick = true
        var pointerEffect: PointerEffect = .none

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            style = (try? container.decodeIfPresent(ClickStyle.self, forKey: .style)) ?? .ring
            color = (try? container.decodeIfPresent(Palette.self, forKey: .color)) ?? .yellow
            size = (try? container.decodeIfPresent(Double.self, forKey: .size)) ?? 1
            distinctRightClick = (try? container.decodeIfPresent(Bool.self, forKey: .distinctRightClick)) ?? true
            pointerEffect = (try? container.decodeIfPresent(PointerEffect.self, forKey: .pointerEffect)) ?? .none
        }
    }

    enum CaptionPosition: String, CaseIterable, Codable {
        case bottom, top
    }

    enum CaptionStyle: String, CaseIterable, Codable {
        case dark, light
    }

    struct Keystrokes: Codable, Equatable {
        static let sizeRange = 0.6...1.8
        var enabled = true
        var mode: RecorderKeystrokeCapture = .shortcuts
        var position: CaptionPosition = .bottom
        var size: Double = 1
        var style: CaptionStyle = .dark

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            mode = (try? container.decodeIfPresent(RecorderKeystrokeCapture.self, forKey: .mode)) ?? .shortcuts
            position = (try? container.decodeIfPresent(CaptionPosition.self, forKey: .position)) ?? .bottom
            size = (try? container.decodeIfPresent(Double.self, forKey: .size)) ?? 1
            style = (try? container.decodeIfPresent(CaptionStyle.self, forKey: .style)) ?? .dark
        }
    }

    enum BubbleShape: String, CaseIterable, Codable {
        case circle, roundedRect
    }

    enum Corner: String, CaseIterable, Codable {
        case bottomRight, bottomLeft, topRight, topLeft
    }

    struct Camera: Codable, Equatable {
        static let sizeRange = 0.1...0.5
        static let defaultSize = 0.24
        var enabled = true
        var shape: BubbleShape = .circle
        var corner: Corner = .bottomRight
        /// The bubble's width as a share of the frame's shorter side.
        var size: Double = defaultSize
        var mirrored = true
        var border = true
        var shadow = true

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            shape = (try? container.decodeIfPresent(BubbleShape.self, forKey: .shape)) ?? .circle
            corner = (try? container.decodeIfPresent(Corner.self, forKey: .corner)) ?? .bottomRight
            size = (try? container.decodeIfPresent(Double.self, forKey: .size)) ?? Self.defaultSize
            mirrored = (try? container.decodeIfPresent(Bool.self, forKey: .mirrored)) ?? true
            border = (try? container.decodeIfPresent(Bool.self, forKey: .border)) ?? true
            shadow = (try? container.decodeIfPresent(Bool.self, forKey: .shadow)) ?? true
        }
    }
}

// MARK: - Key chords

/// Modifier bits as a track stores them, independent of AppKit's flags.
struct RecorderKeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let control = RecorderKeyModifiers(rawValue: 1 << 0)
    static let option = RecorderKeyModifiers(rawValue: 1 << 1)
    static let shift = RecorderKeyModifiers(rawValue: 1 << 2)
    static let command = RecorderKeyModifiers(rawValue: 1 << 3)

    /// Modifiers that make any key a shortcut. Shift alone only types capitals.
    static let shortcutModifiers: RecorderKeyModifiers = [.control, .option, .command]
}

enum RecorderKeyChord {
    /// Apple's own order in menus: Control, Option, Shift, Command.
    static func glyphs(_ modifiers: RecorderKeyModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    static func label(modifiers: RecorderKeyModifiers, key: String) -> String {
        glyphs(modifiers) + key
    }

    /// Names for keys that type nothing, by virtual key code (the values of
    /// Carbon's kVK constants, which the tests pin down).
    static func specialName(keyCode: UInt16) -> String? {
        switch keyCode {
        case 53: return "⎋"
        case 48: return "⇥"
        case 36: return "↩"
        case 76: return "⌤"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 49: return "Space"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        default: return nil
        }
    }

    /// Keys worth showing on their own even without a modifier: they steer
    /// rather than type. Space and delete are typing, so they are not.
    static func isCommandKey(keyCode: UInt16) -> Bool {
        guard specialName(keyCode: keyCode) != nil else { return false }
        return keyCode != 49 && keyCode != 51
    }

    /// The base key's caption: its special name, or the unmodified character
    /// in capitals, the way the key cap prints it.
    static func keyLabel(keyCode: UInt16, unmodifiedCharacters: String?) -> String? {
        if let name = specialName(keyCode: keyCode) { return name }
        guard let characters = unmodifiedCharacters?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
              !characters.isEmpty
        else { return nil }
        return characters.uppercased()
    }

    /// Characters a person typed, minus anything that is not text.
    static func typedText(_ characters: String?) -> String? {
        guard let characters else { return nil }
        let scalars = characters.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                // The private-use range is where AppKit puts function keys.
                && !(0xF700...0xF8FF).contains($0.value)
        }
        let text = String(String.UnicodeScalarView(scalars))
        return text.isEmpty ? nil : text
    }

    /// One key press as the track would keep it, or nil when the capture mode
    /// says it must not be kept at all. Shortcuts-only drops plain typing
    /// before anything is stored.
    static func stroke(time: Double,
                       keyCode: UInt16,
                       modifiers: RecorderKeyModifiers,
                       unmodifiedCharacters: String?,
                       characters: String?,
                       capture: RecorderKeystrokeCapture) -> RecorderKeystroke? {
        guard time.isFinite, time >= 0,
              let key = keyLabel(keyCode: keyCode, unmodifiedCharacters: unmodifiedCharacters)
        else { return nil }
        let isShortcut = !modifiers.isDisjoint(with: .shortcutModifiers) || isCommandKey(keyCode: keyCode)
        if isShortcut {
            return RecorderKeystroke(time: time, key: key, modifiers: modifiers, kind: .shortcut)
        }
        guard capture == .all else { return nil }
        if keyCode == 51 || keyCode == 117 {
            return RecorderKeystroke(time: time, key: key, modifiers: modifiers, kind: .delete)
        }
        guard let text = typedText(characters) else { return nil }
        return RecorderKeystroke(time: time, key: key, modifiers: modifiers, kind: .text, text: text)
    }
}

/// One key press in a recording. A shortcut keeps its chord; a typed key keeps
/// its text only when the recording was set to capture every key.
struct RecorderKeystroke: Codable, Equatable {
    enum Kind: String, Codable {
        case shortcut, text, delete
    }

    var time: Double
    var key: String
    var modifiers: RecorderKeyModifiers
    var kind: Kind
    var text: String?

    init(time: Double, key: String, modifiers: RecorderKeyModifiers = [], kind: Kind, text: String? = nil) {
        self.time = time
        self.key = key
        self.modifiers = modifiers
        self.kind = kind
        self.text = text
    }

    var chord: String { RecorderKeyChord.label(modifiers: modifiers, key: key) }
}

// MARK: - Captions

/// One pill on screen: a chord, a repeated chord, or a run of typing.
struct RecorderKeyCaption: Equatable {
    var start: Double
    /// The last key that fed this caption; the hold is counted from here.
    var lastKey: Double
    var text: String
    /// When it leaves: faded out, or replaced by the next caption.
    var end: Double
}

enum RecorderKeyCaptions {
    static let fadeIn = 0.08
    static let hold = 1.1
    static let fadeOut = 0.3
    /// Keys closer than this join the caption before them.
    static let joinGap = 1.0
    static let maxCharacters = 28

    static func visible(_ strokes: [RecorderKeystroke], mode: RecorderKeystrokeCapture) -> [RecorderKeystroke] {
        strokes.filter { mode == .all || $0.kind == .shortcut }
            .filter { $0.time.isFinite }
            .sorted { $0.time < $1.time }
    }

    /// Groups key presses into the captions a viewer reads. A run of typing
    /// stays one growing line; the same chord pressed again counts up rather
    /// than flashing; anything else starts a new pill.
    static func captions(_ strokes: [RecorderKeystroke], mode: RecorderKeystrokeCapture) -> [RecorderKeyCaption] {
        struct Building {
            var start: Double
            var lastKey: Double
            var kind: RecorderKeystroke.Kind
            var text: String
            var chord: String
            var count: Int
        }
        var built: [Building] = []
        for stroke in visible(strokes, mode: mode) {
            let joins = built.last.map { stroke.time - $0.lastKey <= joinGap } ?? false
            switch stroke.kind {
            case .shortcut:
                if joins, var last = built.last, last.kind == .shortcut, last.chord == stroke.chord {
                    last.count += 1
                    last.lastKey = stroke.time
                    last.text = "\(stroke.chord) ×\(last.count)"
                    built[built.count - 1] = last
                } else {
                    built.append(Building(start: stroke.time, lastKey: stroke.time, kind: .shortcut,
                                          text: stroke.chord, chord: stroke.chord, count: 1))
                }
            case .text, .delete:
                if joins, var last = built.last, last.kind == .text {
                    if stroke.kind == .delete {
                        if last.text.isEmpty || last.text.hasSuffix("⌫") {
                            last.text += "⌫"
                        } else {
                            last.text.removeLast()
                        }
                    } else {
                        last.text += stroke.text ?? ""
                    }
                    if last.text.count > maxCharacters {
                        last.text = "…" + String(last.text.suffix(maxCharacters - 1))
                    }
                    last.lastKey = stroke.time
                    built[built.count - 1] = last
                } else {
                    let text = stroke.kind == .delete ? "⌫" : (stroke.text ?? "")
                    built.append(Building(start: stroke.time, lastKey: stroke.time, kind: .text,
                                          text: text, chord: "", count: 1))
                }
            }
        }
        var captions: [RecorderKeyCaption] = []
        for (index, item) in built.enumerated() {
            let natural = item.lastKey + hold + fadeOut
            let next = index + 1 < built.count ? built[index + 1].start : .infinity
            let text = item.text.trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { continue }
            captions.append(RecorderKeyCaption(start: item.start, lastKey: item.lastKey,
                                               text: text, end: min(natural, next)))
        }
        return captions
    }

    /// How solid a caption is at a moment of the recording: in quickly, held
    /// after its last key, then out. A caption replaced by the next one goes
    /// at once, because two pills in one place read as noise.
    static func opacity(of caption: RecorderKeyCaption, at time: Double) -> Double {
        guard time >= caption.start, time < caption.end else { return 0 }
        let rising = min(1, (time - caption.start) / fadeIn)
        let fadeStart = caption.lastKey + hold
        let falling = time <= fadeStart ? 1 : max(0, 1 - (time - fadeStart) / fadeOut)
        return max(0, min(rising, falling))
    }

    /// The caption on screen at a moment, if any. Captions never overlap,
    /// so a binary search over their starts is enough.
    static func active(_ captions: [RecorderKeyCaption], at time: Double) -> (index: Int, opacity: Double)? {
        var low = 0
        var high = captions.count
        while low < high {
            let mid = (low + high) / 2
            if captions[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard captions.indices.contains(index) else { return nil }
        let opacity = opacity(of: captions[index], at: time)
        return opacity > 0.005 ? (index, opacity) : nil
    }
}

// MARK: - Clicks

enum RecorderClickAnimation {
    static func duration(_ style: RecorderOverlaySettings.ClickStyle) -> Double {
        switch style {
        case .ring: return 0.45
        case .pulse: return 0.5
        case .ripple: return 0.75
        }
    }

    /// Where a click's animation is at a moment, 0 at the press and 1 when
    /// it has gone; nil before the press and after the animation.
    static func progress(at time: Double, clickTime: Double, duration: Double) -> Double? {
        guard duration > 0, time.isFinite, clickTime.isFinite else { return nil }
        let elapsed = time - clickTime
        guard elapsed >= 0, elapsed <= duration else { return nil }
        return elapsed / duration
    }

    /// The presses animating at a moment, newest last. `downTimes` ascending.
    static func active(at time: Double, downTimes: [Double], duration: Double) -> [(index: Int, progress: Double)] {
        var low = 0
        var high = downTimes.count
        let earliest = time - duration
        while low < high {
            let mid = (low + high) / 2
            if downTimes[mid] < earliest { low = mid + 1 } else { high = mid }
        }
        var result: [(index: Int, progress: Double)] = []
        var index = low
        while index < downTimes.count, downTimes[index] <= time {
            if let progress = progress(at: time, clickTime: downTimes[index], duration: duration) {
                result.append((index, progress))
            }
            index += 1
        }
        return result
    }

    static func easeOut(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return 1 - pow(1 - clamped, 3)
    }

    /// Ring radius and opacity at a point of the animation, as fractions of
    /// the full radius and of full strength.
    static func ring(progress: Double) -> (radius: Double, alpha: Double) {
        (0.3 + 0.7 * easeOut(progress), max(0, 1 - progress) * max(0, 1 - progress * 0.4))
    }

    static func pulse(progress: Double) -> (radius: Double, alpha: Double) {
        let swell = progress < 0.3 ? easeOut(progress / 0.3) : 1
        return (0.45 + 0.55 * swell, 0.55 * max(0, 1 - progress))
    }
}

// MARK: - Camera bubble

enum RecorderBubbleLayout {
    /// The bubble's rectangle on a canvas, in Core Image coordinates (origin
    /// at the bottom left). Always whole and always inside the frame, however
    /// small the canvas or large the size asked for.
    static func rect(canvas: CGSize,
                     shape: RecorderOverlaySettings.BubbleShape,
                     corner: RecorderOverlaySettings.Corner,
                     size: Double) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let short = min(canvas.width, canvas.height)
        let fraction = RecorderOverlaySettings.clamp(size, RecorderOverlaySettings.Camera.sizeRange,
                                                     fallback: RecorderOverlaySettings.Camera.defaultSize)
        let margin = (short * 0.035).rounded()
        var width = (short * fraction).rounded()
        var height = shape == .circle ? width : (width * 0.75).rounded()
        let room = CGSize(width: max(1, canvas.width - margin * 2), height: max(1, canvas.height - margin * 2))
        let fit = min(1, room.width / max(1, width), room.height / max(1, height))
        width = max(1, (width * fit).rounded(.down))
        height = max(1, (height * fit).rounded(.down))
        let left = margin
        let right = canvas.width - margin - width
        let bottom = margin
        let top = canvas.height - margin - height
        let origin: CGPoint
        switch corner {
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .topLeft: origin = CGPoint(x: left, y: top)
        }
        return clamped(CGRect(origin: origin, size: CGSize(width: width, height: height)), in: canvas)
    }

    static func clamped(_ rect: CGRect, in canvas: CGSize) -> CGRect {
        let width = min(rect.width, canvas.width)
        let height = min(rect.height, canvas.height)
        let x = min(max(0, rect.minX), canvas.width - width)
        let y = min(max(0, rect.minY), canvas.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func cornerRadius(for rect: CGRect, shape: RecorderOverlaySettings.BubbleShape) -> CGFloat {
        shape == .circle ? min(rect.width, rect.height) / 2 : min(rect.width, rect.height) * 0.16
    }

    /// The scale and offset that fill the bubble with the camera image without
    /// distorting it, cropping whichever side is too long.
    static func aspectFill(image: CGSize, into rect: CGRect) -> (scale: CGFloat, origin: CGPoint) {
        guard image.width > 0, image.height > 0 else { return (1, rect.origin) }
        let scale = max(rect.width / image.width, rect.height / image.height)
        let drawn = CGSize(width: image.width * scale, height: image.height * scale)
        return (scale, CGPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2))
    }
}
