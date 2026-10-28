import Foundation

@testable import SlatedCore
@testable import SlatedScript

// What the shortcuts of a ~/.slate.js do when they run functions, so Settings and the island's cheat
// sheet can list "First Third" instead of "JavaScript function" (SlateImporter.describeFunctions).

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

private func move(_ x: String, _ y: String, _ width: String, _ height: String) -> Action {
  .move(x: x, y: y, width: width, height: height, screen: nil)
}

/// A Slate config in the author's style: every shortcut is a function, thirds turn with the display.
private let fixture = """
  var leftHalf = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY" });
  var wideThird = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/3", "height": "screenSizeY" });
  var tallThird = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX", "height": "screenSizeY/3" });
  var wideLastTwo = slate.operation("move", {
    "x": "screenOriginX+screenSizeX*1/3", "y": "screenOriginY", "width": "screenSizeX*2/3", "height": "screenSizeY" });
  var tallLastTwo = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY+screenSizeY*1/3", "width": "screenSizeX", "height": "screenSizeY*2/3" });
  slate.bind("a:ctrl,shift,alt,cmd", (win) => { win.doOperation(leftHalf); });
  slate.bind("f:ctrl,shift,alt,cmd", (win) => {
    let rect = slate.screen().rect();
    win.doOperation(rect.width > rect.height ? wideThird : tallThird);
  });
  slate.bind("b:ctrl,shift,alt,cmd", (win) => {
    let rect = slate.screen().rect();
    win.doOperation(rect.width > rect.height ? wideLastTwo : tallLastTwo);
  });
  slate.bind("right:ctrl,shift,alt,cmd", (win) => { win.doOperation(slate.operationFromString("throw right resize")); });
  slate.bind("i:ctrl,shift,alt,cmd", (win) => { win.doOperation(win.title() === "Inbox" ? "push left" : "push right"); });
  var presses = 0;
  slate.bind("1:ctrl,shift,alt,cmd", (win) => {
    presses += 1;
    win.doOperation(presses === 1 ? "push up" : "push down");
  });
  slate.bind("s:ctrl,shift,alt,cmd", "push up");
  """

private let firstThird = Action.byOrientation(
  landscape: move("screenOriginX", "screenOriginY", "screenSizeX/3", "screenSizeY"),
  portrait: move("screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY/3"))
private let throwRight = Action.throwWindow(screen: .relative(.right), width: "screenSizeX", height: "screenSizeY")

private func function(_ keystroke: String, _ keys: KeyCombo) -> ScriptBinding {
  ScriptBinding(
    keystroke: keystroke, keys: keys, target: .callback(ScriptCallbackID(rawValue: 1)), summary: "JavaScript function")
}

/// Every function is tried in an engine of its own, and matched to the app's load of the same file.
@MainActor
private func describesWhatFunctionsDo() throws {
  let descriptions = SlateImporter.describeFunctions(path: "/fixture.js", readFile: { _ in fixture })
  expectEqual(descriptions.problem, nil)
  // The file as the app loads it, in the engine whose functions the shortcuts run.
  let host = FakeScriptHost()
  let live = SlateScriptEngine(host: host, readFile: { _ in fixture })
  let bindings = live.load(path: "/fixture.js").bindings
  let probes = bindings.reduce(into: [String: SlateImporter.Probe]()) { $0[$1.keys.key] = descriptions.probe(for: $1) }
  expectEqual(probes["a"], .converted(move("screenOriginX", "screenOriginY", "screenSizeX/2", "screenSizeY")))
  expectEqual(probes["f"], .converted(firstThird))
  expectEqual(
    probes["b"],
    .converted(
      .byOrientation(
        landscape: move("screenOriginX+screenSizeX*1/3", "screenOriginY", "screenSizeX*2/3", "screenSizeY"),
        portrait: move("screenOriginX", "screenOriginY+screenSizeY*1/3", "screenSizeX", "screenSizeY*2/3"))))
  expectEqual(probes["right"], .converted(throwRight))
  // What these do can't be shown; the importer's reason says why.
  expectEqual(probes["i"], .skipped("depends on the focused app or window title"))
  expectEqual(probes["1"], .skipped("does something different each time it runs"))
  // A plain operation needs no trying.
  expectEqual(probes["s"], nil)
  // A binding this load didn't make (another Mac's script took another branch) has no description.
  expectEqual(descriptions.probe(for: function("z:ctrl", KeyCombo(key: "z", modifiers: .control))), nil)

  // Trying the functions didn't run them in the app's engine: its counter still starts at zero.
  live.invoke(try require(bindings.first { $0.keys.key == "1" }))
  expectEqual(host.performed.count, 1)
  guard case .push(let direction, _, _)? = host.performed.last?.action else { return expect(false, "no push") }
  expectEqual(direction, .up)
}

/// A file that runs shell commands or changes windows while loading may set itself up differently on
/// this Mac than on the pretend ones, so none of its functions is described.
@MainActor
private func describesNothingOfAnUnreliableFile() throws {
  let script = #"""
    var name = slate.shell("/bin/hostname -s", true);
    slate.bind("a:ctrl", (win) => { win.doOperation("push up"); });
    """#
  let shell = SlateImporter.describeFunctions(path: "/shell.js", readFile: { _ in script })
  expectEqual(shell.problem, "the file runs shell commands while loading")
  let a = function("a:ctrl", KeyCombo(key: "a", modifiers: .control))
  expectEqual(shell.probe(for: a), .skipped("the file runs shell commands while loading"))

  let moves = SlateImporter.describeFunctions(
    path: "/moves.js",
    readFile: { _ in #"slate.window().move({x: 0, y: 0}); slate.bind("a:ctrl", (win) => {});"# })
  expectEqual(moves.problem, "the file moves or focuses windows while loading")
}

/// The app loads Slate files again on every settings change; the functions are tried again only when
/// a file the script read has changed.
@MainActor
private func describerReusesItsAnswer() throws {
  var files = [
    "/main.js": #"slate.source("/more.js"); slate.bind("a:ctrl", (win) => { win.doOperation(op); });"#,
    "/more.js": #"var op = "push up";"#,
  ]
  let describer = SlateFunctionDescriber(readFile: { files[$0] })
  let live = SlateScriptEngine(host: FakeScriptHost(), readFile: { files[$0] })
  let a = try require(live.load(path: "/main.js").bindings.first)
  let first = describer.describe(path: "/main.js")
  expect(!describer.reusedLast)
  expectEqual(first.probe(for: a), .converted(.push(direction: .up, style: .none, screen: nil)))
  _ = describer.describe(path: "/main.js")
  expect(describer.reusedLast, "nothing changed")
  // A change to a file it sources counts too.
  files["/more.js"] = #"var op = "push down";"#
  let changed = describer.describe(path: "/main.js")
  expect(!describer.reusedLast, "/more.js changed")
  expectEqual(changed.probe(for: a), .converted(.push(direction: .down, style: .none, screen: nil)))
}

/// The author's own ~/.slate.js (when there is one): every function is described, quickly, since the
/// app does this whenever the file changes.
@MainActor
private func describesTheAuthorsConfig() throws {
  let path = NSString(string: "~/.slate.js").expandingTildeInPath
  guard FileManager.default.fileExists(atPath: path) else { return }
  let start = Date()
  let descriptions = SlateImporter.describeFunctions(path: path)
  let ms = Date().timeIntervalSince(start) * 1000
  let live = SlateScriptEngine(host: FakeScriptHost())
  let functions = live.load(path: path).bindings.filter { $0.target.action == nil }
  let undescribed = functions.filter {
    if case .converted = descriptions.probe(for: $0) { return false }
    return true
  }
  expect(undescribed.isEmpty, undescribed.map(\.keystroke).joined(separator: ", "))
  expect(ms < 1000, "describing \(functions.count) functions took \(Int(ms)) ms")
}

let slateDescriptionTests = Suite(
  "SlateFunctionDescriptions",
  [
    ("describes what bound functions do", { try onMain { try describesWhatFunctionsDo() } }),
    (
      "describes nothing of a file that may load differently",
      { try onMain { try describesNothingOfAnUnreliableFile() } }
    ),
    ("tries the functions again only when a file changed", { try onMain { try describerReusesItsAnswer() } }),
    ("describes the author's ~/.slate.js quickly", { try onMain { try describesTheAuthorsConfig() } }),
  ])
