import Foundation

/// Keyboard modifiers. `.hyper` is all four of ⌃⌥⇧⌘ — what Caps Lock produces when it is the Hyper key.
public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let control = Modifiers(rawValue: 1 << 0)
  public static let option = Modifiers(rawValue: 1 << 1)
  public static let shift = Modifiers(rawValue: 1 << 2)
  public static let command = Modifiers(rawValue: 1 << 3)
  public static let function = Modifiers(rawValue: 1 << 4)

  public static let hyper: Modifiers = [.control, .option, .shift, .command]
  /// ⌃⌥⇧ — "Meh", Hyper without ⌘.
  public static let meh: Modifiers = [.control, .option, .shift]

  /// Display glyphs in macOS menu order (⌃⌥⇧⌘), with `fn` first.
  public var symbols: String {
    var s = ""
    if contains(.function) { s += "fn" }
    if contains(.control) { s += "⌃" }
    if contains(.option) { s += "⌥" }
    if contains(.shift) { s += "⇧" }
    if contains(.command) { s += "⌘" }
    return s
  }

  /// Token names used in config strings, in canonical order.
  public var tokens: [String] {
    if isSuperset(of: .hyper) {
      var t = ["hyper"]
      if contains(.function) { t.insert("fn", at: 0) }
      return t
    }
    var t: [String] = []
    if contains(.function) { t.append("fn") }
    if contains(.control) { t.append("ctrl") }
    if contains(.option) { t.append("alt") }
    if contains(.shift) { t.append("shift") }
    if contains(.command) { t.append("cmd") }
    return t
  }

  /// Parses one modifier token. Accepts Slate's names (`ctrl`, `alt`, `cmd`, `shift`, `fn`) plus common
  /// aliases (`control`, `opt`, `option`, `command`, `hyper`, `meh`).
  public static func token(_ raw: String) -> Modifiers? {
    switch raw.lowercased() {
    case "ctrl", "control", "⌃": return .control
    case "alt", "opt", "option", "⌥": return .option
    case "shift", "⇧": return .shift
    case "cmd", "command", "⌘": return .command
    case "fn", "function": return .function
    case "hyper", "✦": return .hyper
    case "meh": return .meh
    default: return nil
    }
  }
}

/// A key plus modifiers, e.g. `hyper+a` or `ctrl+cmd+left`.
///
/// `key` uses Slate's key names (see `KeyNames`): letters and digits, punctuation like `'` and `;`,
/// and named keys such as `left`, `return`, `tab`, `space`, `f1`…`f20`, `pad1`, `padEnter`.
/// Characters are mapped to physical keys through the active keyboard layout at registration time.
public struct KeyCombo: Hashable, Sendable {
  public var key: String
  public var modifiers: Modifiers

  public init(key: String, modifiers: Modifiers = []) {
    self.key = KeyNames.canonical(key)
    self.modifiers = modifiers
  }

  /// Parses `"hyper+a"`, `"ctrl+cmd+left"`, `"cmd+shift+'"`, `"pad+"` (the keypad plus key).
  /// The key is always the last `+`-separated component, so `"cmd++"` means ⌘ and the `+` key.
  public init?(string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    var parts = trimmed.components(separatedBy: "+")
    // "cmd++" → ["cmd", "", ""]; "pad+" → ["pad", ""]; "+" → ["", ""]
    var key: String
    if trimmed.hasSuffix("+") {
      if trimmed.lowercased().hasSuffix("pad+") {
        parts.removeLast(2)
        key = "pad+"
      } else {
        parts.removeLast(2)
        key = "+"
      }
    } else {
      key = parts.removeLast()
    }
    var mods: Modifiers = []
    for part in parts where !part.isEmpty {
      guard let m = Modifiers.token(part.trimmingCharacters(in: .whitespaces)) else { return nil }
      mods.formUnion(m)
    }
    key = key.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    self.init(key: key, modifiers: mods)
  }

  /// Canonical config string, e.g. `"hyper+a"`.
  public var string: String { (modifiers.tokens + [key]).joined(separator: "+") }

  /// Display string, e.g. `"⌃⌥⇧⌘A"`, or `"✦A"` when `hyperGlyph` is true and all four modifiers are held.
  public func display(hyperGlyph: Bool = true) -> String {
    let mods =
      hyperGlyph && modifiers.isSuperset(of: .hyper)
      ? (modifiers.contains(.function) ? "fn✦" : "✦") : modifiers.symbols
    return mods + KeyNames.displayName(for: key)
  }
}

extension KeyCombo: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let combo = KeyCombo(string: raw) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid key combo \"\(raw)\". Expected e.g. \"hyper+a\" or \"ctrl+cmd+left\".")
    }
    self = combo
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(string)
  }
}

/// Slate's key vocabulary.
public enum KeyNames {
  /// Named (non-character) keys Slate accepts, lowercased → canonical spelling.
  public static let named: [String: String] = {
    var map: [String: String] = [:]
    let names = [
      "left", "right", "up", "down", "return", "tab", "space", "delete", "forwardDelete", "esc",
      "home", "end", "pageUp", "pageDown", "help", "caps", "mute", "volumeUp", "volumeDown",
      "backslash", "padClear", "padEnter", "pad=", "pad*", "pad+", "pad-", "pad.", "pad/",
    ]
    for n in names { map[n.lowercased()] = n }
    for i in 0...9 { map["pad\(i)"] = "pad\(i)" }
    for i in 1...20 { map["f\(i)"] = "f\(i)" }
    map["escape"] = "esc"
    map["enter"] = "return"
    map["backspace"] = "delete"
    map["pageup"] = "pageUp"
    map["pagedown"] = "pageDown"
    return map
  }()

  /// Normalizes a key name: named keys get their canonical spelling, single characters are lowercased.
  public static func canonical(_ key: String) -> String {
    if let named = named[key.lowercased()] { return named }
    return key.count == 1 ? key.lowercased() : key
  }

  public static func isValid(_ key: String) -> Bool {
    named[key.lowercased()] != nil || key.count == 1
  }

  public static func displayName(for key: String) -> String {
    switch key {
    case "left": return "←"
    case "right": return "→"
    case "up": return "↑"
    case "down": return "↓"
    case "return": return "↩"
    case "tab": return "⇥"
    case "space": return "Space"
    case "delete": return "⌫"
    case "forwardDelete": return "⌦"
    case "esc": return "⎋"
    case "home": return "↖"
    case "end": return "↘"
    case "pageUp": return "⇞"
    case "pageDown": return "⇟"
    case "padEnter": return "⌤"
    case "backslash": return "\\"
    case "caps": return "⇪"
    default:
      if key.hasPrefix("pad") { return "Pad " + key.dropFirst(3) }
      if key.hasPrefix("f"), Int(key.dropFirst()) != nil { return key.uppercased() }
      return key.uppercased()
    }
  }
}
