import Foundation

@testable import SlatedCore

/// A window at (100, 200), 800×600, on a 1440×875 visible screen area starting at (0, 25).
private let variables: [String: Double] = [
  "screenOriginX": 0, "screenOriginY": 25, "screenSizeX": 1440, "screenSizeY": 875,
  "windowTopLeftX": 100, "windowTopLeftY": 200, "windowSizeX": 800, "windowSizeY": 600,
  "newWindowSizeX": 640, "newWindowSizeY": 480,
]

private func evaluate(_ expression: String) throws -> Double {
  try SlateExpression.evaluate(expression, variables: variables)
}

/// The description of the error `body` throws, or "no error".
func errorMessage(_ body: () throws -> Void) -> String {
  do {
    try body()
    return "no error"
  } catch {
    return "\(error)"
  }
}

func expectClose(
  _ actual: @autoclosure () throws -> Double, _ expected: Double, tolerance: Double = 1e-9,
  file: StaticString = #fileID, line: UInt = #line
) {
  do {
    let value = try actual()
    expect(abs(value - expected) <= tolerance, "expected \(expected), got \(value)", file: file, line: line)
  } catch {
    expect(false, "threw \(error)", file: file, line: line)
  }
}

/// Stops the test unless `items` has exactly `count` elements, so indexing into it afterwards can't crash.
func requireCount<T>(_ items: [T], _ count: Int, file: StaticString = #fileID, line: UInt = #line) throws {
  guard items.count == count else {
    throw TestFailure(description: "\(file):\(line): expected \(count) items, got \(items.count): \(items)")
  }
}

/// Fails unless `message` contains every one of `parts`.
func expectMessage(
  _ message: String, contains parts: String..., file: StaticString = #fileID, line: UInt = #line
) {
  for part in parts {
    expect(message.contains(part), "\"\(message)\" should contain \"\(part)\"", file: file, line: line)
  }
}

let expressionTests = Suite(
  "Expression",
  [
    (
      "numbers and arithmetic",
      {
        expectEqual(try evaluate("1+1"), 2)
        expectEqual(try evaluate("1-1"), 0)
        expectEqual(try evaluate("2*2"), 4)
        expectEqual(try evaluate("4/2"), 2)
        expectEqual(try evaluate("3**2"), 9)
        expectEqual(try evaluate("10-2-3"), 5)
        expectEqual(try evaluate("100/10/2"), 5)
        expectEqual(try evaluate("2+3*4"), 14)
        expectEqual(try evaluate("(2+3)*4"), 20)
        expectEqual(try evaluate("1.5e2"), 150)
        expectEqual(try evaluate("1e3"), 1000)
        expectEqual(try evaluate(".5"), 0.5)
        expectEqual(try evaluate("5."), 5)
        expectEqual(try evaluate("2**-1"), 0.5)
        expectClose(try evaluate("2**0.5"), 1.4142135623730951)
      }
    ),
    (
      "** binds tighter than * and is left-associative, like NSExpression",
      {
        expectEqual(try evaluate("2**3**2"), 64)
        expectEqual(try evaluate("2**(3**2)"), 512)
        expectEqual(try evaluate("2*3**2"), 18)
        expectEqual(try evaluate("2**3*2"), 16)
      }
    ),
    (
      "unary minus binds tighter than **, like NSExpression",
      {
        expectEqual(try evaluate("-2**2"), 4)
        expectEqual(try evaluate("-(2**2)"), -4)
        expectEqual(try evaluate("-2**-2"), 0.25)
        expectEqual(try evaluate("2*-3"), -6)
        expectEqual(try evaluate("4/-2"), -2)
        expectEqual(try evaluate("2--3"), 5)
        expectEqual(try evaluate("--2"), 2)
        expectEqual(try evaluate("-windowSizeX"), -800)
        expectEqual(try evaluate("+5"), 5)
        expectEqual(try evaluate("2-+3"), -1)
      }
    ),
    (
      "division is floating point",
      {
        expectEqual(try evaluate("7/2"), 3.5)
        expectEqual(try evaluate("10/4"), 2.5)
        expectEqual(try evaluate("-7/2"), -3.5)
        expectEqual(try evaluate("screenSizeY/2"), 437.5)
        expectClose(try evaluate("1366/3"), 455.3333333333333)
        expectClose(try evaluate("screenSizeX/1.3"), 1107.6923076923076)
      }
    ),
    (
      "variables",
      {
        expectEqual(try evaluate("screenOriginX+screenSizeX/2"), 720)
        expectEqual(try evaluate("screenOriginY+screenSizeY-windowSizeY"), 300)
        expectEqual(try evaluate("screenOriginX+(screenSizeX-windowSizeX)/2"), 320)
        expectEqual(try evaluate("windowTopLeftX+10*screenSizeX/100"), 244)
        expectEqual(try evaluate("newWindowSizeX+newWindowSizeY"), 1120)
        expectEqual(try evaluate("screenSizeX*2/3"), 960)
      }
    ),
    (
      "functions, with the README's examples",
      {
        expectEqual(try evaluate("sum({1,2,3})"), 6)
        expectEqual(try evaluate("count({4,5,6})"), 3)
        expectEqual(try evaluate("min({1,3,5})"), 1)
        expectEqual(try evaluate("max({1,3,5})"), 5)
        expectEqual(try evaluate("average({1,2,3,4})"), 2.5)
        expectEqual(try evaluate("median({1,2,3,10,15})"), 3)
        expectClose(try evaluate("stddev({1,2,3,4,5})"), 1.4142135623730951)
        expectEqual(try evaluate("sqrt(9)"), 3)
        expectEqual(try evaluate("log(100)"), 2)
        expectClose(try evaluate("ln(8)"), 2.0794415416798357)
        expectClose(try evaluate("exp(2)"), 7.3890560989306504)
        expectEqual(try evaluate("floor(1.9)"), 1)
        expectEqual(try evaluate("ceiling(1.1)"), 2)
        expectEqual(try evaluate("abs(-1)"), 1)
        expectEqual(try evaluate("trunc(1.1123123123)"), 1)
        // Slate's own expression tests.
        expectEqual(try evaluate("sqrt((10/2)*5)+count({1,2,3})"), 8)
        expectEqual(try evaluate("2**10+sum({1,2,3})"), 1030)
        expectEqual(try evaluate("min({1,2,3})+max({4,5,6})"), 7)
        expectEqual(try evaluate("average({1,2,3,4})+median({1,2,3,10,15})"), 5.5)
        expectClose(try evaluate("floor(3.9)+(stddev({1,2,3,4,5}))**2"), 5)
        expectClose(try evaluate("log(1000)+ln(exp(5))"), 8)
        expectEqual(try evaluate("ceiling(2.1)+abs(-2)"), 5)
        expectEqual(try evaluate("trunc(3.232472398472834723)"), 3)
      }
    ),
    (
      "function edge cases",
      {
        expectEqual(try evaluate("trunc(-1.7)"), -1)
        expectEqual(try evaluate("floor(-1.5)"), -2)
        expectEqual(try evaluate("ceiling(-1.5)"), -1)
        expectEqual(try evaluate("median({4,1,3,2})"), 2.5)
        expectEqual(try evaluate("median({5})"), 5)
        expectEqual(try evaluate("stddev({1,2})"), 0.5)
        expectEqual(try evaluate("stddev({7})"), 0)
        expectEqual(try evaluate("sum({})"), 0)
        expectEqual(try evaluate("count({})"), 0)
        expectEqual(try evaluate("max({screenSizeX/2, windowSizeX})"), 800)
        expectEqual(try evaluate("min(screenSizeX, 1000)"), 1000)  // Slated: lists may skip the braces
        expectEqual(try evaluate("SQRT(16)"), 4)  // function names ignore case
        expectEqual(try evaluate("sum({1,2},3)"), 6)
      }
    ),
    (
      "spaces are allowed",
      {
        expectEqual(try evaluate(" screenOriginX + screenSizeX / 2 "), 720)
        expectEqual(try evaluate("sum( { 1 , 2 } )"), 3)
        expectEqual(try evaluate("2 ** 3"), 8)
        expectEqual(try evaluate("\tscreenSizeX\t/\t4"), 360)
      }
    ),
    (
      "random numbers stay in range",
      {
        for _ in 0..<50 {
          let r = try evaluate("random()")
          expect(r >= 0 && r < 1, "random() = \(r)")
          let n = try evaluate("randomn(10)")
          expect(n >= 0 && n < 10 && n == n.rounded(), "randomn(10) = \(n)")
        }
        expectEqual(try evaluate("randomn(1)"), 0)
        expectEqual(try evaluate("randomn(1.9)"), 0)
      }
    ),
    (
      "errors say what is wrong and where",
      {
        expectMessage(
          errorMessage { _ = try evaluate("screenSizeZ/2") },
          contains: "Unknown variable \"screenSizeZ\" at column 1 in \"screenSizeZ/2\"", "Did you mean \"screenSizeX\"?"
        )
        expectMessage(
          errorMessage { _ = try evaluate("screensizex/2") }, contains: "Did you mean \"screenSizeX\"?")
        expectMessage(errorMessage { _ = try evaluate("1+*2") }, contains: "Unexpected \"*\" at column 3 in \"1+*2\"")
        expectMessage(
          errorMessage { _ = try evaluate("(1+2") }, contains: "Missing \")\" for the \"(\" at column 1 in \"(1+2\"")
        expectMessage(errorMessage { _ = try evaluate("1+2)") }, contains: "Unexpected \")\" at column 4")
        expectMessage(errorMessage { _ = try evaluate("1 2") }, contains: "Unexpected \"2\" at column 3")
        expectMessage(errorMessage { _ = try evaluate("2+") }, contains: "\"2+\" ends too early")
        expectMessage(errorMessage { _ = try evaluate("") }, contains: "The expression is empty")
        expectMessage(errorMessage { _ = try evaluate("   ") }, contains: "The expression is empty")
        expectMessage(errorMessage { _ = try evaluate("2 $ 3") }, contains: "Unexpected character \"$\" at column 3")
        expectMessage(errorMessage { _ = try evaluate("foo(1)") }, contains: "Unknown function \"foo\" at column 1")
        expectMessage(errorMessage { _ = try evaluate("ceil(1.5)") }, contains: "Did you mean \"ceiling\"?")
        expectMessage(
          errorMessage { _ = try evaluate("sqrt(1,2)") }, contains: "\"sqrt\" takes 1 argument but got 2 at column 1")
        expectMessage(errorMessage { _ = try evaluate("random(3)") }, contains: "\"random\" takes no arguments")
        expectMessage(errorMessage { _ = try evaluate("sqrt({4})") }, contains: "takes a number, not a list")
        expectMessage(errorMessage { _ = try evaluate("random") }, contains: "is a function; call it like random()")
        expectMessage(errorMessage { _ = try evaluate("{1,2}") }, contains: "can only be passed to sum")
        expectMessage(errorMessage { _ = try evaluate("sum({1,{2}})") }, contains: "Lists can't be nested")
        expectMessage(errorMessage { _ = try evaluate("sum({1,2)") }, contains: "Unexpected \")\" at column 9")
        expectMessage(
          errorMessage { _ = try evaluate("max(1") }, contains: "Missing \")\" after the arguments of \"max\"")
        expectMessage(
          errorMessage { _ = try evaluate("min({})") },
          contains: "\"min\" at column 1 in \"min({})\" needs at least one value")
        expectMessage(errorMessage { _ = try evaluate("average({})") }, contains: "needs at least one value")
        expectMessage(errorMessage { _ = try evaluate("randomn(0)") }, contains: "needs a number of at least 1")
        expectMessage(errorMessage { _ = try evaluate("1/0") }, contains: "Division by zero at column 2 in \"1/0\"")
        expectMessage(
          errorMessage { _ = try evaluate("windowSizeX/(windowSizeX-800)") }, contains: "Division by zero at column 12")
        expectMessage(errorMessage { _ = try evaluate("sqrt(-1)") }, contains: "doesn't evaluate to a finite number")
        expectMessage(errorMessage { _ = try evaluate("log(0)") }, contains: "doesn't evaluate to a finite number")
        expectMessage(errorMessage { _ = try evaluate("1.2.3") }, contains: "Unexpected \"0.3\" at column 4")
        expectMessage(
          errorMessage { _ = try evaluate(String(repeating: "(", count: 500) + "1") }, contains: "nested too deeply")
        // Errors are SlatedError.invalidExpression.
        do {
          _ = try evaluate("nope")
          expect(false, "should have thrown")
        } catch let error as SlatedError {
          guard case .invalidExpression = error else { return expect(false, "wrong case \(error)") }
        }
      }
    ),
    (
      "a very long or deeply nested expression is an error, not a crash",
      {
        let chain = { (op: String, count: Int) in Array(repeating: "1", count: count).joined(separator: op) }
        expectEqual(try evaluate(chain("+", 1000)), 1000)
        expectEqual(try evaluate(chain("**", 1000)), 1)
        expectEqual(try evaluate("sum({" + chain(",", 999) + "})"), 999)
        let tooLong =
          "\"1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+…\" is too long: an expression can have at most 1,000 terms"
        expectEqual(errorMessage { _ = try evaluate(chain("+", 1001)) }, tooLong)
        for op in ["-", "*", "/", "**"] {
          expectMessage(errorMessage { _ = try evaluate(chain(op, 100_000)) }, contains: "is too long")
        }
        expectMessage(errorMessage { try SlateExpression.validate(chain("+", 100_000)) }, contains: "is too long")
        expectMessage(errorMessage { _ = try evaluate("sum({" + chain(",", 1000) + "})") }, contains: "is too long")
        expectMessage(
          errorMessage { _ = try evaluate("screenSizeX" + String(repeating: "+windowSizeX", count: 1000)) },
          contains: "is too long")
        let tooDeep =
          "\"((((((((((((((((((((((((((((((((((((((((…\" is nested too deeply: an expression can nest at most 200 levels"
        expectEqual(errorMessage { _ = try evaluate(String(repeating: "(", count: 100_000) + "1") }, tooDeep)
        expectEqual(
          errorMessage { _ = try evaluate(String(repeating: "-", count: 100_000) + "1") },
          "\"\(String(repeating: "-", count: 40))…\" is nested too deeply: an expression can nest at most 200 levels")
      }
    ),
    (
      "validate checks syntax and variables without evaluating",
      {
        try SlateExpression.validate("screenOriginX+screenSizeX/2")
        try SlateExpression.validate("1/0")  // only evaluation can find this
        try SlateExpression.validate("random()*windowSizeX")
        expectThrows { try SlateExpression.validate("windowHintsWidth/2") }
        try SlateExpression.validate("windowHintsWidth/2", variables: SlateExpression.variableNames)
        expectMessage(
          errorMessage { try SlateExpression.validate("screenOrginX+1") },
          contains: "Unknown variable \"screenOrginX\" at column 1", "Did you mean \"screenOriginX\"?")
        expectThrows { try SlateExpression.validate("2+") }
        expectEqual(SlateExpression.variableNames.count, 12)
        expectEqual(SlateExpression.windowVariableNames.count, 10)
      }
    ),
  ])
