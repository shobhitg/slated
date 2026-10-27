import AppKit
import SlatedCore
import SlatedScript
import SlatedUI

/// Runs `~/.slate.js` files on the JavaScript engine and turns what they register into hotkeys,
/// layouts, defaults and event handlers.
final class JavaScriptSources {
  private(set) var settings = SlateSettings()
  /// Layouts that are plain operations; the action runner applies them like any other layout.
  private(set) var layouts: [Layout] = []
  /// Display defaults whose target is a layout or snapshot name.
  private(set) var defaults: [ScreenDefault] = []

  private let host = AppScriptHost()
  private var engines: [String: SlateScriptEngine] = [:]
  private var bindings: [(engine: SlateScriptEngine, binding: ScriptBinding)] = []
  /// Layouts with JavaScript steps, run through their engine.
  private var scriptLayouts: [String: (engine: SlateScriptEngine, layout: ScriptLayout)] = [:]
  private var callbackDefaults: [(engine: SlateScriptEngine, condition: ScreenDefault.Condition, id: ScriptCallbackID)] = []
  private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
  private weak var runner: ActionRunner?
  /// Problems from running scripts (as opposed to loading them).
  var onDiagnostics: (([Diagnostic]) -> Void)?

  func reset() {
    settings = SlateSettings()
    layouts = []
    defaults = []
    bindings = []
    scriptLayouts = [:]
    callbackDefaults = []
    // A script that isn't loaded again (Slate files turned off, the file deleted) gets no more events.
    for observer in observers { observer.center.removeObserver(observer.token) }
    observers.removeAll()
  }

  func load(path: String, displayPath: String, runner: ActionRunner) -> SlateSource {
    self.runner = runner
    host.runner = runner
    runner.externalLayout = { [weak self] name in self?.runLayout(named: name) ?? false }

    let engine = engines[path] ?? SlateScriptEngine(host: host)
    engines[path] = engine
    let result = engine.load(path: path)

    settings = settings.merging(engine.evaluatedSettings())
    for layout in result.layouts {
      if let plain = layout.staticLayout {
        layouts.append(plain)
      } else {
        scriptLayouts[layout.name] = (engine, layout)
      }
    }
    for entry in result.defaults {
      if let plain = entry.screenDefault {
        defaults.append(plain)
      } else if case .callback(let id) = entry.target {
        callbackDefaults.append((engine, entry.condition, id))
      }
    }
    bindings += result.bindings.map { (engine, $0) }
    observeEvents(result.events, engine: engine)

    return SlateSource(
      path: displayPath, kind: .javascript, exists: true,
      loaded: !result.hasErrors || !result.bindings.isEmpty,
      bindings: result.bindings.map {
        SourceBinding(keys: $0.keys, modal: $0.modal, summary: $0.summary, action: $0.target.action)
      },
      layouts: result.layouts.compactMap(\.staticLayout),
      diagnostics: result.diagnostics)
  }

  func entries(settings: SlateSettings) -> [HotkeyManager.Entry] {
    bindings.map { item in
      let binding = item.binding
      let source = binding.file.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "JavaScript"
      return HotkeyManager.Entry(keys: binding.keys, modal: binding.modal, repeats: binding.repeats, source: source) {
        [weak self] in
        switch binding.target {
        case .action(let action):
          self?.runner?.run(
            action, chainKey: "js:\(binding.keystroke)", trigger: "hotkey \(binding.keys.string)", source: source)
        case .callback:
          let start = CFAbsoluteTimeGetCurrent()
          let result = item.engine.invoke(binding)
          var data: [String: Any] = [
            "trigger": "hotkey \(binding.keys.string)", "source": source, "function": binding.summary,
            "ms": (CFAbsoluteTimeGetCurrent() - start) * 1000,
          ]
          if !result.diagnostics.isEmpty { data["errors"] = result.diagnostics.map(\.description) }
          Log.record(result.success ? "script.binding" : "script.binding_failed", level: result.success ? .info : .error, data)
          if !result.diagnostics.isEmpty { self?.onDiagnostics?(result.diagnostics) }
        }
      }
    }
  }

  /// Runs JavaScript display defaults matching the current screens. Returns true if one ran.
  @discardableResult
  func runCallbackDefaults(screens: [ScreenInfo]) -> Bool {
    let resolutions = screens.map(\.resolution).sorted()
    for entry in callbackDefaults {
      let matches: Bool
      switch entry.condition {
      case .count(let n): matches = screens.count == n
      case .resolutions(let list): matches = list.sorted() == resolutions
      }
      if matches {
        report(entry.engine.run(.callback(entry.id), on: nil))
        return true
      }
    }
    return false
  }

  private func runLayout(named name: String) -> Bool {
    guard let (engine, layout) = scriptLayouts[name] else { return false }
    for step in layout.before { report(engine.run(step, on: nil)) }
    for app in layout.apps {
      guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app.app }),
        !app.operations.isEmpty
      else { continue }
      let windows = host.windows(ofApp: running.processIdentifier)
      for (i, window) in windows.enumerated() {
        let index: Int
        if i < app.operations.count {
          index = i
        } else if app.options.repeat {
          index = i % app.operations.count
        } else if app.options.repeatLast {
          index = app.operations.count - 1
        } else {
          break
        }
        let result = engine.run(app.operations[index], on: window)
        report(result)
        if !result.success && !app.options.ignoreFail { break }
      }
    }
    for step in layout.after { report(engine.run(step, on: nil)) }
    return true
  }

  // MARK: Events (`slate.on`)

  /// Adds this file's observers; `reset()` removes them before the next load.
  private func observeEvents(_ events: Set<ScriptEventName>, engine: SlateScriptEngine) {
    let center = NSWorkspace.shared.notificationCenter
    let workspace: [(ScriptEventName, Notification.Name)] = [
      (.appOpened, NSWorkspace.didLaunchApplicationNotification),
      (.appClosed, NSWorkspace.didTerminateApplicationNotification),
      (.appHidden, NSWorkspace.didHideApplicationNotification),
      (.appUnhidden, NSWorkspace.didUnhideApplicationNotification),
      (.appActivated, NSWorkspace.didActivateApplicationNotification),
      (.appDeactivated, NSWorkspace.didDeactivateApplicationNotification),
    ]
    for (event, name) in workspace where events.contains(event) {
      let token = center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self, weak engine] note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let info = ScriptAppInfo(pid: app.processIdentifier, name: app.localizedName ?? "", bundleID: app.bundleIdentifier)
        MainActor.assumeIsolated {
          guard let engine else { return }
          let scriptEvent: ScriptEvent
          switch event {
          case .appOpened: scriptEvent = .appOpened(info)
          case .appClosed: scriptEvent = .appClosed(info)
          case .appHidden: scriptEvent = .appHidden(info)
          case .appUnhidden: scriptEvent = .appUnhidden(info)
          case .appActivated: scriptEvent = .appActivated(info)
          default: scriptEvent = .appDeactivated(info)
          }
          self?.report(engine.dispatch(event: scriptEvent))
        }
      }
      observers.append((center, token))
    }
    if events.contains(.screenConfigurationChanged) {
      let token = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self, weak engine] _ in
        MainActor.assumeIsolated {
          guard let engine else { return }
          self?.report(engine.dispatch(event: .screenConfigurationChanged))
        }
      }
      observers.append((NotificationCenter.default, token))
    }
    let unsupported = events.subtracting(Set(workspace.map(\.0)) + [.screenConfigurationChanged])
    if !unsupported.isEmpty {
      Log.record("script.unsupported_events", level: .notice, ["events": unsupported.map(\.rawValue).sorted()])
    }
  }

  private func report(_ result: ScriptRunResult) {
    if !result.diagnostics.isEmpty { onDiagnostics?(result.diagnostics) }
  }
}
