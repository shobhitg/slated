import CoreGraphics
import SlatedCore

/// The shortcuts the island lists while you hold the Hyper key (or after pressing a modal key),
/// grouped by what they do and sorted in keyboard order.
public struct CheatSheet: Hashable, Sendable {
  /// One shortcut from any source: Slated's bindings, Slate files or Slated's built-ins.
  public struct Shortcut: Hashable, Sendable {
    public var keys: KeyCombo
    /// The modal key that must be pressed first, if any.
    public var modal: KeyCombo?
    public var name: String?
    /// The operation when it is static (JavaScript callbacks have none).
    public var action: Action?
    /// Shown when there's neither a name nor an action ("JavaScript function").
    public var summary: String?

    public init(
      keys: KeyCombo, modal: KeyCombo? = nil, name: String? = nil, action: Action? = nil, summary: String? = nil
    ) {
      self.keys = keys
      self.modal = modal
      self.name = name
      self.action = action
      self.summary = summary
    }

    var id: String { (modal.map { $0.string + " " } ?? "") + keys.string }
  }

  public struct Item: Hashable, Sendable, Identifiable {
    /// The shortcut's id: modal key (if any), a space, then the keys, as config strings.
    public var id: String
    /// The keycap: the key plus any modifiers beyond the ones the sheet is about ("⇧H" under Hyper).
    public var label: String
    public var title: String
    /// Where a window action puts the window, as fractions of the screen (for the region glyph).
    public var region: CGRect?
    public var symbol: String
  }

  public struct Section: Hashable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var items: [Item]
  }

  /// "Hyper" or the modal key's glyphs ("⌃E").
  public var title: String
  public var isHyper: Bool
  public var sections: [Section]

  public var items: [Item] { sections.flatMap(\.items) }
  public var isEmpty: Bool { sections.isEmpty }

  /// Every shortcut that holds at least the Hyper modifiers, without a modal key. The first
  /// shortcut for a key wins, as when registering hotkeys.
  public static func hyper(_ shortcuts: [Shortcut], hyperModifiers: Modifiers) -> CheatSheet {
    let matching = shortcuts.filter {
      $0.modal == nil && $0.keys.modifiers.isSuperset(of: hyperModifiers) && !$0.keys.key.isEmpty
    }
    return CheatSheet(
      title: "Hyper", isHyper: true,
      sections: sections(matching) { combo in
        combo.modifiers.subtracting(hyperModifiers).symbols + KeyNames.displayName(for: combo.key)
      })
  }

  /// The keys available after pressing the modal key `modal`.
  public static func modal(_ modal: KeyCombo, _ shortcuts: [Shortcut]) -> CheatSheet {
    CheatSheet(
      title: modal.display(), isHyper: false,
      sections: sections(shortcuts.filter { $0.modal == modal && !$0.keys.key.isEmpty }) { $0.display() })
  }

  // MARK: Building

  enum Group: Int, CaseIterable {
    case windows, displays, apps, layouts, automation, utilities, scripts

    var title: String {
      switch self {
      case .windows: return "Windows"
      case .displays: return "Displays"
      case .apps: return "Apps & Focus"
      case .layouts: return "Layouts"
      case .automation: return "Automation"
      case .utilities: return "Utilities"
      case .scripts: return "Scripts"
      }
    }
  }

  private static func sections(_ shortcuts: [Shortcut], label: (KeyCombo) -> String) -> [Section] {
    var seen = Set<String>()
    var groups: [Group: [(rank: [Int], item: Item)]] = [:]
    for shortcut in shortcuts where seen.insert(shortcut.id).inserted {
      let group = group(for: shortcut.action)
      let item = Item(
        id: shortcut.id, label: label(shortcut.keys), title: shortened(title(for: shortcut), in: group),
        region: shortcut.action.flatMap(region(for:)),
        symbol: shortcut.action.map { WindowPresets.matching($0)?.symbol ?? ActionKind($0).symbol } ?? "curlybraces")
      groups[group, default: []].append((rank(shortcut.keys), item))
    }
    return Group.allCases.compactMap { group in
      guard let entries = groups[group], !entries.isEmpty else { return nil }
      let items = entries.sorted { $0.rank.lexicographicallyPrecedes($1.rank) }.map(\.item)
      return Section(title: group.title, items: items)
    }
  }

  static func title(for shortcut: Shortcut) -> String {
    if let name = shortcut.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
    if let action = shortcut.action { return ActionDescriber.title(action) }
    return shortcut.summary ?? "Script"
  }

  /// Drops what the section title already says: under Displays, "Throw to the screen on the right"
  /// reads "Screen on the right". "Throw to Display Above, Resized" reads "Display Above": at a glance
  /// it's where the window goes that matters, and the columns are narrow.
  static func shortened(_ title: String, in group: Group) -> String {
    guard group == .displays else { return title }
    var title = title
    if title.hasSuffix(", Resized") { title.removeLast(", Resized".count) }
    for prefix in ["Throw to the ", "Throw to "] where title.hasPrefix(prefix) && title.count > prefix.count {
      let rest = title.dropFirst(prefix.count)
      return rest.prefix(1).uppercased() + rest.dropFirst()
    }
    return title
  }

  static func group(for action: Action?) -> Group {
    guard let action else { return .scripts }
    // Anything that clicks or presses is an automation, as in Settings, whatever its shape.
    if action.containsAutomation { return .automation }
    switch action {
    case .throwWindow: return .displays
    case .byOrientation(let landscape, _): return group(for: landscape)
    case .chain(let actions): return actions.first.map(group(for:)) ?? .windows
    case .sequence(let steps):
      // Like a chain, a sequence goes with its first step ("Next display, then maximize" is a
      // display shortcut).
      return steps.first.map { group(for: $0.action) } ?? .utilities
    case .move, .resize, .push, .nudge, .corner, .grid, .undo: return .windows
    case .focus, .focusApp, .hide, .show, .toggle, .switchApp, .hint: return .apps
    case .layout, .snapshot, .activateSnapshot, .deleteSnapshot: return .layouts
    case .click, .press, .hold, .autoRepeat, .wait, .stopAutomations: return .automation
    case .shell, .insertText, .keystroke, .openURL, .relaunch, .clipboardHistory: return .utilities
    }
  }

  /// Keyboard order: letters, digits (1 before 0, as on the keyboard), punctuation, arrows, then
  /// everything else by name; fewer extra modifiers first.
  static func rank(_ combo: KeyCombo) -> [Int] {
    let key = combo.key.lowercased()
    let base: Int
    if key.count == 1, let scalar = key.unicodeScalars.first, ("a"..."z").contains(scalar) {
      base = Int(scalar.value - 97)
    } else if key.count == 1, let digit = Int(key) {
      base = 100 + (digit == 0 ? 10 : digit)
    } else if let arrow = ["left", "up", "down", "right"].firstIndex(of: key) {
      base = 300 + arrow
    } else if key.count == 1 {
      base = 200 + Int(key.unicodeScalars.first!.value % 100)
    } else {
      base = 400 + (namedKeyOrder[KeyNames.canonical(combo.key)] ?? namedKeyOrder.count)
    }
    return [base, combo.modifiers.rawValue.nonzeroBitCount]
  }

  /// Named keys in natural order, so F2 comes before F10 and Pad 1 before Pad 10: by name, then by
  /// the number they end with.
  private static let namedKeyOrder: [String: Int] = {
    func split(_ name: String) -> (name: String, number: Int) {
      let digits = name.reversed().prefix(while: \.isNumber).count
      return (name.dropLast(digits).lowercased(), Int(name.suffix(digits)) ?? -1)
    }
    let names = Set(KeyNames.named.values).sorted { a, b in
      let (x, y) = (split(a), split(b))
      return x.name == y.name ? x.number < y.number : x.name < y.name
    }
    return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
  }()

  /// The region a window action lands in on a sample screen, as fractions of the screen.
  static func region(for action: Action) -> CGRect? {
    if let region = WindowPresets.matching(action)?.region { return region }
    switch action {
    case .byOrientation(let landscape, _): return region(for: landscape)
    case .chain(let actions): return actions.first.flatMap(region(for:))
    case .move, .resize, .push, .corner:
      let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
      let screen = ScreenInfo(displayID: 1, name: "Sample", frame: bounds, visibleFrame: bounds, isMain: true)
      let start = CGRect(x: 400, y: 250, width: 800, height: 500)
      let context = WindowContext(frame: start, screens: [screen])
      guard let frame = try? FrameCalculator.targetFrame(for: action, in: context), frame.width > 0, frame.height > 0
      else { return nil }
      let region = CGRect(
        x: frame.minX / bounds.width, y: frame.minY / bounds.height, width: frame.width / bounds.width,
        height: frame.height / bounds.height)
      return region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)).nilIfEmpty
    default:
      return nil
    }
  }
}

extension CGRect {
  fileprivate var nilIfEmpty: CGRect? { isNull || isEmpty ? nil : self }
}
