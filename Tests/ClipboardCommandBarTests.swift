// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: the clipboard in the Command Bar. Rows map back to their items,
/// ages stay short, a pick pastes only where there is a text field, and the
/// island drops its tab only when the setting is on.
enum ClipboardCommandBarTests {
    static func run(_ suite: TestSuite) {
        let id = UUID()
        suite.expect(ClipboardCommandBar.entryID(forRowID: "clipboard.\(id.uuidString)") == id,
                     "a clipboard row leads back to its item")
        suite.expect(ClipboardCommandBar.entryID(forRowID: "action.clipboardWindow") == nil
                        && ClipboardCommandBar.entryID(forRowID: "clipboard.nonsense") == nil,
                     "other rows are not clipboard items")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let locale = Locale(identifier: "en_US")
        func age(_ seconds: TimeInterval) -> String {
            ClipboardCommandBar.age(of: now.addingTimeInterval(-seconds), now: now,
                                    calendar: calendar, locale: locale)
        }
        suite.expect(age(5) == "now" && age(-30) == "now", "the last minute is now")
        suite.expect(age(5 * 60) == "5m" && age(3 * 3600 + 59) == "3h" && age(2 * 86_400) == "2d",
                     "recent items show minutes, hours and days")
        suite.expect(age(30 * 86_400).contains("Dec") || age(30 * 86_400).contains("Nov"),
                     "older items show the day")

        suite.expect(ClipboardCommandBar.acceptsText(role: "AXTextArea", subrole: nil,
                                                    caretSettable: false, valueSettable: false, editableAncestor: false),
                     "a text area takes a paste")
        suite.expect(ClipboardCommandBar.acceptsText(role: "AXGroup", subrole: nil,
                                                    caretSettable: false, valueSettable: false, editableAncestor: true),
                     "editable web content takes a paste")
        suite.expect(!ClipboardCommandBar.acceptsText(role: "AXOutline", subrole: nil,
                                                     caretSettable: false, valueSettable: false, editableAncestor: false)
                        && !ClipboardCommandBar.acceptsText(role: nil, subrole: nil,
                                                            caretSettable: false, valueSettable: false, editableAncestor: false),
                     "a list, or nothing focused, gets a copy instead")
        suite.expect(!ClipboardCommandBar.acceptsText(role: "AXWebArea", subrole: nil,
                                                     caretSettable: true, valueSettable: false,
                                                     editableAncestor: false)
                        && ClipboardCommandBar.acceptsText(role: "AXGroup", subrole: nil,
                                                          caretSettable: true, valueSettable: true,
                                                          editableAncestor: false),
                     "a caret pastes only where the text can be changed")

        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.clipboardCommandBar")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.clipboardCommandBar")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.clipboardCommandBar") }
        suite.expect(!ClipboardCommandBar.isOn(in: defaults), "unset keeps upstream's behavior")
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        let before = NotchSupport.modules(in: defaults).contains(.clipboard)
        defaults.set(true, forKey: DefaultsKey.clipboardInCommandBar)
        suite.expect(!NotchSupport.modules(in: defaults).contains(.clipboard),
                     "the island drops its clipboard tab")
        defaults.set(false, forKey: DefaultsKey.clipboardInCommandBar)
        suite.expect(NotchSupport.modules(in: defaults).contains(.clipboard) == before,
                     "turning it off brings the tab back")
    }
}
