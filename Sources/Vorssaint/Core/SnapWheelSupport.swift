// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: the Snap Wheel, in the spirit of Loop. Hold the trigger key and
// nothing happens; move the pointer and a ring appears with a preview of
// where the focused window will go. Release to place it. Each of the eight
// directions and the center holds a list of placements: the first is chosen
// on the way in, a click moves on to the next. Preferences, the hold, the
// pointer geometry and the Loop import live here, where the tests compile
// them; the event taps are in Services/SnapWheel and the drawing in
// UI/SnapWheel.

extension DefaultsKey {
    static let snapWheelEnabled = "snapWheelEnabled"
    /// `SnapWheelTriggerKeys` tokens joined by "+", e.g. "leftControl".
    static let snapWheelTrigger = "snapWheelTrigger"
    /// Either Control (or Option…) starts the wheel, not only the side recorded.
    static let snapWheelTriggerEitherSide = "snapWheelTriggerEitherSide"
    /// JSON object of slot raw value to a list of action ids.
    static let snapWheelSlots = "snapWheelSlots"
    static let snapWheelPlacement = "snapWheelPlacement"
    static let snapWheelShowsWheel = "snapWheelShowsWheel"
    static let snapWheelSize = "snapWheelSize"
    static let snapWheelThickness = "snapWheelThickness"
    static let snapWheelCornerRadius = "snapWheelCornerRadius"
    static let snapWheelMaterial = "snapWheelMaterial"
    static let snapWheelColorMode = "snapWheelColorMode"
    static let snapWheelColor = "snapWheelColor"
    static let snapWheelGradientColor = "snapWheelGradientColor"
    static let snapWheelPreviewEnabled = "snapWheelPreviewEnabled"
    static let snapWheelPreviewMaterial = "snapWheelPreviewMaterial"
    static let snapWheelPreviewPadding = "snapWheelPreviewPadding"
    static let snapWheelPreviewCornerRadius = "snapWheelPreviewCornerRadius"
    static let snapWheelPreviewBorder = "snapWheelPreviewBorder"
    static let snapWheelPreviewTint = "snapWheelPreviewTint"
    static let snapWheelPreviewStart = "snapWheelPreviewStart"
    static let snapWheelAnimation = "snapWheelAnimation"
    static let snapWheelHaptics = "snapWheelHaptics"
    static let snapWheelTarget = "snapWheelTarget"
    static let snapWheelScreen = "snapWheelScreen"
    /// 0 relaxed … 1 twitchy: how little movement shows the ring and picks.
    static let snapWheelSensitivity = "snapWheelSensitivity"
    /// A pointer that rests and moves on starts over from where it rested.
    static let snapWheelRecenter = "snapWheelRecenter"
    /// Seconds of stillness that count as resting.
    static let snapWheelRestDelay = "snapWheelRestDelay"
    /// A big circle drawn while holding picks the center.
    static let snapWheelCircle = "snapWheelCircle"
}

// MARK: - Trigger

/// The modifier keys that can start the wheel, each side on its own.
struct SnapWheelTriggerKeys: OptionSet, Hashable {
    let rawValue: UInt16

    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let leftControl = Self(rawValue: 1 << 0)
    static let rightControl = Self(rawValue: 1 << 1)
    static let leftOption = Self(rawValue: 1 << 2)
    static let rightOption = Self(rawValue: 1 << 3)
    static let leftCommand = Self(rawValue: 1 << 4)
    static let rightCommand = Self(rawValue: 1 << 5)
    static let leftShift = Self(rawValue: 1 << 6)
    static let rightShift = Self(rawValue: 1 << 7)
    static let function = Self(rawValue: 1 << 8)

    static let control: Self = [.leftControl, .rightControl]
    static let option: Self = [.leftOption, .rightOption]
    static let command: Self = [.leftCommand, .rightCommand]
    static let shift: Self = [.leftShift, .rightShift]

    /// Storage token, display name and symbol, in the order keys are shown.
    static let catalog: [(key: Self, token: String, name: String, symbol: String)] = [
        (.function, "function", "fn", "fn"),
        (.leftControl, "leftControl", "Left Control", "⌃"),
        (.rightControl, "rightControl", "Right Control", "⌃"),
        (.leftOption, "leftOption", "Left Option", "⌥"),
        (.rightOption, "rightOption", "Right Option", "⌥"),
        (.leftShift, "leftShift", "Left Shift", "⇧"),
        (.rightShift, "rightShift", "Right Shift", "⇧"),
        (.leftCommand, "leftCommand", "Left Command", "⌘"),
        (.rightCommand, "rightCommand", "Right Command", "⌘"),
    ]

    // The device-dependent bits macOS sets in every event's flags (IOKit's
    // NX_DEVICE…KEYMASK), which tell the left key from the right one.
    private static let deviceBits: [(UInt64, Self)] = [
        (0x0000_0001, .leftControl), (0x0000_2000, .rightControl),
        (0x0000_0020, .leftOption), (0x0000_0040, .rightOption),
        (0x0000_0008, .leftCommand), (0x0000_0010, .rightCommand),
        (0x0000_0002, .leftShift), (0x0000_0004, .rightShift),
    ]

    /// The keys held according to an event's flags. A source that only sets
    /// the generic bit (some remappers and remote-control apps do) counts as
    /// the left key.
    init(eventFlags flags: UInt64) {
        var keys: Self = []
        for (bit, key) in Self.deviceBits where flags & bit != 0 { keys.insert(key) }
        let generic: [(CGEventFlags, Self, Self)] = [
            (.maskControl, .control, .leftControl), (.maskAlternate, .option, .leftOption),
            (.maskCommand, .command, .leftCommand), (.maskShift, .shift, .leftShift),
        ]
        for (mask, both, left) in generic where flags & mask.rawValue != 0 && keys.isDisjoint(with: both) {
            keys.insert(left)
        }
        if flags & CGEventFlags.maskSecondaryFn.rawValue != 0 { keys.insert(.function) }
        self = keys
    }

    /// The same keys with each side folded onto the left one, for "either side".
    var sideless: Self {
        var keys = intersection(.function)
        if !isDisjoint(with: .control) { keys.insert(.leftControl) }
        if !isDisjoint(with: .option) { keys.insert(.leftOption) }
        if !isDisjoint(with: .command) { keys.insert(.leftCommand) }
        if !isDisjoint(with: .shift) { keys.insert(.leftShift) }
        return keys
    }

    init?(storageValue: String) {
        var keys: Self = []
        for token in storageValue.split(separator: "+") {
            guard let entry = Self.catalog.first(where: { $0.token == token }) else { return nil }
            keys.insert(entry.key)
        }
        guard !keys.isEmpty else { return nil }
        self = keys
    }

    var storageValue: String {
        Self.catalog.filter { contains($0.key) }.map(\.token).joined(separator: "+")
    }

    /// Shift alone is held while typing and selecting; it needs company.
    var isUsableTrigger: Bool {
        !isEmpty && !isDisjoint(with: [.control, .option, .command, .function])
    }

    func displayName(eitherSide: Bool) -> String {
        let keys = eitherSide ? sideless : self
        return Self.catalog.filter { keys.contains($0.key) }.map { entry in
            guard eitherSide else { return entry.name }
            return entry.name.replacingOccurrences(of: "Left ", with: "")
        }.joined(separator: " + ")
    }

    func symbols(eitherSide: Bool) -> String {
        let keys = eitherSide ? sideless : self
        return Self.catalog.filter { keys.contains($0.key) }.map(\.symbol).joined()
    }
}

struct SnapWheelTrigger: Equatable {
    var keys: SnapWheelTriggerKeys
    var eitherSide: Bool

    static let `default` = SnapWheelTrigger(keys: .leftControl, eitherSide: false)

    func matches(_ held: SnapWheelTriggerKeys) -> Bool {
        eitherSide ? held.sideless == keys.sideless : held == keys
    }

    /// True while every key held so far belongs to the trigger, so a chord
    /// being pressed one key at a time is not mistaken for something else.
    func isPartOf(_ held: SnapWheelTriggerKeys) -> Bool {
        eitherSide ? keys.sideless.isSuperset(of: held.sideless) : keys.isSuperset(of: held)
    }

    static func current(in defaults: UserDefaults = .standard) -> SnapWheelTrigger {
        let keys = defaults.string(forKey: DefaultsKey.snapWheelTrigger)
            .flatMap(SnapWheelTriggerKeys.init(storageValue:))
            .flatMap { $0.isUsableTrigger ? $0 : nil } ?? Self.default.keys
        return SnapWheelTrigger(keys: keys, eitherSide: defaults.bool(forKey: DefaultsKey.snapWheelTriggerEitherSide))
    }
}

/// One physical hold of the trigger. It arms when exactly the trigger is
/// held, finishes when a trigger key is let go, and once anything else
/// joins (another modifier, a key, a click) it waits for every key to come
/// up before it can arm again.
struct SnapWheelHold {
    enum Decision: Equatable { case nothing, arm, release, cancel }

    let trigger: SnapWheelTrigger
    private(set) var isArmed = false
    private var isBlocked: Bool

    init(trigger: SnapWheelTrigger, initiallyHeld: SnapWheelTriggerKeys = []) {
        self.trigger = trigger
        isBlocked = !initiallyHeld.isEmpty
    }

    mutating func update(_ held: SnapWheelTriggerKeys) -> Decision {
        if isArmed {
            if trigger.matches(held) { return .nothing }
            isArmed = false
            isBlocked = !held.isEmpty
            // Letting go of a trigger key places the window; adding another
            // modifier means the hold was for something else.
            return trigger.isPartOf(held) ? .release : .cancel
        }
        if isBlocked {
            isBlocked = !held.isEmpty
            return .nothing
        }
        if trigger.matches(held) {
            isArmed = true
            return .arm
        }
        if !trigger.isPartOf(held) { isBlocked = true }
        return .nothing
    }

    /// A key, click or scroll while held: the hold belonged to that input.
    mutating func cancel() -> Bool {
        let wasArmed = isArmed
        isArmed = false
        isBlocked = true
        return wasArmed
    }
}

// MARK: - Slots and actions

/// The eight directions and the center, in the order they are shown.
enum SnapWheelSlot: String, CaseIterable, Identifiable {
    case top, topRight, right, bottomRight, bottom, bottomLeft, left, topLeft, center

    var id: String { rawValue }

    static let directions: [SnapWheelSlot] = [.right, .topRight, .top, .topLeft,
                                              .left, .bottomLeft, .bottom, .bottomRight]

    /// Degrees counterclockwise from the right, as in AppKit's y-up space.
    var angle: Double? {
        guard let index = Self.directions.firstIndex(of: self) else { return nil }
        return Double(index) * 45
    }

    var title: String {
        switch self {
        case .top: return "Up"
        case .topRight: return "Up Right"
        case .right: return "Right"
        case .bottomRight: return "Down Right"
        case .bottom: return "Down"
        case .bottomLeft: return "Down Left"
        case .left: return "Left"
        case .topLeft: return "Up Left"
        case .center: return "Center"
        }
    }

    var symbol: String {
        switch self {
        case .top: return "arrow.up"
        case .topRight: return "arrow.up.right"
        case .right: return "arrow.right"
        case .bottomRight: return "arrow.down.right"
        case .bottom: return "arrow.down"
        case .bottomLeft: return "arrow.down.left"
        case .left: return "arrow.left"
        case .topLeft: return "arrow.up.left"
        case .center: return "circle.dashed"
        }
    }
}

/// Window Layout action ids (`WindowLayoutAction` raw values) plus the few
/// the wheel adds of its own.
enum SnapWheelActionID {
    static let minimize = "minimize"
    static let hide = "hide"
    static let extra = [minimize, hide]
}

enum SnapWheelSlots {
    static let defaults: [SnapWheelSlot: [String]] = [
        .top: ["topHalf", "topThird", "topTwoThirds"],
        .topRight: ["topRight"],
        .right: ["rightHalf", "rightThird", "rightTwoThirds"],
        .bottomRight: ["bottomRight"],
        .bottom: ["bottomHalf", "bottomThird", "bottomTwoThirds"],
        .bottomLeft: ["bottomLeft"],
        .left: ["leftHalf", "leftThird", "leftTwoThirds"],
        .topLeft: ["topLeft"],
        .center: ["maximize", "center"],
    ]

    static func decode(_ raw: String?) -> [SnapWheelSlot: [String]] {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return defaults }
        var slots: [SnapWheelSlot: [String]] = [:]
        for slot in SnapWheelSlot.allCases {
            slots[slot] = object[slot.rawValue] ?? []
        }
        return slots
    }

    static func encode(_ slots: [SnapWheelSlot: [String]]) -> String {
        var object: [String: [String]] = [:]
        for slot in SnapWheelSlot.allCases { object[slot.rawValue] = slots[slot] ?? [] }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func current(in defaults: UserDefaults = .standard) -> [SnapWheelSlot: [String]] {
        decode(defaults.string(forKey: DefaultsKey.snapWheelSlots))
    }
}

/// Which item of each slot's list is chosen during one hold. Entering a
/// slot picks up after the window's current placement when that placement
/// is one of the slot's, so holding Left again goes from a half to a third.
/// Leaving and coming back keeps the item; a click moves on.
struct SnapWheelCycle {
    private var chosen: [SnapWheelSlot: Int] = [:]

    mutating func enter(_ slot: SnapWheelSlot, actions: [String], windowPlacement: String?) -> String? {
        guard !actions.isEmpty else { return nil }
        if let index = chosen[slot], actions.indices.contains(index) { return actions[index] }
        var index = 0
        if let windowPlacement, let current = actions.firstIndex(of: windowPlacement) {
            index = (current + 1) % actions.count
        }
        chosen[slot] = index
        return actions[index]
    }

    mutating func advance(_ slot: SnapWheelSlot, actions: [String]) -> String? {
        guard !actions.isEmpty else { return nil }
        let index = ((chosen[slot] ?? -1) + 1) % actions.count
        chosen[slot] = index
        return actions[index]
    }

    /// Picks `index` of the slot's list outright, as a circle picks the first.
    mutating func select(_ slot: SnapWheelSlot, index: Int, actions: [String]) -> String? {
        guard actions.indices.contains(index) else { return nil }
        chosen[slot] = index
        return actions[index]
    }

    func position(in slot: SnapWheelSlot) -> Int? { chosen[slot] }
}

// MARK: - Geometry

enum SnapWheelGeometry {
    /// How far the pointer moves before the wheel shows; less is a hand
    /// resting on the mouse.
    static let showDistance: CGFloat = 10

    /// Closer than this to where the hold began is the center; farther picks
    /// a direction. It follows the ring so the hole is the center.
    static func directionalDistance(size: CGFloat, thickness: CGFloat) -> CGFloat {
        max(22, size / 2 - thickness)
    }

    /// AppKit coordinates (y up).
    static func slot(from origin: CGPoint, to point: CGPoint, directionalDistance: CGFloat,
                     showDistance: CGFloat = showDistance) -> SnapWheelSlot? {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let distance = hypot(dx, dy)
        guard distance >= showDistance else { return nil }
        guard distance >= directionalDistance else { return .center }
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let index = Int((degrees + 22.5) / 45) % 8
        return SnapWheelSlot.directions[index]
    }

    /// The angle to turn to next, the short way round from where the
    /// highlight already is, so it never spins the long way.
    static func continuousAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return current + delta
    }

    /// The pointer stops at the edge of the screen while the hand keeps
    /// going. On an axis where it is pinned, the movement the event still
    /// reports is added up, up to a limit, so a hold started near an edge
    /// can still reach the directions past it.
    static func trackedPointer(previous: CGPoint, location: CGPoint, delta: CGVector,
                               pinnedX: Bool, pinnedY: Bool, reach: CGFloat) -> CGPoint {
        var point = location
        if pinnedX { point.x = min(max(previous.x + delta.dx, location.x - reach), location.x + reach) }
        if pinnedY { point.y = min(max(previous.y + delta.dy, location.y - reach), location.y + reach) }
        return point
    }

    /// The preview's rectangle pulled in by its padding, never inside out.
    static func inset(_ rect: CGRect, by padding: CGFloat) -> CGRect {
        let dx = min(max(0, padding), max(0, rect.width / 2 - 20))
        let dy = min(max(0, padding), max(0, rect.height / 2 - 20))
        return rect.insetBy(dx: dx, dy: dy)
    }
}

// MARK: - Feel

/// How much movement the wheel needs, and whether a rest starts it over.
struct SnapWheelFeel: Equatable {
    var sensitivity: Double = 0.7
    var recenters = true
    var restDelay: TimeInterval = 0.3
    var circles = true

    static let restDelayRange: ClosedRange<Double> = 0.15...1.0

    /// Points of movement before the ring shows: 12 relaxed, 4 twitchy.
    var showDistance: CGFloat { CGFloat(12 - 8 * min(max(sensitivity, 0), 1)) }

    /// Points from the center to pick a direction. Relaxed it is the ring's
    /// hole and a bit more; twitchy, under half of it.
    func directionalDistance(size: CGFloat, thickness: CGFloat) -> CGFloat {
        let hole = max(22, size / 2 - thickness)
        let factor = 1.15 - 0.75 * min(max(sensitivity, 0), 1)
        return max(showDistance + 6, hole * CGFloat(factor))
    }

    static func current(in defaults: UserDefaults = .standard) -> SnapWheelFeel {
        var feel = SnapWheelFeel()
        if let value = defaults.object(forKey: DefaultsKey.snapWheelSensitivity) as? Double, value.isFinite {
            feel.sensitivity = min(max(value, 0), 1)
        }
        feel.recenters = defaults.object(forKey: DefaultsKey.snapWheelRecenter) as? Bool ?? true
        feel.circles = defaults.object(forKey: DefaultsKey.snapWheelCircle) as? Bool ?? true
        if let value = defaults.object(forKey: DefaultsKey.snapWheelRestDelay) as? Double, value.isFinite {
            feel.restDelay = min(max(value, restDelayRange.lowerBound), restDelayRange.upperBound)
        }
        return feel
    }
}

/// Where the wheel measures from. A pointer that stops for `restDelay` and
/// then moves on makes the place it stopped the new center, so a hand that
/// was still travelling when the key went down, or that paused to look,
/// picks from where it is now. A few points of tremor are not movement.
struct SnapWheelAnchor: Equatable {
    private(set) var origin: CGPoint
    private(set) var resting: CGPoint
    private(set) var lastMovedAt: TimeInterval
    /// Set once the center has moved during this hold.
    private(set) var hasMoved = false
    static let tremor: CGFloat = 1.5

    init(origin: CGPoint, at time: TimeInterval) {
        self.origin = origin
        resting = origin
        lastMovedAt = time
    }

    /// Makes `point` the center now, as after a circle: the choice made
    /// stays until a direction is picked from here.
    mutating func restart(at point: CGPoint, time: TimeInterval) {
        origin = point
        resting = point
        lastMovedAt = time
        hasMoved = true
    }

    /// Records the pointer at `point`; true when the center moved.
    mutating func move(to point: CGPoint, at time: TimeInterval, restDelay: TimeInterval) -> Bool {
        guard hypot(point.x - resting.x, point.y - resting.y) > Self.tremor else { return false }
        let restedHere = time - lastMovedAt >= restDelay && resting != origin
        if restedHere {
            origin = resting
            hasMoved = true
        }
        resting = point
        lastMovedAt = time
        return restedHere
    }
}

/// Notices a big circle drawn with the pointer: the recent path winds most
/// of a full turn around its own middle, far enough out and round enough.
/// Measuring the winding around the middle, rather than adding up every
/// change of heading, shrugs off a wobbly hand and an uneven loop. A line,
/// a zigzag or a U passes close to its middle or turns too little; a small
/// or flat loop is too small or too far from round.
struct SnapWheelCircle: Equatable {
    /// The smallest radius, in points, that counts (a loop about 70 across).
    static let minimumRadius: CGFloat = 35
    /// Most of a turn: hands rarely close the loop exactly.
    static let turnNeeded = Double.pi * 2 * 0.83
    /// How far back the path is looked at.
    private static let span: TimeInterval = 1.6
    private static let pause: TimeInterval = 0.35
    private static let spacing: CGFloat = 2

    private var points: [CGPoint] = []
    private var times: [TimeInterval] = []
    private(set) var winding: Double = 0

    /// Well into a loop: what the pointer points at is not a choice yet.
    var isCircling: Bool { abs(winding) > .pi * 0.75 }

    mutating func reset() { self = SnapWheelCircle() }

    /// Adds a pointer position; true when it completes a circle.
    mutating func add(_ point: CGPoint, at time: TimeInterval) -> Bool {
        if let last = points.last {
            guard hypot(point.x - last.x, point.y - last.y) >= Self.spacing else { return false }
            if time - times[times.count - 1] > Self.pause { reset() }
        }
        points.append(point)
        times.append(time)
        while let first = times.first, time - first > Self.span {
            points.removeFirst()
            times.removeFirst()
        }
        winding = 0
        guard points.count >= 10 else { return false }

        let count = CGFloat(points.count)
        let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count)
        var radii = points.map { hypot($0.x - center.x, $0.y - center.y) }
        radii.sort()
        let low = radii[radii.count / 10], high = radii[radii.count * 9 / 10]
        guard radii[radii.count / 2] >= Self.minimumRadius, low >= high * 0.4 else { return false }

        var total = 0.0
        var previous = atan2(Double(points[0].y - center.y), Double(points[0].x - center.x))
        for point in points.dropFirst() {
            let angle = atan2(Double(point.y - center.y), Double(point.x - center.x))
            var delta = angle - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            total += delta
            previous = angle
        }
        winding = total
        guard abs(total) >= Self.turnNeeded else { return false }
        reset()
        return true
    }
}

// MARK: - Appearance and behavior

enum SnapWheelPlacement: String, CaseIterable { case pointer, screenCenter }
enum SnapWheelMaterial: String, CaseIterable { case glass, frosted, solid }
enum SnapWheelColorMode: String, CaseIterable { case system, custom, gradient }
enum SnapWheelPreviewMaterial: String, CaseIterable { case frosted, glass, tint }
enum SnapWheelPreviewStart: String, CaseIterable { case screenCenter, wheel, window, target }
enum SnapWheelAnimation: String, CaseIterable { case fluid, snappy, instant }
enum SnapWheelTargetChoice: String, CaseIterable { case focused, underPointer }
enum SnapWheelScreenChoice: String, CaseIterable { case pointer, window }

struct SnapWheelAppearance: Equatable {
    var placement = SnapWheelPlacement.pointer
    var showsWheel = true
    var size: CGFloat = 100
    var thickness: CGFloat = 22
    var cornerRadius: CGFloat = 50
    var material = SnapWheelMaterial.glass
    var colorMode = SnapWheelColorMode.system
    var color = "#0A84FF"
    var gradientColor = "#64D2FF"
    var previewEnabled = true
    var previewMaterial = SnapWheelPreviewMaterial.frosted
    var previewPadding: CGFloat = 0
    var previewCornerRadius: CGFloat = 16
    var previewBorder: CGFloat = 2
    var previewTint: Double = 0.2
    var previewStart = SnapWheelPreviewStart.screenCenter
    var animation = SnapWheelAnimation.fluid
    var haptics = true

    static let sizeRange: ClosedRange<Double> = 70...180
    static let thicknessRange: ClosedRange<Double> = 4...40
    static let cornerRadiusRange: ClosedRange<Double> = 0...50
    static let previewPaddingRange: ClosedRange<Double> = 0...40
    static let previewCornerRadiusRange: ClosedRange<Double> = 0...40
    static let previewBorderRange: ClosedRange<Double> = 0...8

    /// Corner radius as a share of the ring's half width, so a square, a
    /// squircle and a circle stay that shape at any size.
    var ringCornerRadius: CGFloat { size / 2 * min(max(cornerRadius, 0), 50) / 50 }
    var ringThickness: CGFloat { min(max(thickness, 2), size / 2 - 8) }

    static func current(in defaults: UserDefaults = .standard) -> SnapWheelAppearance {
        var value = SnapWheelAppearance()
        func number(_ key: String, _ range: ClosedRange<Double>, _ fallback: CGFloat) -> CGFloat {
            guard let raw = defaults.object(forKey: key) as? Double, raw.isFinite else { return fallback }
            return CGFloat(min(max(raw, range.lowerBound), range.upperBound))
        }
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        value.placement = choice(DefaultsKey.snapWheelPlacement, value.placement)
        value.showsWheel = defaults.object(forKey: DefaultsKey.snapWheelShowsWheel) as? Bool ?? true
        value.size = number(DefaultsKey.snapWheelSize, sizeRange, value.size)
        value.thickness = number(DefaultsKey.snapWheelThickness, thicknessRange, value.thickness)
        value.cornerRadius = number(DefaultsKey.snapWheelCornerRadius, cornerRadiusRange, value.cornerRadius)
        value.material = choice(DefaultsKey.snapWheelMaterial, value.material)
        value.colorMode = choice(DefaultsKey.snapWheelColorMode, value.colorMode)
        value.color = defaults.string(forKey: DefaultsKey.snapWheelColor) ?? value.color
        value.gradientColor = defaults.string(forKey: DefaultsKey.snapWheelGradientColor) ?? value.gradientColor
        value.previewEnabled = defaults.object(forKey: DefaultsKey.snapWheelPreviewEnabled) as? Bool ?? true
        value.previewMaterial = choice(DefaultsKey.snapWheelPreviewMaterial, value.previewMaterial)
        value.previewPadding = number(DefaultsKey.snapWheelPreviewPadding, previewPaddingRange, value.previewPadding)
        value.previewCornerRadius = number(DefaultsKey.snapWheelPreviewCornerRadius, previewCornerRadiusRange,
                                           value.previewCornerRadius)
        value.previewBorder = number(DefaultsKey.snapWheelPreviewBorder, previewBorderRange, value.previewBorder)
        value.previewTint = Double(number(DefaultsKey.snapWheelPreviewTint, 0...1, CGFloat(value.previewTint)))
        value.previewStart = choice(DefaultsKey.snapWheelPreviewStart, value.previewStart)
        value.animation = choice(DefaultsKey.snapWheelAnimation, value.animation)
        value.haptics = defaults.object(forKey: DefaultsKey.snapWheelHaptics) as? Bool ?? true
        return value
    }
}

enum SnapWheelSupport {
    static let title = "Snap Wheel"
    static let hubDescription = "Hold Control and move the pointer to snap the focused window to a half, a third, a corner or the whole screen, with a live preview."

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.snapWheelEnabled: true,
        DefaultsKey.snapWheelTrigger: SnapWheelTrigger.default.keys.storageValue,
        DefaultsKey.snapWheelTriggerEitherSide: false,
        DefaultsKey.snapWheelPlacement: SnapWheelPlacement.pointer.rawValue,
        DefaultsKey.snapWheelShowsWheel: true,
        DefaultsKey.snapWheelSize: 100.0,
        DefaultsKey.snapWheelThickness: 22.0,
        DefaultsKey.snapWheelCornerRadius: 50.0,
        DefaultsKey.snapWheelMaterial: SnapWheelMaterial.glass.rawValue,
        DefaultsKey.snapWheelColorMode: SnapWheelColorMode.system.rawValue,
        DefaultsKey.snapWheelColor: "#0A84FF",
        DefaultsKey.snapWheelGradientColor: "#64D2FF",
        DefaultsKey.snapWheelPreviewEnabled: true,
        DefaultsKey.snapWheelPreviewMaterial: SnapWheelPreviewMaterial.frosted.rawValue,
        DefaultsKey.snapWheelPreviewPadding: 0.0,
        DefaultsKey.snapWheelPreviewCornerRadius: 16.0,
        DefaultsKey.snapWheelPreviewBorder: 2.0,
        DefaultsKey.snapWheelPreviewTint: 0.2,
        DefaultsKey.snapWheelPreviewStart: SnapWheelPreviewStart.screenCenter.rawValue,
        DefaultsKey.snapWheelAnimation: SnapWheelAnimation.fluid.rawValue,
        DefaultsKey.snapWheelHaptics: true,
        DefaultsKey.snapWheelTarget: SnapWheelTargetChoice.focused.rawValue,
        DefaultsKey.snapWheelScreen: SnapWheelScreenChoice.pointer.rawValue,
        DefaultsKey.snapWheelSensitivity: 0.7,
        DefaultsKey.snapWheelRecenter: true,
        DefaultsKey.snapWheelRestDelay: 0.3,
        DefaultsKey.snapWheelCircle: true,
    ]

    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

// MARK: - Loop import

/// Reads Loop's preferences (com.MrKai77.Loop) into the wheel's own. Only
/// what has a counterpart comes over; the rest keeps its value.
enum SnapWheelLoopImport {
    static let bundleID = "com.MrKai77.Loop"

    static let directions: [String: String] = [
        "Maximize": "maximize", "AlmostMaximize": "marginMaximize", "Fullscreen": "fullScreen",
        "Undo": "restore", "Minimize": SnapWheelActionID.minimize, "Hide": SnapWheelActionID.hide,
        "MacOSCenter": "center", "Center": "center",
        "TopHalf": "topHalf", "RightHalf": "rightHalf", "BottomHalf": "bottomHalf", "LeftHalf": "leftHalf",
        "HorizontalCenterHalf": "centerHalf",
        "TopLeftQuarter": "topLeft", "TopRightQuarter": "topRight",
        "BottomRightQuarter": "bottomRight", "BottomLeftQuarter": "bottomLeft",
        "RightThird": "rightThird", "RightTwoThirds": "rightTwoThirds", "HorizontalCenterThird": "centerThird",
        "LeftThird": "leftThird", "LeftTwoThirds": "leftTwoThirds",
        "TopThird": "topThird", "TopTwoThirds": "topTwoThirds", "VerticalCenterThird": "middleThird",
        "BottomThird": "bottomThird", "BottomTwoThirds": "bottomTwoThirds",
        "FirstFourth": "leftQuarter", "SecondFourth": "leftMiddleQuarter",
        "ThirdFourth": "rightMiddleQuarter", "FourthFourth": "rightQuarter",
        "NextScreen": "nextDisplay", "PreviousScreen": "previousDisplay",
    ]

    static let slotKeys: [SnapWheelSlot: String] = [
        .top: "radialMenuTop", .topRight: "radialMenuTopRight", .right: "radialMenuRight",
        .bottomRight: "radialMenuBottomRight", .bottom: "radialMenuBottom",
        .bottomLeft: "radialMenuBottomLeft", .left: "radialMenuLeft", .topLeft: "radialMenuTopLeft",
        .center: "radialMenuCenter",
    ]

    /// Loop stores the trigger as virtual key codes.
    static let keyCodes: [Int: SnapWheelTriggerKeys] = [
        59: .leftControl, 62: .rightControl, 58: .leftOption, 61: .rightOption,
        55: .leftCommand, 54: .rightCommand, 56: .leftShift, 60: .rightShift, 63: .function, 179: .function,
    ]

    /// One radial menu entry: a single action or a cycle of them.
    static func actions(fromSlotJSON raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let direction = object["direction"] as? String
        else { return nil }
        if direction == "Cycle" {
            let items = object["cycle"] as? [[String: Any]] ?? []
            return items.compactMap { ($0["direction"] as? String).flatMap { directions[$0] } }
        }
        return directions[direction].map { [$0] } ?? []
    }

    /// `[colorSpaceName, [r, g, b, a]]`, the way Loop archives a color.
    static func hexColor(_ value: Any?) -> String? {
        guard let parts = value as? [Any], parts.count >= 2,
              let components = parts[1] as? [Any], components.count >= 3
        else { return nil }
        let numbers = components.prefix(3).compactMap { item -> Double? in
            if let number = item as? NSNumber { return number.doubleValue }
            if let text = item as? String { return Double(text) }
            return nil
        }
        guard numbers.count == 3 else { return nil }
        return SnapWheelSupport.hex(red: numbers[0], green: numbers[1], blue: numbers[2])
    }

    /// The preferences to write. Window gaps go to Window Layout's own keys,
    /// which the wheel shares.
    static func preferences(from loop: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        func number(_ key: String) -> Double? {
            if let value = loop[key] as? NSNumber { return value.doubleValue }
            if let text = loop[key] as? String { return Double(text) }
            return nil
        }
        func bool(_ key: String) -> Bool? { (loop[key] as? NSNumber)?.boolValue }

        if let codes = loop["trigger"] as? [NSNumber] {
            let keys = codes.reduce(into: SnapWheelTriggerKeys()) { keys, code in
                if let key = keyCodes[code.intValue] { keys.insert(key) }
            }
            if keys.isUsableTrigger {
                result[DefaultsKey.snapWheelTrigger] = keys.storageValue
                result[DefaultsKey.snapWheelTriggerEitherSide] = !(bool("sideDependentTriggerKey") ?? false)
            }
        }

        var slots = SnapWheelSlots.defaults
        var foundSlot = false
        for (slot, key) in slotKeys {
            if let raw = loop[key] as? String, let actions = actions(fromSlotJSON: raw) {
                slots[slot] = actions
                foundSlot = true
            }
        }
        if foundSlot { result[DefaultsKey.snapWheelSlots] = SnapWheelSlots.encode(slots) }

        if let center = bool("lockRadialMenuToCenter") {
            result[DefaultsKey.snapWheelPlacement] = (center ? SnapWheelPlacement.screenCenter
                                                             : SnapWheelPlacement.pointer).rawValue
        }
        if let visible = bool("radialMenuVisibility") { result[DefaultsKey.snapWheelShowsWheel] = visible }
        // Loop's ring is always 100 points across.
        if let radius = number("radialMenuCornerRadius") {
            result[DefaultsKey.snapWheelSize] = 100.0
            result[DefaultsKey.snapWheelCornerRadius] = min(max(radius, 0), 50)
        }
        if let thickness = number("radialMenuThickness") {
            result[DefaultsKey.snapWheelThickness] = min(max(thickness, 4), 40)
        }

        if let mode = number("accentColorMode") {
            let useGradient = bool("useGradient") ?? false
            if Int(mode) == 2, let color = hexColor(loop["customAccentColor"]) {
                result[DefaultsKey.snapWheelColor] = color
                if useGradient, let second = hexColor(loop["gradientColor"]) {
                    result[DefaultsKey.snapWheelGradientColor] = second
                    result[DefaultsKey.snapWheelColorMode] = SnapWheelColorMode.gradient.rawValue
                } else {
                    result[DefaultsKey.snapWheelColorMode] = SnapWheelColorMode.custom.rawValue
                }
            } else {
                result[DefaultsKey.snapWheelColorMode] = SnapWheelColorMode.system.rawValue
            }
        }

        if let visible = bool("previewVisibility") { result[DefaultsKey.snapWheelPreviewEnabled] = visible }
        if let padding = number("previewPadding") { result[DefaultsKey.snapWheelPreviewPadding] = min(max(padding, 0), 40) }
        if let radius = number("previewCornerRadius") {
            result[DefaultsKey.snapWheelPreviewCornerRadius] = min(max(radius, 0), 40)
        }
        if let border = number("previewBorderThickness") { result[DefaultsKey.snapWheelPreviewBorder] = min(max(border, 0), 8) }
        if let tint = number("previewBackgroundAccentOpacity") { result[DefaultsKey.snapWheelPreviewTint] = min(max(tint, 0), 1) }
        if let blur = bool("previewBackgroundEnableBlur") {
            result[DefaultsKey.snapWheelPreviewMaterial] = (blur ? SnapWheelPreviewMaterial.frosted
                                                                 : SnapWheelPreviewMaterial.tint).rawValue
        }
        if let start = loop["previewStartingPosition"] as? String {
            let mapped: SnapWheelPreviewStart = switch start {
            case "radialMenu": .wheel
            case "actionCenter": .target
            default: .screenCenter
            }
            result[DefaultsKey.snapWheelPreviewStart] = mapped.rawValue
        }
        if let animation = number("animationConfiguration") {
            let mapped: SnapWheelAnimation = switch Int(animation) {
            case 0, 1: .fluid
            case 4: .instant
            default: .snappy
            }
            result[DefaultsKey.snapWheelAnimation] = mapped.rawValue
        }
        if let haptics = bool("hapticFeedback") { result[DefaultsKey.snapWheelHaptics] = haptics }
        if let underCursor = bool("resizeWindowUnderCursor") {
            result[DefaultsKey.snapWheelTarget] = (underCursor ? SnapWheelTargetChoice.underPointer
                                                               : SnapWheelTargetChoice.focused).rawValue
        }
        if let withCursor = bool("useScreenWithCursor") {
            result[DefaultsKey.snapWheelScreen] = (withCursor ? SnapWheelScreenChoice.pointer
                                                              : SnapWheelScreenChoice.window).rawValue
        }

        if bool("enablePadding") == true, let raw = loop["padding"] as? String, let data = raw.data(using: .utf8),
           let padding = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func value(_ key: String) -> Double { (padding[key] as? NSNumber)?.doubleValue ?? 0 }
            result[DefaultsKey.windowLayoutWindowGap] = nearestGapPreset(value("window"))
            let edge = ["top", "bottom", "left", "right"].map(value).max() ?? 0
            result[DefaultsKey.windowLayoutScreenGap] = nearestGapPreset(edge)
        }
        return result
    }

    /// Window Layout offers gaps in steps; Loop's free value lands on the nearest.
    static func nearestGapPreset(_ value: Double, presets: [Int] = [0, 8, 16, 32, 64, 128]) -> Int {
        presets.min { abs(Double($0) - value) < abs(Double($1) - value) } ?? 0
    }
}
