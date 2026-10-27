import Foundation

@testable import SlatedCore

/// The window/screen variables from ExpressionTests: a window at (100, 200), 800×600, on a 1440×875
/// visible screen area starting at (0, 25).
private let defaultVariables: [String: Double] = [
  "screenOriginX": 0, "screenOriginY": 25, "screenSizeX": 1440, "screenSizeY": 875,
  "windowTopLeftX": 100, "windowTopLeftY": 200, "windowSizeX": 800, "windowSizeY": 600,
  "newWindowSizeX": 640, "newWindowSizeY": 480,
]

/// Extra variables beyond Slate's, to show they join the "Did you mean" candidates.
private let extraVariables: [String: Double] = defaultVariables.merging(["myWidth": 300, "half": 0.5]) { a, _ in a }

private let variableSets: [String: [String: Double]] = [
  "default": defaultVariables, "extra": extraVariables, "none": [:],
]

private let evaluateInputs: [String] = [
  // ExpressionTests: numbers and arithmetic
  "1+1", "1-1", "2*2", "4/2", "3**2", "10-2-3", "100/10/2", "2+3*4", "(2+3)*4", "1.5e2", "1e3", ".5", "5.",
  "2**-1", "2**0.5",
  // ** binds tighter than * and is left-associative
  "2**3**2", "2**(3**2)", "2*3**2", "2**3*2",
  // unary minus binds tighter than **
  "-2**2", "-(2**2)", "-2**-2", "2*-3", "4/-2", "2--3", "--2", "-windowSizeX", "+5", "2-+3",
  // division is floating point
  "7/2", "10/4", "-7/2", "screenSizeY/2", "1366/3", "screenSizeX/1.3",
  // variables
  "screenOriginX+screenSizeX/2", "screenOriginY+screenSizeY-windowSizeY", "screenOriginX+(screenSizeX-windowSizeX)/2",
  "windowTopLeftX+10*screenSizeX/100", "newWindowSizeX+newWindowSizeY", "screenSizeX*2/3",
  // functions, with the README's examples
  "sum({1,2,3})", "count({4,5,6})", "min({1,3,5})", "max({1,3,5})", "average({1,2,3,4})", "median({1,2,3,10,15})",
  "stddev({1,2,3,4,5})", "sqrt(9)", "log(100)", "ln(8)", "exp(2)", "floor(1.9)", "ceiling(1.1)", "abs(-1)",
  "trunc(1.1123123123)", "sqrt((10/2)*5)+count({1,2,3})", "2**10+sum({1,2,3})", "min({1,2,3})+max({4,5,6})",
  "average({1,2,3,4})+median({1,2,3,10,15})", "floor(3.9)+(stddev({1,2,3,4,5}))**2", "log(1000)+ln(exp(5))",
  "ceiling(2.1)+abs(-2)", "trunc(3.232472398472834723)",
  // function edge cases
  "trunc(-1.7)", "floor(-1.5)", "ceiling(-1.5)", "median({4,1,3,2})", "median({5})", "stddev({1,2})", "stddev({7})",
  "sum({})", "count({})", "max({screenSizeX/2, windowSizeX})", "min(screenSizeX, 1000)", "SQRT(16)", "sum({1,2},3)",
  // spaces are allowed
  " screenOriginX + screenSizeX / 2 ", "sum( { 1 , 2 } )", "2 ** 3", "\tscreenSizeX\t/\t4",
  // deterministic uses of the random functions
  "randomn(1)", "randomn(1.9)", "floor(random())", "random()*0", "trunc(random())", "min({random(), 2})*0",
  // errors from ExpressionTests
  "screenSizeZ/2", "screensizex/2", "1+*2", "(1+2", "1+2)", "1 2", "2+", "", "   ", "2 $ 3", "foo(1)", "ceil(1.5)",
  "sqrt(1,2)", "random(3)", "sqrt({4})", "random", "{1,2}", "sum({1,{2}})", "sum({1,2)", "max(1", "min({})",
  "average({})", "randomn(0)", "1/0", "windowSizeX/(windowSizeX-800)", "sqrt(-1)", "log(0)", "1.2.3", "nope",
  String(repeating: "(", count: 500) + "1",
  // more numbers
  "0", "-0", "007", "1.", "1.e5", "1e", "1e+", "1e-2", "1E3", "1.5E-3", "2e400", "1e-400", "0.1+0.2", "1e308*10",
  "123456789*1000", "9007199254740993", "4.35", "0.000001", ".e5", "..5", "1..2", "5e", "5e+x",
  // number display in "Unexpected" errors (Swift's Double description)
  "1 2.5", "1 1e20", "1 0.00001", "1 123456789012345678", "1 1e15", "1 999999999999999", "1 100.0", "1 0.1",
  "1 1e-4", "1 12345678.9", "1 1e16", "1 1.5e300", "1 5e-324", "1 2e400", "1 0.30000000000000004", "1 1e-7",
  "1 0.001", "1 1234567890123456", "1 -5", "1 1e14", "1 33.333333333333336",
  // precedence and associativity
  "2+3*4-5/2", "-2*-3", "2*-3**2", "-3**2", "2**-3**2", "(1)", "((1))", "+-+-1", "1--1", "1---1", "1++1",
  "1-2-3-4", "64/4/2/2", "2*3+4*5", "(2+3)*(4-1)/5", "2**2**2**2", "-(-(-1))", "10-(2-3)", "2**3**0",
  "1+2*3**2/4-5", "-2**0.5**2",
  // every function, including case variants and unusual argument shapes
  "Sum({1,2})", "COUNT(1,2,3)", "Min(3,1,2)", "MAX({-1,-5})", "average(2)", "median(3,1,2)", "stddev(2,4,4,4,5,5,7,9)",
  "Sqrt(2)", "LOG(1e3)", "Ln(1)", "EXP(0)", "Floor(-0.5)", "CEILING(-0.5)", "Abs(-0)", "TRUNC(-0.5)",
  "sum()", "count()", "min()", "max()", "average()", "median()", "stddev()", "sqrt()", "randomn()",
  "randomn(1,2)", "randomn({1})", "random(1)", "randomn(0.5)", "randomn(-1)", "randomn(1e15)", "abs({1})",
  "sum(1,)", "sum(,1)", "sum({1,})", "sum({,1})", "sum({1 2})", "sum({1},{2,3})", "max(min({1,2}),3)",
  "median({1,2,3,4,5,6})", "median({1})", "average({1,2},{3})", "count({},{})", "stddev({1,1,1})",
  "min({windowSizeX, screenSizeX})+max(windowSizeY, screenSizeY)", "sum({1e308, 1e308})",
  "floor(2.5)", "ceiling(2.5)", "trunc(2.5)", "floor(-2.5)", "ceiling(-2.000000001)", "sqrt(0)", "sqrt(1e-300)",
  "log(10)", "log(2)", "ln(10)", "exp(1)", "exp(-1)", "2**10", "10**-2", "0**0", "0**-1", "(-8)**(1/3)",
  "(-2)**3", "(-2)**0.5", "2**1024", "exp(1000)", "ln(-1)", "1/(2-2)", "1/-0", "0/0", "screenSizeX/0",
  // C's pow, where it differs from JavaScript's Math.pow
  "1**sqrt(-1)", "1**1e400", "(-1)**1e400", "(-1)**-1e400", "2**sqrt(-1)", "sqrt(-1)**0", "1e400**0", "0**-1e400",
  "(-1)**0.5", "(-0)**-1", "(-8)**(1/3)*0",
  // identifiers and characters
  "screenSizeX×2", "écran", "\u{915}\u{94D}\u{937}+*", "\u{915}\u{94D}\u{200D}\u{937}+*", "\u{1100}\u{1161}\u{11A8}+*",
  "x_1", "_a", "a1b2", "2a", "e\u{301}", "1+e\u{301}x", "1+😀", "😀+1", "1+👍🏽",
  "1+🇺🇸", "1+👨‍👩‍👧", "screenSizeX#2", "screenSizeX%2", "screenSizeX^2", "screenSizeX;2", "[1]", "1,2", "f(1)",
  "screen SizeX", "windowTopLeftX.5",
  // whitespace: Unicode spaces are fine, format characters are not
  "\n1+1\n", "1\u{00A0}+1", "1\u{3000}+1", "1\u{2003}+1", "1\u{85}+1", "1\u{2028}+1", "1\r\n+1", "1\u{200B}+1",
  "1\u{FEFF}+1", "\u{FEFF}1",
  // unknown names and their suggestions
  "sqr(4)", "flor(1)", "averag(1)", "abss(1)", "ceil(1)", "trun(1)", "logg(1)", "xyz(1)", "co(1)", "rand(1)",
  "randomm()", "screenX", "windowsizex", "screen", "new", "win", "window", "screenOrigin", "screenoriginy",
  "myWidht", "halff", "screenSize", "SCREENSIZEX", "max", "MAX", "Random", "ln", "foo", "min ({1})",
  // nesting limits (200 levels)
  String(repeating: "(", count: 199) + "1" + String(repeating: ")", count: 199),
  String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200),
  String(repeating: "-", count: 199) + "1", String(repeating: "-", count: 200) + "1",
  "sum(" + String(repeating: "(", count: 198) + "1" + String(repeating: ")", count: 198) + ")",
  "sum(" + String(repeating: "(", count: 199) + "1" + String(repeating: ")", count: 199) + ")",
  String(repeating: "(", count: 1000) + "1" + String(repeating: ")", count: 1000),
  String(repeating: "-", count: 1000) + "1", String(repeating: "sqrt(", count: 1000) + "1",
  // length limit (1,000 numbers, variables and function calls): long chains would overflow the stack
  chain("+", 1000), chain("+", 1001), chain("-", 1001), chain("*", 1000), chain("*", 1001), chain("/", 1001),
  chain("**", 1000), chain("**", 1001), "(" + chain("+", 1000) + ")",
  "(" + chain("+", 500) + ")*(" + chain("+", 501) + ")",
  "sum({" + chain(",", 999) + "})", "sum({" + chain(",", 1000) + "})", "sum(" + chain(",", 999) + ")",
  "screenSizeX" + String(repeating: "+windowSizeX", count: 1000),
  String(repeating: "abs(", count: 150) + chain("+", 850) + String(repeating: ")", count: 150),
  String(repeating: "abs(", count: 150) + chain("+", 851) + String(repeating: ")", count: 150),
  chain("+", 1001, term: "e\u{301}"), chain("+", 1001, term: "1\r\n"), chain("+", 1001, term: "\u{915}\u{94D}\u{937}"),
  // stray symbols
  "{", "}", ",", "()", "(", ")", "1(", "*", "**2", "2**", "2***3", "2* *3", "(()", "1)(2",
]

/// `count` copies of `term` joined by `op`, such as `1+1+1`.
private func chain(_ op: String, _ count: Int, term: String = "1") -> String {
  Array(repeating: term, count: count).joined(separator: op)
}

/// Expressions whose result goes through pow/log/exp, where libm implementations may differ by an
/// ulp between Swift (Darwin) and JavaScript engines.
private func usesTranscendental(_ expression: String) -> Bool {
  let lowered = expression.lowercased()
  return ["**", "log(", "ln(", "exp("].contains { lowered.contains($0) }
}

private let validateInputs: [(String, String)] = [
  ("screenOriginX+screenSizeX/2", "window"), ("1/0", "window"), ("random()*windowSizeX", "window"),
  ("windowHintsWidth/2", "window"), ("windowHintsWidth/2", "all"), ("windowHintsHeight", "all"),
  ("screenOrginX+1", "window"), ("2+", "window"), ("", "window"), ("sqrt(-1)", "window"), ("newWindowSizeX", "window"),
  ("unknownVar", "window"), ("unknownVar", "all"), ("screenSizeX/2+windowSizeY*3", "window"),
  ("max({screenSizeX, windowHintsWidth})", "window"), ("foo(1)", "window"), ("windowsizex", "window"),
  ("screenOriginX+bogus+alsoBogus", "window"), ("windowHintsWidht", "all"), ("1 2", "window"), ("(1", "all"),
  ("screenSizeX", "none"), ("2*3", "none"), ("a+b", "custom"), ("aa+b", "custom"), ("c", "custom"),
  (chain("+", 1000, term: "a"), "custom"), (chain("+", 1001, term: "a"), "custom"),
  (String(repeating: "(", count: 201) + "a" + String(repeating: ")", count: 201), "custom"),
]

private let validateSets: [String: Set<String>] = [
  "window": SlateExpression.windowVariableNames, "all": SlateExpression.variableNames, "none": [],
  "custom": ["a", "b"],
]

private let closestNameInputs: [(String, [String])] = [
  ("ceil", ExpressionFunction.allCases.map(\.rawValue)), ("sqr", ExpressionFunction.allCases.map(\.rawValue)),
  ("co", ExpressionFunction.allCases.map(\.rawValue)), ("averge", ExpressionFunction.allCases.map(\.rawValue)),
  ("rnd", ExpressionFunction.allCases.map(\.rawValue)), ("", ExpressionFunction.allCases.map(\.rawValue)),
  ("screen", SlateExpression.variableNames.sorted()), ("scrensizex", SlateExpression.variableNames.sorted()),
  ("WINDOWSIZEY", SlateExpression.variableNames.sorted()), ("abc", []), ("ab", ["abc", "abd"]),
  ("abc", ["xyz", "abcd", "abce"]), ("defaultToCurentScreen", SlateConfigParser.knownSettings.sorted()),
  ("nudgepercent", SlateConfigParser.knownSettings.sorted()), ("window", SlateConfigParser.knownSettings.sorted()),
  ("zzz", SlateConfigParser.knownSettings.sorted()), ("lft-half", ["half", "left-half"]), ("x", ["a", "b", "y"]),
  ("éa", ["ea", "éb"]), ("Straße", ["strasse", "STRASSE"]),
]

private let editDistanceInputs: [(String, String)] = [
  ("", ""), ("", "abc"), ("abc", ""), ("kitten", "sitting"), ("flaw", "lawn"), ("abc", "abc"), ("abc", "acb"),
  ("e\u{301}", "é"), ("😀a", "a😀"), ("screensizez", "screensizex"), ("ceil", "ceiling"),
]

func expressionFixtures() -> FixtureFile {
  var evaluate: [J] = []
  for (setName, variables) in [("default", defaultVariables), ("extra", extraVariables), ("none", [:])] {
    let inputs = setName == "default" ? evaluateInputs : evaluateInputs.filter { $0.contains(where: \.isLetter) }
    for expression in inputs {
      var item: [String: J] = ["expression": .string(expression), "variables": .string(setName)]
      do {
        item["result"] = .number(try SlateExpression.evaluate(expression, variables: variables))
        if usesTranscendental(expression) { item["tolerance"] = "ulp" }
      } catch {
        item["error"] = errorJ(error)
      }
      evaluate.append(.object(item))
    }
  }
  // random() and randomn() can only be checked for their range.
  for (expression, low, high, integer) in [
    ("random()", 0.0, 1.0, false), ("randomn(10)", 0.0, 10.0, true), ("random()*screenSizeX", 0.0, 1440.0, false),
    ("randomn(2.9)", 0.0, 2.0, true),
  ] {
    for _ in 0..<200 {
      let value = try! SlateExpression.evaluate(expression, variables: defaultVariables)
      precondition(value >= low && value < high && (!integer || value == value.rounded()), "\(expression) = \(value)")
    }
    evaluate.append([
      "expression": .string(expression), "variables": "default",
      "random": ["min": .number(low), "max": .number(high), "integer": .bool(integer)],
    ])
  }

  let validate: [J] = validateInputs.map { expression, setName in
    var item: [String: J] = ["expression": .string(expression), "variables": .string(setName)]
    do {
      try SlateExpression.validate(expression, variables: validateSets[setName]!)
      item["valid"] = true
    } catch {
      item["error"] = errorJ(error)
    }
    return .object(item)
  }

  let closest: [J] = closestNameInputs.map { name, candidates in
    [
      "name": .string(name), "candidates": .array(candidates.map(J.string)),
      "result": .optional(closestName(to: name, in: candidates)),
    ]
  }
  let distances: [J] = editDistanceInputs.map { a, b in
    ["a": .string(a), "b": .string(b), "distance": .int(editDistance(a, b))]
  }

  return FixtureFile(
    name: "expressions.json",
    description:
      "SlateExpression.evaluate/validate: values, errors (exact messages), precedence, spaces, every function. "
      + "`tolerance: ulp` marks results that go through pow/log/exp (libm may differ by an ulp).",
    sections: ["evaluate": evaluate, "validate": validate, "closestName": closest, "editDistance": distances],
    extra: [
      "variables": .object(variableSets.mapValues { .object($0.mapValues(J.number)) }),
      "variableSets": .object(validateSets.mapValues { .array($0.sorted().map(J.string)) }),
      "windowVariableNames": .array(SlateExpression.windowVariableNames.sorted().map(J.string)),
      "variableNames": .array(SlateExpression.variableNames.sorted().map(J.string)),
    ])
}
