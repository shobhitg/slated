import Foundation
import SlatedCore

/// Sample data for `PreviewServices`: a Hyper-key setup like the author's, a `~/.slate.js` with
/// read-only bindings, two displays (one portrait) and a few hotstrings.
enum PreviewData {
  // MARK: Screens

  static let screens: [ScreenInfo] = [
    ScreenInfo(
      displayID: 1, name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
      visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1340), isMain: true),
    ScreenInfo(
      displayID: 2, name: "DELL U2723QE", frame: CGRect(x: 2560, y: -560, width: 1440, height: 2560),
      visibleFrame: CGRect(x: 2560, y: -535, width: 1440, height: 2535), isMain: false),
  ]

  // MARK: Slated bindings

  private static func hyper(_ key: String) -> KeyCombo { KeyCombo(key: key, modifiers: .hyper) }
  private static func preset(_ id: String) -> Action { WindowPresets.preset(id).action }
  private static func half(_ corner: Corner) -> Action {
    .corner(corner, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)
  }

  static var bindings: [HotkeyBinding] {
    [
      HotkeyBinding(
        name: "Left Half", keys: hyper("left"),
        action: .push(direction: .left, style: .barResize("screenSizeX/2"), screen: nil)),
      HotkeyBinding(
        name: "Right Half", keys: hyper("right"),
        action: .push(direction: .right, style: .barResize("screenSizeX/2"), screen: nil)),
      HotkeyBinding(name: "Top Half", keys: hyper("up"), action: preset("top-half")),
      HotkeyBinding(name: "Bottom Half", keys: hyper("down"), action: preset("bottom-half")),
      HotkeyBinding(name: "Top Left", keys: hyper("u"), action: half(.topLeft)),
      HotkeyBinding(name: "Top Right", keys: hyper("i"), action: half(.topRight)),
      HotkeyBinding(name: "Bottom Left", keys: hyper("j"), action: half(.bottomLeft)),
      HotkeyBinding(name: "Bottom Right", keys: hyper("k"), action: half(.bottomRight)),
      HotkeyBinding(name: "Left Third", keys: hyper("d"), action: preset("left-third")),
      HotkeyBinding(name: "Center Third", keys: hyper("f"), action: preset("center-third")),
      HotkeyBinding(name: "Right Third", keys: hyper("g"), action: preset("right-third")),
      HotkeyBinding(name: "Left Two Thirds", keys: hyper("e"), action: preset("left-two-thirds")),
      HotkeyBinding(name: "Right Two Thirds", keys: hyper("t"), action: preset("right-two-thirds")),
      HotkeyBinding(name: "Center", keys: hyper("c"), action: preset("center")),
      HotkeyBinding(keys: hyper("return"), action: preset("maximize")),
      HotkeyBinding(name: "Almost Maximize", keys: hyper("m"), action: preset("almost-maximize")),
      HotkeyBinding(name: "Center Large", keys: hyper("m"), action: preset("center-large")),
      HotkeyBinding(name: "Next Display", keys: hyper("n"), action: preset("throw-next")),
      HotkeyBinding(name: "Previous Display", keys: hyper("p"), action: preset("throw-previous")),
      HotkeyBinding(name: "Cycle Left", keys: hyper("["), action: .chain(WindowPresets.defaultChain)),
      HotkeyBinding(name: "Window Hints", keys: hyper("space"), action: .hint(characters: nil)),
      HotkeyBinding(name: "Coding Layout", keys: hyper("1"), action: .layout(name: "Coding")),
      HotkeyBinding(name: "Focus Safari", keys: hyper("s"), action: .focusApp("Safari")),
      HotkeyBinding(name: "Undo", keys: hyper("z"), action: .undo),
      HotkeyBinding(
        name: "Paste as Plain Text", keys: hyper("v"),
        action: .keystroke(KeyCombo(key: "v", modifiers: [.command, .option, .shift])), enabled: false),
    ] + automationBindings
  }

  /// Game automation: an auto-clicker on F6, and Minecraft-only holds on a side mouse button and a
  /// plain key.
  static var automationBindings: [HotkeyBinding] {
    [
      HotkeyBinding(
        name: "Auto-Click Left", keys: KeyCombo(key: "f6"),
        action: .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle)),
      HotkeyBinding(
        name: "Hold W (Auto-Run)", keys: KeyCombo(key: "mouse4"), action: .hold(.key(KeyCombo(key: "w"))),
        onlyInApps: [minecraft]),
      HotkeyBinding(
        name: "Toggle Sprint (Shift)", keys: KeyCombo(key: "r"), action: .hold(.key(KeyCombo(key: "shift"))),
        onlyInApps: [minecraft]),
    ]
  }

  static let minecraft = "com.mojang.minecraft"

  /// The binding the "failed" status is reported for in the sample runtime status.
  static let failedKey = "hyper+space"

  // MARK: Hotstrings

  static var hotstrings: [Hotstring] {
    [
      Hotstring(trigger: ";shrug", replacement: "¯\\_(ツ)_/¯"),
      Hotstring(trigger: ";email", replacement: "hello@example.com"),
      Hotstring(
        trigger: ";sig", replacement: "Thanks,\nSam\n\nSent with Slated", onlyInApps: ["com.apple.mail"],
        notes: "Mail only — other apps have their own signatures."),
      Hotstring(
        trigger: "teh", replacement: "the", caseSensitive: false, fire: .afterDelimiter, wordBoundary: true,
        notes: "Autocorrect for the classic typo."),
      Hotstring(
        trigger: ";lgtm", replacement: "Looks good to me — ship it! 🚀", method: .paste,
        exceptInApps: ["com.apple.Terminal"]),
      Hotstring(trigger: ";tm", replacement: "™"),
      Hotstring(trigger: ";addr", replacement: "221B Baker Street\nLondon NW1 6XE", fire: .afterDelimiter),
      Hotstring(trigger: ";meet", replacement: "Could we find 30 minutes this week?", enabled: false),
    ]
  }

  // MARK: Layouts

  static var layouts: [Layout] {
    [
      Layout(
        name: "Coding",
        apps: [
          LayoutApp(app: "Xcode", operations: [preset("left-two-thirds")]),
          LayoutApp(app: "Safari", operations: [preset("right-third")]),
          LayoutApp(
            app: "Terminal",
            operations: [
              .move(
                x: "screenOriginX", y: "screenOriginY", width: "screenSizeX", height: "screenSizeY/2",
                screen: .index(1))
            ],
            options: {
              var o = LayoutAppOptions(); o.ignoreFail = true; return o
            }()),
          LayoutApp(
            app: "Slack",
            operations: [
              .move(
                x: "screenOriginX", y: "screenOriginY+screenSizeY/2", width: "screenSizeX", height: "screenSizeY/2",
                screen: .index(1))
            ]),
        ])
    ]
  }

  static var sourceLayouts: [Layout] {
    [
      Layout(
        name: "Writing",
        apps: [
          LayoutApp(app: "iA Writer", operations: [preset("center-large")]),
          LayoutApp(
            app: "Safari", operations: [.throwWindow(screen: .index(1), width: "screenSizeX", height: "screenSizeY")]),
        ]),
      Layout(
        name: "Meeting",
        apps: [
          LayoutApp(app: "zoom.us", operations: [preset("left-two-thirds")]),
          LayoutApp(app: "Notes", operations: [preset("right-third")]),
        ], after: [.focusApp("zoom.us")]),
    ]
  }

  // MARK: ~/.slate.js

  private static func meh(_ key: String) -> KeyCombo { KeyCombo(key: key, modifiers: [.control, .option, .command]) }
  private static func turning(_ id: String) -> Action { WindowPresets.orientation.first { $0.id == id }!.action }

  /// A ~/.slate.js as the import converts it: its static operations and the functions it could
  /// describe by trying them become shortcuts; two functions that need JavaScript don't.
  static var slateImport: SlateImport {
    let modal = ModalKey(keys: KeyCombo(key: "f4", modifiers: [.control]))
    let bindings: [(KeyCombo, ModalKey?, Action)] = [
      (meh("left"), nil, .push(direction: .left, style: .barResize("screenSizeX/2"), screen: nil)),
      (meh("right"), nil, .push(direction: .right, style: .barResize("screenSizeX/2"), screen: nil)),
      (meh("up"), nil, .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil)),
      (meh("down"), nil, .push(direction: .down, style: .barResize("screenSizeY/2"), screen: nil)),
      (meh("return"), nil, turning("middle-third")),
      (meh("1"), nil, .throwWindow(screen: .index(0), width: "screenSizeX", height: "screenSizeY")),
      (meh("2"), nil, .throwWindow(screen: .index(1), width: "screenSizeX", height: "screenSizeY")),
      (meh("h"), nil, .hint(characters: nil)),
      (meh("z"), nil, .undo),
      (meh("x"), nil, .focusApp("Xcode")),
      (hyper("c"), nil, .corner(.bottomRight, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)),
      (KeyCombo(key: "1"), modal, .layout(name: "Writing")),
      (KeyCombo(key: "2"), modal, .layout(name: "Meeting")),
    ]
    return SlateImport(
      files: ["~/.slate.js"],
      bindings: bindings.map { HotkeyBinding(keys: $0.0, modal: $0.1, action: $0.2) },
      layouts: sourceLayouts,
      windows: SlateSettings(["nudgePercentOf": .string("screenSize")]),
      notConverted: [
        SlateImport.Item("ctrl+alt+cmd+t", "depends on the focused app or window title"),
        SlateImport.Item("alt+tab", "uses JavaScript logic Slated can't express without a script"),
      ])
  }

  // MARK: Running apps

  static let runningApps: [AppInfo] = [
    AppInfo(name: "Finder", bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app"),
    AppInfo(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app"),
    AppInfo(name: "Mail", bundleID: "com.apple.mail", path: "/System/Applications/Mail.app"),
    AppInfo(name: "Messages", bundleID: "com.apple.MobileSMS", path: "/System/Applications/Messages.app"),
    AppInfo(name: "Notes", bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app"),
    AppInfo(name: "Calendar", bundleID: "com.apple.iCal", path: "/System/Applications/Calendar.app"),
    AppInfo(name: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app"),
    AppInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app"),
    AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", path: "/Applications/Slack.app"),
    AppInfo(name: "Music", bundleID: "com.apple.Music", path: "/System/Applications/Music.app"),
    AppInfo(name: "Minecraft", bundleID: minecraft, path: "/Applications/Minecraft.app"),
  ]

  // MARK: Clipboard

  /// A varied history: links, code, a color, an address (pinned) and plain text, from minutes to
  /// days ago, relative to `now` so relative times read naturally.
  static func clipboard(now: Date = Date()) -> [ClipboardItem] {
    let minute = 60.0
    let hour = 3_600.0
    let day = 86_400.0
    let samples: [(String, String?, Double, Bool)] = [
      ("https://github.com/shobhit-aida/slated", "com.apple.Safari", 40, false),
      ("Let's sync tomorrow at 10 — I'll bring the layout sketches.", "com.tinyspeck.slackmacgap", 5 * minute, false),
      ("git commit -m \"Make the author's Slate config the default\"", "com.apple.Terminal", 15 * minute, false),
      (
        "func greet(_ name: String) -> String {\n  let greeting = \"Hello, \\(name)!\"\n  return greeting\n}",
        "com.apple.dt.Xcode", 42 * minute, false
      ),
      ("1 Infinite Loop\nCupertino, CA 95014", "com.apple.Notes", 90 * minute, true),
      ("#6B5EFC", "com.apple.Safari", 2 * hour, true),
      ("hello@example.com", "com.apple.mail", 3 * hour, false),
      ("screenOriginX+screenSizeX/2", "com.apple.dt.Xcode", 26 * hour, false),
      (
        "The original Slate is GPLv3, so Slated re-derives behavior from its README and never copies code. Window math, expressions and the JavaScript API are all reimplemented and pinned by tests.",
        "com.apple.Notes", 3 * day, false
      ),
      ("~/Library/Application Support/Slated", "com.apple.finder", 6 * day, false),
      ("42.50", "com.apple.Safari", 9 * day, false),
    ]
    var items = samples.map { text, app, ago, pinned in
      ClipboardItem(text: text, copiedAt: now.addingTimeInterval(-ago), sourceApp: app, pinned: pinned)
    }
    // Two images: a screenshot copied from Safari and a photo from Preview.
    items.insert(
      ClipboardItem(
        text: "", copiedAt: now.addingTimeInterval(-8 * minute), sourceApp: "com.apple.Safari",
        image: PreviewImages.screenshot),
      at: 2)
    items.insert(
      ClipboardItem(
        text: "", copiedAt: now.addingTimeInterval(-28 * hour), sourceApp: "com.apple.Preview",
        image: PreviewImages.photo),
      at: 9)
    return items
  }

  // MARK: Automation

  /// An auto-clicker that has run for a minute and a held key, as the engine reports them.
  static func activeAutomations(now: Date = Date()) -> [ActiveAutomation] {
    [
      ActiveAutomation(
        id: "hotkey f6", title: "Repeat click left every 100 ms", trigger: "hotkey f6",
        startedAt: now.addingTimeInterval(-72), repetitions: 721),
      ActiveAutomation(
        id: "hold:key:w", title: "Hold W", trigger: "hotkey mouse4", startedAt: now.addingTimeInterval(-15),
        repetitions: 1),
    ]
  }
}
