import Foundation
import SlatedScript

@testable import SlatedCore

let starterTests = Suite(
  "Starter",
  [
    (
      "starter config round-trips through JSON",
      {
        let starter = SlatedConfiguration.starter
        expectEqual(starter.bindings.count, 21)
        expectEqual(starter.keyboard.capsLock, .hyper)
        let decoded = try SlatedConfiguration.decode(from: starter.encoded())
        expectEqual(decoded, starter)
        expectEqual(Set(starter.bindings.map(\.keys)).count, 21)  // no duplicate shortcuts
      }
    ),
    (
      "by-orientation parses, formats and picks the screen's shape",
      {
        let action = try SlateSyntax.parseOperation(
          "by-orientation 'move screenOriginX;screenOriginY screenSizeX/3;screenSizeY' 'move screenOriginX;screenOriginY screenSizeX;screenSizeY/3'"
        )
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
        // A square display counts as portrait: ~/.slate.js treats only `width > height` as landscape.
        let square = ScreenInfo(
          displayID: 3, name: "Square", frame: CGRect(x: 0, y: 1000, width: 1200, height: 1200),
          visibleFrame: CGRect(x: 0, y: 1000, width: 1200, height: 1200), isMain: false)
        expect(square.isPortrait && portrait.isPortrait && !landscape.isPortrait)
        let even = try FrameCalculator.targetFrame(
          for: action,
          in: WindowContext(frame: CGRect(x: 100, y: 1100, width: 400, height: 400), screens: screens + [square]))
        expectEqual(even, CGRect(x: 0, y: 1000, width: 1200, height: 400))
      }
    ),
  ])

/// The starter configuration must behave exactly like the author's ~/.slate.js. Runs each of its
/// bindings on a landscape, a portrait and a square screen and compares. Skipped when the file isn't
/// there.
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
      expect(
        false,
        "\(binding.keystroke): starter has \(starter[binding.keys].map(SlateSyntax.format) ?? "nothing"), ~/.slate.js does \(SlateSyntax.format(expected))"
      )
    }
    // On a square screen the starter's by-orientation must take the branch the script takes.
    let portraitScreen = host.screenList[1]
    host.screenList[1].frame.size = CGSize(width: portraitScreen.frame.width, height: portraitScreen.frame.width)
    host.screenList[1].visibleFrame = host.screenList[1].frame
    defer { host.screenList[1] = portraitScreen }
    host.focused = FakeScriptHost.terminal
    host.performed = []
    _ = engine.invoke(binding)
    let onSquare = host.performed.last?.action
    var resolved = starter[binding.keys]
    if case .byOrientation(let l, let p) = resolved { resolved = host.screenList[1].isPortrait ? p : l }
    if onSquare != resolved {
      expect(
        false,
        "\(binding.keystroke) on a square screen: starter does \(resolved.map(SlateSyntax.format) ?? "nothing"), ~/.slate.js does \(onSquare.map(SlateSyntax.format) ?? "nothing")"
      )
    }
  }
}

let starterSlateJSTests = Suite(
  "StarterVsSlateJS",
  [
    ("starter config matches ~/.slate.js", { try MainActor.assumeIsolated { try starterMatchesSlateJS() } })
  ])

@MainActor
func importerChecks() throws {
  // A fixture: one static operation, one orientation-dependent function, one that needs real JS.
  let script = """
    var half = slate.operation("push", {"direction": "left", "style": "bar-resize:screenSizeX/2"});
    slate.bind("a:ctrl,shift,alt,cmd", half);
    slate.bind("f:ctrl,shift,alt,cmd", function (win) {
      var r = slate.screen().rect();
      win.doOperation(r.width > r.height ? "push" : "corner", r.width > r.height ? {"direction": "left"} : {"direction": "top-left"});
    });
    slate.bind("z:ctrl,shift,alt,cmd", function (win) { win.move({x: 0, y: 0}); });
    """
  let result = SlateImporter.importJavaScript(path: "/fixture.js", readFile: { _ in script })
  expectEqual(result.bindings.count, 2)
  expectEqual(result.skipped.map(\.keystroke), ["z:ctrl,shift,alt,cmd"])
  expectEqual(result.bindings.first?.action, .push(direction: .left, style: .barResize("screenSizeX/2"), screen: nil))
  expectEqual(
    result.bindings.last?.action,
    .byOrientation(
      landscape: .push(direction: .left, style: .none, screen: nil),
      portrait: .corner(.topLeft, width: nil, height: nil, screen: nil)))

  // The author's real config converts completely, into exactly the starter bindings.
  let path = NSString(string: "~/.slate.js").expandingTildeInPath
  guard FileManager.default.fileExists(atPath: path) else { return }
  let real = SlateImporter.importJavaScript(path: path)
  expect(real.skipped.isEmpty, "\(real.skipped)")
  let starter = Dictionary(uniqueKeysWithValues: SlatedConfiguration.starter.bindings.map { ($0.keys, $0.action) })
  expectEqual(Dictionary(uniqueKeysWithValues: real.bindings.map { ($0.keys, $0.action) }), starter)
}

/// Importing turns the Slate files off when nothing was skipped (Engine.importSlateConfigs), so anything
/// the import doesn't carry over must be listed as skipped, or it would silently stop running.
@MainActor
func importerReportsWhatItLeavesBehind() throws {
  let script = """
    slate.bind("a:ctrl", slate.operation("push", {"direction": "left"}));
    slate.on("windowOpened", function (event, win) { win.doOperation("push left"); });
    slate.on("appActivated", function () {});
    slate.on("windowOpened", function () {});
    slate.config("defaultToCurrentScreen", function () { return slate.screenCount() > 1; });
    slate.config("nudgePercentOf", "windowSize");
    slate.layout("js", {"Safari": {"operations": [function (win) { win.doOperation("push left"); }]}});
    slate.layout("plain", {"Safari": {"operations": [slate.operation("push", {"direction": "right"})]}});
    slate.default(2, function () {});
    slate.default(["1920x1080", "1440x900"], "plain");
    """
  let result = SlateImporter.importJavaScript(path: "/events.js", readFile: { _ in script })
  expectEqual(result.bindings.count, 1)
  expectEqual(
    result.skipped.map(\.keystroke),
    [
      #"slate.on("windowOpened")"#, #"slate.on("appActivated")"#, #"slate.config("defaultToCurrentScreen")"#,
      #"slate.layout("js")"#, "slate.default(2 screens)", "slate.default(1440x900, 1920x1080)",
    ])

  // A config with only bindings and plain layouts leaves nothing behind.
  let plain = SlateImporter.importJavaScript(
    path: "/plain.js",
    readFile: { _ in
      #"slate.bind("a:ctrl", "push left"); slate.layout("x", {"Safari": {"operations": ["push up"]}});"#
    })
  expect(plain.skipped.isEmpty, "\(plain.skipped)")
}

let importerTests = Suite(
  "SlateImporter",
  [
    ("converts Slate JavaScript bindings to native ones", { try MainActor.assumeIsolated { try importerChecks() } }),
    (
      "lists event handlers, JavaScript layouts and defaults as skipped",
      { try MainActor.assumeIsolated { try importerReportsWhatItLeavesBehind() } }
    ),
  ])
