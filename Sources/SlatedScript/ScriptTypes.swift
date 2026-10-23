import Foundation
import SlatedCore

/// Identifies a JavaScript function (or an operation that contains one) owned by a
/// `SlateScriptEngine`. Run it with `SlateScriptEngine.run(_:on:)`.
///
/// IDs are never reused within an engine, so a stale ID from an earlier load fails cleanly instead of
/// running the wrong function.
public struct ScriptCallbackID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public var rawValue: Int

  public init(rawValue: Int) { self.rawValue = rawValue }

  public var description: String { "callback #\(rawValue)" }
}

/// What a binding, layout step or event runs: a plain operation the app performs itself, or
/// JavaScript that only the engine can run.
public enum ScriptTarget: Hashable, Sendable {
  case action(Action)
  case callback(ScriptCallbackID)

  /// The operation, when the target is static.
  public var action: Action? {
    if case .action(let action) = self { return action }
    return nil
  }
}

/// A `slate.bind(...)`.
public struct ScriptBinding: Hashable, Sendable {
  /// The keystroke as written in the script, e.g. `"a:ctrl,shift,alt,cmd"`.
  public var keystroke: String
  public var keys: KeyCombo
  public var modal: ModalKey?
  /// Repeat while held: the script's explicit `repeat` argument, otherwise whether the operation is
  /// in Slate's `repeatOnHoldOps` setting (JavaScript functions don't repeat unless asked to).
  public var repeats: Bool
  public var target: ScriptTarget
  /// Short description for the UI, e.g. "corner top-right" or "JavaScript function".
  public var summary: String
  /// Where the binding was made (the config file or a file it `source`d).
  public var file: String?
  public var line: Int?

  public init(
    keystroke: String, keys: KeyCombo, modal: ModalKey? = nil, repeats: Bool = false, target: ScriptTarget,
    summary: String, file: String? = nil, line: Int? = nil
  ) {
    self.keystroke = keystroke
    self.keys = keys
    self.modal = modal
    self.repeats = repeats
    self.target = target
    self.summary = summary
    self.file = file
    self.line = line
  }
}

/// A `slate.layout(name, {...})`. Like `Layout`, but steps may be JavaScript functions.
public struct ScriptLayout: Hashable, Sendable {
  public struct App: Hashable, Sendable {
    public var app: String
    /// Applied to the app's windows in order, like `LayoutApp.operations`.
    public var operations: [ScriptTarget]
    public var options: LayoutAppOptions

    public init(app: String, operations: [ScriptTarget], options: LayoutAppOptions = .init()) {
      self.app = app
      self.operations = operations
      self.options = options
    }
  }

  public var name: String
  /// In the order the script listed them.
  public var apps: [App]
  /// Slate's `_before_` entry.
  public var before: [ScriptTarget]
  /// Slate's `_after_` entry.
  public var after: [ScriptTarget]

  public init(name: String, apps: [App] = [], before: [ScriptTarget] = [], after: [ScriptTarget] = []) {
    self.name = name
    self.apps = apps
    self.before = before
    self.after = after
  }

  /// A layout from a classic `.slate` file (every step is static).
  public init(_ layout: Layout) {
    self.init(
      name: layout.name,
      apps: layout.apps.map {
        App(app: $0.app, operations: $0.operations.map(ScriptTarget.action), options: $0.options)
      },
      before: layout.before.map(ScriptTarget.action), after: layout.after.map(ScriptTarget.action))
  }

  /// The layout as a plain `Layout`, when no step is a JavaScript function.
  public var staticLayout: Layout? {
    func actions(_ targets: [ScriptTarget]) -> [Action]? {
      let actions = targets.compactMap(\.action)
      return actions.count == targets.count ? actions : nil
    }
    guard let before = actions(before), let after = actions(after) else { return nil }
    var apps: [LayoutApp] = []
    for app in self.apps {
      guard let operations = actions(app.operations) else { return nil }
      apps.append(LayoutApp(app: app.app, operations: operations, options: app.options))
    }
    return Layout(name: name, apps: apps, before: before, after: after)
  }
}

/// A `slate.default(screens, layoutOrFunction)`: what to run when the display setup matches.
public struct ScriptDefault: Hashable, Sendable {
  public enum Target: Hashable, Sendable {
    /// A layout or snapshot name.
    case name(String)
    /// A JavaScript function (run it on the focused window).
    case callback(ScriptCallbackID)
  }

  public var condition: ScreenDefault.Condition
  public var target: Target

  public init(condition: ScreenDefault.Condition, target: Target) {
    self.condition = condition
    self.target = target
  }

  /// The default as a plain `ScreenDefault`, when it names a layout or snapshot.
  public var screenDefault: ScreenDefault? {
    if case .name(let name) = target { return ScreenDefault(target: name, condition: condition) }
    return nil
  }
}

/// The events `slate.on(event, callback)` accepts.
public enum ScriptEventName: String, CaseIterable, Hashable, Sendable {
  case windowOpened, windowClosed, windowMoved, windowResized, windowFocused, windowTitleChanged
  case appOpened, appClosed, appHidden, appUnhidden, appActivated, appDeactivated
  case screenConfigurationChanged
}

/// Something that happened, for `SlateScriptEngine.dispatch(event:)`.
///
/// Callbacks receive `(eventName, payload)`. As in Slate, the payload is a window object for
/// `windowOpened`, `windowFocused` and `windowTitleChanged`; an app object for the app events and for
/// `windowClosed`, `windowMoved` and `windowResized`; and `undefined` for
/// `screenConfigurationChanged`.
public enum ScriptEvent: Hashable, Sendable {
  case windowOpened(WindowHandle)
  /// The window is gone, so the event carries its app.
  case windowClosed(ScriptAppInfo)
  case windowMoved(WindowHandle)
  case windowResized(WindowHandle)
  case windowFocused(WindowHandle)
  case windowTitleChanged(WindowHandle)
  case appOpened(ScriptAppInfo)
  case appClosed(ScriptAppInfo)
  case appHidden(ScriptAppInfo)
  case appUnhidden(ScriptAppInfo)
  case appActivated(ScriptAppInfo)
  case appDeactivated(ScriptAppInfo)
  case screenConfigurationChanged

  public var name: ScriptEventName {
    switch self {
    case .windowOpened: return .windowOpened
    case .windowClosed: return .windowClosed
    case .windowMoved: return .windowMoved
    case .windowResized: return .windowResized
    case .windowFocused: return .windowFocused
    case .windowTitleChanged: return .windowTitleChanged
    case .appOpened: return .appOpened
    case .appClosed: return .appClosed
    case .appHidden: return .appHidden
    case .appUnhidden: return .appUnhidden
    case .appActivated: return .appActivated
    case .appDeactivated: return .appDeactivated
    case .screenConfigurationChanged: return .screenConfigurationChanged
    }
  }
}

/// Everything a script registered while it loaded.
public struct ScriptLoadResult: Sendable {
  /// The file that was loaded, if it came from disk.
  public var path: String?
  /// In the order the script bound them.
  public var bindings: [ScriptBinding]
  /// `slate.config` values. Function values are evaluated once, at the end of loading; see
  /// `SlateScriptEngine.evaluatedSettings()` for fresh values.
  public var settings: SlateSettings
  public var layouts: [ScriptLayout]
  public var defaults: [ScriptDefault]
  /// Events with at least one `slate.on` handler, so the app only observes what it must.
  public var events: Set<ScriptEventName>
  /// Files loaded with `slate.source`, for watching.
  public var sourcedFiles: [String]
  public var diagnostics: [Diagnostic]

  public init(
    path: String? = nil, bindings: [ScriptBinding] = [], settings: SlateSettings = .init(),
    layouts: [ScriptLayout] = [], defaults: [ScriptDefault] = [], events: Set<ScriptEventName> = [],
    sourcedFiles: [String] = [], diagnostics: [Diagnostic] = []
  ) {
    self.path = path
    self.bindings = bindings
    self.settings = settings
    self.layouts = layouts
    self.defaults = defaults
    self.events = events
    self.sourcedFiles = sourcedFiles
    self.diagnostics = diagnostics
  }

  public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

/// Outcome of running a binding, layout step or event handler.
public struct ScriptRunResult: Sendable {
  /// False when the operation failed or the JavaScript threw.
  public var success: Bool
  /// JavaScript errors and API misuse found while running, with file and line where known.
  public var diagnostics: [Diagnostic]

  public init(success: Bool, diagnostics: [Diagnostic] = []) {
    self.success = success
    self.diagnostics = diagnostics
  }
}
