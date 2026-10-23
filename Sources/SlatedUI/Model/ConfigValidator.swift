import Foundation
import SlatedCore

/// A problem with the draft configuration, shown next to the field it concerns.
struct ValidationIssue: Identifiable, Hashable {
  enum Severity: Hashable { case error, warning }
  enum Target: Hashable {
    case binding(UUID)
    case hotstring(UUID)
    case layout(String)
  }
  enum Field: Hashable { case keys, action, trigger, replacement, name }

  var severity: Severity
  var target: Target
  var field: Field
  var message: String

  var id: String { "\(target)|\(field)|\(message)" }
}

/// Validates the draft before it is saved.
///
/// Errors keep an item from being written (the last saved version of that item is kept instead, so
/// a half-typed edit never deletes anything on disk). Warnings are advisory.
enum ConfigValidator {
  static func validate(_ config: SlatedConfiguration, knownLayouts: Set<String>) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    let builtIns = BuiltInShortcut.allCases.compactMap { builtIn in builtIn.keys(in: config).map { (builtIn, $0) } }
    issues += bindingIssues(config.bindings, knownLayouts: knownLayouts, builtIns: builtIns)
    issues += hotstringIssues(config.hotstrings)
    issues += layoutIssues(config.layouts, knownLayouts: knownLayouts)
    return issues
  }

  // MARK: Bindings

  private static func bindingIssues(
    _ bindings: [HotkeyBinding], knownLayouts: Set<String>, builtIns: [(BuiltInShortcut, KeyCombo)] = []
  ) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var byKeys: [String: [HotkeyBinding]] = [:]
    for binding in bindings {
      let target = ValidationIssue.Target.binding(binding.id)
      if let problem = keyProblem(binding.keys) {
        issues.append(.init(severity: .error, target: target, field: .keys, message: problem))
      } else if KeyNames.isModifierKey(binding.keys.key) {
        issues.append(
          .init(
            severity: .error, target: target, field: .keys,
            message: "A modifier key can't be a shortcut on its own. Add a key, or use it as a held input instead."))
      } else if binding.onlyInApps.isEmpty, !KeyNames.isMouseButton(binding.keys.key),
        let warning = typingWarning(binding.keys, modal: binding.modal)
      {
        issues.append(.init(severity: .warning, target: target, field: .keys, message: warning))
      } else if binding.onlyInApps.isEmpty, binding.modal == nil, let warning = mouseButtonWarning(binding.keys) {
        issues.append(.init(severity: .warning, target: target, field: .keys, message: warning))
      }
      // Bindings are registered before the built-in shortcuts, so they win.
      if binding.enabled, binding.modal == nil {
        for (builtIn, keys) in builtIns where keys == binding.keys && binding.action != builtIn.action {
          issues.append(
            .init(
              severity: .warning, target: target, field: .keys,
              message:
                "Same keys as \(builtIn.title). This shortcut wins, so \(keys.display()) won't \(builtIn.effect)."
            ))
        }
      }
      if case .wait = binding.action {
        issues.append(
          .init(
            severity: .warning, target: target, field: .action,
            message: "A wait on its own does nothing. Use it as a step in a sequence, between other steps."))
      }
      for problem in actionProblems(binding.action, knownLayouts: knownLayouts) {
        issues.append(.init(severity: problem.severity, target: target, field: .action, message: problem.message))
      }
      if binding.enabled {
        byKeys[BindingStatusKey.key(binding.keys, modal: binding.modal), default: []].append(binding)
      }
    }
    for group in byKeys.values where group.count > 1 {
      for binding in group {
        // Bindings limited to different apps never run at the same time.
        let others = group.filter { $0.id != binding.id && $0.sharesApps(with: binding) }.map {
          "“\(BindingTitle.title(for: $0))”"
        }
        guard !others.isEmpty else { continue }
        issues.append(
          .init(
            severity: .warning, target: .binding(binding.id), field: .keys,
            message: "Same shortcut as \(ListFormatter.localizedString(byJoining: others)). Only one of them can run."))
      }
    }
    return issues
  }

  static func keyProblem(_ keys: KeyCombo) -> String? {
    if keys.key.isEmpty { return "Record a shortcut." }
    return KeyNames.isValid(keys.key) ? nil : "“\(keys.key)” isn't a key Slated knows."
  }

  /// A warning when a shortcut would swallow ordinary typing.
  static func typingWarning(_ keys: KeyCombo, modal: ModalKey?) -> String? {
    guard modal == nil, !keys.modifiers.contains(.control), !keys.modifiers.contains(.option),
      !keys.modifiers.contains(.command), !ShortcutRules.isFunctionKey(keys.key)
    else { return nil }
    return "Without ⌃, ⌥ or ⌘ this shortcut takes over typing \(KeyNames.displayName(for: keys.key)) everywhere."
  }

  /// A warning when a bare mouse button becomes a shortcut everywhere: it stops doing its usual job
  /// in every app.
  static func mouseButtonWarning(_ keys: KeyCombo) -> String? {
    guard keys.modifiers.isEmpty else { return nil }
    let lost: String
    switch keys.key {
    case "mouse3": lost = "Middle-click stops working everywhere else"
    case "mouse4": lost = "Mouse 4 stops working as Back in browsers and other apps"
    case "mouse5": lost = "Mouse 5 stops working as Forward in browsers and other apps"
    default: return nil
    }
    return "\(lost). Limit this shortcut to a game with Only In, or add a modifier."
  }

  // MARK: Actions

  struct Problem: Hashable {
    var severity: ValidationIssue.Severity
    var message: String
  }

  static func actionProblems(_ action: Action, knownLayouts: Set<String>) -> [Problem] {
    func error(_ message: String) -> [Problem] { [Problem(severity: .error, message: message)] }
    func expressions(_ pairs: [(String, String?)], relative: Bool = false) -> [Problem] {
      pairs.flatMap { label, value -> [Problem] in
        guard let value else { return [] }
        switch ExpressionCheck.check(value, relative: relative) {
        case .empty: return error("\(label) is empty.")
        case .invalid(let message): return error("\(label): \(message)")
        case .valid: return []
        }
      }
    }

    switch action {
    case .move(let x, let y, let w, let h, _):
      return expressions([("X", x), ("Y", y), ("Width", w), ("Height", h)])
    case .resize(let w, let h, _):
      return expressions([("Width", w), ("Height", h)], relative: true)
    case .push(_, let style, _):
      if case .barResize(let expression) = style { return expressions([("Size", expression)]) }
      return []
    case .nudge(let x, let y):
      return expressions([("Horizontal", x), ("Vertical", y)], relative: true)
    case .throwWindow(_, let w, let h), .corner(_, let w, let h, _):
      return expressions([("Width", w), ("Height", h)])
    case .chain(let ops):
      if ops.isEmpty { return error("Add at least one operation to the chain.") }
      return ops.enumerated().flatMap { i, op in
        actionProblems(op, knownLayouts: knownLayouts).map {
          Problem(severity: $0.severity, message: "Step \(i + 1): \($0.message)")
        }
      }
    case .sequence(let steps):
      if steps.isEmpty { return error("Add at least one step to the sequence.") }
      var problems = steps.enumerated().flatMap { i, step in
        actionProblems(step.action, knownLayouts: knownLayouts).map {
          Problem(severity: $0.severity, message: "Step \(i + 1): \($0.message)")
        }
      }
      for input in unreleasedPresses(steps.map(\.action)) {
        problems.append(
          Problem(
            severity: .warning,
            message:
              "\(AutomationDescriber.inputName(input)) stays down after the last step. Add a Release step, or press the stop shortcut to let go."
          ))
      }
      return problems
    case .autoRepeat(let repeated, let interval, _, _, _):
      var problems = actionProblems(repeated, knownLayouts: knownLayouts).map {
        Problem(severity: $0.severity, message: "Repeated: \($0.message)")
      }
      if interval < 0.01 { problems += error("Repeat at most 100 times a second (an interval of 10 ms or more).") }
      switch repeated {
      case .autoRepeat: problems += error("An auto-repeat can't repeat another auto-repeat.")
      case .wait:
        problems.append(Problem(severity: .warning, message: "Repeating a wait does nothing. Repeat a click or a key."))
      case .stopAutomations:
        problems.append(Problem(severity: .warning, message: "This would stop itself the first time it runs."))
      default: break
      }
      return problems
    case .wait(let seconds):
      return seconds > 600 ? [Problem(severity: .warning, message: "That's a wait of over 10 minutes.")] : []
    case .byOrientation(let landscape, let portrait):
      let prefixed = { (label: String, action: Action) in
        actionProblems(action, knownLayouts: knownLayouts).map {
          Problem(severity: $0.severity, message: "\(label): \($0.message)")
        }
      }
      return prefixed("Landscape", landscape) + prefixed("Portrait", portrait)
    case .layout(let name):
      if name.trimmingCharacters(in: .whitespaces).isEmpty { return error("Choose a layout.") }
      if !knownLayouts.contains(name) {
        return [Problem(severity: .warning, message: "There's no layout named “\(name)” yet.")]
      }
      return []
    case .focusApp(let app):
      return app.trimmingCharacters(in: .whitespaces).isEmpty ? error("Choose an app to focus.") : []
    case .snapshot(let name, _, _), .deleteSnapshot(let name, _), .activateSnapshot(let name, _):
      return name.trimmingCharacters(in: .whitespaces).isEmpty ? error("Name the snapshot.") : []
    case .grid(_, let grids):
      return grids.contains { $0.width < 1 || $0.height < 1 } ? error("Grid sizes must be at least 1 × 1.") : []
    case .hide(let s), .show(let s), .toggle(let s):
      switch s {
      case .apps(let apps) where apps.isEmpty: return error("Choose at least one app.")
      case .allBut(let app) where app.isEmpty: return error("Choose the app to leave alone.")
      default: return []
      }
    case .shell(let command, _, _):
      return command.trimmingCharacters(in: .whitespaces).isEmpty ? error("Enter a command to run.") : []
    case .insertText(let text, _):
      return text.isEmpty ? error("Enter the text to insert.") : []
    case .openURL(let url):
      guard let parsed = URL(string: url), let scheme = parsed.scheme, !scheme.isEmpty,
        url.count > scheme.count + 1, !url.hasSuffix("://")
      else { return error("Enter a full URL, like https://example.com.") }
      return []
    case .keystroke(let combo):
      return keyProblem(combo).map(error) ?? []
    case .switchApp:
      return [Problem(severity: .warning, message: "Slated doesn't run the app switcher yet.")]
    case .press(.key(let combo), _), .hold(.key(let combo)):
      return keyProblem(combo).map(error) ?? []
    case .focus, .hint, .undo, .relaunch, .click, .press, .hold, .stopAutomations, .clipboardHistory:
      return []
    }
  }

  /// Inputs a macro presses down (`press … down`) without a later step releasing them. `hold`
  /// steps are left out: staying down until the next run is what they're for.
  static func unreleasedPresses(_ steps: [Action]) -> [SyntheticInput] {
    var down: [SyntheticInput] = []
    for case .press(let input, let phase) in steps {
      if phase == .down {
        if !down.contains(input) { down.append(input) }
      } else {
        down.removeAll { $0 == input }
      }
    }
    return down
  }

  // MARK: Hotstrings

  private static func hotstringIssues(_ hotstrings: [Hotstring]) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    for hotstring in hotstrings {
      let target = ValidationIssue.Target.hotstring(hotstring.id)
      let trigger = hotstring.trigger
      if trigger.isEmpty {
        issues.append(.init(severity: .error, target: target, field: .trigger, message: "Type a trigger."))
        continue
      }
      if trigger.contains(where: \.isNewline) {
        issues.append(
          .init(severity: .error, target: target, field: .trigger, message: "A trigger can't contain a line break."))
      }
      if hotstring.replacement.isEmpty, hotstring.action == nil {
        issues.append(
          .init(
            severity: .warning, target: target, field: .replacement,
            message: "The replacement is empty, so the trigger will just be deleted."))
      }
      guard hotstring.enabled else { continue }
      for other in hotstrings where other.id != hotstring.id && other.enabled && !other.trigger.isEmpty {
        let caseInsensitive = !hotstring.caseSensitive || !other.caseSensitive
        let mine = caseInsensitive ? trigger.lowercased() : trigger
        let theirs = caseInsensitive ? other.trigger.lowercased() : other.trigger
        if mine == theirs {
          issues.append(
            .init(
              severity: .warning, target: target, field: .trigger,
              message: "Another hotstring uses the same trigger. Only one of them will fire."))
          break
        }
        if other.fire == .immediately, mine.hasPrefix(theirs), !other.wordBoundary || hotstring.wordBoundary {
          issues.append(
            .init(
              severity: .warning, target: target, field: .trigger,
              message: "“\(other.trigger)” fires as soon as it's typed, so this one never gets the chance."))
          break
        }
      }
    }
    return issues
  }

  // MARK: Layouts

  private static func layoutIssues(_ layouts: [Layout], knownLayouts: Set<String>) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var seen: Set<String> = []
    for layout in layouts {
      let target = ValidationIssue.Target.layout(layout.name)
      if layout.name.trimmingCharacters(in: .whitespaces).isEmpty {
        issues.append(.init(severity: .error, target: target, field: .name, message: "Name the layout."))
      } else if !seen.insert(layout.name).inserted {
        issues.append(
          .init(severity: .error, target: target, field: .name, message: "Another layout already has this name."))
      }
      for app in layout.apps {
        for op in app.operations {
          for problem in actionProblems(op, knownLayouts: knownLayouts) where problem.severity == .error {
            issues.append(
              .init(severity: .error, target: target, field: .action, message: "\(app.app): \(problem.message)"))
          }
        }
      }
    }
    return issues
  }

  // MARK: Saving

  /// The configuration to write: the draft, except that items with errors fall back to their last
  /// saved version (or are left out if they were never saved). Layouts have no stable identity
  /// beyond their name, which is exactly what's being edited when a name clashes or is empty, so
  /// any layout error keeps all layouts as last saved.
  static func savable(
    _ draft: SlatedConfiguration, lastSaved: SlatedConfiguration, issues: [ValidationIssue]
  ) -> SlatedConfiguration {
    var bad = Set<ValidationIssue.Target>()
    for issue in issues where issue.severity == .error { bad.insert(issue.target) }
    guard !bad.isEmpty else { return draft }
    var result = draft
    result.bindings = draft.bindings.compactMap { binding in
      bad.contains(.binding(binding.id)) ? lastSaved.bindings.first { $0.id == binding.id } : binding
    }
    result.hotstrings = draft.hotstrings.compactMap { hotstring in
      bad.contains(.hotstring(hotstring.id)) ? lastSaved.hotstrings.first { $0.id == hotstring.id } : hotstring
    }
    if bad.contains(where: { if case .layout = $0 { return true } else { return false } }) {
      result.layouts = lastSaved.layouts
    }
    return result
  }
}

extension HotkeyBinding {
  /// Whether the two bindings can be live at the same time: either works everywhere, or they share
  /// an app.
  func sharesApps(with other: HotkeyBinding) -> Bool {
    onlyInApps.isEmpty || other.onlyInApps.isEmpty || !Set(onlyInApps).isDisjoint(with: other.onlyInApps)
  }
}

/// Keys of `RuntimeStatus.hotkeys`: the combo string, prefixed with the modal key and a space.
enum BindingStatusKey {
  static func key(_ keys: KeyCombo, modal: ModalKey?) -> String {
    (modal.map { $0.keys.string + " " } ?? "") + keys.string
  }
}

/// The display title of a binding: its name, else the action's title.
enum BindingTitle {
  static func title(for binding: HotkeyBinding) -> String {
    if let name = binding.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
    return ActionDescriber.title(binding.action)
  }

  /// Secondary text for list rows: what the action is, without repeating the title.
  /// "Cycle Left" → "Cycle Left Half → Left Third → …"; "Left Half" → "Push to Edge"; "Undo" → "Snapshots".
  static func subtitle(for binding: HotkeyBinding) -> String {
    let title = title(for: binding)
    let actionTitle = ActionDescriber.title(binding.action)
    if actionTitle != title { return actionTitle }
    let kind = ActionKind(binding.action)
    return kind.title != title ? kind.title : kind.category.rawValue
  }
}

/// Rules for what makes a good global shortcut.
enum ShortcutRules {
  static func isFunctionKey(_ key: String) -> Bool {
    key.hasPrefix("f") && Int(key.dropFirst()) != nil
  }

  /// Global shortcuts need ⌃, ⌥ or ⌘ unless they're on a function key or an extra mouse button;
  /// otherwise they'd swallow typing.
  static func isAcceptableGlobalShortcut(_ combo: KeyCombo) -> Bool {
    isFunctionKey(combo.key) || KeyNames.isMouseButton(combo.key)
      || !combo.modifiers.intersection([.control, .option, .command]).isEmpty
  }
}
