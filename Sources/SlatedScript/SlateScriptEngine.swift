import Foundation
import JavaScriptCore
import SlatedCore

/// Runs Slate JavaScript configs (`~/.slate.js`) on JavaScriptCore and collects what they register.
///
/// Every `load` starts a fresh JavaScript context. Plain operations come out as `Action`s the app
/// performs itself; anything that needs JavaScript at run time (bound functions, layout steps,
/// event handlers) stays in the engine and runs through `invoke(_:)`, `run(_:on:)` and
/// `dispatch(event:)`. Scripts can't crash the app: exceptions and API misuse become `Diagnostic`s
/// with file and line.
@MainActor
public final class SlateScriptEngine {
  public let host: any ScriptHost
  /// What the last `load` registered.
  public private(set) var result = ScriptLoadResult()

  let readFile: (String) -> String?

  // MARK: State of the current load (reset by every `load`)

  var context: JSContext?
  var classes: PreludeClasses?
  var isLoading = false
  /// Files being evaluated, innermost last, for diagnostics and `slate.source` loops.
  var loadingFiles: [String] = []
  var pendingBindings: [PendingBinding] = []
  var settings = SlateSettings()
  /// `slate.config` values that are functions, evaluated when settings are read.
  var configFunctions: [String: JSValue] = [:]
  var layouts: [ScriptLayout] = []
  var defaults: [ScriptDefault] = []
  var eventHandlers: [ScriptEventName: [JSValue]] = [:]
  var callbacks: [ScriptCallbackID: Callback] = [:]
  /// Next step of each JavaScript-backed chain, per window (Slate cycles chains per window).
  var chainPositions: [Int: [WindowHandle?: Int]] = [:]
  var sourcedFiles: [String] = []

  // MARK: Running state

  var diagnostics: [Diagnostic] = []
  /// Native functions currently executing. Exceptions thrown by JavaScript they call are handed back
  /// to the script that called them instead of being reported on the spot.
  var nativeDepth = 0
  var capturedException: JSValue?
  var recordedExceptions = 0
  /// The window JavaScript is running for (`slate.window()`); nil entries mean "no window".
  var windowContext: [WindowHandle?] = []
  /// Told the name of every native function the script calls (the importer watches for reads of the
  /// app name and window title).
  var nativeObserver: ((String) -> Void)?

  // MARK: Never reset, so IDs from an earlier load can't be confused with new ones

  var nextCallbackID = 1
  var nextOperationID = 1

  /// - Parameter readFile: Loads files for `load(path:)` and `slate.source`; injectable for tests.
  public init(
    host: any ScriptHost,
    readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) {
    self.host = host
    self.readFile = readFile
  }

  // MARK: - Loading

  /// Loads a config file (`~` is expanded), replacing everything from the previous load.
  ///
  /// Don't call it while the engine is running a script (from inside `ScriptHost.perform`, say);
  /// schedule the reload instead. Such a call changes nothing and returns an error.
  @discardableResult
  public func load(path: String) -> ScriptLoadResult {
    let expanded = (path as NSString).expandingTildeInPath
    if let busy = refuseReentrantLoad(path: expanded) { return busy }
    guard let source = readFile(expanded) else {
      reset()
      diagnostics.append(
        Diagnostic(.error, "Couldn't read \(path). Check that the file exists and is readable.", file: expanded))
      return finishLoad(path: expanded)
    }
    return load(source: source, path: expanded)
  }

  /// Loads a script from a string, replacing everything from the previous load. `path` is used for
  /// diagnostics.
  @discardableResult
  public func load(source: String, path: String? = nil) -> ScriptLoadResult {
    if let busy = refuseReentrantLoad(path: path) { return busy }
    reset()
    isLoading = true
    if let path { loadingFiles.append(path) }
    evaluate(source, path: path)
    loadingFiles.removeAll()
    isLoading = false
    return finishLoad(path: path)
  }

  /// Slate settings with `slate.config` functions evaluated now.
  public func evaluatedSettings() -> SlateSettings {
    var values = settings
    _ = activity {
      values = settingsEvaluatingFunctions()
      return true
    }
    return values
  }

  /// The layout named `name` from the last load.
  public func layout(named name: String) -> ScriptLayout? {
    layouts.first { $0.name == name }
  }

  // MARK: - Running

  /// Runs a binding on the focused window, as when its hotkey is pressed. Bound functions receive the
  /// focused window object (or `undefined` when nothing is focused), as in Slate.
  @discardableResult
  public func invoke(_ binding: ScriptBinding) -> ScriptRunResult {
    run(binding.target, on: host.focusedWindow())
  }

  /// Runs a binding target, layout step or default on `window`.
  @discardableResult
  public func run(_ target: ScriptTarget, on window: WindowHandle?) -> ScriptRunResult {
    activity {
      switch target {
      case .action(let action): return host.perform(action, on: window)
      case .callback(let id): return runCallback(id, on: window)
      }
    }
  }

  /// Calls the `slate.on` handlers for `event`.
  @discardableResult
  public func dispatch(event: ScriptEvent) -> ScriptRunResult {
    activity {
      guard let handlers = eventHandlers[event.name], !handlers.isEmpty else { return true }
      let payload = eventPayload(event)
      var success = true
      for handler in handlers where callJS(handler, [event.name.rawValue, payload]).threw {
        success = false
      }
      return success
    }
  }

  // MARK: - Internals

  enum Callback {
    /// Called with the window object.
    case function(JSValue)
    /// A JavaScript operation object that needs the engine to run (a chain with functions, say).
    case operation(JSValue)
  }

  struct PendingBinding {
    var binding: ScriptBinding
    /// The script's `repeat` argument; nil means "use `repeatOnHoldOps`".
    var explicitRepeat: Bool?
    var operationName: String
  }

  struct PreludeClasses {
    var operation: JSValue
    var window: JSValue
    var app: JSValue
    var screen: JSValue
  }

  private func reset() {
    let context: JSContext = JSContext()
    context.name = "Slated config"
    context.exceptionHandler = { [weak self] _, exception in
      MainActor.assumeIsolated { self?.handle(exception) }
    }
    self.context = context
    classes = nil
    isLoading = false
    loadingFiles = []
    pendingBindings = []
    settings = SlateSettings()
    configFunctions = [:]
    layouts = []
    defaults = []
    eventHandlers = [:]
    callbacks = [:]
    chainPositions = [:]
    sourcedFiles = []
    diagnostics = []
    nativeDepth = 0
    capturedException = nil
    windowContext = []
    installAPI(in: context)
  }

  /// Replacing the context while JavaScript runs would pull it out from under the running script.
  private func refuseReentrantLoad(path: String?) -> ScriptLoadResult? {
    guard isLoading || nativeDepth > 0 || !windowContext.isEmpty else { return nil }
    let message = "Slated can't reload the config while it is running part of it. Reload again in a moment."
    return ScriptLoadResult(path: path, diagnostics: [Diagnostic(.error, message, file: path)])
  }

  private func finishLoad(path: String?) -> ScriptLoadResult {
    settings = settingsEvaluatingFunctions()
    let bindings = pendingBindings.map { pending -> ScriptBinding in
      var binding = pending.binding
      binding.repeats = pending.explicitRepeat ?? settings.repeatOnHoldOps.contains(pending.operationName)
      return binding
    }
    result = ScriptLoadResult(
      path: path, bindings: bindings, settings: settings, layouts: layouts, defaults: defaults,
      events: Set(eventHandlers.keys), sourcedFiles: sourcedFiles, diagnostics: diagnostics)
    return result
  }

  private func settingsEvaluatingFunctions() -> SlateSettings {
    var values = settings
    for name in configFunctions.keys.sorted() {
      guard let function = configFunctions[name] else { continue }
      let call = callJS(function, [])
      guard !call.threw, let value = call.value else { continue }
      if let setting = settingValue(value) {
        values[name] = setting
      } else {
        diagnostics.append(
          Diagnostic(
            .error,
            "The function for config \"\(name)\" returned \(describe(value)); expected a string, number or boolean."))
      }
    }
    return values
  }

  /// Runs `source` as a script in the current context. Returns false if it threw. Errors are
  /// reported here, even when a script `source`s another, as in Slate.
  @discardableResult
  func evaluate(_ source: String, path: String?) -> Bool {
    guard let context else { return false }
    let before = recordedExceptions
    let savedDepth = nativeDepth
    nativeDepth = 0
    context.evaluateScript(source, withSourceURL: Self.sourceURL(for: path))
    nativeDepth = savedDepth
    return recordedExceptions == before
  }

  static func sourceURL(for path: String?) -> URL {
    guard let path else { return URL(string: "slated://inline.js")! }
    return URL(fileURLWithPath: path)
  }

  /// Wraps work started from Swift: collects the diagnostics it produced and reports failure if any
  /// of them is an error.
  func activity(_ body: () -> Bool) -> ScriptRunResult {
    let start = diagnostics.count
    let success = body()
    let found = Array(diagnostics[start...])
    if !isLoading { diagnostics.removeSubrange(start...) }
    return ScriptRunResult(success: success && !found.contains { $0.severity == .error }, diagnostics: found)
  }

  func runCallback(_ id: ScriptCallbackID, on window: WindowHandle?) -> Bool {
    guard let callback = callbacks[id] else {
      report(
        .error, "This JavaScript binding is from an earlier load of the config. Reload Slated's bindings to use it.")
      return false
    }
    switch callback {
    case .function(let function): return callFunction(function, window: window)
    case .operation(let operation): return runOperation(operation, on: window)
    }
  }

  func register(_ callback: Callback) -> ScriptCallbackID {
    let id = ScriptCallbackID(rawValue: nextCallbackID)
    nextCallbackID += 1
    callbacks[id] = callback
    return id
  }

  // MARK: Calling JavaScript

  /// Calls a JavaScript function from Swift and says whether it threw. Inside a native function, the
  /// exception goes back to the script that called the native once it returns, like an exception
  /// escaping an `Array.forEach` callback; callers should stop and return. At the top level it is
  /// reported as a diagnostic.
  func callJS(_ function: JSValue, _ arguments: [Any]) -> (value: JSValue?, threw: Bool) {
    let before = recordedExceptions
    let value = function.call(withArguments: arguments)
    let threw = capturedException != nil || recordedExceptions != before
    return (threw ? nil : value, threw)
  }

  /// True when JavaScript called from the current native function threw; stop calling more.
  var shouldStop: Bool { capturedException != nil }

  /// Calls a function the way Slate calls bound functions and layout steps: with the window object.
  func callFunction(_ function: JSValue, window: WindowHandle?) -> Bool {
    withWindow(window) {
      let argument: Any = window.flatMap { windowObject($0) } ?? undefinedValue
      return !callJS(function, [argument]).threw
    }
  }

  func withWindow<T>(_ window: WindowHandle?, _ body: () -> T) -> T {
    windowContext.append(window)
    defer { windowContext.removeLast() }
    return body()
  }

  /// The window `slate.window()` refers to: the one JavaScript is running for, else the focused one.
  func currentWindow() -> WindowHandle? {
    if let window = windowContext.last { return window }
    return host.focusedWindow()
  }

  // MARK: Diagnostics

  private func handle(_ exception: JSValue?) {
    guard let exception else { return }
    if nativeDepth > 0 {
      capturedException = exception
      return
    }
    recordedExceptions += 1
    let location = location(of: exception)
    let message = exception.toString() ?? "JavaScript error"
    diagnostics.append(Diagnostic(.error, message, file: location.file, line: location.line))
  }

  /// Records a problem at the script line that called into the API (or at `location`).
  func report(_ severity: Diagnostic.Severity, _ message: String, at location: (file: String?, line: Int?)? = nil) {
    let location = location ?? callerLocation()
    diagnostics.append(Diagnostic(severity, message, file: location.file, line: location.line))
  }

  /// True when an error was already reported for this script line.
  func hasError(at location: (file: String?, line: Int?)) -> Bool {
    guard location.line != nil else { return false }
    return diagnostics.contains { $0.severity == .error && $0.file == location.file && $0.line == location.line }
  }

  /// The innermost script frame on the JavaScript stack.
  func callerLocation() -> (file: String?, line: Int?) {
    if let stack = context?.evaluateScript("new Error().stack")?.toString(),
      let frame = Self.firstScriptFrame(in: stack)
    {
      return frame
    }
    return (loadingFiles.last, nil)
  }

  private func location(of exception: JSValue) -> (file: String?, line: Int?) {
    if let stack = exception.forProperty("stack"), stack.isString,
      let frame = Self.firstScriptFrame(in: stack.toString())
    {
      return frame
    }
    if let line = exception.forProperty("line"), line.isNumber {
      let url = exception.forProperty("sourceURL")
      let file = url.flatMap { $0.isString ? Self.filePath(fromSourceURL: $0.toString()) : nil }
      return (file ?? loadingFiles.last, Int(line.toInt32()))
    }
    return (loadingFiles.last, nil)
  }

  /// Finds the first frame from a user script in a JavaScriptCore stack trace, whose frames look like
  /// `name@file:///Users/me/.slate.js:12:5`, `@[native code]` or `global code@`.
  static func firstScriptFrame(in stack: String) -> (file: String?, line: Int?)? {
    for frame in stack.split(separator: "\n") {
      guard let at = frame.firstIndex(of: "@") else { continue }
      let location = frame[frame.index(after: at)...]
      if location.isEmpty || location.hasPrefix("[") || location.hasPrefix(ScriptPrelude.sourceURL.absoluteString) {
        continue
      }
      let parts = location.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count >= 3, let line = Int(parts[parts.count - 2]) else { continue }
      return (filePath(fromSourceURL: parts.dropLast(2).joined(separator: ":")), line)
    }
    return nil
  }

  static func filePath(fromSourceURL url: String) -> String? {
    guard url.hasPrefix("file:"), let parsed = URL(string: url) else { return nil }
    return parsed.path
  }
}
