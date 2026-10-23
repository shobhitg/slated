import Foundation
import SlatedCore

/// Human-readable names for actions, for list rows, menus and the menu bar.
enum ActionDescriber {
  /// A short title: the preset name when the action is a known placement ("Left Half"), otherwise
  /// a plain description ("Focus Safari", "Throw to Next Display").
  static func title(_ action: Action) -> String {
    if let preset = WindowPresets.matching(action) { return preset.title }
    switch action {
    case .move: return "Move & Resize"
    case .resize(let w, let h, _): return "Resize \(w) × \(h)"
    case .push(let d, let style, _):
      switch style {
      case .bar: return "Push \(d.title), Full \(d.isVertical ? "Width" : "Height")"
      case .center: return "Push \(d.title), Centered"
      default: return "Push \(d.title)"
      }
    case .nudge(let x, let y): return "Nudge \(x), \(y)"
    case .throwWindow(let screen, let w, _):
      return "Throw to \(screenName(screen))" + (w == nil ? "" : ", Resized")
    case .corner(let c, _, _, _): return "\(c.title) Corner"
    case .chain(let ops):
      return ops.isEmpty ? "Empty Chain" : "Cycle " + ops.prefix(3).map(title).joined(separator: " → ")
    case .sequence(let steps): return steps.isEmpty ? "Empty Sequence" : "Sequence of \(steps.count)"
    case .layout(let name): return name.isEmpty ? "Apply Layout" : "Layout “\(name)”"
    case .byOrientation(let l, let p): return "\(title(l)) / \(title(p))"
    case .focus(let d): return d == .behind ? "Focus Window Behind" : "Focus \(d.rawValue.capitalized)"
    case .focusApp(let app): return app.isEmpty ? "Focus App" : "Focus \(app)"
    case .snapshot(let name, _, _): return "Snapshot “\(name)”"
    case .deleteSnapshot(let name, _): return "Delete Snapshot “\(name)”"
    case .activateSnapshot(let name, _): return "Restore Snapshot “\(name)”"
    case .hint: return "Window Hints"
    case .grid: return "Grid"
    case .hide(let s): return "Hide \(appsPhrase(s))"
    case .show(let s): return "Show \(appsPhrase(s))"
    case .toggle(let s): return "Toggle \(appsPhrase(s))"
    case .shell(let command, _, _): return command.isEmpty ? "Run Command" : "Run “\(truncate(command, 28))”"
    case .undo: return "Undo"
    case .relaunch: return "Reload Configuration"
    case .switchApp: return "App Switcher"
    case .insertText(let text, _):
      return text.isEmpty ? "Insert Text" : "Insert “\(truncate(singleLine(text), 24))”"
    case .openURL(let url): return "Open \(URL(string: url)?.host ?? truncate(url, 28))"
    case .keystroke(let combo): return "Press \(combo.display())"
    case .clipboardHistory: return "Clipboard History"
    case .click(let button, let count):
      return (count == 2 ? "Double-Click " : count > 2 ? "\(count)× Click " : "Click ") + button.rawValue.capitalized
    case .press(let input, let phase): return (phase == .down ? "Press " : "Release ") + inputTitle(input)
    case .hold(let input): return "Hold \(inputTitle(input))"
    case .autoRepeat(let action, let interval, let mode, let times, _):
      return "Repeat \(title(action)) every \(seconds(interval))" + (mode == .whileHeld ? " while held" : "")
        + (times.map { ", \($0)×" } ?? "")
    case .wait(let s): return "Wait \(seconds(s))"
    case .stopAutomations: return "Stop Automations"
    }
  }

  static func inputTitle(_ input: SyntheticInput) -> String {
    switch input {
    case .mouse(let button): return "\(button.rawValue.capitalized) Button"
    case .key(let combo): return combo.display()
    }
  }

  /// "100 ms", "0.5 s", "2 s".
  static func seconds(_ value: Double) -> String {
    if value < 1 { return "\(Int((value * 1000).rounded())) ms" }
    return value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
  }

  /// Slate syntax for secondary text, e.g. `push left bar-resize:screenSizeX/2`.
  ///
  /// Uses SlatedCore's `SlateSyntax.format` once it formats parameters (it returns just the
  /// operation name until then), so the UI and config files always agree.
  static func detail(_ action: Action) -> String {
    let formatted = SlateSyntax.format(action)
    if formatted != action.name { return formatted }
    return localDetail(action)
  }

  private static func localDetail(_ action: Action) -> String {
    switch action {
    case .move(let x, let y, let w, let h, let screen):
      return "move \(x);\(y) \(w);\(h)" + screenSuffix(screen)
    case .resize(let w, let h, let anchor):
      return "resize \(w) \(h)" + (anchor == .topLeft ? "" : " \(anchor.rawValue)")
    case .push(let d, let style, let screen):
      return "push \(d.rawValue)" + (style == .none ? "" : " \(style.slate)") + screenSuffix(screen)
    case .nudge(let x, let y): return "nudge \(x) \(y)"
    case .throwWindow(let screen, let w, let h):
      return "throw \(screen.slate)" + (w.map { " \($0);\(h ?? "")" } ?? "")
    case .corner(let c, let w, let h, let screen):
      return "corner \(c.rawValue)" + (w.map { " resize:\($0);\(h ?? "")" } ?? "") + screenSuffix(screen)
    case .chain(let ops): return ops.map { $0.name }.joined(separator: " | ")
    case .sequence(let steps):
      return steps.enumerated().map { i, step in
        (i == 0 ? "" : (step.keepWindow ? "> " : "| ")) + step.action.name
      }.joined(separator: " ")
    case .layout(let name): return "layout \(name)"
    case .byOrientation(let l, let p): return "landscape: \(localDetail(l)) · portrait: \(localDetail(p))"
    case .focus(let d): return "focus \(d.rawValue)"
    case .focusApp(let app): return "focus '\(app)'"
    case .snapshot(let name, let save, let stack):
      return "snapshot \(name)" + (save ? " save-to-disk" : "") + (stack ? " stack" : "")
    case .deleteSnapshot(let name, let all): return "delete \(name)" + (all ? " all" : "")
    case .activateSnapshot(let name, let delete): return "activate-snapshot \(name)" + (delete ? " delete" : "")
    case .hint(let chars): return "hint" + (chars.map { " \($0)" } ?? "")
    case .grid(let padding, let grids):
      return "grid" + (padding.map { " padding:\($0)" } ?? "")
        + grids.map { " \($0.screen):\($0.width),\($0.height)" }.joined()
    case .hide(let s): return "hide \(selectorSyntax(s))"
    case .show(let s): return "show \(selectorSyntax(s))"
    case .toggle(let s): return "toggle \(selectorSyntax(s))"
    case .shell(let command, let wait, _): return "shell" + (wait ? " wait" : "") + " '\(command)'"
    case .undo: return "undo"
    case .relaunch: return "relaunch"
    case .switchApp: return "switch"
    case .insertText(let text, let method):
      return "insert-text" + (method == .auto ? "" : " (\(method.rawValue))") + " “\(truncate(singleLine(text), 40))”"
    case .openURL(let url): return url
    case .keystroke(let combo): return "keystroke \(combo.string)"
    case .clipboardHistory, .click, .press, .hold, .autoRepeat, .wait, .stopAutomations:
      return SlateSyntax.format(action)
    }
  }

  static func screenName(_ ref: ScreenRef) -> String {
    switch ref {
    case .index(let i): return "Display \(i + 1)"
    case .orderedIndex(let i): return "Display \(i + 1) (left to right)"
    case .resolution(let w, let h): return "the \(w)×\(h) Display"
    case .relative(let d): return "\(d.title) Display"
    case .next: return "Next Display"
    case .previous: return "Previous Display"
    }
  }

  static func appsPhrase(_ selector: AppSelector) -> String {
    switch selector {
    case .current: return "Current App"
    case .all: return "All Apps"
    case .allBut(let app): return "All but \(app)"
    case .apps(let apps):
      if apps.isEmpty { return "Apps" }
      return apps.count <= 2 ? apps.joined(separator: " & ") : "\(apps[0]) & \(apps.count - 1) more"
    }
  }

  private static func selectorSyntax(_ selector: AppSelector) -> String {
    switch selector {
    case .current: return "current"
    case .all: return "all"
    case .allBut(let app): return "all-but:'\(app)'"
    case .apps(let apps): return apps.map { "'\($0)'" }.joined(separator: " ")
    }
  }

  private static func screenSuffix(_ screen: ScreenRef?) -> String { screen.map { " \($0.slate)" } ?? "" }

  static func truncate(_ s: String, _ max: Int) -> String {
    s.count <= max ? s : String(s.prefix(max - 1)) + "…"
  }

  static func singleLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ⏎ ")
  }
}

extension Direction {
  var title: String {
    switch self {
    case .left: return "Left"
    case .right: return "Right"
    case .up: return "Up"
    case .down: return "Down"
    }
  }

  var isVertical: Bool { self == .up || self == .down }
}

extension Corner {
  var title: String {
    switch self {
    case .topLeft: return "Top Left"
    case .topRight: return "Top Right"
    case .bottomLeft: return "Bottom Left"
    case .bottomRight: return "Bottom Right"
    }
  }
}
