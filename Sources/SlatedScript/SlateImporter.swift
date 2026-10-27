import Foundation
import SlatedCore

/// Converts a Slate JavaScript config into plain Slated bindings, so it can be edited in the UI and the
/// script retired.
///
/// Static operations convert directly. A bound function is run on pretend Macs (`ProbeSetup`): for each
/// orientation of the focused window's screen, twice in a row (catches state), with another app and
/// window title, with the window filling the screen, and with other display counts and sizes. If every
/// run of an orientation performs the same single operation, the binding becomes that operation (or a
/// `by-orientation` pair when the orientations differ). Anything else genuinely needs JavaScript and is
/// reported as skipped, with the reason.
@MainActor
public enum SlateImporter {
  public struct Result: Sendable {
    public var bindings: [HotkeyBinding]
    /// Display defaults (`slate.default`) that name a layout or snapshot.
    public var defaults: [ScreenDefault]
    /// Keystrokes that couldn't be converted, with the reason.
    public var skipped: [(keystroke: String, reason: String)]
    /// What the import leaves out because it never runs in Slated anyway (handlers for window
    /// events), with the reason. Unlike `skipped`, these don't need the file to stay loaded.
    public var neverRun: [(keystroke: String, reason: String)]
    /// `slate.config` names whose value comes from a function. They stay in the script (and are
    /// skipped): a copy in Slated's settings would freeze today's value and, since Slated's own
    /// settings win, override the function for good.
    public var functionSettings: [String]
    /// Why this import may not match what the script does on the real Mac: errors on the pretend Mac,
    /// shell commands or window changes while loading. The app then imports nothing from the file
    /// and keeps it loaded.
    public var problems: [String]
    /// Everything the pretend run reported while loading, errors and warnings.
    public var diagnostics: [Diagnostic]
  }

  /// The problem reported for a script that runs `slate.shell` while loading.
  public static let shellWhileLoading =
    "it runs slate.shell while loading, which the import can't do, so it can't tell what the script sets up on this Mac"

  public static func importJavaScript(
    path: String, readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> Result {
    let host = ProbeHost()
    let engine = SlateScriptEngine(host: host, readFile: readFile)
    let loaded = engine.load(path: path)
    let loadEffects = host.effects
    var problems = loaded.diagnostics.filter { $0.severity == .error }.map { "it hit an error on a test Mac: \($0)" }
    if loadEffects.contains(.shell) { problems.append(shellWhileLoading) }
    if !loadEffects.subtracting([.shell]).isEmpty {
      problems.append("it moves or focuses windows while loading, which the import can't do")
    }
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
        switch probe(binding, engine: engine, host: host) {
        case .converted(let converted): action = converted
        case .skipped(let reason):
          skipped.append((binding.keystroke, reason))
          continue
        }
      }
      bindings.append(
        HotkeyBinding(name: nil, keys: binding.keys, modal: binding.modal, action: action, repeats: repeats))
    }

    // The app turns the Slate files off after an import that skipped nothing, so everything else the
    // script set up that doesn't become part of Slated's config is listed too; the file then keeps
    // running it. Plain layouts and settings are imported by the app; plain display defaults are in
    // the result.
    var neverRun: [(String, String)] = []
    for event in ScriptEventName.allCases where loaded.events.contains(event) {
      let handler = "slate.on(\"\(event.rawValue)\")"
      if ScriptEventName.delivered.contains(event) {
        skipped.append((handler, "event handlers need JavaScript"))
      } else {
        neverRun.append((handler, "Slated doesn't deliver window events, so this never runs"))
      }
    }
    for name in engine.configFunctions.keys.sorted() {
      skipped.append(("slate.config(\"\(name)\")", "its value comes from a JavaScript function"))
    }
    for layout in loaded.layouts where layout.staticLayout == nil {
      skipped.append(("slate.layout(\"\(layout.name)\")", "has steps that run JavaScript"))
    }
    var defaults: [ScreenDefault] = []
    for entry in loaded.defaults {
      if let plain = entry.screenDefault {
        defaults.append(plain)
      } else {
        skipped.append(("slate.default(\(describe(entry.condition)))", "runs JavaScript"))
      }
    }
    return Result(
      bindings: bindings, defaults: defaults, skipped: skipped, neverRun: neverRun,
      functionSettings: engine.configFunctions.keys.sorted(),
      problems: problems, diagnostics: loaded.diagnostics)
  }

  private enum Probe {
    case converted(Action)
    case skipped(String)
  }

  /// Runs a bound function on every pretend Mac in `ProbeSetup.orientations`; see the type's
  /// documentation.
  private static func probe(_ binding: ScriptBinding, engine: SlateScriptEngine, host: ProbeHost) -> Probe {
    let needsScript = "uses JavaScript logic Slated can't express without a script"
    var actions: [Action] = []
    for setups in ProbeSetup.orientations {
      var first: Action?
      for setup in setups {
        var outcome = ScriptRunResult(success: true)
        let run = host.probe(setup, engine: engine) { outcome = engine.invoke(binding) }
        if !outcome.success, let error = outcome.diagnostics.first {
          return .skipped("stops with an error on a test Mac: \(error)")
        }
        guard run.actions.count == 1, run.effects.isEmpty else { return .skipped(needsScript) }
        // A compared name (`=== "Terminal"`) can't be found by trying other names.
        if run.readAppOrTitle { return .skipped(ProbeSetup.otherApp) }
        guard let expected = first else {
          first = run.actions[0]
          continue
        }
        if run.actions[0] != expected { return .skipped(setup.change) }
      }
      if let first { actions.append(first) }
    }
    guard actions.count == 2 else { return .skipped(needsScript) }
    return .converted(actions[0] == actions[1] ? actions[0] : .byOrientation(landscape: actions[0], portrait: actions[1]))
  }

  private static func describe(_ condition: ScreenDefault.Condition) -> String {
    switch condition {
    case .count(let count): return count == 1 ? "1 screen" : "\(count) screens"
    case .resolutions(let resolutions): return resolutions.joined(separator: ", ")
    }
  }
}

/// One pretend Mac a bound function runs on while importing: its displays, and the focused window's
/// frame, app and title.
struct ProbeSetup {
  var screens: [ScreenInfo]
  var window: CGRect
  var app = "App"
  var title = "Window"
  /// What this setup changes from the first of its orientation, worded as the reason a binding that
  /// does something different here is skipped.
  var change = ""

  static let otherApp = "depends on the focused app or window title"
  private static let again = "does something different each time it runs"
  private static let otherFrame = "depends on the focused window's position or size"
  private static let otherDisplays = "depends on how many displays there are, or their sizes"

  /// The first setup of each list is the reference; the others change one thing each.
  static let orientations = [landscape, portrait]

  /// The focused window on a landscape display.
  static let landscape: [ProbeSetup] = {
    let window = CGRect(x: 200, y: 200, width: 800, height: 600)
    return [
      ProbeSetup(screens: pair, window: window),
      ProbeSetup(screens: pair, window: window, change: again),
      ProbeSetup(screens: pair, window: window, app: "Other", title: "Document", change: otherApp),
      ProbeSetup(screens: pair, window: pair[0].visibleFrame, change: otherFrame),
      ProbeSetup(
        screens: [display(1, CGRect(x: 0, y: 0, width: 2560, height: 1440), main: true)], window: window,
        change: otherDisplays),
      ProbeSetup(screens: three, window: CGRect(x: 2840, y: 200, width: 800, height: 600), change: otherDisplays),
    ]
  }()

  /// The focused window on a portrait display.
  static let portrait: [ProbeSetup] = {
    let window = CGRect(x: 2100, y: 300, width: 700, height: 900)
    return [
      ProbeSetup(screens: pair, window: window),
      ProbeSetup(screens: pair, window: window, change: again),
      ProbeSetup(screens: pair, window: window, app: "Other", title: "Document", change: otherApp),
      ProbeSetup(screens: pair, window: pair[1].visibleFrame, change: otherFrame),
      ProbeSetup(
        screens: [display(1, CGRect(x: 0, y: 0, width: 1440, height: 2560), main: true)],
        window: CGRect(x: 100, y: 300, width: 700, height: 900), change: otherDisplays),
      ProbeSetup(screens: three, window: CGRect(x: 1640, y: 300, width: 700, height: 900), change: otherDisplays),
    ]
  }()

  /// A landscape main display and a portrait one to its right.
  private static let pair = [
    display(1, CGRect(x: 0, y: 0, width: 1920, height: 1080), main: true),
    display(2, CGRect(x: 1920, y: 0, width: 1080, height: 1920)),
  ]
  /// A small landscape main display, a portrait one and a wide one.
  private static let three = [
    display(1, CGRect(x: 0, y: 0, width: 1440, height: 900), main: true),
    display(2, CGRect(x: 1440, y: 0, width: 1200, height: 1920)),
    display(3, CGRect(x: 2640, y: 0, width: 3440, height: 1440)),
  ]

  /// The main display loses its top 25 points to the menu bar.
  private static func display(_ id: UInt32, _ frame: CGRect, main: Bool = false) -> ScreenInfo {
    let visible = main ? CGRect(x: frame.minX, y: frame.minY + 25, width: frame.width, height: frame.height - 25) : frame
    return ScreenInfo(displayID: id, name: "Display \(id)", frame: frame, visibleFrame: visible, isMain: main)
  }
}

/// A pretend Mac (a `ProbeSetup`) with the focused window and one more window of its app. Records the
/// operations a script performs instead of doing anything.
@MainActor
private final class ProbeHost: ScriptHost {
  static let focused = WindowHandle(1)
  static let other = WindowHandle(2)

  /// Things a script did besides performing operations.
  enum Effect: Hashable {
    case shell, move, focus
  }

  struct Run {
    var actions: [Action]
    /// Such a function needs JavaScript.
    var effects: Set<Effect>
    /// The function read the app's name or a window's title.
    var readAppOrTitle: Bool
  }

  /// While loading, the script sees the first landscape setup.
  private var setup = ProbeSetup.landscape[0]
  private var recorded: [Action] = []
  /// What the script did besides performing operations: while loading until the first probe, then
  /// in the current probe.
  private(set) var effects: Set<Effect> = []

  func probe(_ setup: ProbeSetup, engine: SlateScriptEngine, _ body: () -> Void) -> Run {
    self.setup = setup
    recorded = []
    effects = []
    var read = false
    engine.nativeObserver = { name in
      if name == "appName" || name == "windowTitle" { read = true }
    }
    body()
    engine.nativeObserver = nil
    return Run(actions: recorded, effects: effects, readAppOrTitle: read)
  }


  func focusedWindow() -> WindowHandle? { Self.focused }

  func windowInfo(_ window: WindowHandle) -> ScriptWindowInfo? {
    switch window {
    case Self.focused:
      return ScriptWindowInfo(handle: window, title: setup.title, frame: setup.window, pid: 1, isMain: true)
    case Self.other:
      let screen = setup.screens[0].visibleFrame
      let frame = CGRect(x: screen.minX + 40, y: screen.minY + 40, width: 400, height: 300)
      return ScriptWindowInfo(handle: window, title: "Other window", frame: frame, pid: 1, isMain: false)
    default:
      return nil
    }
  }

  func windows(ofApp pid: Int32) -> [WindowHandle] { [Self.focused, Self.other] }
  func runningApps() -> [ScriptAppInfo] { [ScriptAppInfo(pid: 1, name: setup.app)] }
  func screens() -> [ScreenInfo] { setup.screens }

  func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool {
    effects.insert(.move)
    return true
  }

  func focus(_ window: WindowHandle) -> Bool {
    effects.insert(.focus)
    return true
  }

  func perform(_ action: Action, on window: WindowHandle?) -> Bool {
    recorded.append(action)
    return true
  }

  func runShell(_ command: String, wait: Bool, path: String?) -> String? {
    effects.insert(.shell)
    return nil
  }

  func log(_ message: String) {}
}
