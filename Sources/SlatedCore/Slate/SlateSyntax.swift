import Foundation

/// Errors from parsing and evaluating Slate syntax.
public enum SlatedError: Error, Equatable, Sendable, CustomStringConvertible {
  case notImplemented(String)
  case invalidSyntax(String)
  case invalidExpression(String)
  case unknownOperation(String)
  case screenNotFound(String)

  public var description: String {
    switch self {
    case .notImplemented(let what): return "Not implemented yet: \(what)"
    case .invalidSyntax(let msg): return msg
    case .invalidExpression(let msg): return msg
    case .unknownOperation(let name): return "Unknown operation \"\(name)\""
    case .screenNotFound(let ref): return "No screen matches \"\(ref)\""
    }
  }
}

/// A problem found while loading a config file, with its location.
public struct Diagnostic: Hashable, Sendable, Codable, CustomStringConvertible {
  public enum Severity: String, Hashable, Sendable, Codable { case error, warning }

  public var severity: Severity
  public var message: String
  /// File the problem is in, if known.
  public var file: String?
  /// 1-based line number, if known.
  public var line: Int?

  public init(_ severity: Severity, _ message: String, file: String? = nil, line: Int? = nil) {
    self.severity = severity
    self.message = message
    self.file = file
    self.line = line
  }

  public var description: String {
    let location = [file.map { ($0 as NSString).lastPathComponent }, line.map { "line \($0)" }]
      .compactMap { $0 }.joined(separator: ", ")
    return location.isEmpty ? message : "\(location): \(message)"
  }
}

/// Slate's operation and keystroke syntax, as used in `.slate` files and `slate.operationFromString`.
public enum SlateSyntax {
  /// Parses an operation string such as `push left bar-resize:screenSizeX/2`,
  /// `move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 1`, `throw right resize`,
  /// `grid padding:4 0:6,6 1:6,6`, or `chain push up | push down`.
  public static func parseOperation(_ string: String) throws -> Action {
    throw SlatedError.notImplemented("SlateSyntax.parseOperation")
  }

  /// Formats an operation back into Slate syntax. Round-trips with `parseOperation` for Slate's own
  /// operations; Slated-only operations use the same `name key:value` style.
  public static func format(_ action: Action) -> String {
    action.name
  }

  /// Parses a Slate keystroke: `a:ctrl,shift,alt,cmd`, `left:ctrl;cmd`, `1:f4,ctrl,alt` (modal key `f4`
  /// with ⌃⌥), or `1:ctrl,f4:toggle`.
  public static func parseKeystroke(_ string: String) throws -> (keys: KeyCombo, modal: ModalKey?) {
    var rest = string.trimmingCharacters(in: .whitespaces)
    var toggle = false
    if rest.lowercased().hasSuffix(":toggle") {
      toggle = true
      rest = String(rest.dropLast(":toggle".count))
    }
    // The key comes first and is never ":" itself, so the first colon separates it from the
    // modifier list. Keys like ";" and "," are fine because they come before that colon.
    let key: String
    let modifierList: String
    if let colon = rest.dropFirst().firstIndex(of: ":") {
      key = String(rest[..<colon])
      modifierList = String(rest[rest.index(after: colon)...])
    } else {
      key = rest
      modifierList = ""
    }
    guard KeyNames.isValid(key) else { throw SlatedError.invalidSyntax("Unknown key \"\(key)\" in \"\(string)\"") }

    var modifiers: Modifiers = []
    var modalKey: String?
    for token in modifierList.split(whereSeparator: { $0 == "," || $0 == ";" }) {
      let t = token.trimmingCharacters(in: .whitespaces)
      if let m = Modifiers.token(t) {
        modifiers.formUnion(m)
      } else if KeyNames.isValid(t), modalKey == nil {
        modalKey = t
      } else {
        throw SlatedError.invalidSyntax("Unknown modifier \"\(t)\" in \"\(string)\"")
      }
    }
    if let modalKey {
      // Slate applies the listed modifiers to the modal key; the binding's own key is pressed bare.
      return (KeyCombo(key: key), ModalKey(keys: KeyCombo(key: modalKey, modifiers: modifiers), toggle: toggle))
    }
    if toggle { throw SlatedError.invalidSyntax(":toggle needs a modal key in \"\(string)\"") }
    return (KeyCombo(key: key, modifiers: modifiers), nil)
  }
}

/// Result of parsing a classic `.slate` file (and everything it `source`s).
public struct SlateConfigFile: Hashable, Sendable {
  public var settings: SlateSettings
  public var bindings: [HotkeyBinding]
  public var layouts: [Layout]
  public var defaults: [ScreenDefault]
  public var diagnostics: [Diagnostic]

  public init(
    settings: SlateSettings = .init(), bindings: [HotkeyBinding] = [], layouts: [Layout] = [],
    defaults: [ScreenDefault] = [], diagnostics: [Diagnostic] = []
  ) {
    self.settings = settings
    self.bindings = bindings
    self.layouts = layouts
    self.defaults = defaults
    self.diagnostics = diagnostics
  }
}

/// Parser for classic `.slate` files: `config`, `alias`, `layout`, `default`, `bind`, `source`.
public enum SlateConfigParser {
  /// Parses `text`. `path` is used for diagnostics and to resolve relative `source` paths;
  /// `readFile` loads sourced files (injected so tests don't touch the disk).
  public static func parse(
    _ text: String, path: String? = nil,
    readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> SlateConfigFile {
    SlateConfigFile(diagnostics: [Diagnostic(.error, "Classic .slate parsing is not implemented yet", file: path)])
  }
}

/// Slate's expression language: numbers, the variables below, `+ - * / **`, parentheses, and the
/// functions `sum count min max average median stddev sqrt log ln exp floor ceiling abs trunc random randomn`.
///
/// Variables: `screenOriginX screenOriginY screenSizeX screenSizeY windowTopLeftX windowTopLeftY
/// windowSizeX windowSizeY newWindowSizeX newWindowSizeY windowHintsWidth windowHintsHeight`.
/// Unlike Slate, spaces are allowed.
public enum SlateExpression {
  public static func evaluate(_ expression: String, variables: [String: Double]) throws -> Double {
    throw SlatedError.notImplemented("SlateExpression.evaluate")
  }
}
