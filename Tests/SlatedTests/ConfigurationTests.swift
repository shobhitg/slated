import Foundation

@testable import SlatedCore

let configurationTests = Suite(
  "Configuration",
  [
    (
      "key combos parse and format",
      {
        let combo = try require(KeyCombo(string: "ctrl+shift+alt+cmd+a"))
        expectEqual(combo.modifiers, .hyper)
        expectEqual(combo.key, "a")
        expectEqual(combo.string, "hyper+a")
        expectEqual(combo.display(), "✦A")
        expectEqual(KeyCombo(string: "cmd++")?.key, "+")
        expectEqual(KeyCombo(string: "ctrl+pad+")?.key, "pad+")
        expectEqual(KeyCombo(string: "Return")?.key, "return")
        expect(KeyCombo(string: "bogus+a") == nil)
      }
    ),
    (
      "actions round-trip through JSON",
      {
        let actions: [Action] = [
          .move(
            x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: .index(1)),
          .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil),
          .corner(.bottomLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil),
          .throwWindow(screen: .relative(.right), width: "screenSizeX", height: "screenSizeY"),
          .grid(padding: 4, grids: [GridScreen(screen: "0", width: 6, height: 6)]),
          .chain([.push(direction: .left, style: .none, screen: nil), .undo]),
          .sequence([
            SequenceStep(.focus(.right)),
            SequenceStep(.push(direction: .left, style: .bar, screen: nil), keepWindow: true),
          ]),
          .hide(.allBut("Finder")),
          .insertText("¯\\_(ツ)_/¯", method: .type),
          .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])),
        ]
        for action in actions {
          let data = try JSONEncoder().encode(action)
          expectEqual(try JSONDecoder().decode(Action.self, from: data), action)
        }
      }
    ),
    (
      "decodes Slate JavaScript-style parameters",
      {
        // The same shape as slate.operation("push", {...}) in ~/.slate.js.
        let json = #"{"op": "push", "direction": "top", "style": "bar-resize:screenSizeY/2"}"#
        let action = try JSONDecoder().decode(Action.self, from: Data(json.utf8))
        expectEqual(action, .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil))
      }
    ),
    (
      "configuration tolerates missing keys and comments",
      {
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
      }
    ),
    (
      "a modal key's toggle and a sequence step's keepWindow can be left out",
      {
        let json = #"""
          {"bindings": [
            {"keys": "a", "modal": {"keys": "ctrl+f4"}, "action": "undo"},
            {"keys": "b", "action": {"op": "sequence", "steps": [{"action": "focus right"}, {"action": "push left", "keepWindow": true}]}}
          ]}
          """#
        let config = try SlatedConfiguration.decode(from: Data(json.utf8))
        expectEqual(config.bindings[0].modal, ModalKey(keys: KeyCombo(key: "f4", modifiers: .control), toggle: false))
        expectEqual(
          config.bindings[1].action,
          .sequence([
            SequenceStep(.focus(.right)), SequenceStep(.push(direction: .left, style: .none, screen: nil), keepWindow: true),
          ]))
        expectEqual(try SlatedConfiguration.decode(from: config.encoded()), config)
        expectThrows { _ = try SlatedConfiguration.decode(from: Data(#"{"bindings": [{"keys": "a", "modal": {}, "action": "undo"}]}"#.utf8)) }
      }
    ),
    (
      "an action parameter of the wrong type is an error, not missing or silently dropped",
      {
        func message(_ json: String) -> String? {
          let result = Result { try JSONDecoder().decode(Action.self, from: Data(json.utf8)) }
          guard case .failure(let error) = result else { return nil }
          if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
          return "\(error)"
        }
        // Used to say "needs \"x\"", although x is there.
        expectEqual(
          message(#"{"op": "move", "x": true, "y": "0", "width": "1", "height": "1"}"#),
          #""move" needs "x" to be text or a number"#)
        // Used to become "+0", and the value was lost on the next save.
        expectEqual(message(#"{"op": "resize", "width": [10]}"#), #""resize" needs "width" to be text or a number"#)
        expectEqual(
          try JSONDecoder().decode(Action.self, from: Data(#"{"op": "resize", "width": null, "height": 5}"#.utf8)),
          .resize(width: "+0", height: "5", anchor: .topLeft))
      }
    ),
  ])

let slateKeystrokeTests = Suite(
  "SlateKeystroke",
  [
    (
      "parses Slate keystrokes",
      {
        let hyperA = try SlateSyntax.parseKeystroke("a:ctrl,shift,alt,cmd")
        expectEqual(hyperA.keys, KeyCombo(key: "a", modifiers: .hyper))
        expect(hyperA.modal == nil)
        expectEqual(
          try SlateSyntax.parseKeystroke("left:ctrl;cmd").keys, KeyCombo(key: "left", modifiers: [.control, .command]))
        expectEqual(try SlateSyntax.parseKeystroke("':ctrl,shift,alt,cmd").keys.key, "'")
        expectEqual(try SlateSyntax.parseKeystroke(";:ctrl").keys, KeyCombo(key: ";", modifiers: .control))
        expectEqual(try SlateSyntax.parseKeystroke("return:ctrl,shift,alt,cmd").keys.key, "return")
      }
    ),
    (
      "parses modal keystrokes",
      {
        let modal = try SlateSyntax.parseKeystroke("1:f4,ctrl,alt")
        expectEqual(modal.keys, KeyCombo(key: "1"))
        expectEqual(modal.modal, ModalKey(keys: KeyCombo(key: "f4", modifiers: [.control, .option])))
        let toggle = try SlateSyntax.parseKeystroke("1:ctrl,f4:toggle")
        expectEqual(toggle.modal?.toggle, true)
        expectThrows { _ = try SlateSyntax.parseKeystroke("a:ctrl,bogus") }
      }
    ),
  ])

let numericEdgeTests = Suite(
  "NumericEdges",
  [
    (
      "huge numbers in actions and settings don't crash",
      {
        let json = #"{"op": "move", "x": 1e21, "y": 0, "width": 100, "height": 1e300}"#
        let action = try JSONDecoder().decode(Action.self, from: Data(json.utf8))
        if case .move(let x, _, _, let h, _) = action {
          expectEqual(x, "1e+21")
          expect(h.contains("e+300"))
        } else {
          expect(false, "expected move")
        }
        expectEqual(SettingValue.number(1e20).stringValue, "1e+20")
        expectEqual(SettingValue.number(42).stringValue, "42")
      }
    ),
    (
      "undoMaxStackSize never traps on NaN, infinite or huge values",
      {
        // Each of these used to crash Slated on the next undoable window operation.
        let slate = SlateConfigParser.parse("config undoMaxStackSize inf", homeDirectory: "/tmp") { _ in nil }
        expectEqual(slate.settings.undoMaxStackSize, 1_000_000_000_000_000)
        let json5 = try SlatedConfiguration.decode(from: Data(#"{"settings": {"undoMaxStackSize": Infinity}}"#.utf8))
        expectEqual(json5.settings.undoMaxStackSize, 1_000_000_000_000_000)
        expectEqual(SlateSettings(["undoMaxStackSize": .number(1e20)]).undoMaxStackSize, 1_000_000_000_000_000)
        expectEqual(SlateSettings(["undoMaxStackSize": .number(-1e20)]).undoMaxStackSize, -1_000_000_000_000_000)
        expectEqual(SlateSettings(["undoMaxStackSize": .number(.nan)]).undoMaxStackSize, 10)
        expectEqual(SlateSettings(["undoMaxStackSize": .string("nan")]).undoMaxStackSize, 10)
        expectEqual(SlateSettings(["undoMaxStackSize": .number(20.9)]).undoMaxStackSize, 20)
        expectEqual(SlateSettings().undoMaxStackSize, 10)
      }
    ),
  ])

/// Bugs found by the Linux port's golden-vector comparison.
let crossPlatformBugTests = Suite(
  "CrossPlatformBugs",
  [
    (
      "a key combo ending in + without a key is invalid",
      {
        expect(KeyCombo(string: "cmd+") == nil)
        expect(KeyCombo(string: "a+") == nil)
        expect(KeyCombo(string: "ctrl+ ") == nil)
        expectEqual(KeyCombo(string: "cmd++"), KeyCombo(key: "+", modifiers: .command))
        expectEqual(KeyCombo(string: "+"), KeyCombo(key: "+"))
        expectEqual(KeyCombo(string: "ctrl+pad+"), KeyCombo(key: "pad+", modifiers: .control))
      }
    ),
    (
      "open-url with an empty URL says the URL is missing",
      {
        do {
          _ = try SlateSyntax.parseOperation("open-url ''")
          expect(false, "expected an error")
        } catch {
          expect("\(error)".contains("Missing the URL"), "\(error)")
        }
      }
    ),
    (
      "malformed resolutions are rejected",
      {
        expect(ScreenRef(slate: "1920xx1080") == nil)
        expect(ScreenRef(slate: "x1080") == nil)
        expect(ScreenRef(slate: "1920x") == nil)
        expectEqual(ScreenRef(slate: "1920x1080"), .resolution(width: 1920, height: 1080))
      }
    ),
    (
      "fn in the Hyper modifiers survives saving",
      {
        let config = try SlatedConfiguration.decode(from: Data(#"{"keyboard":{"hyperModifiers":["fn","ctrl"]}}"#.utf8))
        expectEqual(config.keyboard.hyperModifiers, [.function, .control])
        expectEqual(try SlatedConfiguration.decode(from: config.encoded()), config)
      }
    ),
  ])
