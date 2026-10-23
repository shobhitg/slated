import Foundation
import JavaScriptCore
import SlatedCore

// Small helpers for reading JavaScript values from Swift.
extension SlateScriptEngine {
  func isNullish(_ value: JSValue) -> Bool { value.isUndefined || value.isNull }

  /// JavaScript `undefined`, for passing as an argument.
  var undefinedValue: Any {
    context.flatMap { JSValue(undefinedIn: $0) } ?? NSNull()
  }

  func isFunction(_ value: JSValue) -> Bool {
    guard let context, value.isObject else { return false }
    return JSObjectIsFunction(context.jsGlobalContextRef, value.jsValueRef)
  }

  /// True for objects the API creates: operations, windows, apps and screens.
  func isWrapper(_ value: JSValue) -> Bool {
    guard let classes, value.isObject else { return false }
    return [classes.operation, classes.window, classes.app, classes.screen].contains { value.isInstance(of: $0) }
  }

  /// An object literal (or similar), as opposed to arrays, functions and API objects.
  func isPlainObject(_ value: JSValue) -> Bool {
    value.isObject && !value.isArray && !isFunction(value) && !isWrapper(value)
  }

  /// Own enumerable keys in insertion order, like `Object.keys`. Slate configs list apps in layouts
  /// in the order they should be arranged.
  func keys(of value: JSValue) -> [String] {
    guard let context, value.isObject,
      let keys = context.objectForKeyedSubscript("Object")?.invokeMethod("keys", withArguments: [value])
    else { return [] }
    return elements(of: keys).compactMap { $0.toString() }
  }

  /// Array elements. Capped, so a sparse array with a huge `length` can't stall the app.
  func elements(of value: JSValue?) -> [JSValue] {
    guard let value, value.isArray else { return [] }
    let count = min(max(Int(value.forProperty("length").toInt32()), 0), 10_000)
    return (0..<count).compactMap { value.atIndex($0) }
  }

  /// A JavaScript number as an `Int` (truncated), or nil for non-numbers, NaN, infinities and values
  /// too large to be an index or handle. Swift traps when converting those, and scripts can pass them.
  func intValue(_ value: JSValue) -> Int? {
    guard value.isNumber else { return nil }
    let number = value.toDouble()
    guard number.isFinite, abs(number) < 9_007_199_254_740_992 else { return nil }
    return Int(number)
  }

  /// Slate read flags with Objective-C's `boolValue`: numbers are true unless zero, and strings are
  /// true unless they say otherwise.
  func truthy(_ value: JSValue) -> Bool {
    if value.isBoolean { return value.toBool() }
    if value.isNumber { return value.toDouble() != 0 }
    if value.isString { return Self.truthy(value.toString()) }
    return value.toBool()
  }

  static func truthy(_ text: String) -> Bool {
    !["", "false", "no", "0", "off"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
  }

  func defineHidden(_ object: JSValue, _ key: String, _ value: Any?) {
    guard let value else { return }
    object.defineProperty(key as NSString, descriptor: [JSPropertyDescriptorValueKey: value])
  }

  /// A JavaScript object with keys in the given order (`{x, y, width, height}` reads better than a
  /// dictionary's arbitrary order).
  func object(_ pairs: KeyValuePairs<String, Any>) -> JSValue? {
    guard let context, let object = JSValue(newObjectIn: context) else { return nil }
    for (key, value) in pairs { object.setValue(value, forProperty: key as NSString) }
    return object
  }

  /// For error messages: "undefined", "the number 3", "a function"…
  func describe(_ value: JSValue) -> String {
    if value.isUndefined { return "undefined" }
    if value.isNull { return "null" }
    if value.isBoolean { return value.toBool() ? "true" : "false" }
    if value.isNumber { return "the number \(value.toString() ?? "")" }
    if value.isString {
      let text = value.toString() ?? ""
      return "the string \"\(text.count > 40 ? text.prefix(40) + "…" : text)\""
    }
    if isFunction(value) { return "a function" }
    if isOperation(value) { return "an operation" }
    if value.isArray { return "an array" }
    if let classes {
      if value.isInstance(of: classes.window) { return "a window" }
      if value.isInstance(of: classes.app) { return "an app" }
      if value.isInstance(of: classes.screen) { return "a screen" }
    }
    return "an object"
  }
}

/// Converts a coordinate the way Slate did when handing numbers to scripts (truncating toward zero).
/// Never traps: a script can move a window to an absurd position.
func integer(_ value: CGFloat) -> Int {
  guard value.isFinite else { return 0 }
  return Int(min(max(value, -1e15), 1e15))
}
