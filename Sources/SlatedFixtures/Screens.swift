import Foundation

@testable import SlatedCore

/// A display arrangement plus some windows on it (top-left global coordinates).
struct ScreenSetup {
  var name: String
  var description: String
  var screens: [ScreenInfo]
  var windows: [(String, CGRect)]
  /// Settings variations to run on this setup (names from `settingsVariants`).
  var settings: [String]

  var json: J {
    [
      "description": .string(description), "screens": .array(screens.map(screenJ)),
      "windows": .object(Dictionary(uniqueKeysWithValues: windows.map { ($0.0, rectJ($0.1)) })),
      "windowOrder": .array(windows.map { .string($0.0) }),
    ]
  }
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
  CGRect(x: x, y: y, width: width, height: height)
}

private func screen(
  _ id: UInt32, _ name: String, _ frame: CGRect, _ visible: CGRect, main: Bool = false, scale: Double = 2
) -> ScreenInfo {
  ScreenInfo(displayID: id, name: name, frame: frame, visibleFrame: visible, isMain: main, scale: scale)
}

let allSettingsVariants = [
  "default", "resizePercentOfWindow", "nudgePercentOfWindow", "osOrder", "defaultToCurrent", "allFlipped", "stringly",
]

/// Slate settings variations (the `config` values FrameCalculator and ScreenResolver read).
let settingsVariants: [String: [String: SettingValue]] = [
  "default": [:],
  "resizePercentOfWindow": ["resizePercentOf": .string("windowSize")],
  "nudgePercentOfWindow": ["nudgePercentOf": .string("windowSize")],
  "osOrder": ["orderScreensLeftToRight": .bool(false)],
  "defaultToCurrent": ["defaultToCurrentScreen": .bool(true)],
  "allFlipped": [
    "resizePercentOf": .string("windowSize"), "nudgePercentOf": .string("windowSize"),
    "orderScreensLeftToRight": .bool(false), "defaultToCurrentScreen": .bool(true),
  ],
  // Values as a hand-edited file or a .slate `config` line may give them: booleans as text or
  // numbers, and spellings that don't match exactly.
  "stringly": [
    "resizePercentOf": .string("bogus"), "nudgePercentOf": .string("WindowSize"),
    "orderScreensLeftToRight": .number(0), "defaultToCurrentScreen": .string("YES"),
  ],
]

let screenSetups: [ScreenSetup] = [
  ScreenSetup(
    name: "four",
    description:
      "FrameCalculatorTests' layout: main 1440×900 with menu bar and Dock; a 2560×1440 on the right; a 1920×1080 "
      + "above at negative y; a 1080×1920 portrait on the left. OS order main, right, above, portrait.",
    screens: [
      screen(1, "Built-in", rect(0, 0, 1440, 900), rect(0, 25, 1440, 815), main: true),
      screen(2, "Right", rect(1440, 0, 2560, 1440), rect(1440, 25, 2560, 1415)),
      screen(3, "Above", rect(-240, -1080, 1920, 1080), rect(-240, -1055, 1920, 1055)),
      screen(4, "Portrait", rect(-1080, 0, 1080, 1920), rect(-1080, 25, 1080, 1895)),
    ],
    windows: [
      ("onMain", rect(100, 100, 800, 600)), ("onRight", rect(2000, 100, 800, 600)),
      ("onPortrait", rect(-1000, 300, 600, 800)), ("onAbove", rect(0, -900, 800, 600)),
      ("straddle", rect(1300, 100, 800, 600)),
    ],
    settings: allSettingsVariants),
  ScreenSetup(
    name: "single",
    description: "One 1440×900 display with menu bar and Dock.",
    screens: [screen(1, "Built-in", rect(0, 0, 1440, 900), rect(0, 25, 1440, 815), main: true)],
    windows: [
      ("onMain", rect(100, 100, 800, 600)), ("offscreen", rect(5000, 5000, 100, 100)),
      ("fractional", rect(10.7, -20.5, 300.9, 200.4)),
    ],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "aboveMain",
    description: "A notched laptop (38-point menu bar) with a 2560×1440 display above it, at negative y.",
    screens: [
      screen(1, "MacBook", rect(0, 0, 1512, 982), rect(0, 38, 1512, 944), main: true),
      screen(5, "Studio Display", rect(-204, -1440, 2560, 1440), rect(-204, -1415, 2560, 1415)),
    ],
    windows: [("onMain", rect(200, 150, 900, 600)), ("onAbove", rect(100, -1200, 1200, 800))],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "portraitLeft",
    description: "A 1920×1080 main display with the Dock on the left, and a portrait display on its left, shifted up.",
    screens: [
      screen(1, "Desk", rect(0, 0, 1920, 1080), rect(80, 25, 1840, 1055), main: true),
      screen(6, "Portrait", rect(-1080, -420, 1080, 1920), rect(-1080, -395, 1080, 1895), scale: 1),
    ],
    windows: [("onMain", rect(300, 200, 1000, 700)), ("onPortrait", rect(-900, 0, 700, 1200))],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "rightExternal",
    description: "A 1728×1117 laptop and a 1920×1080 external display on its right, 100 points higher.",
    screens: [
      screen(1, "Built-in", rect(0, 0, 1728, 1117), rect(0, 32, 1728, 1085), main: true),
      screen(7, "External", rect(1728, -100, 1920, 1080), rect(1728, -75, 1920, 1055), scale: 1),
    ],
    windows: [("onMain", rect(100, 100, 800, 600)), ("onRight", rect(2000, 0, 900, 700))],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "cornerOnly",
    description:
      "Displays that only meet at corners (ScreenResolverTests), so directions fall back to the nearest screen.",
    screens: [
      screen(1, "Built-in", rect(0, 0, 1440, 900), rect(0, 25, 1440, 815), main: true),
      screen(20, "Corner", rect(1440, 900, 1920, 1080), rect(1440, 925, 1920, 1055)),
      screen(21, "Far", rect(3360, 1980, 1920, 1080), rect(3360, 2005, 1920, 1055)),
    ],
    windows: [("onMain", rect(100, 100, 800, 600)), ("onCorner", rect(2000, 1000, 400, 300))],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "gnome",
    description:
      "A GNOME-like arrangement: a primary display with a 32-pixel top bar, a scaled display on the right with no "
      + "panel, and a laptop below; fractional window coordinates.",
    screens: [
      screen(1, "DP-1", rect(0, 0, 1920, 1080), rect(0, 32, 1920, 1048), main: true, scale: 1),
      screen(2, "HDMI-1", rect(1920, 0, 2560, 1440), rect(1920, 0, 2560, 1440), scale: 1.5),
      screen(3, "eDP-1", rect(320, 1080, 1280, 800), rect(320, 1080, 1280, 800), scale: 1.25),
    ],
    windows: [("onPrimary", rect(100.5, 100.25, 800.75, 600.5)), ("onSecondary", rect(2000, 300, 1200, 900))],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "starterTests",
    description: "StarterTests' screens: a wide 1800×1000 display and a tall 1000×1800 one on its right, no menu bar.",
    screens: [
      screen(1, "Wide", rect(0, 0, 1800, 1000), rect(0, 0, 1800, 1000), main: true),
      screen(2, "Tall", rect(1800, 0, 1000, 1800), rect(1800, 0, 1000, 1800)),
    ],
    windows: [("wide", rect(100, 100, 400, 400)), ("tall", rect(2000, 100, 400, 400))],
    settings: ["default", "allFlipped"]),
  ScreenSetup(
    name: "empty",
    description: "No displays at all (e.g. while displays reconfigure).",
    screens: [],
    windows: [("onMain", rect(100, 100, 800, 600))],
    settings: ["default", "resizePercentOfWindow"]),
]

private let refInputs: [String?] = [
  nil, "0", "1", "2", "3", "4", "9", "-1", "-2", "ordered:0", "ordered:1", "ordered:2", "ordered:3", "ordered:4",
  "ordered:-1", "ordered:-2", "1440x900", "2560x1440", "1920x1080", "1080x1920", "1440x815", "800x600", "1512x982",
  "left", "right", "up", "down", "next", "previous",
]

private let refParseInputs: [String] = [
  "0", "1", "-1", "+2", "01", " 3 ", "ordered:1", "ORDERED:2", "ordered:-1", "ordered:", "ordered:x", "ordered: 1",
  "1920x1080", "1920X1080", "1920xx1080", "x1920x1080", "1920x1080x", "1x", "x1080", "1920x1080x1", "-1x-1",
  "+1x+1", "0x0", "left", "LEFT", "right", "up", "top", "above", "down", "bottom", "below", "next", "NEXT",
  "previous", "prev", "Prev", "", " ", "bogus", "１", "99999999999999999999", "9223372036854775807",
  "-9223372036854775808", "9223372036854775808", "1.5", "0x10", "\t2\t", "next ", "le ft",
]

/// The screens a fixture case can name, by display name.
private func screenName(_ s: ScreenInfo?) -> J { s.map { .string($0.name) } ?? .null }

func screenFixtures() -> FixtureFile {
  let parse: [J] = refParseInputs.map { input in
    ["input": .string(input), "ref": ScreenRef(slate: input).map { .string($0.slate) } ?? .null]
  }

  var resolve: [J] = []
  for setup in screenSetups {
    for (windowName, window) in setup.windows {
      for settingsName in ["default", "osOrder", "defaultToCurrent", "allFlipped"] {
        let settings = SlateSettings(settingsVariants[settingsName]!)
        var results: [String: J] = [:]
        for raw in refInputs {
          let ref = raw.flatMap { ScreenRef(slate: $0) }
          precondition(raw == nil || ref != nil)
          results[raw ?? "(none)"] = screenName(
            ScreenResolver.screen(for: ref, windowFrame: window, screens: setup.screens, settings: settings))
        }
        resolve.append([
          "setup": .string(setup.name), "window": .string(windowName), "settings": .string(settingsName),
          "results": .object(results),
        ])
      }
    }
  }

  var ordered: [J] = []
  for setup in screenSetups {
    ordered.append([
      "setup": .string(setup.name), "names": .array(setup.screens.orderedLeftToRight().map { .string($0.name) }),
    ])
  }
  // Screens sharing an x: the lower one first (ScreenResolverTests).
  let main = screenSetups[0].screens[0]
  let top = ScreenInfo(
    displayID: 10, name: "Top", frame: CGRect(x: 0, y: -1080, width: 1440, height: 1080),
    visibleFrame: CGRect(x: 0, y: -1055, width: 1440, height: 1055), isMain: false)
  let twin = ScreenInfo(
    displayID: 11, name: "Twin", frame: main.frame, visibleFrame: main.visibleFrame, isMain: false)
  var extraOrders: [J] = []
  for list in [[main, top], [top, main], [top, twin, main], [twin, main, top]] {
    extraOrders.append([
      "screens": .array(list.map(screenJ)), "names": .array(list.orderedLeftToRight().map { .string($0.name) }),
    ])
  }

  var containing: [J] = []
  let probeRects: [CGRect] = [
    CGRect(x: 100, y: 100, width: 800, height: 600), CGRect(x: 1300, y: 100, width: 800, height: 600),
    CGRect(x: -200, y: -500, width: 400, height: 300), CGRect(x: -300, y: -100, width: 400, height: 300),
    CGRect(x: 5000, y: 5000, width: 100, height: 100), CGRect(x: 1440, y: 0, width: 0, height: 100),
    CGRect(x: 1390, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 0, height: 0),
    CGRect(x: -1080, y: -1080, width: 5000, height: 4000), CGRect(x: 1439.5, y: 899.5, width: 1, height: 1),
    CGRect(x: 500, y: 500, width: -200, height: -200),
  ]
  for setup in screenSetups {
    for probe in probeRects {
      containing.append([
        "setup": .string(setup.name), "rect": rectJ(probe),
        "screen": screenName(setup.screens.screen(containing: probe)),
      ])
    }
  }

  return FixtureFile(
    name: "screens.json",
    description:
      "ScreenRef(slate:) parsing (canonical text or null), ScreenResolver.screen for every kind of reference on each "
      + "setup, window and settings variation (screen name or null), Slate's left-to-right ordering, and the screen "
      + "holding most of a rectangle.",
    sections: [
      "parse": parse, "resolve": resolve, "orderedLeftToRight": ordered + extraOrders, "containing": containing,
    ],
    extra: [
      "setups": .object(Dictionary(uniqueKeysWithValues: screenSetups.map { ($0.name, $0.json) })),
      "settings": .object(settingsVariants.mapValues { settingsJ(SlateSettings($0)) }),
    ],
    depth: ["resolve": 2, "setups": 3])
}
