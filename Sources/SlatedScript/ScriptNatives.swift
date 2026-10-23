import Foundation
import JavaScriptCore
import SlatedCore

/// Arguments of a native function call. Missing arguments read as `undefined`, like in JavaScript.
struct Arguments {
  let values: [JSValue]
  let context: JSContext

  subscript(index: Int) -> JSValue {
    index < values.count ? values[index] : JSValue(undefinedIn: context)
  }

  /// The argument when it is a string.
  func string(_ index: Int) -> String? {
    let value = self[index]
    return value.isString ? value.toString() : nil
  }
}

// The registration half of the API: what scripts call while they load.
extension SlateScriptEngine {
  func installAPI(in context: JSContext) {
    guard let native = JSValue(newObjectIn: context) else { return }

    define(native, "log") { engine, args in
      engine.host.log(args.string(0) ?? "")
      return nil
    }
    define(native, "config") { $0.nativeConfig($1) }
    define(native, "configAll") { $0.nativeConfigAll($1) }
    define(native, "bind") { engine, args in
      engine.bind(args[0], args[1], args[2])
      return nil
    }
    define(native, "bindAll") { $0.nativeBindAll($1) }
    define(native, "operation") { $0.nativeOperation($1) }
    define(native, "operationFromString") { $0.nativeOperationFromString($1) }
    define(native, "doOperation") { $0.nativeDoOperation($1) }
    define(native, "runOperation") { engine, args in engine.runOperation(args[0], on: engine.host.focusedWindow()) }
    define(native, "dupOperation") { $0.nativeDupOperation($1) }
    define(native, "source") { $0.nativeSource($1) }
    define(native, "layout") { $0.nativeLayout($1) }
    define(native, "defaultLayout") { $0.nativeDefault($1) }
    define(native, "shell") { $0.nativeShell($1) }
    define(native, "on") { $0.nativeOn($1) }
    installInfoAPI(on: native)

    let factory = context.evaluateScript(ScriptPrelude.source, withSourceURL: ScriptPrelude.sourceURL)
    guard let global = context.globalObject, let exports = factory?.call(withArguments: [global, native]),
      exports.isObject
    else {
      diagnostics.append(Diagnostic(.error, "Slated couldn't set up its JavaScript API. This is a bug in Slated."))
      return
    }
    classes = PreludeClasses(
      operation: exports.forProperty("SlateOperation"), window: exports.forProperty("SlateWindow"),
      app: exports.forProperty("SlateApplication"), screen: exports.forProperty("SlateScreen"))
  }

  /// Adds a native function. `body` gets the engine and the call's arguments and returns a Swift
  /// value (converted to JavaScript), a `JSValue`, or nil for `undefined`.
  ///
  /// The block holds the engine weakly: the engine owns the context, so a strong reference would
  /// keep both alive forever.
  func define(_ native: JSValue, _ name: String, _ body: @escaping @MainActor (SlateScriptEngine, Arguments) -> Any?) {
    let block: @convention(block) () -> JSValue? = { [weak self] in
      guard let self, let context = self.context else { return nil }
      let arguments = Arguments(values: JSContext.currentArguments() as? [JSValue] ?? [], context: context)
      self.nativeDepth += 1
      let value = body(self, arguments)
      self.nativeDepth -= 1
      if let exception = self.capturedException {
        // JavaScript called by this native threw: re-throw it to the script that called the native.
        self.capturedException = nil
        context.exception = exception
        return nil
      }
      return self.jsValue(value)
    }
    native.setObject(block, forKeyedSubscript: name as NSString)
  }

  func jsValue(_ value: Any?) -> JSValue? {
    guard let value, let context else { return nil }
    switch value {
    case let value as JSValue: return value
    case let value as Bool: return JSValue(bool: value, in: context)
    case let value as Int: return JSValue(double: Double(value), in: context)
    case let value as Double: return JSValue(double: value, in: context)
    case let value as String: return JSValue(object: value, in: context)
    default: return JSValue(object: value, in: context)
    }
  }

  // MARK: config

  func nativeConfig(_ args: Arguments) -> Any? {
    guard let name = args.string(0) else {
      report(.error, "slate.config needs a setting name (a string), got \(describe(args[0])).")
      return nil
    }
    setConfig(name, args[1])
    return nil
  }

  func nativeConfigAll(_ args: Arguments) -> Any? {
    let values = args[0]
    guard isPlainObject(values) else {
      report(
        .error, "slate.configAll needs an object like {\"defaultToCurrentScreen\": true}, got \(describe(values)).")
      return nil
    }
    for name in keys(of: values) { setConfig(name, values.forProperty(name)) }
    return nil
  }

  func setConfig(_ name: String, _ value: JSValue) {
    if isFunction(value) {
      // Like Slate, a function is asked for the value whenever the setting is read.
      configFunctions[name] = value
      return
    }
    guard let setting = settingValue(value) else {
      report(
        .error,
        "slate.config(\"\(name)\", …) needs a string, number, boolean, array or function, got \(describe(value)).")
      return
    }
    configFunctions[name] = nil
    settings[name] = setting
  }

  /// Slate stores config values as text; arrays become `;`-separated lists.
  func settingValue(_ value: JSValue) -> SettingValue? {
    if value.isBoolean { return .bool(value.toBool()) }
    if value.isNumber { return .number(value.toDouble()) }
    if value.isString { return .string(value.toString()) }
    if value.isArray { return .string(elements(of: value).map { $0.toString() ?? "" }.joined(separator: ";")) }
    return nil
  }

  // MARK: bind

  func bind(_ keystrokeValue: JSValue, _ targetValue: JSValue, _ repeatValue: JSValue) {
    guard isLoading else {
      report(.warning, "slate.bind only works while the config loads, so this binding was ignored.")
      return
    }
    guard keystrokeValue.isString, let keystroke = keystrokeValue.toString() else {
      report(.error, "slate.bind needs a keystroke like \"a:ctrl,shift\", got \(describe(keystrokeValue)).")
      return
    }
    let parsed: (keys: KeyCombo, modal: ModalKey?)
    do {
      parsed = try SlateSyntax.parseKeystroke(keystroke)
    } catch {
      report(.error, "Can't bind \"\(keystroke)\": \(error)")
      return
    }
    guard let target = scriptTarget(targetValue, for: "slate.bind(\"\(keystroke)\", …)") else { return }
    let location = callerLocation()
    if let earlier = pendingBindings.first(where: { $0.binding.keys == parsed.keys && $0.binding.modal == parsed.modal }
    ) {
      let place = earlier.binding.line.map { " (first on line \($0))" } ?? ""
      report(.warning, "\"\(keystroke)\" is bound more than once\(place).")
    }
    let binding = ScriptBinding(
      keystroke: keystroke, keys: parsed.keys, modal: parsed.modal, target: target.target, summary: target.summary,
      file: location.file, line: location.line)
    pendingBindings.append(
      PendingBinding(
        binding: binding, explicitRepeat: isNullish(repeatValue) ? nil : truthy(repeatValue),
        operationName: target.operationName))
  }

  func nativeBindAll(_ args: Arguments) -> Any? {
    let bindings = args[0]
    guard isPlainObject(bindings) else {
      report(.error, "slate.bindAll needs an object mapping keystrokes to operations, got \(describe(bindings)).")
      return nil
    }
    let undefined = JSValue(undefinedIn: args.context)!
    for keystroke in keys(of: bindings) {
      let value = bindings.forProperty(keystroke)!
      let key = JSValue(object: keystroke, in: args.context)!
      if value.isArray {
        // [operation] or [operation, repeat]
        let items = elements(of: value)
        bind(key, items.first ?? undefined, items.count > 1 ? items[1] : undefined)
      } else {
        bind(key, value, undefined)
      }
    }
    return nil
  }

  // MARK: Operations

  func nativeOperation(_ args: Arguments) -> Any? {
    guard let name = args.string(0) else {
      report(.error, "slate.operation needs an operation name like \"move\", got \(describe(args[0])).")
      return nil
    }
    return makeOperation(name, params: args[1])
  }

  func nativeOperationFromString(_ args: Arguments) -> Any? {
    guard let text = args.string(0) else {
      report(.error, "slate.operationFromString needs a string like \"push left bar\", got \(describe(args[0])).")
      return nil
    }
    return operation(fromString: text)
  }

  func nativeDoOperation(_ args: Arguments) -> Any? {
    guard let operation = operationArgument(args[0], params: args[1], for: "slate.doOperation") else { return false }
    return runOperation(operation, on: host.focusedWindow())
  }

  // MARK: source

  func nativeSource(_ args: Arguments) -> Any? {
    guard let raw = args.string(0) else {
      report(.error, "slate.source needs a file path (a string), got \(describe(args[0])).")
      return false
    }
    // Slate resolves relative paths against the home folder.
    let path = ((raw.hasPrefix("/") || raw.hasPrefix("~") ? raw : "~/" + raw) as NSString).expandingTildeInPath
    guard !loadingFiles.contains(path) else {
      report(.error, "\(raw) is already loading, so slate.source skipped it to avoid a loop.")
      return false
    }
    guard let text = readFile(path) else {
      report(.warning, "Couldn't read \(raw), so slate.source skipped it.")
      return false
    }
    if !sourcedFiles.contains(path) { sourcedFiles.append(path) }
    if path.hasSuffix(".js") {
      loadingFiles.append(path)
      defer { loadingFiles.removeLast() }
      return evaluate(text, path: path)
    }
    let file = SlateConfigParser.parse(text, path: path, readFile: readFile)
    merge(file, path: path)
    return !file.diagnostics.contains { $0.severity == .error }
  }

  /// Adds what a classic `.slate` file defines.
  func merge(_ file: SlateConfigFile, path: String) {
    settings = settings.merging(file.settings)
    for binding in file.bindings where binding.enabled {
      let keystroke = (binding.modal.map { $0.keys.string + " " } ?? "") + binding.keys.string
      let scriptBinding = ScriptBinding(
        keystroke: keystroke, keys: binding.keys, modal: binding.modal, target: .action(binding.action),
        summary: SlateSyntax.format(binding.action), file: path)
      pendingBindings.append(
        PendingBinding(binding: scriptBinding, explicitRepeat: binding.repeats, operationName: binding.action.name))
    }
    for layout in file.layouts { addLayout(ScriptLayout(layout)) }
    defaults += file.defaults.map { ScriptDefault(condition: $0.condition, target: .name($0.target)) }
    diagnostics += file.diagnostics
  }

  // MARK: layout

  func nativeLayout(_ args: Arguments) -> Any? {
    guard let name = args.string(0) else {
      report(.error, "slate.layout needs a layout name (a string), got \(describe(args[0])).")
      return nil
    }
    let apps = args[1]
    guard isPlainObject(apps) else {
      report(
        .error,
        "slate.layout(\"\(name)\", …) needs an object mapping app names to {\"operations\": …}, got \(describe(apps)).")
      return nil
    }
    var layout = ScriptLayout(name: name)
    for app in keys(of: apps) {
      let entry = apps.forProperty(app)!
      let operations = isPlainObject(entry) ? entry.forProperty("operations")! : JSValue(undefinedIn: args.context)!
      guard !isNullish(operations) else {
        report(.warning, "Layout \"\(name)\": \"\(app)\" has no \"operations\", so it was skipped.")
        continue
      }
      let values = operations.isArray ? elements(of: operations) : [operations]
      let targets = values.enumerated().compactMap { index, value in
        scriptTarget(value, for: "Layout \"\(name)\", \"\(app)\" operation \(index + 1)")?.target
      }
      guard !targets.isEmpty else { continue }
      switch app {
      case "_before_": layout.before = targets
      case "_after_": layout.after = targets
      default: layout.apps.append(ScriptLayout.App(app: app, operations: targets, options: layoutOptions(entry)))
      }
    }
    addLayout(layout)
    return name
  }

  func addLayout(_ layout: ScriptLayout) {
    if let index = layouts.firstIndex(where: { $0.name == layout.name }) {
      layouts[index] = layout
    } else {
      layouts.append(layout)
    }
  }

  private func layoutOptions(_ entry: JSValue) -> LayoutAppOptions {
    func flag(_ key: String) -> Bool {
      let value = entry.forProperty(key)!
      return !isNullish(value) && truthy(value)
    }
    func strings(_ key: String) -> [String]? {
      let value = entry.forProperty(key)!
      if value.isArray { return elements(of: value).compactMap { $0.isString ? $0.toString() : nil } }
      if value.isString { return value.toString().split(separator: ";").map(String.init) }
      return nil
    }
    var options = LayoutAppOptions()
    options.ignoreFail = flag("ignore-fail")
    options.`repeat` = flag("repeat")
    options.repeatLast = flag("repeat-last")
    options.mainFirst = flag("main-first")
    options.mainLast = flag("main-last")
    options.sortTitle = flag("sort-title")
    options.titleOrder = strings("title-order")
    options.titleOrderRegex = strings("title-order-regex")
    return options
  }

  // MARK: default

  func nativeDefault(_ args: Arguments) -> Any? {
    let screens = args[0]
    let target = args[1]
    let condition: ScreenDefault.Condition
    if screens.isNumber {
      condition = .count(Int(screens.toInt32()))
    } else if screens.isString, let text = screens.toString()?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
      if let count = Int(text) {
        condition = .count(count)
      } else {
        let resolutions = text.split(whereSeparator: { $0 == ";" || $0 == "," })
        condition = .resolutions(resolutions.map { $0.trimmingCharacters(in: .whitespaces) }.sorted())
      }
    } else if screens.isArray {
      condition = .resolutions(elements(of: screens).compactMap { $0.isString ? $0.toString() : nil }.sorted())
    } else {
      report(
        .error,
        "slate.default needs a screen count or an array of resolutions like [\"1920x1080\"], got \(describe(screens)).")
      return nil
    }

    let defaultTarget: ScriptDefault.Target
    if target.isString {
      defaultTarget = .name(target.toString())
    } else if isOperation(target) {
      if case .layout(let name)? = staticAction(target) {
        defaultTarget = .name(name)
      } else {
        defaultTarget = .callback(register(.operation(target)))
      }
    } else if isFunction(target) {
      defaultTarget = .callback(register(.function(target)))
    } else {
      report(.error, "slate.default needs a layout name, an operation or a function, got \(describe(target)).")
      return nil
    }
    defaults.append(ScriptDefault(condition: condition, target: defaultTarget))
    return nil
  }

  // MARK: shell

  func nativeShell(_ args: Arguments) -> Any? {
    guard let command = args.string(0) else {
      report(.error, "slate.shell needs a command (a string), got \(describe(args[0])).")
      return nil
    }
    var wait = false
    if !isNullish(args[1]) {
      guard args[1].isBoolean else {
        report(.error, "slate.shell's second argument (wait) must be true or false, got \(describe(args[1])).")
        return nil
      }
      wait = args[1].toBool()
    }
    var path: String?
    if !isNullish(args[2]) {
      guard let raw = args.string(2) else {
        report(.error, "slate.shell's third argument (path) must be a string, got \(describe(args[2])).")
        return nil
      }
      path = (raw as NSString).expandingTildeInPath
    }
    return host.runShell(command, wait: wait, path: path)
  }

  // MARK: on

  func nativeOn(_ args: Arguments) -> Any? {
    guard let name = args.string(0), let event = ScriptEventName(rawValue: name) else {
      let known = ScriptEventName.allCases.map(\.rawValue).joined(separator: ", ")
      report(.error, "slate.on doesn't know the event \(describe(args[0])). Use one of: \(known).")
      return nil
    }
    guard isFunction(args[1]) else {
      report(.error, "slate.on(\"\(name)\", …) needs a function, got \(describe(args[1])).")
      return nil
    }
    eventHandlers[event, default: []].append(args[1])
    return nil
  }
}
