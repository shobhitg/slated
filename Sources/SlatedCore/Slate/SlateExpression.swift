import Foundation

/// Slate's expression language: numbers, the variables below, `+ - * / **`, unary minus, parentheses, and
/// the functions `sum count min max average median stddev sqrt log ln exp floor ceiling abs trunc random
/// randomn`.
///
/// Variables: `screenOriginX screenOriginY screenSizeX screenSizeY windowTopLeftX windowTopLeftY
/// windowSizeX windowSizeY newWindowSizeX newWindowSizeY windowHintsWidth windowHintsHeight`.
///
/// Slate handed expressions to `NSExpression`; this is a recursive-descent parser that keeps the
/// behavior configs can observe:
/// - `**` binds tighter than `*` and `/` and is **left**-associative: `2**3**2` is 64.
/// - Unary minus binds tighter than `**`: `-2**2` is 4.
/// - `/` is floating-point division (`7/2` is 3.5). `NSExpression` truncates when both operands are
///   integers, so Slate computed `1366/3` as 455 where Slated gets 455.33; window positions differ by
///   at most a point or two.
/// - Aggregates take a list: `sum({1,2,3})`. Slated also accepts `sum(1,2,3)`.
/// - `log` is base 10, `ln` is natural, `stddev` is the population standard deviation, and `median` of
///   an even count averages the middle two.
///
/// Unlike Slate, spaces are allowed, unary plus is accepted, and the result must be a finite number
/// (division by zero and `sqrt(-1)` are errors instead of silently producing garbage frames).
public enum SlateExpression {
  /// Variables describing the window and its target screen, available to every window operation.
  public static let windowVariableNames: Set<String> = [
    "screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY", "windowTopLeftX", "windowTopLeftY",
    "windowSizeX", "windowSizeY", "newWindowSizeX", "newWindowSizeY",
  ]

  /// Every variable Slate documents: the window variables plus the window-hint size variables used by
  /// the `windowHintsTopLeftX`/`windowHintsTopLeftY` settings.
  public static let variableNames: Set<String> = windowVariableNames.union(["windowHintsWidth", "windowHintsHeight"])

  /// Evaluates `expression` with `variables` supplying the value of each variable it mentions.
  ///
  /// Throws `SlatedError.invalidExpression` describing what is wrong and where (1-based column), e.g.
  /// `Unknown variable "screenSizeZ" at column 1 in "screenSizeZ/2". Did you mean "screenSizeX"?`.
  public static func evaluate(_ expression: String, variables: [String: Double]) throws -> Double {
    let parsed = try ExpressionParser.parse(expression)
    let value = try ExpressionEvaluator(source: expression, variables: variables).value(of: parsed)
    guard value.isFinite else {
      throw SlatedError.invalidExpression("\"\(expression)\" doesn't evaluate to a finite number")
    }
    return value
  }

  /// Checks that `expression` parses and only mentions variables in `variables`, without evaluating it.
  /// Configs call this at load time so typos surface before a hotkey is pressed.
  public static func validate(_ expression: String, variables: Set<String> = windowVariableNames) throws {
    let parsed = try ExpressionParser.parse(expression)
    try parsed.forEachVariable { name, column in
      guard variables.contains(name) else {
        throw ExpressionParser.unknownVariable(name, column: column, in: expression, known: variables)
      }
    }
  }
}

// MARK: - Syntax tree

/// A parsed expression. Columns are 1-based character positions, kept for error messages.
indirect enum ExpressionNode: Equatable {
  case number(Double)
  case variable(String, column: Int)
  case negate(ExpressionNode)
  case binary(ExpressionOperator, ExpressionNode, ExpressionNode, column: Int)
  case call(ExpressionFunction, [ExpressionArgument], column: Int)

  /// Calls `body` for every variable reference, in source order.
  func forEachVariable(_ body: (String, Int) throws -> Void) rethrows {
    switch self {
    case .number: break
    case .variable(let name, let column): try body(name, column)
    case .negate(let operand): try operand.forEachVariable(body)
    case .binary(_, let lhs, let rhs, _):
      try lhs.forEachVariable(body)
      try rhs.forEachVariable(body)
    case .call(_, let arguments, _):
      for argument in arguments {
        switch argument {
        case .value(let node): try node.forEachVariable(body)
        case .list(let nodes): for node in nodes { try node.forEachVariable(body) }
        }
      }
    }
  }
}

enum ExpressionOperator: String, Equatable {
  case add = "+", subtract = "-", multiply = "*", divide = "/", power = "**"
}

/// A function argument: a single value, or a `{a,b,c}` list (only aggregates accept lists).
enum ExpressionArgument: Equatable {
  case value(ExpressionNode)
  case list([ExpressionNode])
}

enum ExpressionFunction: String, CaseIterable, Equatable {
  // Aggregates over a list of values.
  case sum, count, min, max, average, median, stddev
  // One number in, one number out.
  case sqrt, log, ln, exp, floor, ceiling, abs, trunc
  // Random numbers.
  case random, randomn

  var isAggregate: Bool {
    switch self {
    case .sum, .count, .min, .max, .average, .median, .stddev: return true
    default: return false
    }
  }

  /// Number of arguments for non-aggregates.
  var arity: Int { self == .random ? 0 : 1 }
}

// MARK: - Lexer

private struct ExpressionToken: Equatable {
  enum Kind: Equatable {
    case number(Double)
    case identifier(String)
    case symbol(String)  // + - * / ** ( ) { } ,
    case end
  }

  var kind: Kind
  /// 1-based column of the token's first character.
  var column: Int

  var display: String {
    switch kind {
    case .number(let n): return n == n.rounded() && Swift.abs(n) < 1e15 ? String(Int(n)) : String(n)
    case .identifier(let name): return name
    case .symbol(let s): return s
    case .end: return "end"
    }
  }
}

private func lex(_ source: String) throws -> [ExpressionToken] {
  let chars = Array(source)
  var tokens: [ExpressionToken] = []
  var i = 0
  while i < chars.count {
    let c = chars[i]
    let column = i + 1
    if c.isWhitespace {
      i += 1
    } else if c.isASCII && (c.isNumber || c == ".") {
      // digits [. digits] [e [+-] digits], or .digits
      var j = i
      while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
      if j < chars.count, chars[j] == "." {
        j += 1
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
      }
      if j < chars.count, chars[j] == "e" || chars[j] == "E" {
        var k = j + 1
        if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
        if k < chars.count, chars[k].isASCII, chars[k].isNumber {
          while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
          j = k
        }
      }
      let text = String(chars[i..<j])
      guard let value = Double(text), text != "." else {
        throw SlatedError.invalidExpression("Invalid number \"\(text)\" at column \(column) in \"\(source)\"")
      }
      tokens.append(ExpressionToken(kind: .number(value), column: column))
      i = j
    } else if c.isLetter || c == "_" {
      var j = i
      while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
      tokens.append(ExpressionToken(kind: .identifier(String(chars[i..<j])), column: column))
      i = j
    } else if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
      tokens.append(ExpressionToken(kind: .symbol("**"), column: column))
      i += 2
    } else if "+-*/(){},".contains(c) {
      tokens.append(ExpressionToken(kind: .symbol(String(c)), column: column))
      i += 1
    } else {
      throw SlatedError.invalidExpression("Unexpected character \"\(c)\" at column \(column) in \"\(source)\"")
    }
  }
  tokens.append(ExpressionToken(kind: .end, column: chars.count + 1))
  return tokens
}

// MARK: - Parser

/// Recursive descent, lowest precedence first:
///
///     expression := term (('+' | '-') term)*
///     term       := power (('*' | '/') power)*
///     power      := unary ('**' unary)*            -- left-associative, like NSExpression
///     unary      := ('-' | '+') unary | primary    -- binds tighter than '**', like NSExpression
///     primary    := number | variable | function '(' arguments ')' | '(' expression ')'
///     arguments  := (argument (',' argument)*)?
///     argument   := expression | '{' (expression (',' expression)*)? '}'
struct ExpressionParser {
  private let source: String
  private var tokens: [ExpressionToken] = []
  private var position = 0
  private var depth = 0
  private var terms = 0
  private static let maximumDepth = 200
  /// A chain like `1+1+1…` builds a tree as deep as it is long, and evaluating it recurses that deep:
  /// thousands of terms would overflow the stack.
  private static let maximumTerms = 1000

  init(_ source: String) {
    self.source = source
  }

  static func parse(_ source: String) throws -> ExpressionNode {
    var parser = ExpressionParser(source)
    return try parser.parse()
  }

  mutating func parse() throws -> ExpressionNode {
    tokens = try lex(source)
    if tokens.count == 1 {
      throw SlatedError.invalidExpression("The expression is empty")
    }
    let node = try parseExpression()
    if current.kind != .end {
      throw unexpected(current, expecting: "an operator such as + or *")
    }
    return node
  }

  private var current: ExpressionToken { tokens[position] }

  private mutating func advance() -> ExpressionToken {
    let token = tokens[position]
    if position < tokens.count - 1 { position += 1 }
    return token
  }

  private func isSymbol(_ symbol: String) -> Bool { current.kind == .symbol(symbol) }

  private mutating func parseExpression() throws -> ExpressionNode {
    depth += 1
    defer { depth -= 1 }
    guard depth <= Self.maximumDepth else { throw tooDeep() }
    var lhs = try parseTerm()
    while isSymbol("+") || isSymbol("-") {
      let op = advance()
      let rhs = try parseTerm()
      lhs = .binary(op.kind == .symbol("+") ? .add : .subtract, lhs, rhs, column: op.column)
    }
    return lhs
  }

  private mutating func parseTerm() throws -> ExpressionNode {
    var lhs = try parsePower()
    while isSymbol("*") || isSymbol("/") {
      let op = advance()
      let rhs = try parsePower()
      lhs = .binary(op.kind == .symbol("*") ? .multiply : .divide, lhs, rhs, column: op.column)
    }
    return lhs
  }

  private mutating func parsePower() throws -> ExpressionNode {
    var lhs = try parseUnary()
    while isSymbol("**") {
      let op = advance()
      let rhs = try parseUnary()
      lhs = .binary(.power, lhs, rhs, column: op.column)
    }
    return lhs
  }

  private mutating func parseUnary() throws -> ExpressionNode {
    if isSymbol("-") || isSymbol("+") {
      let op = advance()
      depth += 1
      defer { depth -= 1 }
      guard depth <= Self.maximumDepth else { throw tooDeep() }
      let operand = try parseUnary()
      return op.kind == .symbol("-") ? .negate(operand) : operand
    }
    return try parsePrimary()
  }

  private mutating func parsePrimary() throws -> ExpressionNode {
    let token = current
    switch token.kind {
    case .number(let value):
      try countTerm()
      _ = advance()
      return .number(value)
    case .identifier(let name):
      try countTerm()
      _ = advance()
      if isSymbol("(") {
        return try parseCall(name, column: token.column)
      }
      if ExpressionFunction(rawValue: name.lowercased()) != nil {
        let example = name.lowercased() == "random" ? "random()" : "\(name.lowercased())(…)"
        throw SlatedError.invalidExpression(
          "\"\(name)\" at column \(token.column) in \"\(source)\" is a function; call it like \(example)")
      }
      return .variable(name, column: token.column)
    case .symbol("("):
      let open = advance()
      let inner = try parseExpression()
      guard isSymbol(")") else {
        if current.kind == .end {
          throw SlatedError.invalidExpression(
            "Missing \")\" for the \"(\" at column \(open.column) in \"\(source)\"")
        }
        throw unexpected(current, expecting: "\")\"")
      }
      _ = advance()
      return inner
    case .symbol("{"):
      throw SlatedError.invalidExpression(
        "A list like {1,2} at column \(token.column) in \"\(source)\" can only be passed to "
          + "sum, count, min, max, average, median or stddev")
    default:
      throw unexpected(token, expecting: "a number, a variable or \"(\"")
    }
  }

  /// Counts a number, variable or function call towards `maximumTerms`.
  private mutating func countTerm() throws {
    terms += 1
    guard terms <= Self.maximumTerms else {
      throw SlatedError.invalidExpression("\(abbreviated) is too long: an expression can have at most 1,000 terms")
    }
  }

  private func tooDeep() -> SlatedError {
    .invalidExpression("\(abbreviated) is nested too deeply: an expression can nest at most 200 levels")
  }

  /// The start of the expression, quoted: these errors are about expressions of 200 characters or more.
  private var abbreviated: String { "\"\(source.prefix(40))…\"" }

  private mutating func parseCall(_ name: String, column: Int) throws -> ExpressionNode {
    guard let function = ExpressionFunction(rawValue: name.lowercased()) else {
      var message = "Unknown function \"\(name)\" at column \(column) in \"\(source)\""
      if let suggestion = closestName(to: name, in: ExpressionFunction.allCases.map(\.rawValue)) {
        message += ". Did you mean \"\(suggestion)\"?"
      }
      throw SlatedError.invalidExpression(message)
    }
    _ = advance()  // (
    var arguments: [ExpressionArgument] = []
    if !isSymbol(")") {
      repeat {
        if isSymbol("{") {
          arguments.append(.list(try parseList()))
        } else {
          arguments.append(.value(try parseExpression()))
        }
      } while consume(",")
    }
    guard isSymbol(")") else {
      if current.kind == .end {
        throw SlatedError.invalidExpression(
          "Missing \")\" after the arguments of \"\(name)\" at column \(column) in \"\(source)\"")
      }
      throw unexpected(current, expecting: "\",\" or \")\"")
    }
    _ = advance()

    if function.isAggregate { return .call(function, arguments, column: column) }
    if arguments.contains(where: { if case .list = $0 { return true } else { return false } }) {
      throw SlatedError.invalidExpression(
        "\"\(function.rawValue)\" at column \(column) in \"\(source)\" takes a number, not a list")
    }
    if arguments.count != function.arity {
      let expected = function.arity == 1 ? "1 argument" : "no arguments"
      throw SlatedError.invalidExpression(
        "\"\(function.rawValue)\" takes \(expected) but got \(arguments.count) at column \(column) in \"\(source)\"")
    }
    return .call(function, arguments, column: column)
  }

  private mutating func parseList() throws -> [ExpressionNode] {
    let open = advance()  // {
    var items: [ExpressionNode] = []
    if !isSymbol("}") {
      repeat {
        if isSymbol("{") {
          throw SlatedError.invalidExpression("Lists can't be nested (column \(current.column) in \"\(source)\")")
        }
        items.append(try parseExpression())
      } while consume(",")
    }
    guard isSymbol("}") else {
      if current.kind == .end {
        throw SlatedError.invalidExpression("Missing \"}\" for the \"{\" at column \(open.column) in \"\(source)\"")
      }
      throw unexpected(current, expecting: "\",\" or \"}\"")
    }
    _ = advance()
    return items
  }

  private mutating func consume(_ symbol: String) -> Bool {
    guard isSymbol(symbol) else { return false }
    _ = advance()
    return true
  }

  private func unexpected(_ token: ExpressionToken, expecting: String) -> SlatedError {
    if token.kind == .end {
      return SlatedError.invalidExpression("\"\(source)\" ends too early; expected \(expecting)")
    }
    return SlatedError.invalidExpression(
      "Unexpected \"\(token.display)\" at column \(token.column) in \"\(source)\"; expected \(expecting)")
  }

  static func unknownVariable(_ name: String, column: Int, in source: String, known: Set<String>) -> SlatedError {
    var message = "Unknown variable \"\(name)\" at column \(column) in \"\(source)\""
    if let suggestion = closestName(to: name, in: known.sorted()) {
      message += ". Did you mean \"\(suggestion)\"?"
    }
    return SlatedError.invalidExpression(message)
  }
}

/// The candidate closest to `name` (ignoring case), if it is close enough to be a likely typo.
func closestName(to name: String, in candidates: [String]) -> String? {
  let lowered = name.lowercased()
  var best: (name: String, distance: Int)?
  for candidate in candidates {
    let distance = editDistance(lowered, candidate.lowercased())
    if distance < (best?.distance ?? Int.max) { best = (candidate, distance) }
  }
  let allowed = Swift.max(1, Swift.min(3, name.count / 3))
  if let best, best.distance <= allowed { return best.name }
  // An abbreviation, like "ceil" for "ceiling".
  guard lowered.count >= 3 else { return nil }
  return candidates.first { $0.lowercased().hasPrefix(lowered) }
}

/// Levenshtein distance between two strings, by characters.
func editDistance(_ a: String, _ b: String) -> Int {
  let a = Array(a)
  let b = Array(b)
  if a.isEmpty { return b.count }
  if b.isEmpty { return a.count }
  var previous = Array(0...b.count)
  var row = [Int](repeating: 0, count: b.count + 1)
  for i in 1...a.count {
    row[0] = i
    for j in 1...b.count {
      let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
      row[j] = Swift.min(substitution, previous[j] + 1, row[j - 1] + 1)
    }
    swap(&previous, &row)
  }
  return previous[b.count]
}

// MARK: - Evaluator

struct ExpressionEvaluator {
  let source: String
  let variables: [String: Double]

  func value(of node: ExpressionNode) throws -> Double {
    switch node {
    case .number(let value):
      return value
    case .variable(let name, let column):
      guard let value = variables[name] else {
        throw ExpressionParser.unknownVariable(
          name, column: column, in: source, known: Set(variables.keys).union(SlateExpression.variableNames))
      }
      return value
    case .negate(let operand):
      return -(try value(of: operand))
    case .binary(let op, let lhsNode, let rhsNode, let column):
      let lhs = try value(of: lhsNode)
      let rhs = try value(of: rhsNode)
      switch op {
      case .add: return lhs + rhs
      case .subtract: return lhs - rhs
      case .multiply: return lhs * rhs
      case .divide:
        guard rhs != 0 else {
          throw SlatedError.invalidExpression("Division by zero at column \(column) in \"\(source)\"")
        }
        return lhs / rhs
      case .power: return Foundation.pow(lhs, rhs)
      }
    case .call(let function, let arguments, let column):
      return try call(function, arguments, column: column)
    }
  }

  private func call(_ function: ExpressionFunction, _ arguments: [ExpressionArgument], column: Int) throws -> Double {
    if function.isAggregate {
      var values: [Double] = []
      for argument in arguments {
        switch argument {
        case .value(let node): values.append(try value(of: node))
        case .list(let nodes): for node in nodes { values.append(try value(of: node)) }
        }
      }
      return try aggregate(function, values, column: column)
    }
    let operands = try arguments.map { argument -> Double in
      guard case .value(let node) = argument else { return .nan }  // rejected by the parser
      return try value(of: node)
    }
    switch function {
    case .sqrt: return Foundation.sqrt(operands[0])
    case .log: return Foundation.log10(operands[0])
    case .ln: return Foundation.log(operands[0])
    case .exp: return Foundation.exp(operands[0])
    case .floor: return operands[0].rounded(.down)
    case .ceiling: return operands[0].rounded(.up)
    case .abs: return Swift.abs(operands[0])
    case .trunc: return operands[0].rounded(.towardZero)
    case .random: return Double.random(in: 0..<1)
    case .randomn:
      // Like NSExpression: a random integer from 0 to n-1, with n truncated to an integer.
      let n = operands[0].rounded(.towardZero)
      guard n >= 1, n < 1e15 else {
        throw SlatedError.invalidExpression(
          "\"randomn\" at column \(column) in \"\(source)\" needs a number of at least 1")
      }
      return Double(Int.random(in: 0..<Int(n)))
    default:
      return .nan  // aggregates are handled above
    }
  }

  private func aggregate(_ function: ExpressionFunction, _ values: [Double], column: Int) throws -> Double {
    switch function {
    case .sum: return values.reduce(0, +)
    case .count: return Double(values.count)
    default: break
    }
    guard !values.isEmpty else {
      throw SlatedError.invalidExpression(
        "\"\(function.rawValue)\" at column \(column) in \"\(source)\" needs at least one value")
    }
    switch function {
    case .min: return values.min()!
    case .max: return values.max()!
    case .average: return values.reduce(0, +) / Double(values.count)
    case .median:
      let sorted = values.sorted()
      let middle = sorted.count / 2
      return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    case .stddev:
      let mean = values.reduce(0, +) / Double(values.count)
      let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
      return Foundation.sqrt(variance)
    default:
      return .nan
    }
  }
}
