import Foundation
import SlatedScript

@testable import SlatedCore

let starterTests = Suite("Starter", [
  ("starter config round-trips through JSON", {
    let starter = SlatedConfiguration.starter
    expectEqual(starter.bindings.count, 21)
    expectEqual(starter.keyboard.capsLock, .hyper)
    let decoded = try SlatedConfiguration.decode(from: starter.encoded())
    expectEqual(decoded, starter)
    expectEqual(Set(starter.bindings.map(\.keys)).count, 21)  // no duplicate shortcuts
  }),
  ("by-orientation parses, formats and picks the screen's shape", {
    let action = try SlateSyntax.parseOperation(
      "by-orientation 'move screenOriginX;screenOriginY screenSizeX/3;screenSizeY' 'move screenOriginX;screenOriginY screenSizeX;screenSizeY/3'")
    expectEqual(try SlateSyntax.parseOperation(SlateSyntax.format(action)), action)
    let landscape = ScreenInfo(
      displayID: 1, name: "Wide", frame: CGRect(x: 0, y: 0, width: 1800, height: 1000),
      visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1000), isMain: true)
    let portrait = ScreenInfo(
      displayID: 2, name: "Tall", frame: CGRect(x: 1800, y: 0, width: 1000, height: 1800),
      visibleFrame: CGRect(x: 1800, y: 0, width: 1000, height: 1800), isMain: false)
    let screens = [landscape, portrait]
    let wide = try FrameCalculator.targetFrame(
      for: action, in: WindowContext(frame: CGRect(x: 100, y: 100, width: 400, height: 400), screens: screens))
    expectEqual(wide, CGRect(x: 0, y: 0, width: 600, height: 1000))
    let tall = try FrameCalculator.targetFrame(
      for: action, in: WindowContext(frame: CGRect(x: 2000, y: 100, width: 400, height: 400), screens: screens))
    expectEqual(tall, CGRect(x: 1800, y: 0, width: 1000, height: 600))
  }),
])

/// The starter configuration must behave exactly like the author's ~/.slate.js. Runs each of its
/// bindings on a landscape and a portrait screen and compares. Skipped when the file isn't there.
@MainActor
func starterMatchesSlateJS() throws {
  let path = NSString(string: "~/.slate.js").expandingTildeInPath
  guard FileManager.default.fileExists(atPath: path) else {
    print("    (skipped: no ~/.slate.js)")
    return
  }
  let host = FakeScriptHost()
  let engine = SlateScriptEngine(host: host)
  let result = engine.load(path: path)
  expect(!result.hasErrors, "\(result.diagnostics)")
  let starter = Dictionary(uniqueKeysWithValues: SlatedConfiguration.starter.bindings.map { ($0.keys, $0.action) })
  expectEqual(result.bindings.count, starter.count)
  for binding in result.bindings {
    host.focused = FakeScriptHost.safariFront  // on the landscape main screen
    host.performed = []
    _ = engine.invoke(binding)
    let landscape = host.performed.last?.action
    host.focused = FakeScriptHost.terminal  // on the portrait screen
    host.performed = []
    _ = engine.invoke(binding)
    let portrait = host.performed.last?.action
    guard let landscape, let portrait else {
      expect(false, "\(binding.keystroke) performed nothing")
      continue
    }
    let expected = landscape == portrait ? landscape : .byOrientation(landscape: landscape, portrait: portrait)
    if starter[binding.keys] != expected {
      expect(false, "\(binding.keystroke): starter has \(starter[binding.keys].map(SlateSyntax.format) ?? "nothing"), ~/.slate.js does \(SlateSyntax.format(expected))")
    }
  }
}

let starterSlateJSTests = Suite("StarterVsSlateJS", [
  ("starter config matches ~/.slate.js", { try MainActor.assumeIsolated { try starterMatchesSlateJS() } })
])
