import Foundation

@testable import SlatedCore

let configurationTests = Suite("Configuration", [
  ("key combos parse and format", {
    let combo = try require(KeyCombo(string: "ctrl+shift+alt+cmd+a"))
    expectEqual(combo.modifiers, .hyper)
    expectEqual(combo.key, "a")
    expectEqual(combo.string, "hyper+a")
    expectEqual(combo.display(), "✦A")
    expectEqual(KeyCombo(string: "cmd++")?.key, "+")
    expectEqual(KeyCombo(string: "ctrl+pad+")?.key, "pad+")
    expectEqual(KeyCombo(string: "Return")?.key, "return")
    expect(KeyCombo(string: "bogus+a") == nil)
  }),
  ("actions round-trip through JSON", {
    let actions: [Action] = [
      .move(x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: .index(1)),
      .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil),
      .corner(.bottomLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil),
      .throwWindow(screen: .relative(.right), width: "screenSizeX", height: "screenSizeY"),
      .grid(padding: 4, grids: [GridScreen(screen: "0", width: 6, height: 6)]),
      .chain([.push(direction: .left, style: .none, screen: nil), .undo]),
      .sequence([SequenceStep(.focus(.right)), SequenceStep(.push(direction: .left, style: .bar, screen: nil), keepWindow: true)]),
      .hide(.allBut("Finder")),
      .insertText("¯\\_(ツ)_/¯", method: .type),
      .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])),
    ]
    for action in actions {
      let data = try JSONEncoder().encode(action)
      expectEqual(try JSONDecoder().decode(Action.self, from: data), action)
    }
  }),
  ("decodes Slate JavaScript-style parameters", {
    // The same shape as slate.operation("push", {...}) in ~/.slate.js.
    let json = #"{"op": "push", "direction": "top", "style": "bar-resize:screenSizeY/2"}"#
    let action = try JSONDecoder().decode(Action.self, from: Data(json.utf8))
    expectEqual(action, .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil))
  }),
  ("configuration tolerates missing keys and comments", {
    let json = """
      {
        // JSON5 comments are allowed in hand-edited files
        "keyboard": { "capsLock": "hyper" },
        "hotstrings": [ { "trigger": ";shrug", "replacement": "¯\\\\_(ツ)_/¯" } ],
      }
      """
    let config = try SlatedConfiguration.decode(from: Data(json.utf8))
    expectEqual(config.keyboard.capsLock, .hyper)
    expectEqual(config.keyboard.hyperModifiers, .hyper)
    expectEqual(config.hotstrings.first?.replacement, "¯\\_(ツ)_/¯")
    expect(config.general.loadSlateConfigs)
    expectEqual(try SlatedConfiguration.decode(from: config.encoded()), config)
  }),
])
