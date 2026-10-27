import Foundation

/// A Slate `config` value. Stored as the natural JSON type.
public enum SettingValue: Hashable, Sendable, Codable {
  case bool(Bool)
  case number(Double)
  case string(String)

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else {
      self = .string(try c.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    }
  }

  /// Interprets Slate's textual config values (`config name value`): booleans, numbers, otherwise text.
  public init(slate raw: String) {
    let s = raw.trimmingCharacters(in: .whitespaces)
    switch s.lowercased() {
    case "true", "yes": self = .bool(true)
    case "false", "no": self = .bool(false)
    default:
      if let n = Double(s) { self = .number(n) } else { self = .string(s) }
    }
  }

  public var boolValue: Bool? {
    switch self {
    case .bool(let b): return b
    case .number(let n): return n != 0
    case .string(let s): return ["true", "yes", "1"].contains(s.lowercased()) ? true : (["false", "no", "0"].contains(s.lowercased()) ? false : nil)
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .bool(let b): return b ? 1 : 0
    case .number(let n): return n
    case .string(let s): return Double(s)
    }
  }

  public var stringValue: String {
    switch self {
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    case .string(let s): return s
    }
  }
}

/// Slate's global configuration (`config <name> <value>` / `slate.configAll({...})`).
///
/// Any Slate config key is accepted and preserved; typed accessors below supply Slate's defaults for
/// the ones Slated acts on.
public struct SlateSettings: Hashable, Sendable, Codable {
  public var values: [String: SettingValue]

  public init(_ values: [String: SettingValue] = [:]) { self.values = values }

  public init(from decoder: Decoder) throws {
    values = try decoder.singleValueContainer().decode([String: SettingValue].self)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(values)
  }

  public subscript(key: String) -> SettingValue? {
    get { values[key] }
    set { values[key] = newValue }
  }

  public func bool(_ key: String, default value: Bool) -> Bool { values[key]?.boolValue ?? value }
  public func double(_ key: String, default value: Double) -> Double { values[key]?.doubleValue ?? value }
  public func string(_ key: String, default value: String) -> String { values[key]?.stringValue ?? value }

  /// Merges `other` on top of `self` (later sources win, like later `config` lines in Slate).
  public func merging(_ other: SlateSettings) -> SlateSettings {
    SlateSettings(values.merging(other.values) { _, new in new })
  }

  // MARK: Typed accessors (Slate defaults)

  /// When an operation names a screen that doesn't exist (an index or resolution that matches no
  /// display), use the window's own screen instead of doing nothing. Slate's default is false.
  public var defaultToCurrentScreen: Bool { bool("defaultToCurrentScreen", default: false) }
  /// `windowSize` or `screenSize`: what `nudge` percentages are relative to.
  public var nudgePercentOf: String { string("nudgePercentOf", default: "screenSize") }
  /// `windowSize` or `screenSize`: what `resize` percentages are relative to.
  public var resizePercentOf: String { string("resizePercentOf", default: "screenSize") }
  public var orderScreensLeftToRight: Bool { bool("orderScreensLeftToRight", default: true) }
  /// Action names that repeat while their hotkey is held.
  public var repeatOnHoldOps: [String] {
    string("repeatOnHoldOps", default: "resize,nudge").split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }
  public var secondsBeforeRepeat: Double { double("secondsBeforeRepeat", default: 0.4) }
  public var secondsBetweenRepeat: Double { double("secondsBetweenRepeat", default: 0.1) }
  /// Truncated to a whole number. `Int(_:)` traps on NaN, infinities and values beyond `Int`'s range,
  /// which a config can hold (`config undoMaxStackSize inf`, JSON5 `Infinity`), so NaN reads as the
  /// default and the size is capped at ±1e15.
  public var undoMaxStackSize: Int {
    let value = double("undoMaxStackSize", default: 10)
    guard !value.isNaN else { return 10 }
    return Int(min(max(value, -1e15), 1e15))
  }
  public var focusCheckWidth: Double { double("focusCheckWidth", default: 100) }
  public var focusCheckWidthMax: Double { double("focusCheckWidthMax", default: 100) }
  public var focusPreferSameApp: Bool { bool("focusPreferSameApp", default: true) }
  public var checkDefaultsOnLoad: Bool { bool("checkDefaultsOnLoad", default: false) }
  public var windowHintsCharacters: String {
    string("windowHintsCharacters", default: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  }
}
