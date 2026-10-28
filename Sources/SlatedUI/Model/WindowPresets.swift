import CoreGraphics
import SlatedCore

/// A named window placement offered in the binding editor, with a glyph region for its icon.
struct WindowPreset: Identifiable, Hashable {
  enum Group: String, CaseIterable, Identifiable {
    case halves = "Halves"
    case quarters = "Quarters"
    case thirds = "Thirds"
    case center = "Center & Fill"
    case screens = "Displays"

    var id: String { rawValue }
  }

  let id: String
  let title: String
  let group: Group
  /// The area the window covers, in unit coordinates of the screen (top-left origin). `nil` for
  /// presets that move between screens, which use `symbol` instead.
  let region: CGRect?
  let symbol: String?
  let action: Action
  /// Other spellings of the same placement (e.g. Slate's `push left bar-resize:screenSizeX/2`), so
  /// bindings written either way are recognized.
  let aliases: [Action]

  init(
    _ id: String, _ title: String, _ group: Group, region: CGRect? = nil, symbol: String? = nil,
    _ action: Action, aliases: [Action] = []
  ) {
    self.id = id
    self.title = title
    self.group = group
    self.region = region
    self.symbol = symbol
    self.action = action
    self.aliases = aliases
  }

  func matches(_ other: Action) -> Bool { other == action || aliases.contains(other) }
}

enum WindowPresets {
  private static func move(_ x: String, _ y: String, _ w: String, _ h: String) -> Action {
    .move(x: x, y: y, width: w, height: h, screen: nil)
  }

  private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
  }

  static let all: [WindowPreset] = [
    // Halves
    WindowPreset(
      "left-half", "Left Half", .halves, region: rect(0, 0, 0.5, 1),
      move("screenOriginX", "screenOriginY", "screenSizeX/2", "screenSizeY"),
      aliases: [.push(direction: .left, style: .barResize("screenSizeX/2"), screen: nil)]),
    WindowPreset(
      "right-half", "Right Half", .halves, region: rect(0.5, 0, 0.5, 1),
      move("screenOriginX+screenSizeX/2", "screenOriginY", "screenSizeX/2", "screenSizeY"),
      aliases: [.push(direction: .right, style: .barResize("screenSizeX/2"), screen: nil)]),
    WindowPreset(
      "top-half", "Top Half", .halves, region: rect(0, 0, 1, 0.5),
      move("screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY/2"),
      aliases: [.push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil)]),
    WindowPreset(
      "bottom-half", "Bottom Half", .halves, region: rect(0, 0.5, 1, 0.5),
      move("screenOriginX", "screenOriginY+screenSizeY/2", "screenSizeX", "screenSizeY/2"),
      aliases: [.push(direction: .down, style: .barResize("screenSizeY/2"), screen: nil)]),
    // Quarters
    WindowPreset(
      "top-left", "Top Left", .quarters, region: rect(0, 0, 0.5, 0.5),
      move("screenOriginX", "screenOriginY", "screenSizeX/2", "screenSizeY/2"),
      aliases: [.corner(.topLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)]),
    WindowPreset(
      "top-right", "Top Right", .quarters, region: rect(0.5, 0, 0.5, 0.5),
      move("screenOriginX+screenSizeX/2", "screenOriginY", "screenSizeX/2", "screenSizeY/2"),
      aliases: [.corner(.topRight, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)]),
    WindowPreset(
      "bottom-left", "Bottom Left", .quarters, region: rect(0, 0.5, 0.5, 0.5),
      move("screenOriginX", "screenOriginY+screenSizeY/2", "screenSizeX/2", "screenSizeY/2"),
      aliases: [.corner(.bottomLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)]),
    WindowPreset(
      "bottom-right", "Bottom Right", .quarters, region: rect(0.5, 0.5, 0.5, 0.5),
      move("screenOriginX+screenSizeX/2", "screenOriginY+screenSizeY/2", "screenSizeX/2", "screenSizeY/2"),
      aliases: [.corner(.bottomRight, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)]),
    // Thirds
    WindowPreset(
      "left-third", "Left Third", .thirds, region: rect(0, 0, 1.0 / 3, 1),
      move("screenOriginX", "screenOriginY", "screenSizeX/3", "screenSizeY")),
    WindowPreset(
      "center-third", "Center Third", .thirds, region: rect(1.0 / 3, 0, 1.0 / 3, 1),
      move("screenOriginX+screenSizeX/3", "screenOriginY", "screenSizeX/3", "screenSizeY")),
    WindowPreset(
      "right-third", "Right Third", .thirds, region: rect(2.0 / 3, 0, 1.0 / 3, 1),
      move("screenOriginX+screenSizeX*2/3", "screenOriginY", "screenSizeX/3", "screenSizeY")),
    WindowPreset(
      "left-two-thirds", "Left Two Thirds", .thirds, region: rect(0, 0, 2.0 / 3, 1),
      move("screenOriginX", "screenOriginY", "screenSizeX*2/3", "screenSizeY")),
    WindowPreset(
      "right-two-thirds", "Right Two Thirds", .thirds, region: rect(1.0 / 3, 0, 2.0 / 3, 1),
      move("screenOriginX+screenSizeX/3", "screenOriginY", "screenSizeX*2/3", "screenSizeY"),
      // Slate configs commonly write the offset of a two-thirds span as "*1/3".
      aliases: [move("screenOriginX+screenSizeX*1/3", "screenOriginY", "screenSizeX*2/3", "screenSizeY")]),
    // Center & fill
    WindowPreset(
      "center", "Center", .center, region: rect(0.25, 0.22, 0.5, 0.56),
      move(
        "screenOriginX+(screenSizeX-windowSizeX)/2", "screenOriginY+(screenSizeY-windowSizeY)/2", "windowSizeX",
        "windowSizeY")),
    WindowPreset(
      "center-large", "Center Large", .center, region: rect(1.0 / 6, 1.0 / 6, 2.0 / 3, 2.0 / 3),
      move("screenOriginX+screenSizeX/6", "screenOriginY+screenSizeY/6", "screenSizeX*2/3", "screenSizeY*2/3")),
    WindowPreset(
      "almost-maximize", "Almost Maximize", .center, region: rect(0.06, 0.06, 0.88, 0.88),
      move("screenOriginX+screenSizeX/20", "screenOriginY+screenSizeY/20", "screenSizeX*0.9", "screenSizeY*0.9")),
    WindowPreset(
      "maximize", "Maximize", .center, region: rect(0, 0, 1, 1),
      move("screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY"),
      aliases: [.corner(.topLeft, width: "screenSizeX", height: "screenSizeY", screen: nil)]),
    // Displays
    WindowPreset(
      "throw-next", "Next Display", .screens, symbol: "arrow.right.to.line.compact",
      .throwWindow(screen: .next, width: nil, height: nil)),
    WindowPreset(
      "throw-previous", "Previous Display", .screens, symbol: "arrow.left.to.line.compact",
      .throwWindow(screen: .previous, width: nil, height: nil)),
    WindowPreset(
      "throw-next-max", "Next Display, Maximized", .screens, symbol: "arrow.up.left.and.arrow.down.right",
      .throwWindow(screen: .next, width: "screenSizeX", height: "screenSizeY")),
  ]

  /// Thirds that turn with the display (`Action.byOrientation`): side by side on a landscape one,
  /// stacked on a portrait one. No single side names both, so they're named by position. `matching`
  /// finds them; the pickers offer only `all`.
  static let orientation: [WindowPreset] = [
    turning("left-third", into: "first-third", "First Third"),
    turning("center-third", into: "middle-third", "Middle Third"),
    turning("right-third", into: "last-third", "Last Third"),
    turning("left-two-thirds", into: "first-two-thirds", "First Two Thirds"),
    turning("right-two-thirds", into: "last-two-thirds", "Last Two Thirds"),
  ]

  /// A landscape preset paired with itself turned on its side for portrait displays: x and y trade
  /// places, and so do width and height (`screenSizeX/3` becomes `screenSizeY/3`).
  private static func turning(_ id: String, into newID: String, _ title: String) -> WindowPreset {
    let landscape = preset(id)
    let pairs = ([landscape.action] + landscape.aliases).compactMap { action -> Action? in
      guard case .move(let x, let y, let width, let height, let screen) = action else { return nil }
      func turn(_ expression: String) -> String { String(expression.map { $0 == "X" ? "Y" : $0 == "Y" ? "X" : $0 }) }
      let portrait = Action.move(x: turn(y), y: turn(x), width: turn(height), height: turn(width), screen: screen)
      return .byOrientation(landscape: action, portrait: portrait)
    }
    return WindowPreset(newID, title, .thirds, region: landscape.region, pairs[0], aliases: Array(pairs.dropFirst()))
  }

  static func preset(_ id: String) -> WindowPreset { all.first { $0.id == id }! }

  private static let matchable = all + orientation

  /// The preset an action corresponds to, if any.
  static func matching(_ action: Action) -> WindowPreset? { matchable.first { $0.matches(action) } }

  /// Default operations for a new Chain: cycle left half → left third → left two-thirds.
  static var defaultChain: [Action] {
    ["left-half", "left-third", "left-two-thirds"].map { preset($0).action }
  }

  /// Default steps for a new Sequence: move to the next display, then maximize there.
  static var defaultSequence: [SequenceStep] {
    [SequenceStep(preset("throw-next").action), SequenceStep(preset("maximize").action)]
  }

  /// A small starter set offered during onboarding when Slated has no bindings of its own.
  static var starterBindings: [HotkeyBinding] {
    let pairs: [(String, String)] = [
      ("left", "left-half"), ("right", "right-half"), ("up", "top-half"), ("down", "bottom-half"),
      ("return", "maximize"), ("c", "center"), ("n", "throw-next"), ("z", "undo"),
    ]
    return pairs.map { key, id in
      if id == "undo" {
        return HotkeyBinding(name: "Undo", keys: KeyCombo(key: key, modifiers: .hyper), action: .undo)
      }
      let preset = preset(id)
      return HotkeyBinding(name: preset.title, keys: KeyCombo(key: key, modifiers: .hyper), action: preset.action)
    }
  }
}
