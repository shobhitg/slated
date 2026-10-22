import Foundation

/// A screen edge or direction. Slate also accepts `top`/`above` for `up` and `bottom`/`below` for `down`.
public enum Direction: String, Codable, Sendable, CaseIterable, Hashable {
  case left, right, up, down

  public init?(slate raw: String) {
    switch raw.lowercased() {
    case "left": self = .left
    case "right": self = .right
    case "up", "top", "above": self = .up
    case "down", "bottom", "below": self = .down
    default: return nil
    }
  }
}

public enum Corner: String, Codable, Sendable, CaseIterable, Hashable {
  case topLeft = "top-left"
  case topRight = "top-right"
  case bottomLeft = "bottom-left"
  case bottomRight = "bottom-right"
}

/// Which screen an operation targets (Slate's screen reference syntax).
public enum ScreenRef: Hashable, Sendable {
  /// `"0"`, `"1"` — left-to-right index when `orderScreensLeftToRight` is on (Slate's default),
  /// otherwise the OS index.
  case index(Int)
  /// `"ordered:1"` — always the left-to-right index.
  case orderedIndex(Int)
  /// `"1680x1050"`.
  case resolution(width: Int, height: Int)
  /// `"left"`, `"right"`, `"up"`/`"above"`, `"down"`/`"below"` — relative to the window's screen.
  case relative(Direction)
  case next
  case previous

  public init?(slate raw: String) {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if let i = Int(s) {
      self = .index(i)
    } else if s.lowercased().hasPrefix("ordered:"), let i = Int(s.dropFirst("ordered:".count)) {
      self = .orderedIndex(i)
    } else if s.lowercased() == "next" {
      self = .next
    } else if s.lowercased() == "previous" || s.lowercased() == "prev" {
      self = .previous
    } else if let d = Direction(slate: s) {
      self = .relative(d)
    } else {
      let parts = s.lowercased().split(separator: "x")
      guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
      self = .resolution(width: w, height: h)
    }
  }

  public var slate: String {
    switch self {
    case .index(let i): return String(i)
    case .orderedIndex(let i): return "ordered:\(i)"
    case .resolution(let w, let h): return "\(w)x\(h)"
    case .relative(let d): return d.rawValue
    case .next: return "next"
    case .previous: return "previous"
    }
  }
}

extension ScreenRef: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let i = try? c.decode(Int.self) {
      self = .index(i)
      return
    }
    let raw = try c.decode(String.self)
    guard let ref = ScreenRef(slate: raw) else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid screen reference \"\(raw)\"")
    }
    self = ref
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(slate)
  }
}

/// How `push` sizes the window. Slate syntax: `none`, `center`, `bar`, `bar-resize:<expression>`.
public enum PushStyle: Hashable, Sendable {
  case none
  /// Center the window along the edge it is pushed to.
  case center
  /// Stretch the window along the edge (full width for up/down, full height for left/right).
  case bar
  /// Like `bar`, and resize the other dimension to the expression (e.g. `screenSizeX/2`).
  case barResize(String)

  public init?(slate raw: String) {
    let s = raw.trimmingCharacters(in: .whitespaces)
    switch s.lowercased() {
    case "", "none": self = .none
    case "center": self = .center
    case "bar": self = .bar
    default:
      guard s.lowercased().hasPrefix("bar-resize:") else { return nil }
      self = .barResize(String(s.dropFirst("bar-resize:".count)))
    }
  }

  public var slate: String {
    switch self {
    case .none: return "none"
    case .center: return "center"
    case .bar: return "bar"
    case .barResize(let e): return "bar-resize:\(e)"
    }
  }
}

extension PushStyle: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    let raw = try c.decode(String.self)
    guard let style = PushStyle(slate: raw) else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid push style \"\(raw)\"")
    }
    self = style
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(slate)
  }
}

public enum FocusDirection: String, Codable, Sendable, CaseIterable, Hashable {
  case left, right, up, down, behind

  public init?(slate raw: String) {
    if raw.lowercased() == "behind" {
      self = .behind
    } else if let d = Direction(slate: raw) {
      self = FocusDirection(rawValue: d.rawValue)!
    } else {
      return nil
    }
  }
}

/// Which apps `hide`/`show`/`toggle` act on.
public enum AppSelector: Hashable, Sendable {
  case current
  case all
  case allBut(String)
  case apps([String])
}

extension AppSelector: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let list = try? c.decode([String].self) {
      self = .apps(list)
      return
    }
    let raw = try c.decode(String.self)
    switch raw.lowercased() {
    case "current": self = .current
    case "all": self = .all
    default:
      if raw.lowercased().hasPrefix("all-but:") {
        self = .allBut(String(raw.dropFirst("all-but:".count)))
      } else {
        self = .apps([raw])
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .current: try c.encode("current")
    case .all: try c.encode("all")
    case .allBut(let app): try c.encode("all-but:\(app)")
    case .apps(let apps): try c.encode(apps)
    }
  }
}

/// How text is inserted into the focused app.
public enum InsertMethod: String, Codable, Sendable, CaseIterable, Hashable {
  /// Type short text, paste long text.
  case auto
  /// Synthesize keystrokes. Works everywhere, slower for long text.
  case type
  /// Put the text on the clipboard, press ⌘V, then restore the clipboard.
  case paste
}

/// Grid size for one screen in the `grid` operation.
public struct GridScreen: Hashable, Sendable, Codable {
  /// Screen reference string: an index (`"0"`) or a resolution (`"1680x1050"`).
  public var screen: String
  public var width: Int
  public var height: Int

  public init(screen: String, width: Int, height: Int) {
    self.screen = screen
    self.width = width
    self.height = height
  }
}

/// One step of a `sequence`.
public struct SequenceStep: Hashable, Sendable, Codable {
  public var action: Action
  /// Slate's `>` separator: run on the window that was focused when the `>` run began, instead of
  /// whatever is focused when this step runs (`|`).
  public var keepWindow: Bool

  public init(_ action: Action, keepWindow: Bool = false) {
    self.action = action
    self.keepWindow = keepWindow
  }
}

/// Everything a trigger can do: all of Slate's operations plus Slated's own actions.
///
/// Expression parameters are strings in Slate's expression language, e.g. `"screenOriginX+screenSizeX/2"`.
/// On disk an operation is a JSON object whose `"op"` names the operation and whose other keys are
/// Slate's JavaScript parameter names — the same shape as `slate.operation("push", {...})`.
public indirect enum Action: Hashable, Sendable {
  // MARK: Slate window geometry
  case move(x: String, y: String, width: String, height: String, screen: ScreenRef?)
  /// `width`/`height` are `+10%`, `-100`, or expressions; `anchor` stays fixed.
  case resize(width: String, height: String, anchor: Corner)
  case push(direction: Direction, style: PushStyle, screen: ScreenRef?)
  /// `x`/`y` are `+10%`, `-100`, or expressions.
  case nudge(x: String, y: String)
  /// Move to another screen; resize to `width`×`height` when given (Slate's `resize` style is
  /// `screenSizeX`×`screenSizeY`).
  case throwWindow(screen: ScreenRef, width: String?, height: String?)
  case corner(Corner, width: String?, height: String?, screen: ScreenRef?)

  // MARK: Slate composition
  /// Each press runs the next operation, cycling.
  case chain([Action])
  case sequence([SequenceStep])
  case layout(name: String)

  // MARK: Slate focus, snapshots, overlays, apps
  case focus(FocusDirection)
  case focusApp(String)
  case snapshot(name: String, save: Bool, stack: Bool)
  case deleteSnapshot(name: String, all: Bool)
  case activateSnapshot(name: String, delete: Bool)
  case hint(characters: String?)
  case grid(padding: Int?, grids: [GridScreen])
  case hide(AppSelector)
  case show(AppSelector)
  case toggle(AppSelector)
  case shell(command: String, wait: Bool, path: String?)
  case undo
  case relaunch
  /// Slate's beta application switcher. Parsed for compatibility; not implemented yet.
  case switchApp

  // MARK: Slated extensions (Keyboard Maestro-style actions)
  case insertText(String, method: InsertMethod)
  case openURL(String)
  case keystroke(KeyCombo)

  /// The name used in configs and Slate syntax.
  public var name: String {
    switch self {
    case .move: return "move"
    case .resize: return "resize"
    case .push: return "push"
    case .nudge: return "nudge"
    case .throwWindow: return "throw"
    case .corner: return "corner"
    case .chain: return "chain"
    case .sequence: return "sequence"
    case .layout: return "layout"
    case .focus, .focusApp: return "focus"
    case .snapshot: return "snapshot"
    case .deleteSnapshot: return "delete-snapshot"
    case .activateSnapshot: return "activate-snapshot"
    case .hint: return "hint"
    case .grid: return "grid"
    case .hide: return "hide"
    case .show: return "show"
    case .toggle: return "toggle"
    case .shell: return "shell"
    case .undo: return "undo"
    case .relaunch: return "relaunch"
    case .switchApp: return "switch"
    case .insertText: return "insert-text"
    case .openURL: return "open-url"
    case .keystroke: return "keystroke"
    }
  }

  /// True for operations that move or resize the focused window (and can be undone).
  public var isWindowGeometry: Bool {
    switch self {
    case .move, .resize, .push, .nudge, .throwWindow, .corner: return true
    default: return false
    }
  }
}

// MARK: - Codable

extension Action: Codable {
  private enum Key: String, CodingKey {
    case op, x, y, width, height, screen, anchor, direction, style, operations, steps, name
    case app, save, stack, all, delete, characters, padding, grids, command, wait, path
    case text, method, url, keys
  }

  private struct GridSize: Codable {
    var width: Int
    var height: Int
  }

  public init(from decoder: Decoder) throws {
    // A bare string is Slate operation syntax: "push left bar-resize:screenSizeX/2".
    if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
      do {
        self = try SlateSyntax.parseOperation(raw)
      } catch {
        throw DecodingError.dataCorruptedError(
          in: single, debugDescription: "Invalid operation \"\(raw)\": \(error)")
      }
      return
    }

    let c = try decoder.container(keyedBy: Key.self)
    let op = try c.decode(String.self, forKey: .op)

    func expr(_ key: Key) throws -> String? {
      if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
      if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
        return d == d.rounded() ? String(Int(d)) : String(d)
      }
      return nil
    }
    func required(_ key: Key) throws -> String {
      guard let v = try expr(key) else {
        throw DecodingError.keyNotFound(
          key, .init(codingPath: c.codingPath, debugDescription: "\"\(op)\" needs \"\(key.rawValue)\""))
      }
      return v
    }
    func bool(_ key: Key) throws -> Bool { try c.decodeIfPresent(Bool.self, forKey: key) ?? false }

    switch op {
    case "move":
      self = .move(
        x: try required(.x), y: try required(.y), width: try required(.width),
        height: try required(.height), screen: try c.decodeIfPresent(ScreenRef.self, forKey: .screen))
    case "resize":
      self = .resize(
        width: try expr(.width) ?? "+0", height: try expr(.height) ?? "+0",
        anchor: try c.decodeIfPresent(Corner.self, forKey: .anchor) ?? .topLeft)
    case "push":
      let raw = try required(.direction)
      guard let d = Direction(slate: raw) else {
        throw DecodingError.dataCorruptedError(forKey: .direction, in: c, debugDescription: "Invalid direction \"\(raw)\"")
      }
      self = .push(
        direction: d, style: try c.decodeIfPresent(PushStyle.self, forKey: .style) ?? .none,
        screen: try c.decodeIfPresent(ScreenRef.self, forKey: .screen))
    case "nudge":
      self = .nudge(x: try expr(.x) ?? "+0", y: try expr(.y) ?? "+0")
    case "throw":
      self = .throwWindow(
        screen: try c.decode(ScreenRef.self, forKey: .screen), width: try expr(.width),
        height: try expr(.height))
    case "corner":
      let raw = try required(.direction)
      guard let corner = Corner(rawValue: raw.lowercased()) else {
        throw DecodingError.dataCorruptedError(forKey: .direction, in: c, debugDescription: "Invalid corner \"\(raw)\"")
      }
      self = .corner(
        corner, width: try expr(.width), height: try expr(.height),
        screen: try c.decodeIfPresent(ScreenRef.self, forKey: .screen))
    case "chain":
      self = .chain(try c.decode([Action].self, forKey: .operations))
    case "sequence":
      if let steps = try c.decodeIfPresent([SequenceStep].self, forKey: .steps) {
        self = .sequence(steps)
      } else {
        self = .sequence(try c.decode([Action].self, forKey: .operations).map { SequenceStep($0) })
      }
    case "layout":
      self = .layout(name: try required(.name))
    case "focus":
      if let app = try c.decodeIfPresent(String.self, forKey: .app) {
        self = .focusApp(app)
      } else {
        let raw = try required(.direction)
        guard let d = FocusDirection(slate: raw) else {
          throw DecodingError.dataCorruptedError(forKey: .direction, in: c, debugDescription: "Invalid focus direction \"\(raw)\"")
        }
        self = .focus(d)
      }
    case "snapshot":
      self = .snapshot(name: try required(.name), save: try bool(.save), stack: try bool(.stack))
    case "delete-snapshot":
      self = .deleteSnapshot(name: try required(.name), all: try bool(.all))
    case "activate-snapshot":
      self = .activateSnapshot(name: try required(.name), delete: try bool(.delete))
    case "hint":
      self = .hint(characters: try c.decodeIfPresent(String.self, forKey: .characters))
    case "grid":
      let sizes = try c.decodeIfPresent([String: GridSize].self, forKey: .grids) ?? [:]
      self = .grid(
        padding: try c.decodeIfPresent(Int.self, forKey: .padding),
        grids: sizes.keys.sorted().map { GridScreen(screen: $0, width: sizes[$0]!.width, height: sizes[$0]!.height) })
    case "hide":
      self = .hide(try c.decode(AppSelector.self, forKey: .app))
    case "show":
      self = .show(try c.decode(AppSelector.self, forKey: .app))
    case "toggle":
      self = .toggle(try c.decode(AppSelector.self, forKey: .app))
    case "shell":
      self = .shell(
        command: try required(.command), wait: try bool(.wait),
        path: try c.decodeIfPresent(String.self, forKey: .path))
    case "undo": self = .undo
    case "relaunch": self = .relaunch
    case "switch": self = .switchApp
    case "insert-text":
      self = .insertText(
        try required(.text), method: try c.decodeIfPresent(InsertMethod.self, forKey: .method) ?? .auto)
    case "open-url":
      self = .openURL(try required(.url))
    case "keystroke":
      self = .keystroke(try c.decode(KeyCombo.self, forKey: .keys))
    default:
      throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown operation \"\(op)\"")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(name, forKey: .op)
    switch self {
    case .move(let x, let y, let w, let h, let screen):
      try c.encode(x, forKey: .x)
      try c.encode(y, forKey: .y)
      try c.encode(w, forKey: .width)
      try c.encode(h, forKey: .height)
      try c.encodeIfPresent(screen, forKey: .screen)
    case .resize(let w, let h, let anchor):
      try c.encode(w, forKey: .width)
      try c.encode(h, forKey: .height)
      if anchor != .topLeft { try c.encode(anchor, forKey: .anchor) }
    case .push(let d, let style, let screen):
      try c.encode(d, forKey: .direction)
      if style != .none { try c.encode(style, forKey: .style) }
      try c.encodeIfPresent(screen, forKey: .screen)
    case .nudge(let x, let y):
      try c.encode(x, forKey: .x)
      try c.encode(y, forKey: .y)
    case .throwWindow(let screen, let w, let h):
      try c.encode(screen, forKey: .screen)
      try c.encodeIfPresent(w, forKey: .width)
      try c.encodeIfPresent(h, forKey: .height)
    case .corner(let corner, let w, let h, let screen):
      try c.encode(corner, forKey: .direction)
      try c.encodeIfPresent(w, forKey: .width)
      try c.encodeIfPresent(h, forKey: .height)
      try c.encodeIfPresent(screen, forKey: .screen)
    case .chain(let ops):
      try c.encode(ops, forKey: .operations)
    case .sequence(let steps):
      if steps.allSatisfy({ !$0.keepWindow }) {
        try c.encode(steps.map(\.action), forKey: .operations)
      } else {
        try c.encode(steps, forKey: .steps)
      }
    case .layout(let name):
      try c.encode(name, forKey: .name)
    case .focus(let d):
      try c.encode(d, forKey: .direction)
    case .focusApp(let app):
      try c.encode(app, forKey: .app)
    case .snapshot(let name, let save, let stack):
      try c.encode(name, forKey: .name)
      if save { try c.encode(true, forKey: .save) }
      if stack { try c.encode(true, forKey: .stack) }
    case .deleteSnapshot(let name, let all):
      try c.encode(name, forKey: .name)
      if all { try c.encode(true, forKey: .all) }
    case .activateSnapshot(let name, let delete):
      try c.encode(name, forKey: .name)
      if delete { try c.encode(true, forKey: .delete) }
    case .hint(let chars):
      try c.encodeIfPresent(chars, forKey: .characters)
    case .grid(let padding, let grids):
      try c.encodeIfPresent(padding, forKey: .padding)
      if !grids.isEmpty {
        try c.encode(
          Dictionary(grids.map { ($0.screen, GridSize(width: $0.width, height: $0.height)) }, uniquingKeysWith: { a, _ in a }),
          forKey: .grids)
      }
    case .hide(let apps), .show(let apps), .toggle(let apps):
      try c.encode(apps, forKey: .app)
    case .shell(let command, let wait, let path):
      try c.encode(command, forKey: .command)
      if wait { try c.encode(true, forKey: .wait) }
      try c.encodeIfPresent(path, forKey: .path)
    case .undo, .relaunch, .switchApp:
      break
    case .insertText(let text, let method):
      try c.encode(text, forKey: .text)
      if method != .auto { try c.encode(method, forKey: .method) }
    case .openURL(let url):
      try c.encode(url, forKey: .url)
    case .keystroke(let combo):
      try c.encode(combo, forKey: .keys)
    }
  }
}
