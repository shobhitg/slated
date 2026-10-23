import Foundation
import JavaScriptCore

// Characterization tests for JavaScriptCore behavior that the Slate script engine relies on to run
// `~/.slate.js` and to point errors at the right line. They started as probes during development;
// if a macOS update changes any of this, these fail before users see broken diagnostics.

/// Collects values from JavaScriptCore callbacks.
private final class Recorder: @unchecked Sendable {
  var values: [String] = []
}

private func context(recording recorder: Recorder) -> JSContext {
  let ctx = JSContext()!
  ctx.exceptionHandler = { _, exception in
    guard let exception else { return }
    let line = exception.objectForKeyedSubscript("line")?.toString() ?? "-"
    let url = exception.objectForKeyedSubscript("sourceURL")?.toString() ?? "-"
    let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? "-"
    recorder.values.append("\(exception.toString() ?? "") | line \(line) | \(url) | \(stack)")
  }
  return ctx
}

private let slateFile = URL(fileURLWithPath: "/tmp/contract.slate.js")

let javaScriptCoreContractTests = Suite("JavaScriptCoreContract", [
  ("exceptions carry the line and source URL", {
    let recorder = Recorder()
    let ctx = context(recording: recorder)
    ctx.evaluateScript("let a = 1;\n\nundefinedFn();\n", withSourceURL: slateFile)
    let report = try require(recorder.values.first)
    expect(report.hasPrefix("ReferenceError: Can't find variable: undefinedFn"), report)
    expect(report.contains("| line 3 | file:///tmp/contract.slate.js |"), report)
  }),
  ("native functions can see the JavaScript call stack with file and line", {
    let recorder = Recorder()
    let ctx = context(recording: recorder)
    let native: @convention(block) () -> Void = {
      recorder.values.append(JSContext.current()?.evaluateScript("new Error().stack")?.toString() ?? "")
    }
    ctx.setObject(native, forKeyedSubscript: "nat" as NSString)
    ctx.evaluateScript("function foo() {\n  nat();\n}\nconst f = () => foo();\nf();\n", withSourceURL: slateFile)
    let stack = try require(recorder.values.first)
    expect(stack.contains("foo@file:///tmp/contract.slate.js:2:"), stack)
    expect(stack.contains("f@file:///tmp/contract.slate.js:4:"), stack)
  }),
  ("blocks receive this and arguments, and returning nil gives undefined", {
    let recorder = Recorder()
    let ctx = context(recording: recorder)
    let native: @convention(block) () -> JSValue? = {
      recorder.values.append("args \(JSContext.currentArguments()?.count ?? -1)")
      recorder.values.append("this \(JSContext.currentThis()?.isObject == true)")
      return nil
    }
    ctx.setObject(native, forKeyedSubscript: "nat" as NSString)
    expect(ctx.evaluateScript("nat(1, 2) === undefined")?.toBool() == true)
    expectEqual(recorder.values, ["args 2", "this true"])
  }),
  ("top-level let bindings persist across evaluations in one context", {
    let ctx = context(recording: Recorder())
    ctx.evaluateScript("let a = 1;", withSourceURL: slateFile)
    expectEqual(ctx.evaluateScript("typeof a + ' ' + a")?.toString(), "number 1")
  }),
  ("syntax errors have a line but no stack; thrown strings have neither", {
    let recorder = Recorder()
    let ctx = context(recording: recorder)
    ctx.evaluateScript("let x = ;\n", withSourceURL: URL(fileURLWithPath: "/tmp/bad.js"))
    ctx.evaluateScript("\n\nthrow 'plain string';", withSourceURL: URL(fileURLWithPath: "/tmp/str.js"))
    expectEqual(recorder.values.count, 2)
    expect(recorder.values[0].hasPrefix("SyntaxError:") && recorder.values[0].contains("| line 1 |"), recorder.values[0])
    expect(recorder.values[0].hasSuffix("| undefined"), "syntax errors have no stack: \(recorder.values[0])")
    expect(recorder.values[1].hasPrefix("plain string | line undefined | undefined"), recorder.values[1])
  }),
  ("an exception set by a native function points at the line that called it", {
    let recorder = Recorder()
    let ctx = context(recording: recorder)
    let thrower: @convention(block) () -> Void = {
      guard let current = JSContext.current() else { return }
      current.exception = JSValue(newErrorFromMessage: "native boom", in: current)
    }
    ctx.setObject(thrower, forKeyedSubscript: "boom" as NSString)
    ctx.evaluateScript("\nfunction g() {\n  boom();\n}\ng();\n", withSourceURL: URL(fileURLWithPath: "/tmp/boom.js"))
    let report = try require(recorder.values.first)
    expect(report.hasPrefix("Error: native boom | line 3 | file:///tmp/boom.js"), report)
    expect(report.contains("g@file:///tmp/boom.js:3:"), report)
  }),
  ("calling a throwing JavaScript function from Swift returns undefined and reports once", {
    let recorder = Recorder()
    let ctx = context(recording: recorder)
    let function = try require(ctx.evaluateScript("(function (w) { w.nope(); })", withSourceURL: URL(fileURLWithPath: "/tmp/cb.js")))
    let result = function.call(withArguments: [JSValue(undefinedIn: ctx)!])
    expect(result?.isUndefined == true)
    expectEqual(recorder.values.count, 1)
    expect(ctx.exception == nil, "the handler consumes the exception")
  }),
  ("exceptions from callbacks run by native code can be captured and rethrown", {
    // The engine's eachApp/eachWindow pattern: stop iterating at the first exception and hand it back
    // to the script that called the native function, so try/catch in the config works.
    let ctx = JSContext()!
    final class State: @unchecked Sendable {
      var depth = 0
      var captured: JSValue?
      var uncaught: [String] = []
    }
    let state = State()
    ctx.exceptionHandler = { _, exception in
      guard let exception else { return }
      if state.depth > 0 {
        state.captured = exception
      } else {
        state.uncaught.append("\(exception) line \(exception.objectForKeyedSubscript("line")?.toString() ?? "-")")
      }
    }
    let each: @convention(block) (JSValue) -> Void = { function in
      for i in 0..<3 {
        state.depth += 1
        _ = function.call(withArguments: [i])
        state.depth -= 1
        if let exception = state.captured {
          state.captured = nil
          JSContext.current()?.exception = exception
          return
        }
      }
    }
    ctx.setObject(each, forKeyedSubscript: "each" as NSString)
    ctx.evaluateScript(
      "var seen = [];\neach(function (i) { seen.push(i); if (i == 1) { null.boom; } });\nseen.push('after');\n",
      withSourceURL: URL(fileURLWithPath: "/tmp/a.js"))
    expectEqual(state.uncaught, ["TypeError: null is not an object (evaluating 'null.boom') line 2"])
    expectEqual(ctx.evaluateScript("JSON.stringify(seen)")?.toString(), "[0,1]")
    state.uncaught = []
    ctx.evaluateScript(
      "var caught = 'no';\ntry { each(function (i) { if (i == 0) throw new Error('inner'); }); } catch (e) { caught = String(e); }\n",
      withSourceURL: URL(fileURLWithPath: "/tmp/b.js"))
    expectEqual(state.uncaught, [])
    expectEqual(ctx.evaluateScript("caught")?.toString(), "Error: inner")
  }),
])
