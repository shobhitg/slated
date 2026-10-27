import Foundation
import SlatedCore

/// A ready-made automation offered in Settings → Automation. Adding one creates an ordinary
/// binding in `config.bindings`, so it's edited like any other shortcut.
struct AutomationRecipe: Identifiable, Hashable {
  /// What the recipe card draws.
  enum Art: Hashable {
    /// A mouse with one button lit; `repeating` adds the auto-click ripples.
    case mouse(MouseButton, repeating: Bool)
    /// A mouse button held down.
    case holdMouse(MouseButton)
    /// A key held down.
    case holdKey(String)
    /// A key pressed over and over.
    case spamKey(String)
    case doubleClick
    /// A counted burst of clicks.
    case clickCount
    /// A sequence of steps over time.
    case macro
  }

  /// The parameters the "add" sheet lets you adjust before creating the binding.
  enum Option: Hashable {
    case speed, humanize, count, key, modifierKey, button
  }

  let id: String
  let title: String
  /// One line for the card.
  let summary: String
  /// A longer explanation for the "add" sheet.
  let detail: String
  let art: Art
  let action: Action
  let options: [Option]

  /// The binding's name for a (possibly adjusted) action: "Click 25 Times", "Spam F", "Hold Space".
  func bindingName(for action: Action) -> String {
    switch (id, action) {
    case ("click-times", .autoRepeat(.click, _, _, let times?, _)):
      return "Click \(times) Time\(times == 1 ? "" : "s")"
    case ("spam-key", .autoRepeat(.keystroke(let combo), _, _, _, _)) where combo != KeyCombo(key: "e"):
      return "Spam \(combo.display())"
    case ("hold-w", .hold(.key(let combo))) where combo != KeyCombo(key: "w"):
      return "Hold \(combo.display())"
    case ("toggle-sprint", .hold(.key(let combo))), ("toggle-crouch", .hold(.key(let combo))):
      // The key in brackets follows the one picked: "Toggle Sprint (Option)".
      guard action != self.action else { return title }
      return "\(purpose) (\(AutomationDescriber.inputName(.key(combo))))"
    default:
      return title
    }
  }

  /// Whether `action` is this recipe, adjusted or not (an auto-clicker at another speed still
  /// counts), so the gallery can mark recipes that are already set up.
  func matches(_ action: Action) -> Bool {
    switch (id, action) {
    case ("auto-click-left", .autoRepeat(.click(.left, 1), _, .toggle, nil, _)),
      ("auto-click-right", .autoRepeat(.click(.right, 1), _, .toggle, nil, _)),
      ("click-times", .autoRepeat(.click, _, _, .some(_), _)),
      ("spam-key", .autoRepeat(.keystroke, _, .whileHeld, _, _)),
      ("double-click", .click(_, 2)),
      ("hold-left", .hold(.mouse(.left))),
      ("hold-right", .hold(.mouse(.right))):
      return true
    case ("hold-w", .hold(.key(let combo))): return !KeyNames.isModifierKey(combo.key)
    case ("toggle-sprint", .hold(.key(let combo))): return combo.key.lowercased().hasSuffix("shift")
    case ("toggle-crouch", .hold(.key(let combo))): return combo.key.lowercased().hasSuffix("ctrl")
    default: return action == self.action
    }
  }

  /// Whether `binding` is this recipe, adjusted or not. Sprint and crouch both hold a modifier key,
  /// and the add sheet offers every modifier for either, so the name the sheet gave says which one
  /// a binding is ("Toggle Sprint (Control)" is sprint). A renamed one goes by its key, as above.
  func matches(_ binding: HotkeyBinding) -> Bool {
    let modifierHolds = ["toggle-sprint", "toggle-crouch"]
    guard modifierHolds.contains(id), case .hold(.key(let combo)) = binding.action, KeyNames.isModifierKey(combo.key)
    else { return matches(binding.action) }
    let named = AutomationRecipes.all.first {
      modifierHolds.contains($0.id) && binding.name?.hasPrefix($0.purpose) == true
    }
    return named.map { $0.id == id } ?? matches(binding.action)
  }

  /// The title without the key in brackets: "Toggle Sprint".
  private var purpose: String { title.components(separatedBy: " (").first ?? title }
}

enum AutomationRecipes {
  static let all: [AutomationRecipe] = [
    // Clicking
    AutomationRecipe(
      id: "auto-click-left", title: "Auto-Click Left",
      summary: "Clicks the left button 10 times a second.",
      detail:
        "Clicks the left mouse button wherever the pointer is, 10 times a second, until you press the shortcut again.",
      art: .mouse(.left, repeating: true),
      action: .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle), options: [.speed, .humanize]),
    AutomationRecipe(
      id: "auto-click-right", title: "Auto-Click Right",
      summary: "Clicks the right button 10 times a second.",
      detail:
        "Clicks the right mouse button wherever the pointer is, 10 times a second, until you press the shortcut again.",
      art: .mouse(.right, repeating: true),
      action: .autoRepeat(.click(.right, count: 1), interval: 0.1, mode: .toggle), options: [.speed, .humanize]),
    AutomationRecipe(
      id: "double-click", title: "Double-Click",
      summary: "A perfect double-click from one keystroke.",
      detail:
        "Double-clicks where the pointer is. Handy where double-clicking is tiring, or for a mouse that misfires.",
      art: .doubleClick,
      action: .click(.left, count: 2), options: [.button]),
    AutomationRecipe(
      id: "click-times", title: "Click 50 Times",
      summary: "50 clicks, 10 a second, then it stops by itself.",
      detail:
        "Clicks the left mouse button 50 times, 10 a second, then stops on its own. Press the shortcut again to stop early.",
      art: .clickCount,
      action: .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: 50), options: [.count, .speed]),
    // Holding
    AutomationRecipe(
      id: "hold-left", title: "Hold Left Click",
      summary: "Keeps the left button down: mine, drag or fire.",
      detail: "Presses the left mouse button and keeps it down until you press the shortcut again.",
      art: .holdMouse(.left),
      action: .hold(.mouse(.left)), options: []),
    AutomationRecipe(
      id: "hold-right", title: "Hold Right Click",
      summary: "Keeps the right button down: aim, block or charge.",
      detail: "Presses the right mouse button and keeps it down until you press the shortcut again.",
      art: .holdMouse(.right),
      action: .hold(.mouse(.right)), options: []),
    AutomationRecipe(
      id: "hold-w", title: "Hold W (Auto-Run)",
      summary: "Keeps W pressed so your character keeps running.",
      detail: "Presses W and keeps it down until you press the shortcut again. Steer with the mouse meanwhile.",
      art: .holdKey("w"),
      action: .hold(.key(KeyCombo(key: "w"))), options: [.key]),
    AutomationRecipe(
      id: "toggle-sprint", title: "Toggle Sprint (Shift)",
      summary: "Holds Shift for you, so sprint stays on.",
      detail:
        "Presses Shift and keeps it down until you press the shortcut again, for games that only sprint while Shift is held.",
      art: .holdKey("shift"),
      action: .hold(.key(KeyCombo(key: "shift"))), options: [.modifierKey]),
    AutomationRecipe(
      id: "toggle-crouch", title: "Toggle Crouch (Control)",
      summary: "Holds Control for you, so you stay crouched.",
      detail:
        "Presses Control and keeps it down until you press the shortcut again, for games that only crouch while it's held.",
      art: .holdKey("ctrl"),
      action: .hold(.key(KeyCombo(key: "ctrl"))), options: [.modifierKey]),
    // Keys and macros
    AutomationRecipe(
      id: "spam-key", title: "Spam a Key",
      summary: "Presses E 20 times a second while you hold the shortcut.",
      detail: "Presses E over and over, 20 times a second, for as long as you hold the shortcut down.",
      art: .spamKey("e"),
      action: .autoRepeat(.keystroke(KeyCombo(key: "e")), interval: 0.05, mode: .whileHeld),
      options: [.key, .speed, .humanize]),
    AutomationRecipe(
      id: "macro", title: "Macro: Walk, Then Click",
      summary: "Holds W for 2 seconds, lets go, then clicks.",
      detail:
        "A sequence with a wait: press W down, wait 2 seconds, release W, then click. A starting point for your own macros: add, remove or reorder steps in the editor.",
      art: .macro,
      action: .sequence([
        SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .down)),
        SequenceStep(.wait(2)),
        SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .up)),
        SequenceStep(.click(.left, count: 1)),
      ]), options: []),
  ]

  static func recipe(_ id: String) -> AutomationRecipe? { all.first { $0.id == id } }

  /// Keys offered first for a recipe's shortcut: function keys need no modifier (so they don't get
  /// in the way of a game's own keys) and few apps use F6 and up.
  static let preferredFunctionKeys = (6...12).map { "f\($0)" } + (13...19).map { "f\($0)" } + ["f5"]

  /// Keys games commonly use, offered as one-click choices in key pickers.
  static let commonGameKeys = ["w", "a", "s", "d", "space", "e", "f", "r", "q", "1", "2", "3"]

  /// Modifier keys that can be held (they can't be recorded on their own), with their names.
  static let modifierKeys: [(key: String, title: String)] = [
    ("shift", "Shift ⇧"), ("ctrl", "Control ⌃"), ("alt", "Option ⌥"), ("cmd", "Command ⌘"),
    ("rightShift", "Right Shift"), ("rightCtrl", "Right Control"), ("rightAlt", "Right Option"),
    ("rightCmd", "Right Command"),
  ]
}

extension Action {
  /// Whether this moves or resizes a window, here or in any nested step.
  var containsWindowGeometry: Bool {
    if isWindowGeometry { return true }
    switch self {
    case .chain(let actions): return actions.contains(where: \.containsWindowGeometry)
    case .sequence(let steps): return steps.contains { $0.action.containsWindowGeometry }
    case .byOrientation(let landscape, let portrait):
      return landscape.containsWindowGeometry || portrait.containsWindowGeometry
    default: return false
    }
  }

  /// Whether running this synthesizes mouse or keyboard input, here or in any nested step.
  var containsAutomation: Bool {
    if isAutomation { return true }
    switch self {
    case .chain(let actions): return actions.contains(where: \.containsAutomation)
    case .sequence(let steps): return steps.contains { $0.action.containsAutomation }
    case .byOrientation(let landscape, let portrait): return landscape.containsAutomation || portrait.containsAutomation
    default: return false
    }
  }
}

/// Plain-language descriptions of automation actions, for cards, lists and editors.
enum AutomationDescriber {
  /// "10 per second", "2.5 per second", "once every 2 seconds".
  static func rate(_ interval: Double) -> String {
    guard interval > 0, interval.isFinite else { return "—" }
    if interval > 1.0001 {
      let seconds = interval == interval.rounded() ? "\(Int(interval))" : String(format: "%.1f", interval)
      return "once every \(seconds) seconds"
    }
    let perSecond = 1 / interval
    if abs(perSecond - perSecond.rounded()) < 0.05 { return "\(Int(perSecond.rounded())) per second" }
    return String(format: "%.1f per second", perSecond)
  }

  /// "10/s", "1 per 2 s": the short form for chips.
  static func shortRate(_ interval: Double) -> String {
    guard interval > 0, interval.isFinite else { return "—" }
    if interval > 1.0001 { return "1 per \(ActionDescriber.seconds(interval))" }
    let perSecond = 1 / interval
    if abs(perSecond - perSecond.rounded()) < 0.05 { return "\(Int(perSecond.rounded()))/s" }
    return String(format: "%.1f/s", perSecond)
  }

  static func modeTitle(_ mode: RepeatMode) -> String {
    switch mode {
    case .toggle: return "Toggle"
    case .whileHeld: return "While held"
    }
  }

  static func modeExplanation(_ mode: RepeatMode) -> String {
    switch mode {
    case .toggle: return "Press the shortcut to start, press it again to stop."
    case .whileHeld: return "Runs only while you hold the shortcut down."
    }
  }

  /// "±15%": jitter as a percentage.
  static func jitter(_ value: Double) -> String { "±\(Int((value * 100).rounded()))%" }

  /// "Left Button", "W", "Shift".
  static func inputName(_ input: SyntheticInput) -> String {
    switch input {
    case .mouse(let button): return "\(button.title) Button"
    case .key(let combo):
      if combo.key.isEmpty { return "a key" }
      if combo.modifiers.isEmpty, let modifier = AutomationRecipes.modifierKeys.first(where: { $0.key == combo.key }) {
        return modifier.title.replacingOccurrences(of: #" [⇧⌃⌥⌘]$"#, with: "", options: .regularExpression)
      }
      return combo.display()
    }
  }

  /// One sentence for lists: "Clicks left 10 times a second until pressed again".
  static func sentence(_ action: Action) -> String {
    switch action {
    case .autoRepeat(let repeated, let interval, let mode, let times, let jitter):
      let what: String
      switch repeated {
      case .click(let button, let count):
        what = (count == 2 ? "Double-clicks the " : "Clicks the ") + button.title.lowercased() + " button"
      case .keystroke(let combo): what = "Presses \(combo.key.isEmpty ? "a key" : combo.display())"
      default: what = "Runs \(ActionDescriber.title(repeated))"
      }
      let speed = rate(interval).replacingOccurrences(of: "per second", with: "times a second")
      var sentence = "\(what) \(speed)"
      if let times {
        sentence = "\(what) \(times) time\(times == 1 ? "" : "s"), \(speed)"
      }
      sentence += mode == .toggle ? (times == nil ? " until pressed again" : "") : " while held"
      if jitter > 0 { sentence += ", timing varied \(self.jitter(jitter))" }
      return sentence
    case .hold(let input):
      if case .mouse(let button) = input {
        return "Holds the \(button.title.lowercased()) button down until pressed again"
      }
      return "Holds \(inputName(input)) down until pressed again"
    case .click(let button, let count):
      switch count {
      case 1: return "Clicks the \(button.title.lowercased()) button once"
      case 2: return "Double-clicks the \(button.title.lowercased()) button"
      default: return "Clicks the \(button.title.lowercased()) button \(count) times"
      }
    case .press(let input, let phase):
      return (phase == .down ? "Presses " : "Releases ") + inputName(input)
    case .wait(let seconds): return "Waits \(ActionDescriber.seconds(seconds))"
    case .stopAutomations: return "Stops every automation and lets go of anything held"
    case .sequence(let steps):
      let titles = steps.prefix(4).map { ActionDescriber.title($0.action) }
      let more = steps.count > 4 ? " → …" : ""
      return "\(steps.count) step\(steps.count == 1 ? "" : "s"): " + titles.joined(separator: " → ") + more
    default:
      return ActionDescriber.title(action)
    }
  }

  /// Short facts for chips: "10/s", "Toggle"; "4 steps", "2 s".
  static func facts(_ action: Action) -> [String] {
    switch action {
    case .autoRepeat(_, let interval, let mode, let times, let jitter):
      var facts = [shortRate(interval)]
      facts.append(times.map { "\($0)×" } ?? modeTitle(mode))
      if jitter > 0 { facts.append(self.jitter(jitter)) }
      return facts
    case .hold: return ["Toggle"]
    case .click(_, let count): return [count == 2 ? "2 clicks" : count == 1 ? "1 click" : "\(count) clicks"]
    case .sequence(let steps):
      let duration = MacroSchedule(steps: steps.map(\.action)).duration
      return ["\(steps.count) steps"] + (duration > 0 ? [ActionDescriber.seconds(duration)] : [])
    default: return []
    }
  }
}

extension MouseButton {
  var title: String {
    switch self {
    case .left: return "Left"
    case .right: return "Right"
    case .middle: return "Middle"
    }
  }
}

/// When each step of a macro happens, for the timeline drawing: held inputs become spans, clicks
/// and keystrokes become instants, waits move time forward.
struct MacroSchedule: Equatable {
  struct Span: Equatable {
    var input: SyntheticInput
    var start: Double
    /// `nil` when nothing releases it (it stays down until the stop shortcut).
    var end: Double?
  }

  struct Instant: Equatable {
    var label: String
    var time: Double
    /// The input the instant belongs to, so it shares that lane (a click on the mouse lane).
    var input: SyntheticInput?
  }

  var spans: [Span] = []
  var instants: [Instant] = []
  /// Total time the steps take (the sum of the waits).
  var duration: Double = 0

  init(steps: [Action]) {
    var time = 0.0
    var open: [SyntheticInput: Int] = [:]
    for step in steps {
      switch step {
      case .wait(let seconds):
        time += max(0, seconds)
      case .press(let input, .down):
        if open[input] == nil {
          open[input] = spans.count
          spans.append(Span(input: input, start: time, end: nil))
        }
      case .press(let input, .up):
        if let index = open.removeValue(forKey: input) { spans[index].end = time }
      case .hold(let input):
        if let index = open.removeValue(forKey: input) {
          spans[index].end = time
        } else {
          open[input] = spans.count
          spans.append(Span(input: input, start: time, end: nil))
        }
      case .click(let button, let count):
        instants.append(Instant(label: count == 2 ? "Double-click" : "Click", time: time, input: .mouse(button)))
      case .keystroke(let combo):
        instants.append(Instant(label: combo.display(), time: time, input: .key(combo)))
      default:
        instants.append(Instant(label: ActionDescriber.title(step), time: time, input: nil))
      }
    }
    duration = time
  }

  /// The lanes to draw, in order of first appearance: one per held or clicked input, then one for
  /// everything else.
  var lanes: [SyntheticInput?] {
    var result: [SyntheticInput?] = []
    let events: [(time: Double, input: SyntheticInput?)] =
      spans.map { ($0.start, Optional($0.input)) } + instants.map { ($0.time, $0.input) }
    // Sorted by time; ties keep step order (spans were listed first, so a held key's lane comes first).
    let ordered = events.enumerated().sorted { a, b in
      a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
    }
    for event in ordered where !result.contains(where: { $0 == event.element.input }) {
      result.append(event.element.input)
    }
    return result
  }

  /// Inputs pressed down and never released by a later step.
  var unreleased: [SyntheticInput] { spans.filter { $0.end == nil }.map(\.input) }
}
