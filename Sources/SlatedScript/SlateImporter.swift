import Foundation
import SlatedCore

/// Converts a Slate JavaScript config into plain Slated bindings, so it can be edited in the UI and the
/// script retired.
///
/// Static operations convert directly. A bound function is run against a pretend Mac: once with the
/// focused window on a landscape screen and once on a portrait screen. If each run performs exactly
/// one operation, the binding becomes that operation (or a `by-orientation` pair when they differ).
/// Anything else genuinely needs JavaScript and is reported as skipped.
@MainActor
public enum SlateImporter {
  public struct Result: Sendable {
    public var bindings: [HotkeyBinding]
    /// Keystrokes that couldn't be converted, with the reason.
    public var skipped: [(keystroke: String, reason: String)]
    public var diagnostics: [Diagnostic]
  }

  public static func importJavaScript(
    path: String, readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> Result {
    let host = ProbeHost()
    let engine = SlateScriptEngine(host: host, readFile: readFile)
    let loaded = engine.load(path: path)
    var bindings: [HotkeyBinding] = []
    var skipped: [(String, String)] = []

    for (index, binding) in loaded.bindings.enumerated() {
      // An explicit `repeat` argument carries over. Without one, a static operation keeps following
      // `repeatOnHoldOps`, and a bound function keeps Slate's rule: no repeat unless asked
      // (`binding.repeats` already resolved that), whatever operation it turns into.
      let pending = engine.pendingBindings.indices.contains(index) ? engine.pendingBindings[index] : nil
      let repeats = binding.target.action == nil ? binding.repeats : pending?.explicitRepeat
      let action: Action
      switch binding.target {
      case .action(let staticAction):
        action = staticAction
      case .callback:
        let landscape = host.probe(on: ProbeHost.landscapeWindow) { _ = engine.invoke(binding) }
        let portrait = host.probe(on: ProbeHost.portraitWindow) { _ = engine.invoke(binding) }
        guard landscape.count == 1, portrait.count == 1, host.sideEffects == 0 else {
          skipped.append((binding.keystroke, "uses JavaScript logic Slated can't express without a script"))
          continue
        }
        action = landscape[0] == portrait[0] ? landscape[0] : .byOrientation(landscape: landscape[0], portrait: portrait[0])
      }
      bindings.append(
        HotkeyBinding(name: nil, keys: binding.keys, modal: binding.modal, action: action, repeats: repeats))
    }

    // The app turns the Slate files off after an import that skipped nothing, so everything else the
    // script set up that doesn't become part of Slated's config is listed too; the file then keeps
    // running it. Plain layouts and settings are imported by the app.
    for event in ScriptEventName.allCases where loaded.events.contains(event) {
      skipped.append(("slate.on(\"\(event.rawValue)\")", "event handlers need JavaScript"))
    }
    for name in engine.configFunctions.keys.sorted() {
      skipped.append(("slate.config(\"\(name)\")", "its value comes from a JavaScript function"))
    }
    for layout in loaded.layouts where layout.staticLayout == nil {
      skipped.append(("slate.layout(\"\(layout.name)\")", "has steps that run JavaScript"))
    }
    for entry in loaded.defaults {
      let reason = entry.screenDefault == nil ? "runs JavaScript" : "display defaults aren't imported yet"
      skipped.append(("slate.default(\(describe(entry.condition)))", reason))
    }
    return Result(bindings: bindings, skipped: skipped, diagnostics: loaded.diagnostics)
  }

  private static func describe(_ condition: ScreenDefault.Condition) -> String {
    switch condition {
    case .count(let count): return count == 1 ? "1 screen" : "\(count) screens"
    case .resolutions(let resolutions): return resolutions.joined(separator: ", ")
    }
  }
}

/// A pretend Mac with a landscape and a portrait screen, one window on each. Records the operations
/// a script performs instead of doing anything.
@MainActor
private final class ProbeHost: ScriptHost {
  static let landscapeWindow = WindowHandle(1)
  static let portraitWindow = WindowHandle(2)

  private var focused: WindowHandle? = landscapeWindow
  private var recorded: [Action] = []
  /// Things a script did besides performing operations (moving, focusing, shell); such bindings need
  /// JavaScript.
  private(set) var sideEffects = 0

  private let screenList = [
    ScreenInfo(
      displayID: 1, name: "Landscape", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055), isMain: true),
    ScreenInfo(
      displayID: 2, name: "Portrait", frame: CGRect(x: 1920, y: 0, width: 1080, height: 1920),
      visibleFrame: CGRect(x: 1920, y: 0, width: 1080, height: 1920), isMain: false),
  ]

  func probe(on window: WindowHandle, _ body: () -> Void) -> [Action] {
    focused = window
    recorded = []
    body()
    return recorded
  }

  func focusedWindow() -> WindowHandle? { focused }

  func windowInfo(_ window: WindowHandle) -> ScriptWindowInfo? {
    let frame =
      window == Self.landscapeWindow
      ? CGRect(x: 200, y: 200, width: 800, height: 600) : CGRect(x: 2100, y: 300, width: 700, height: 900)
    return ScriptWindowInfo(handle: window, title: "Window", frame: frame, pid: 1, isMain: true)
  }

  func windows(ofApp pid: Int32) -> [WindowHandle] { [Self.landscapeWindow, Self.portraitWindow] }
  func runningApps() -> [ScriptAppInfo] { [ScriptAppInfo(pid: 1, name: "App")] }
  func screens() -> [ScreenInfo] { screenList }

  func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool {
    sideEffects += 1
    return true
  }

  func focus(_ window: WindowHandle) -> Bool {
    sideEffects += 1
    return true
  }

  func perform(_ action: Action, on window: WindowHandle?) -> Bool {
    recorded.append(action)
    return true
  }

  func runShell(_ command: String, wait: Bool, path: String?) -> String? {
    sideEffects += 1
    return nil
  }

  func log(_ message: String) {}
}
