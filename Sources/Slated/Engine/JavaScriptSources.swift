import Foundation
import SlatedCore
import SlatedUI

/// Runs `~/.slate.js` files. Placeholder until the JavaScriptCore engine (SlatedScript) is wired in.
final class JavaScriptSources {
  private(set) var settings = SlateSettings()
  private(set) var layouts: [Layout] = []
  private(set) var defaults: [ScreenDefault] = []

  func load(path: String, displayPath: String, runner: ActionRunner) -> SlateSource {
    SlateSource(
      path: displayPath, kind: .javascript, exists: true, loaded: false,
      diagnostics: [Diagnostic(.warning, "JavaScript configs aren't wired in yet", file: path)])
  }

  func entries(settings: SlateSettings) -> [HotkeyManager.Entry] { [] }
}
