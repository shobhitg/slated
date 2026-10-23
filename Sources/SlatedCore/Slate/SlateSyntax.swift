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
  ///
  /// Every Slate operation is supported, plus Slated's own:
  /// - `insert-text [type|paste] 'text'`: `\n`, `\t`, `\r` and `\\` in the text are escapes.
  /// - `open-url 'https://example.com'`
  /// - `keystroke cmd+shift+4` (Slate's `4:cmd,shift` also works)
  ///
  /// Whitespace between parameters is free-form, `'…'` and `"…"` both quote, and expressions are
  /// checked, so errors (thrown as `SlatedError`) say what is wrong and where.
  public static func parseOperation(_ string: String) throws -> Action {
    try SlateOperationParser(string).parse()
  }

  /// Formats an action as an operation string that `parseOperation` reads back as the same action.
  ///
  /// Two shapes can't be written exactly, so they come back equivalent rather than identical: a
  /// `throw`/`corner` with only one of width and height (the other comes back as `windowSizeX`/
  /// `windowSizeY`), and a `chain` or `sequence` nested inside another (Slate syntax has no grouping).
  public static func format(_ action: Action) -> String {
    SlateOperationFormatter.format(action)
  }

  /// Splits a `shell` command into the program and its arguments the way Slate ran it: no shell is
  /// involved, words are separated by whitespace, and `'…'`/`"…"` group words (Slate 1.0.25+).
  /// For example `/usr/bin/say "hello world"` → `["/usr/bin/say", "hello world"]`.
  public static func shellArguments(_ command: String) throws -> [String] {
    try SlateTokenizer.tokenize(command).map(\.text)
  }

  /// Reverses `escapeText`: `\n`, `\t`, `\r` and `\\` become a newline, tab, carriage return and
  /// backslash; any other backslash is kept as written.
  static func unescapeText(_ text: String) -> String {
    var result = ""
    var iterator = text.makeIterator()
    while let c = iterator.next() {
      guard c == "\\" else {
        result.append(c)
        continue
      }
      switch iterator.next() {
      case "n": result.append("\n")
      case "t": result.append("\t")
      case "r": result.append("\r")
      case "\\": result.append("\\")
      case let other?: result += "\\\(other)"
      case nil: result.append("\\")
      }
    }
    return result
  }

  /// Escapes text for `insert-text` so it fits on one line.
  static func escapeText(_ text: String) -> String {
    var result = ""
    for c in text {
      switch c {
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\t": result += "\\t"
      case "\r": result += "\\r"
      default: result.append(c)
      }
    }
    return result
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
