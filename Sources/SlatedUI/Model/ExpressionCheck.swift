import Foundation
import SlatedCore

/// Checks Slate expressions as the user types, e.g. `screenOriginX+screenSizeX/2`.
///
/// Uses `SlateExpression.evaluate` when SlatedCore implements it (and then also reports the value
/// on a sample screen). Until then, a lightweight local lint catches typos: unknown names,
/// unbalanced parentheses, stray characters.
enum ExpressionCheck {
  enum Result: Equatable {
    case empty
    /// The value on the sample screen, when the evaluator is available.
    case valid(Double?)
    case invalid(String)

    var message: String? {
      if case .invalid(let message) = self { return message }
      return nil
    }
  }

  static let variables = [
    "screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY", "windowTopLeftX", "windowTopLeftY",
    "windowSizeX", "windowSizeY", "newWindowSizeX", "newWindowSizeY", "windowHintsWidth", "windowHintsHeight",
  ]
  static let functions = [
    "sum", "count", "min", "max", "average", "median", "stddev", "sqrt", "log", "ln", "exp", "floor",
    "ceiling", "abs", "trunc", "random", "randomn",
  ]

  /// Values for every variable on a typical 1440 × 900 screen, so expressions can be evaluated
  /// (and so validated) even when no real screen is at hand.
  static let defaultVariables = sampleVariables(
    screen: CGRect(x: 0, y: 25, width: 1440, height: 875), window: CGRect(x: 360, y: 200, width: 720, height: 525))

  /// - Parameters:
  ///   - relative: also accept Slate's relative amounts for `resize`/`nudge`: `+10%`, `-100`.
  ///   - variables: sample values used to evaluate the expression when the evaluator exists. Every
  ///     variable needs a value, or the evaluator would report it as unknown.
  static func check(_ raw: String, relative: Bool = false, variables: [String: Double] = defaultVariables) -> Result {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return .empty }
    if relative, isRelativeAmount(text) { return .valid(nil) }
    let variables = variables.isEmpty ? defaultVariables : variables
    do {
      return .valid(try SlateExpression.evaluate(text, variables: variables))
    } catch let error as SlatedError {
      if case .notImplemented = error { return lint(text) }
      return .invalid(error.description)
    } catch {
      return .invalid(error.localizedDescription)
    }
  }

  static func isRelativeAmount(_ text: String) -> Bool {
    text.range(of: #"^[+-]\s*\d+(\.\d+)?%?$"#, options: .regularExpression) != nil
  }

  /// Sample variable values for a window on `screen`'s visible frame.
  static func sampleVariables(screen: CGRect, window: CGRect) -> [String: Double] {
    [
      "screenOriginX": screen.minX, "screenOriginY": screen.minY, "screenSizeX": screen.width,
      "screenSizeY": screen.height, "windowTopLeftX": window.minX, "windowTopLeftY": window.minY,
      "windowSizeX": window.width, "windowSizeY": window.height, "newWindowSizeX": window.width,
      "newWindowSizeY": window.height, "windowHintsWidth": 100, "windowHintsHeight": 100,
    ]
  }

  private static func lint(_ text: String) -> Result {
    var depth = 0
    var braces = 0
    var index = text.startIndex
    var lastSignificant: Character?
    while index < text.endIndex {
      let c = text[index]
      if c.isLetter {
        let start = index
        while index < text.endIndex, text[index].isLetter || text[index].isNumber { index = text.index(after: index) }
        let name = String(text[start..<index])
        if functions.contains(name) {
          let next = text[index...].first { !$0.isWhitespace }
          if next != "(" { return .invalid("“\(name)” is a function — write \(name)(…)") }
        } else if !variables.contains(name) {
          return .invalid(suggestion(for: name))
        }
        lastSignificant = "a"
        continue
      }
      switch c {
      case "0"..."9", ".": lastSignificant = "0"
      case "+", "-", "*", "/": lastSignificant = c
      case "(":
        depth += 1
        lastSignificant = c
      case ")":
        depth -= 1
        if depth < 0 { return .invalid("There's a “)” without a matching “(”") }
        lastSignificant = c
      case "{":
        braces += 1
        lastSignificant = c
      case "}":
        braces -= 1
        if braces < 0 { return .invalid("There's a “}” without a matching “{”") }
        lastSignificant = c
      case ",": lastSignificant = c
      case " ", "\t": break
      default: return .invalid("“\(c)” can't be used in an expression")
      }
      index = text.index(after: index)
    }
    if depth > 0 { return .invalid("Missing “)”") }
    if braces > 0 { return .invalid("Missing “}”") }
    if let last = lastSignificant, "+-*/(".contains(last) { return .invalid("The expression ends too early") }
    return .valid(nil)
  }

  private static func suggestion(for name: String) -> String {
    let lower = name.lowercased()
    let match = (variables + functions).min { distance($0.lowercased(), lower) < distance($1.lowercased(), lower) }
    if let match, distance(match.lowercased(), lower) <= max(2, name.count / 3) {
      return "Unknown name “\(name)”. Did you mean \(match)?"
    }
    return "Unknown name “\(name)”"
  }

  /// Levenshtein distance, for "did you mean" suggestions.
  private static func distance(_ a: String, _ b: String) -> Int {
    let a = Array(a)
    let b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
      }
      previous = current
    }
    return previous[b.count]
  }
}
