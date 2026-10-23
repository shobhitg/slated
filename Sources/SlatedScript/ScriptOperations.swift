import Foundation
import JavaScriptCore
import SlatedCore

/// Carries an `Action` inside a JavaScript operation object. It holds no JavaScript values, so the
/// operation object is garbage-collected normally.
final class ActionBox: NSObject {
  let action: Action

  init(_ action: Action) { self.action = action }
}

/// A parameter value Slated can't turn into an operation parameter.
struct ParameterError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}

// Operation objects (`slate.operation`, `slate.operationFromString`, `op.dup`, `op.run`).
//
// A JavaScript operation object keeps its data in hidden properties, so everything it refers to
// lives on the JavaScript heap: `__kind` says what it is, and `__action`, `__function`, `__items`,
// `__groups` and `__params` hold the details. Most operations are plain `Action`s; the other kinds
// exist because Slate lets JavaScript functions appear inside chains, sequences and parameters.
extension SlateScriptEngine {
  /// Slate's operations plus Slated's own, with the parameters each understands.
  static let operationParameters: [String: Set<String>] = [
    "move": ["x", "y", "width", "height", "screen"],
    "resize": ["width", "height", "anchor"],
    "push": ["direction", "style", "screen"],
    "nudge": ["x", "y"],
    "throw": ["screen", "width", "height"],
    "corner": ["direction", "width", "height", "screen"],
    "chain": ["operations"],
    "sequence": ["operations"],
    "layout": ["name"],
    "focus": ["direction", "app"],
    "snapshot": ["name", "save", "stack"],
    "delete-snapshot": ["name", "all"],
    "activate-snapshot": ["name", "delete"],
    "hint": ["characters"],
    "grid": ["padding", "grids"],
    "hide": ["app"],
    "show": ["app"],
    "toggle": ["app"],
    "shell": ["command", "wait", "path"],
    "undo": [],
    "relaunch": [],
    // Slate's app switcher took key names as parameters; Slated parses but doesn't use them yet.
    "switch": ["back", "quit", "force-quit", "hide"],
    "insert-text": ["text", "method"],
    "open-url": ["url"],
    "keystroke": ["keys"],
  ]

  enum OperationKind {
    /// A plain operation the host performs.
    case action(Action)
    /// A JavaScript function, called with the window.
    case function(JSValue)
    /// A chain with at least one step that needs JavaScript.
    case chain([JSValue])
    /// A sequence with at least one step that needs JavaScript; inner arrays share a window.
    case sequence([[JSValue]])
    /// An operation with function-valued parameters, evaluated each time it runs.
    case dynamic(name: String, params: JSValue)
  }

  // MARK: Creating operations

  func newOperation(name: String, kind: OperationKind, params: JSValue? = nil) -> JSValue? {
    guard let context, let operation = classes?.operation.construct(withArguments: [name]) else { return nil }
    defineHidden(operation, "__id", nextOperationID)
    nextOperationID += 1
    switch kind {
    case .action(let action):
      defineHidden(operation, "__kind", "action")
      defineHidden(operation, "__action", JSValue(object: ActionBox(action), in: context))
    case .function(let function):
      defineHidden(operation, "__kind", "function")
      defineHidden(operation, "__function", function)
    case .chain(let items):
      defineHidden(operation, "__kind", "chain")
      defineHidden(operation, "__items", JSValue(object: items, in: context))
    case .sequence(let groups):
      defineHidden(operation, "__kind", "sequence")
      defineHidden(operation, "__groups", JSValue(object: groups, in: context))
    case .dynamic:
      defineHidden(operation, "__kind", "dynamic")
    }
    if let params, !isNullish(params) { defineHidden(operation, "__params", params) }
    return operation
  }

  /// `slate.operation(name, params)`: validates the parameters by decoding them into an `Action`,
  /// the same JSON shape Slated's own config uses.
  func makeOperation(_ name: String, params rawParams: JSValue, ignoring ignored: Set<String> = []) -> JSValue? {
    guard let context else { return nil }
    guard let known = Self.operationParameters[name] else {
      report(.error, "Unknown operation \"\(name)\".")
      return nil
    }
    let params: JSValue
    if isNullish(rawParams) {
      guard let empty = JSValue(newObjectIn: context) else { return nil }
      params = empty
    } else if isPlainObject(rawParams) {
      params = rawParams
    } else {
      report(
        .error,
        "The parameters of \"\(name)\" must be an object like {\"direction\": \"left\"}, got \(describe(rawParams)).")
      return nil
    }
    let entries = keys(of: params).filter { !ignored.contains($0) }.map { ($0, params.forProperty($0)!) }
    for (key, _) in entries where !known.contains(key) {
      report(.warning, "\"\(name)\" has no parameter \"\(key)\", so it was ignored.")
    }

    switch name {
    case "chain": return makeChain(params)
    case "sequence": return makeSequence(params)
    default: break
    }
    if entries.contains(where: { isFunction($0.1) }) {
      // Slate evaluates function parameters each time the operation runs.
      return newOperation(name: name, kind: .dynamic(name: name, params: params), params: params)
    }
    do {
      return newOperation(name: name, kind: .action(try decodeAction(name, entries)), params: params)
    } catch {
      report(.error, "Invalid \"\(name)\" operation: \(Self.describe(error)).")
      return nil
    }
  }

  private func makeChain(_ params: JSValue) -> JSValue? {
    let list = params.forProperty("operations")!
    let values = elements(of: list)
    guard list.isArray, !values.isEmpty else {
      report(.error, "\"chain\" needs \"operations\": an array of operations, got \(describe(list)).")
      return nil
    }
    var items: [JSValue] = []
    for (index, value) in values.enumerated() {
      guard let item = operationObject(value, for: "Chain operation \(index + 1)") else { return nil }
      items.append(item)
    }
    let actions = items.compactMap(staticAction)
    if actions.count == items.count {
      return newOperation(name: "chain", kind: .action(.chain(actions)), params: params)
    }
    return newOperation(name: "chain", kind: .chain(items), params: params)
  }

  /// Slate's JavaScript sequences list steps; a step that is an array runs its operations on the same
  /// window, like `>` in Slate's operation syntax.
  private func makeSequence(_ params: JSValue) -> JSValue? {
    let list = params.forProperty("operations")!
    let values = elements(of: list)
    guard list.isArray, !values.isEmpty else {
      report(.error, "\"sequence\" needs \"operations\": an array of operations, got \(describe(list)).")
      return nil
    }
    var groups: [[JSValue]] = []
    for (index, value) in values.enumerated() {
      var group: [JSValue] = []
      for member in value.isArray ? elements(of: value) : [value] {
        guard let item = operationObject(member, for: "Sequence step \(index + 1)") else { return nil }
        group.append(item)
      }
      if !group.isEmpty { groups.append(group) }
    }
    var steps: [SequenceStep] = []
    for group in groups {
      for (index, item) in group.enumerated() {
        guard let action = staticAction(item) else {
          return newOperation(name: "sequence", kind: .sequence(groups), params: params)
        }
        steps.append(SequenceStep(action, keepWindow: index > 0))
      }
    }
    return newOperation(name: "sequence", kind: .action(.sequence(steps)), params: params)
  }

  /// `slate.operationFromString`: Slate's operation syntax, parsed by `SlateSyntax`.
  func operation(fromString text: String) -> JSValue? {
    do {
      let action = try SlateSyntax.parseOperation(text)
      return newOperation(name: action.name, kind: .action(action))
    } catch {
      report(.error, "Can't parse the operation \"\(text)\": \(error)")
      return nil
    }
  }

  /// Accepts what Slated treats as an operation: an operation object, a function, a string in
  /// Slate's operation syntax, or an object with an `op` name and parameters.
  func operationObject(_ value: JSValue, for caller: String) -> JSValue? {
    if isOperation(value) { return value }
    if isFunction(value) { return newOperation(name: "js", kind: .function(value)) }
    if value.isString { return operation(fromString: value.toString()) }
    if isPlainObject(value), let name = value.forProperty("op"), name.isString {
      return makeOperation(name.toString(), params: value, ignoring: ["op"])
    }
    let location = callerLocation()
    if isNullish(value), hasError(at: location) {
      // Usually `slate.operation(...)` failed on this same line and already said why.
      return nil
    }
    report(.error, "\(caller) needs an operation or a function, got \(describe(value)).", at: location)
    return nil
  }

  /// `doOperation(op)`, `doOperation("push", {...})`, or `doOperation("push left")`.
  func operationArgument(_ value: JSValue, params: JSValue, for caller: String) -> JSValue? {
    if value.isString, let text = value.toString() {
      if !isNullish(params) || Self.operationParameters[text] != nil { return makeOperation(text, params: params) }
      return operation(fromString: text)
    }
    return operationObject(value, for: caller)
  }

  /// What a binding, layout step or default runs.
  func scriptTarget(_ value: JSValue, for caller: String) -> (
    target: ScriptTarget, summary: String, operationName: String
  )? {
    guard let operation = operationObject(value, for: caller), let kind = operationKind(operation) else { return nil }
    switch kind {
    case .action(let action):
      return (.action(action), SlateSyntax.format(action), action.name)
    case .function(let function):
      return (.callback(register(.function(function))), "JavaScript function", "js")
    case .chain, .sequence, .dynamic:
      let name = operation.forProperty("name").toString() ?? "operation"
      return (.callback(register(.operation(operation))), "\(name) (with JavaScript)", name)
    }
  }

  // MARK: Reading operations

  func isOperation(_ value: JSValue) -> Bool {
    guard let classes, value.isObject else { return false }
    return value.isInstance(of: classes.operation)
  }

  func operationKind(_ value: JSValue) -> OperationKind? {
    guard isOperation(value), let kind = value.forProperty("__kind"), kind.isString else { return nil }
    switch kind.toString() {
    case "action":
      guard let box = value.forProperty("__action")?.toObject() as? ActionBox else { return nil }
      return .action(box.action)
    case "function":
      return value.forProperty("__function").map(OperationKind.function)
    case "chain":
      return .chain(elements(of: value.forProperty("__items")))
    case "sequence":
      return .sequence(elements(of: value.forProperty("__groups")).map { elements(of: $0) })
    case "dynamic":
      return .dynamic(name: value.forProperty("name").toString(), params: value.forProperty("__params"))
    default:
      return nil
    }
  }

  func staticAction(_ operation: JSValue) -> Action? {
    if case .action(let action)? = operationKind(operation) { return action }
    return nil
  }

  // MARK: Running operations

  /// Runs an operation on `window` (nil: no window). Returns false if it failed or threw.
  @discardableResult
  func runOperation(_ operation: JSValue, on window: WindowHandle?) -> Bool {
    guard let kind = operationKind(operation) else {
      report(.error, "Expected an operation, got \(describe(operation)).")
      return false
    }
    switch kind {
    case .action(let action):
      return host.perform(action, on: window)
    case .function(let function):
      return callFunction(function, window: window)
    case .chain(let items):
      guard !items.isEmpty else { return false }
      let id = Int(operation.forProperty("__id").toInt32())
      let index = (chainPositions[id]?[window] ?? 0) % items.count
      chainPositions[id, default: [:]][window] = (index + 1) % items.count
      return runOperation(items[index], on: window)
    case .sequence(let groups):
      var success = true
      let exceptionsBefore = recordedExceptions
      for group in groups {
        // Like Slate, each step acts on whatever is focused when it starts.
        let target = host.focusedWindow()
        for item in group {
          success = runOperation(item, on: target) && success
          if shouldStop || recordedExceptions != exceptionsBefore { return false }
        }
      }
      return success
    case .dynamic(let name, let params):
      guard let action = resolveDynamic(name, params: params, window: window) else { return false }
      return host.perform(action, on: window)
    }
  }

  private func resolveDynamic(_ name: String, params: JSValue, window: WindowHandle?) -> Action? {
    var entries: [(String, JSValue)] = []
    for key in keys(of: params) where key != "op" {
      var value = params.forProperty(key)!
      if isFunction(value) {
        let call = withWindow(window) { callJS(value, []) }
        guard !call.threw, let result = call.value else { return nil }
        value = result
      }
      entries.append((key, value))
    }
    do {
      return try decodeAction(name, entries)
    } catch {
      report(.error, "Invalid \"\(name)\" operation: \(Self.describe(error)).")
      return nil
    }
  }

  func nativeDupOperation(_ args: Arguments) -> Any? {
    let operation = args[0]
    let changes = args[1]
    guard let kind = operationKind(operation) else {
      report(.error, "dup only works on operations.")
      return nil
    }
    guard isPlainObject(changes) else {
      report(
        .error,
        "operation.dup needs an object with the parameters to change, like {\"width\": \"screenSizeX/3\"}, got \(describe(changes))."
      )
      return nil
    }
    let base: JSValue
    if let params = operation.forProperty("__params"), params.isObject {
      base = params
    } else if case .action(let action) = kind, let json = try? Self.jsonObject(for: action),
      let value = JSValue(object: json, in: context)
    {
      // Made from a string: start from the operation's JSON form.
      base = value
    } else {
      report(.error, "This operation is a JavaScript function, so it can't be duplicated.")
      return nil
    }
    guard let context, let target = JSValue(newObjectIn: context),
      let merged = context.objectForKeyedSubscript("Object")?.invokeMethod(
        "assign", withArguments: [target, base, changes])
    else { return nil }
    return makeOperation(operation.forProperty("name").toString(), params: merged, ignoring: ["op"])
  }

  // MARK: JavaScript parameters → Action

  /// Builds `{"op": name, ...params}` and decodes it with `Action`'s Codable, which uses Slate's
  /// JavaScript parameter names.
  func decodeAction(_ name: String, _ entries: [(String, JSValue)]) throws -> Action {
    var object: [String: Any] = ["op": name]
    for (key, value) in entries {
      guard let json = try jsonValue(value, key: key) else { continue }
      object[key] = Self.coerce(json, forParameter: key)
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(Action.self, from: data)
  }

  /// A JSON-compatible Foundation value for a parameter, or nil to leave it out (`undefined`, `null`).
  private func jsonValue(_ value: JSValue, key: String, depth: Int = 0) throws -> Any? {
    guard depth < 32 else { throw ParameterError("\"\(key)\" is nested too deeply") }
    if isNullish(value) { return nil }
    if value.isBoolean { return NSNumber(value: value.toBool()) }
    if value.isNumber {
      let number = value.toDouble()
      // Also keeps `Action`'s decoder away from integers it can't convert.
      guard number.isFinite, abs(number) < 1e15 else { throw ParameterError("\"\(key)\" is out of range") }
      return number == number.rounded() ? NSNumber(value: Int(number)) : NSNumber(value: number)
    }
    if value.isString { return value.toString() as String }
    if isOperation(value) {
      guard let action = staticAction(value) else {
        throw ParameterError("\"\(key)\" can't hold an operation that runs JavaScript")
      }
      return try Self.jsonObject(for: action)
    }
    if isFunction(value) { throw ParameterError("\"\(key)\" can't be a function here") }
    if let classes {
      // Slate passes screens by their ID and apps by their name.
      if value.isInstance(of: classes.screen) { return value.forProperty("__id").toNumber() }
      if value.isInstance(of: classes.app) { return value.forProperty("__name").toString() as String }
      if value.isInstance(of: classes.window) { throw ParameterError("\"\(key)\" can't be a window") }
    }
    if value.isArray {
      return try elements(of: value).compactMap { try jsonValue($0, key: key, depth: depth + 1) }
    }
    var object: [String: Any] = [:]
    for name in keys(of: value) {
      if let json = try jsonValue(value.forProperty(name), key: name, depth: depth + 1) { object[name] = json }
    }
    return object
  }

  static func jsonObject(for action: Action) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(action))
  }

  /// Slate accepted strings and numbers where a flag or count was expected, so Slated does too.
  static func coerce(_ value: Any, forParameter key: String) -> Any {
    switch key {
    case "wait", "save", "stack", "all", "delete":
      if let text = value as? String { return NSNumber(value: truthy(text)) }
      if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return NSNumber(value: number.doubleValue != 0)
      }
      return value
    case "padding":
      if let text = value as? String, let number = Int(text.trimmingCharacters(in: .whitespaces)) {
        return NSNumber(value: number)
      }
      return value
    case "grids":
      guard let grids = value as? [String: Any] else { return value }
      return grids.mapValues { size -> Any in
        guard var size = size as? [String: Any] else { return size }
        for dimension in ["width", "height"] {
          if let text = size[dimension] as? String, let number = Int(text) { size[dimension] = NSNumber(value: number) }
        }
        return size
      }
    default:
      return value
    }
  }

  /// A short, readable reason for a decoding failure.
  static func describe(_ error: Error) -> String {
    if let error = error as? ParameterError { return error.description }
    guard let error = error as? DecodingError else { return "\(error)" }
    func path(_ context: DecodingError.Context) -> String {
      let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
      return path.isEmpty ? "the value" : "\"\(path)\""
    }
    switch error {
    case .keyNotFound(let key, _):
      return "it needs \"\(key.stringValue)\""
    case .valueNotFound(_, let context):
      return "\(path(context)) is missing"
    case .typeMismatch(let type, let context):
      let expected: String
      switch type {
      case is String.Type: expected = "a string"
      case is Bool.Type: expected = "true or false"
      case is Int.Type, is Double.Type: expected = "a number"
      default: expected = type is [Any].Type ? "an array" : "an object"
      }
      return "\(path(context)) should be \(expected)"
    case .dataCorrupted(let context):
      return context.debugDescription
    @unknown default:
      return "\(error)"
    }
  }
}
