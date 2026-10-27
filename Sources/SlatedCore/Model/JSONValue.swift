import Foundation

/// Any JSON value, as read. Holds config.json's top-level sections that this version of Slated doesn't
/// know (a newer one wrote them), so that saving writes them back instead of dropping them.
public indirect enum JSONValue: Hashable, Sendable {
  case null
  case bool(Bool)
  /// A whole number that fits in `Int`, kept exact. Other numbers are `double`.
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    // Containers are tried before single values so that an error inside one keeps its own message
    // and coding path.
    if var list = try? decoder.unkeyedContainer() {
      var items: [JSONValue] = []
      while !list.isAtEnd { items.append(try list.decode(JSONValue.self)) }
      self = .array(items)
    } else if let object = try? decoder.container(keyedBy: AnyKey.self) {
      var members: [String: JSONValue] = [:]
      for key in object.allKeys { members[key.stringValue] = try object.decode(JSONValue.self, forKey: key) }
      self = .object(members)
    } else {
      let c = try decoder.singleValueContainer()
      if c.decodeNil() {
        self = .null
      } else if let value = try? c.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? c.decode(String.self) {
        self = .string(value)
      } else if let value = try? c.decode(Int.self) {
        self = .int(value)
      } else {
        self = .double(try c.decode(Double.self))
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .array(let items):
      var list = encoder.unkeyedContainer()
      for item in items { try list.encode(item) }
    case .object(let members):
      var object = encoder.container(keyedBy: AnyKey.self)
      for (key, value) in members { try object.encode(value, forKey: AnyKey(key)) }
    case .null:
      var c = encoder.singleValueContainer()
      try c.encodeNil()
    case .bool(let value):
      var c = encoder.singleValueContainer()
      try c.encode(value)
    case .int(let value):
      var c = encoder.singleValueContainer()
      try c.encode(value)
    case .double(let value):
      var c = encoder.singleValueContainer()
      try c.encode(value)
    case .string(let value):
      var c = encoder.singleValueContainer()
      try c.encode(value)
    }
  }
}

/// A coding key for any member name.
struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ name: String) { stringValue = name }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}
