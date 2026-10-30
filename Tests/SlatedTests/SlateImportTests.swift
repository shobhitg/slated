import Foundation

@testable import SlatedCore
@testable import SlatedScript

// Importing a Slate config (SlateConfigImport) and merging it into Slated's own
// (SlatedConfiguration.merge): Slated never runs Slate files, so this is how their shortcuts come over.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

private func move(_ x: String, _ y: String, _ width: String, _ height: String) -> Action {
  .move(x: x, y: y, width: width, height: height, screen: nil)
}

private func keys(_ string: String) throws -> KeyCombo { try require(KeyCombo(string: string), string) }

/// A Slate config in the author's style: every shortcut is a function, thirds turn with the display.
private let authorsStyle = """
  var leftHalf = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY" });
  var wideThird = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/3", "height": "screenSizeY" });
  var tallThird = slate.operation("move", {
    "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX", "height": "screenSizeY/3" });
  slate.bind("a:ctrl,shift,alt,cmd", (win) => { win.doOperation(leftHalf); });
  slate.bind("f:ctrl,shift,alt,cmd", (win) => {
    let rect = slate.screen().rect();
    win.doOperation(rect.width > rect.height ? wideThird : tallThird);
  });
  slate.bind("right:ctrl,shift,alt,cmd", (win) => { win.doOperation(slate.operationFromString("throw right resize")); });
  slate.bind("i:ctrl,shift,alt,cmd", (win) => { win.doOperation(win.title() === "Inbox" ? "push left" : "push right"); });
  var presses = 0;
  slate.bind("1:ctrl,shift,alt,cmd", (win) => {
    presses += 1;
    win.doOperation(presses === 1 ? "push up" : "push down");
  });
  slate.bind("s:ctrl,shift,alt,cmd", "push up");
  slate.config("nudgePercentOf", "screenSize");
  """

@MainActor
private func convertsTheAuthorsStyle() throws {
  let result = SlateConfigImport.importFile("/fixture.js", displayPath: "~/.slate.js", readFile: { _ in authorsStyle })
  expectEqual(result.files, ["~/.slate.js"])
  let actions = Dictionary(result.bindings.map { ($0.keys.string, $0.action) }, uniquingKeysWith: { a, _ in a })
  expectEqual(actions["hyper+a"], move("screenOriginX", "screenOriginY", "screenSizeX/2", "screenSizeY"))
  expectEqual(
    actions["hyper+f"],
    .byOrientation(
      landscape: move("screenOriginX", "screenOriginY", "screenSizeX/3", "screenSizeY"),
      portrait: move("screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY/3")))
  expectEqual(
    actions["hyper+right"], .throwWindow(screen: .relative(.right), width: "screenSizeX", height: "screenSizeY"))
  expectEqual(actions["hyper+s"], .push(direction: .up, style: .none, screen: nil))
  // What needs JavaScript is listed by its keys, as Slated writes them, with why: never its source.
  expectEqual(
    result.notConverted.map(\.description),
    [
      "hyper+i: depends on the focused app or window title",
      "hyper+1: does something different each time it runs",
    ])
  expectEqual(result.windows["nudgePercentOf"], .string("screenSize"))
  expectEqual(result.problems, [])
  // Fresh ids each time, so importing twice can't make two bindings one item.
  let again = SlateConfigImport.importFile("/fixture.js", displayPath: "~/.slate.js", readFile: { _ in authorsStyle })
  expect(Set(again.bindings.map(\.id)).isDisjoint(with: result.bindings.map(\.id)))
}

@MainActor
private func classicAndProblems() throws {
  let classic = """
    config nudgePercentOf screenSize
    bind a:ctrl push left
    bind b:ctrl teleport
    """
  let result = SlateConfigImport.importFile("/home/.slate", displayPath: "~/.slate", readFile: { _ in classic })
  expectEqual(result.bindings.map(\.keys.string), ["ctrl+a"])
  expectEqual(result.windows["nudgePercentOf"], .string("screenSize"))
  expectEqual(result.notConverted.map(\.what), ["line 3"])

  // A script whose import may not match this Mac says so, naming the file.
  let shell = SlateConfigImport.importFile(
    "/x.js", displayPath: "~/.slate.js",
    readFile: { _ in #"var m = slate.shell("/bin/hostname", true); slate.bind("a:ctrl", "push up");"# })
  expectEqual(shell.bindings.count, 1)
  expectEqual(shell.problems, ["~/.slate.js: \(SlateImporter.shellWhileLoading)"])

  // A file that can't be read is a problem, not a crash.
  let missing = SlateConfigImport.importFile("/nope", displayPath: "~/.slate", readFile: { _ in nil })
  expectEqual(missing.problems, ["~/.slate: Slated couldn't read the file"])
}

/// Real files: missing ones are skipped, one listed twice is read once, and `~` is the given home.
@MainActor
private func importsFilesUnderAHome() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("SlatedImport-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  try Data(#"slate.bind("a:ctrl", "push left");"#.utf8).write(to: home.appendingPathComponent(".slate.js"))
  expectEqual(SlateImport.find(home: home.path), "~/.slate.js")
  let result = SlateConfigImport.importFiles(
    ["~/.slate.js", home.path + "/.slate.js", "~/.slate"], home: home.path)
  expectEqual(result.files, ["~/.slate.js"])
  expectEqual(result.bindings.count, 1)
  try Data("bind b:ctrl push right".utf8).write(to: home.appendingPathComponent(".slate"))
  try FileManager.default.removeItem(at: home.appendingPathComponent(".slate.js"))
  expectEqual(SlateImport.find(home: home.path), "~/.slate")
  expectEqual(SlateImport.find(home: home.path + "/nowhere"), nil)
}

let slateImportTests = Suite(
  "SlateImport",
  [
    ("converts the author's style of functions", { try onMain { try convertsTheAuthorsStyle() } }),
    ("converts a classic ~/.slate, and reports problems by file", { try onMain { try classicAndProblems() } }),
    ("imports files under a home, each once", { try onMain { try importsFilesUnderAHome() } }),
    (
      "merging keeps what Slated has: same trigger, layout name, display default or setting",
      {
        let nativeA = HotkeyBinding(keys: try keys("hyper+a"), action: .undo)
        let gameA = HotkeyBinding(keys: try keys("hyper+b"), action: .undo, onlyInApps: ["com.example.game"])
        let modalX = HotkeyBinding(
          keys: try keys("x"), modal: ModalKey(keys: try keys("ctrl+f6")), action: .undo, enabled: false)
        var config = SlatedConfiguration(
          windows: SlateSettings(["nudgePercentOf": .string("windowSize")]), bindings: [nativeA, gameA, modalX],
          layouts: [Layout(name: "work")], defaults: [ScreenDefault(target: "work", condition: .count(2))])
        let slate = SlateImport(
          files: ["~/.slate.js"],
          bindings: [
            HotkeyBinding(keys: try keys("hyper+a"), action: .relaunch),  // taken
            HotkeyBinding(keys: try keys("hyper+b"), action: .relaunch),  // everywhere: not the game's trigger
            HotkeyBinding(keys: try keys("x"), action: .relaunch),  // no modal key: another trigger
            // Off, but there.
            HotkeyBinding(keys: try keys("x"), modal: ModalKey(keys: try keys("ctrl+f6")), action: .relaunch),
            HotkeyBinding(keys: try keys("hyper+c"), action: .relaunch),
            HotkeyBinding(keys: try keys("hyper+c"), action: .undo),  // the file's own duplicate: the first wins
          ],
          layouts: [Layout(name: "work", apps: [LayoutApp(app: "Safari", operations: [])]), Layout(name: "play")],
          defaults: [
            ScreenDefault(target: "work", condition: .count(2)), ScreenDefault(target: "play", condition: .count(1)),
          ],
          windows: SlateSettings(["nudgePercentOf": .string("screenSize"), "undoMaxStackSize": .number(5)]),
          notConverted: [SlateImport.Item("hyper+t", "needs JavaScript")])
        let before = config
        let report = config.merge(slate)
        expectEqual(report.added, 3)
        expectEqual(report.alreadyThere, 3)
        expectEqual(config.bindings.prefix(3).map(\.action), before.bindings.map(\.action))
        expectEqual(config.bindings.dropFirst(3).map(\.trigger), ["hyper+b", "x", "hyper+c"])
        expectEqual(config.bindings.last?.action, .relaunch)
        expectEqual(config.layouts.map(\.name), ["work", "play"])
        expectEqual(config.layouts[0].apps, [])
        expectEqual(config.defaults.count, 2)
        expectEqual(config.windows["nudgePercentOf"], .string("windowSize"))
        expectEqual(config.windows["undoMaxStackSize"], .number(5))
        expectEqual(
          [report.layoutsAdded, report.defaultsAdded, report.settingsAdded], [1, 1, 1])
        expectEqual(report.notConverted.map(\.what), ["hyper+t"])
        // Again: nothing twice.
        let merged = config
        let again = config.merge(slate)
        expectEqual(config, merged)
        expectEqual([again.added, again.alreadyThere, again.layoutsAdded, again.settingsAdded], [0, 6, 0, 0])
      }
    ),
    (
      "shortcuts a version 1 config imported earlier stay out, however they were changed since",
      {
        // hyper+a was imported, then moved to hyper+z in Settings; ctrl+alt+f6 x was deleted.
        var config = SlatedConfiguration(bindings: [HotkeyBinding(keys: try keys("hyper+z"), action: .undo)])
        let slate = SlateImport(bindings: [
          HotkeyBinding(keys: try keys("hyper+a"), action: .undo),
          HotkeyBinding(keys: try keys("x"), modal: ModalKey(keys: try keys("ctrl+alt+f6")), action: .undo),
          HotkeyBinding(keys: try keys("hyper+q"), action: .undo),
        ])
        let report = config.merge(slate, alreadyImported: ["hyper+a", "ctrl+alt+f6 x"])
        expectEqual(config.bindings.map(\.keys.string), ["hyper+z", "hyper+q"])
        expectEqual([report.added, report.alreadyThere], [1, 2])
      }
    ),
    (
      "the import report says what happened in plain words",
      {
        let report = SlateImportReport(
          files: ["~/.slate.js"], added: 2, alreadyThere: 1, layoutsAdded: 1,
          notConverted: [SlateImport.Item("hyper+t", "depends on the focused app or window title")])
        expectEqual(report.title, "Imported 2 shortcuts")
        expectEqual(
          report.message,
          "Added 2 shortcuts and 1 layout from ~/.slate.js to Slated's config, where you can change them. "
            + "Slated doesn't read ~/.slate.js itself.\n\n1 shortcut was already in Slated on the same keys, so "
            + "Slated kept its own.\n\n1 couldn't be converted:\nhyper+t: depends on the focused app or window title")
        expectEqual(SlateImportReport(files: ["~/.slate"]).message, "~/.slate has nothing Slated could import.")
        expectEqual(
          SlateImportReport(files: ["~/.slate.js", "~/.slate"]).fileNames, "~/.slate.js and ~/.slate")
      }
    ),
  ])
