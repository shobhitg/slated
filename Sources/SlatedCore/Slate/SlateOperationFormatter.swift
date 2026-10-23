import Foundation

/// Formats actions as Slate operation strings (`SlateSyntax.format`).
///
/// Output is canonical: lowercase names, `;` between coordinates, single spaces, `up`/`down` rather than
/// `top`/`bottom`, and quotes only where needed (app names and shell commands are always quoted, as Slate
/// expects). Parameters that contain spaces, such as expressions written in JavaScript configs, are
/// quoted so they read back unchanged.
enum SlateOperationFormatter {
  static func format(_ action: Action) -> String {
    switch action {
    case .move(let x, let y, let width, let height, let screen):
      return join("move", word("\(x);\(y)"), word("\(width);\(height)"), screen.map { word($0.slate) })

    case .resize(let width, let height, let anchor):
      return join("resize", word(width), word(height), anchor == .topLeft ? nil : anchor.rawValue)

    case .push(let direction, let style, let screen):
      let styleWord = style == .none && screen == nil ? nil : word(style.slate)
      return join("push", direction.rawValue, styleWord, screen.map { word($0.slate) })

    case .nudge(let x, let y):
      return join("nudge", word(x), word(y))

    case .throwWindow(let screen, let width, let height):
      return join("throw", word(screen.slate), resizeStyle(width, height, plainResizeAllowed: true))

    case .corner(let corner, let width, let height, let screen):
      // `noresize` keeps the screen in the fourth position, which Slate also reads that way.
      let style = resizeStyle(width, height, plainResizeAllowed: false) ?? (screen == nil ? nil : "noresize")
      return join("corner", corner.rawValue, style, screen.map { word($0.slate) })

    case .chain(let actions):
      return "chain " + actions.map(format).joined(separator: " | ")

    case .sequence(let steps):
      var text = "sequence"
      for (index, step) in steps.enumerated() {
        if index > 0 { text += step.keepWindow ? " >" : " |" }
        text += " " + format(step.action)
      }
      return text

    case .layout(let name):
      return join("layout", word(name))

    case .focus(let direction):
      return join("focus", direction.rawValue)

    case .focusApp(let app):
      return join("focus", SlateTokenizer.quote(app))

    case .snapshot(let name, let save, let stack):
      let options = [save ? "save-to-disk" : nil, stack ? "stack" : nil].compactMap { $0 }
      return join("snapshot", word(name), options.isEmpty ? nil : options.joined(separator: ";"))

    case .deleteSnapshot(let name, let all):
      return join("delete-snapshot", word(name), all ? "all" : nil)

    case .activateSnapshot(let name, let delete):
      return join("activate-snapshot", word(name), delete ? "delete" : nil)

    case .hint(let characters):
      return join("hint", characters.map(word))

    case .grid(let padding, let grids):
      let sizes = grids.map { "\($0.screen):\($0.width),\($0.height)" }
      return (["grid", padding.map { "padding:\($0)" }].compactMap { $0 } + sizes).joined(separator: " ")

    case .hide(let apps), .show(let apps), .toggle(let apps):
      return join(action.name, appList(apps))

    case .shell(let command, let wait, let path):
      return join(
        "shell", wait ? "wait" : nil, path.map { "path:" + word($0) }, SlateTokenizer.quote(command))

    case .undo, .relaunch, .switchApp:
      return action.name

    case .insertText(let text, let method):
      return join(
        "insert-text", method == .auto ? nil : method.rawValue, SlateTokenizer.quote(SlateSyntax.escapeText(text)))

    case .openURL(let url):
      return join("open-url", SlateTokenizer.quote(url))

    case .keystroke(let combo):
      return join("keystroke", word(combo.string))
    }
  }

  private static func join(_ name: String, _ parameters: String?...) -> String {
    ([name] + parameters.compactMap { $0 }).joined(separator: " ")
  }

  private static func word(_ text: String) -> String { SlateTokenizer.quoteIfNeeded(text) }

  /// `resize` (throw only, when the size is the whole screen), `resize:width;height`, or nil for no resize.
  /// A missing dimension keeps the window's own, which Slate spells `windowSizeX`/`windowSizeY`.
  private static func resizeStyle(_ width: String?, _ height: String?, plainResizeAllowed: Bool) -> String? {
    guard width != nil || height != nil else { return nil }
    if plainResizeAllowed, width == "screenSizeX", height == "screenSizeY" { return "resize" }
    return word("resize:\(width ?? "windowSizeX");\(height ?? "windowSizeY")")
  }

  private static func appList(_ apps: AppSelector) -> String {
    switch apps {
    case .current: return "current"
    case .all: return "all"
    case .allBut(let app): return "all-but:" + SlateTokenizer.quote(app)
    case .apps(let names): return names.map(SlateTokenizer.quote).joined(separator: ",")
    }
  }
}
