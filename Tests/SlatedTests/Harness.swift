import Foundation

// A deliberately tiny test harness. Swift Testing and XCTest ship with Xcode, not with the Command
// Line Tools, so tests run as a plain executable: `make test` (or `swift run SlatedTests [filter]`).
// The API mirrors Swift Testing (`expect`, `require`, suites of named tests) so migrating later is
// mechanical.

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

/// A named group of tests. Register suites in `main.swift`.
struct Suite: Sendable {
  let name: String
  let tests: [(name: String, body: @Sendable () throws -> Void)]

  init(_ name: String, _ tests: [(String, @Sendable () throws -> Void)]) {
    self.name = name
    self.tests = tests.map { (name: $0.0, body: $0.1) }
  }
}

nonisolated(unsafe) private var currentFailures: [String] = []

func expect(
  _ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
  file: StaticString = #fileID, line: UInt = #line
) {
  do {
    if try !condition() {
      currentFailures.append("\(file):\(line): expectation failed \(message())")
    }
  } catch {
    currentFailures.append("\(file):\(line): threw \(error)")
  }
}

func expectEqual<T: Equatable>(
  _ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
  file: StaticString = #fileID, line: UInt = #line
) {
  do {
    let a = try actual()
    let e = try expected()
    if a != e { currentFailures.append("\(file):\(line): expected \(e), got \(a)") }
  } catch {
    currentFailures.append("\(file):\(line): threw \(error)")
  }
}

/// Fails the current test immediately when `value` is nil.
func require<T>(_ value: T?, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws -> T {
  guard let value else { throw TestFailure(description: "\(file):\(line): required value was nil \(message)") }
  return value
}

func expectThrows(_ body: () throws -> Void, file: StaticString = #fileID, line: UInt = #line) {
  do {
    try body()
    currentFailures.append("\(file):\(line): expected an error")
  } catch {}
}

/// Runs suites whose name or test name contains `filter`; returns the number of failed tests.
func run(_ suites: [Suite], filter: String?) -> Int {
  var passed = 0
  var failed = 0
  for suite in suites {
    for test in suite.tests {
      let full = "\(suite.name)/\(test.name)"
      if let filter, !full.localizedCaseInsensitiveContains(filter) { continue }
      currentFailures = []
      do { try test.body() } catch { currentFailures.append("threw \(error)") }
      if currentFailures.isEmpty {
        passed += 1
        print("✔ \(full)")
      } else {
        failed += 1
        print("✘ \(full)")
        for f in currentFailures { print("    \(f)") }
      }
    }
  }
  print("\n\(passed) passed, \(failed) failed")
  return failed
}
