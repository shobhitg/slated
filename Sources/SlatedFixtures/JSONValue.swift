import Foundation

@testable import SlatedCore

/// A JSON value with deterministic rendering: sorted keys, shortest round-trip numbers, and one line
/// per case, so regenerated fixtures are byte-identical and diffs stay readable.
indirect enum J: Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([J])
  case object([String: J])

  static func int(_ value: Int) -> J { .number(Double(value)) }
  static func optional(_ value: String?) -> J { value.map(J.string) ?? .null }

  subscript(key: String) -> J? {
    if case .object(let members) = self { return members[key] }
    return nil
  }

  /// Renders the value. Containers nested less than `expand` levels deep are spread over several
  /// lines; deeper ones are written on one line.
  func rendered(expand: Int = 2, indent: String = "") -> String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return J.renderNumber(n)
    case .string(let s): return J.quote(s)
    case .array(let items):
      if items.isEmpty { return "[]" }
      if expand <= 0 { return "[" + items.map { $0.rendered(expand: 0) }.joined(separator: ",") + "]" }
      let inner = indent + "  "
      return "[\n" + items.map { inner + $0.rendered(expand: expand - 1, indent: inner) }.joined(separator: ",\n")
        + "\n" + indent + "]"
    case .object(let members):
      if members.isEmpty { return "{}" }
      let keys = members.keys.sorted(by: J.scalarOrder)
      if expand <= 0 {
        let parts: [String] = keys.map { key in J.quote(key) + ":" + members[key]!.rendered(expand: 0) }
        return "{" + parts.joined(separator: ",") + "}"
      }
      let inner = indent + "  "
      let lines: [String] = keys.map { key in
        inner + J.quote(key) + ": " + members[key]!.rendered(expand: expand - 1, indent: inner)
      }
      return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    }
  }

  /// Orders keys by Unicode scalar values, so the order doesn't depend on locale or normalization.
  static func scalarOrder(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.map(\.value).lexicographicallyPrecedes(b.unicodeScalars.map(\.value))
  }

  /// Integers print without a fraction; other numbers use Swift's shortest round-trip form, which
  /// `JSON.parse` reads back to the same double. JSON has no infinities or NaN, so those become
  /// `{"$double": "inf" | "-inf" | "nan"}`.
  static func renderNumber(_ n: Double) -> String {
    if n.isNaN { return #"{"$double":"nan"}"# }
    if n.isInfinite { return n > 0 ? #"{"$double":"inf"}"# : #"{"$double":"-inf"}"# }
    if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
      if n == 0 && n.sign == .minus { return "-0.0" }
      return String(Int(n))
    }
    return "\(n)"
  }

  static func quote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}

extension J: Codable {
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([J].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: J].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

/// `value` as Swift's `JSONEncoder` writes it, read back as a `J` (so the fixture shows exactly
/// the shape Slated stores in config.json).
func toJ<T: Encodable>(_ value: T) -> J {
  do {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(J.self, from: data)
  } catch {
    fatalError("Couldn't encode \(value): \(error)")
  }
}

/// Parses JSON text written in a fixture definition below.
func parseJ(_ text: String) -> J {
  do {
    return try JSONDecoder().decode(J.self, from: Data(text.utf8))
  } catch {
    fatalError("Bad JSON in a fixture definition: \(text): \(error)")
  }
}

/// `{"kind": "...", "message": "..."}` for any error the engine throws. Decoding errors also say
/// whether the message is Slated's own (`exact`, so the JavaScript port must match it) or
/// Foundation's (the port only has to fail).
func errorJ(_ error: Error) -> J {
  if let error = error as? SlatedError {
    let kind: String
    switch error {
    case .notImplemented: kind = "notImplemented"
    case .invalidSyntax: kind = "invalidSyntax"
    case .invalidExpression: kind = "invalidExpression"
    case .unknownOperation: kind = "unknownOperation"
    case .screenNotFound: kind = "screenNotFound"
    }
    return .object(["kind": .string(kind), "message": .string(error.description)])
  }
  if let error = error as? DecodingError {
    let message: String
    switch error {
    case .dataCorrupted(let context): message = context.debugDescription
    case .keyNotFound(_, let context): message = context.debugDescription
    case .typeMismatch(_, let context): message = context.debugDescription
    case .valueNotFound(_, let context): message = context.debugDescription
    @unknown default: message = "\(error)"
    }
    // Slated's own decoding messages (Action, ScreenRef, PushStyle, KeyCombo). Everything else comes
    // from Foundation's JSONDecoder and isn't part of the contract.
    let ours = [
      "\" needs \"", "Invalid direction \"", "Invalid corner \"", "Invalid focus direction \"",
      "Unknown operation \"", "Invalid operation \"", "Invalid screen reference \"", "Invalid push style \"",
      "Invalid key combo \"", "Invalid input \"", "interval must be more than 0 seconds", "times must be at least 1",
      "jitter must be between 0 and 0.5", "seconds can't be negative", "Unknown modifier \"",
      "A display default ",
    ]
    let exact = ours.contains { message.contains($0) } && !message.contains("underlying")
    // Foundation's own messages can depend on dictionary order (which of two bad values it meets
    // first), so only Slated's messages are recorded.
    return exact
      ? .object(["kind": .string("decoding"), "message": .string(message), "exact": true])
      : .object(["kind": .string("decoding"), "exact": false])
  }
  if error is EncodingError { return .object(["kind": .string("encoding")]) }
  return .object(["kind": .string("other"), "message": .string("\(error)")])
}

/// Runs `body`, returning `["key": result]` or `["error": …]`.
func outcome(_ key: String, _ body: () throws -> J) -> [String: J] {
  do {
    return [key: try body()]
  } catch {
    return ["error": errorJ(error)]
  }
}

// MARK: - Model helpers shared by several fixture files

/// Modifier tokens in the JavaScript port's canonical order (bit order).
func modifierList(_ m: Modifiers) -> J {
  var tokens: [J] = []
  if m.contains(.control) { tokens.append("ctrl") }
  if m.contains(.option) { tokens.append("alt") }
  if m.contains(.shift) { tokens.append("shift") }
  if m.contains(.command) { tokens.append("cmd") }
  if m.contains(.function) { tokens.append("fn") }
  return .array(tokens)
}

func comboJ(_ combo: KeyCombo) -> J {
  .object(["key": .string(combo.key), "modifiers": modifierList(combo.modifiers)])
}

func rectJ(_ r: CGRect) -> J {
  .object([
    "x": .number(Double(r.origin.x)), "y": .number(Double(r.origin.y)),
    "width": .number(Double(r.size.width)), "height": .number(Double(r.size.height)),
  ])
}

func screenJ(_ s: ScreenInfo) -> J {
  .object([
    "displayID": .int(Int(s.displayID)), "name": .string(s.name), "frame": rectJ(s.frame),
    "visibleFrame": rectJ(s.visibleFrame), "isMain": .bool(s.isMain), "scale": .number(s.scale),
  ])
}

func settingJ(_ value: SettingValue) -> J {
  switch value {
  case .bool(let b): return .bool(b)
  case .number(let n): return .number(n)
  case .string(let s): return .string(s)
  }
}

func settingsJ(_ settings: SlateSettings) -> J {
  .object(settings.values.mapValues(settingJ))
}

func actionJ(_ action: Action) -> J { toJ(action) }

extension J: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
  init(stringLiteral value: String) { self = .string(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(nilLiteral: ()) { self = .null }
}

extension J: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
  init(integerLiteral value: Int) { self = .number(Double(value)) }
  init(floatLiteral value: Double) { self = .number(value) }
}

extension J: ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
  init(arrayLiteral elements: J...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, J)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
  }
}
