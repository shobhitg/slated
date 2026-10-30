import Foundation

@testable import SlatedCore

/// Writes both files and reads them back, as a save and the next launch do.
func roundTripped(_ config: SlatedConfiguration) throws -> SlatedConfiguration {
  try SlatedConfiguration.decodeFiles(config: config.encodedConfigFile(), settings: config.encodedSettingsFile())
    .configuration
}

/// A file's top-level keys, in the order written.
func topLevelKeys(_ data: Data) -> [String] {
  String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("  \"") }
    .map { String($0.split(separator: "\"")[1]) }
}

let configurationTests = Suite(
  "Configuration",
  [
    (
      "config.json holds what keys do, settings.json how Slated behaves",
      {
        let config = SlatedConfiguration.starter
        expectEqual(
          topLevelKeys(try config.encodedConfigFile()),
          ["bindings", "defaults", "hotstrings", "keyboard", "layouts", "version"])
        expectEqual(
          topLevelKeys(try config.encodedSettingsFile()),
          ["automation", "clipboard", "general", "island", "version", "windows"])
        let both = String(decoding: try config.encodedConfigFile() + config.encodedSettingsFile(), as: UTF8.self)
        expect(both.contains(#""version" : 2"#), both)
        for gone in ["loadSlateConfigs", "slateConfigPaths", "importedSlateShortcuts"] {
          expect(!both.contains(gone), gone)
        }
        expectEqual(try roundTripped(config), config)
      }
    ),
    (
      "a version 1 config.json reads as one value: its settings sections, and what it said about Slate",
      {
        let v1 = #"""
          {"version": 1, "general": {"showActionHUD": true, "loadSlateConfigs": false,
            "slateConfigPaths": ["~/a.js"], "importedSlateShortcuts": ["hyper+a"]},
           "settings": {"nudgePercentOf": "screenSize"}, "island": {"enabled": false},
           "keyboard": {"capsLock": "hyper"}, "later": 1}
          """#
        let files = try SlatedConfiguration.decodeFiles(config: Data(v1.utf8), settings: nil)
        let config = files.configuration
        expectEqual(config.version, 2)
        expect(config.general.showActionHUD)
        expectEqual(config.windows["nudgePercentOf"], .string("screenSize"))
        expect(!config.island.enabled)
        expectEqual(config.keyboard.capsLock, .hyper)
        expectEqual(config.unknownSections, ["later": .int(1)])
        expectEqual(
          files.legacy,
          LegacyConfig(
            loadSlateConfigs: false, slateConfigPaths: ["~/a.js"], importedSlateShortcuts: ["hyper+a"],
            settingsMoved: true, hadSettings: true))
        // With a settings.json there, it wins: the old sections are dropped, broken or not.
        let withSettings = try SlatedConfiguration.decodeFiles(
          config: Data(#"{"version": 1, "general": {"launchAtLogin": "yes"}, "island": {"enabled": false}}"#.utf8),
          settings: Data(#"{"general": {"launchAtLogin": true}}"#.utf8))
        expect(withSettings.configuration.general.launchAtLogin)
        expect(withSettings.configuration.island.enabled)
        expectEqual(withSettings.legacy?.settingsMoved, false)
        // A version 2 file isn't legacy; a version 2 file with a settings section is.
        expect(try SlatedConfiguration.decodeFiles(config: Data(#"{"version": 2}"#.utf8), settings: nil).legacy == nil)
        let mixed = try SlatedConfiguration.decodeFiles(
          config: Data(#"{"version": 2, "general": {}}"#.utf8), settings: nil)
        expect(mixed.legacy != nil)
      }
    ),
    (
      "a file that can't be read is named",
      {
        func file(_ config: String, _ settings: String?) -> ConfigFile? {
          let read = Result {
            try SlatedConfiguration.decodeFiles(config: Data(config.utf8), settings: settings.map { Data($0.utf8) })
          }
          guard case .failure(let error) = read else { return nil }
          return (error as? ConfigFileError)?.file
        }
        expectEqual(file(#"{"bindings": 5}"#, nil), .config)
        expectEqual(file(#"{"version": 2}"#, #"{"island": {"enabled": "yes"}}"#), .settings)
        expectEqual(file(#"{"version": 2}"#, "{"), .settings)
        expectEqual(file(#"{"general": {"launchAtLogin": "yes"}}"#, nil), .config)
      }
    ),
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
        expectEqual(try roundTripped(config), config)
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
            SequenceStep(.focus(.right)),
            SequenceStep(.push(direction: .left, style: .none, screen: nil), keepWindow: true),
          ]))
        expectEqual(try roundTripped(config), config)
        let noKeys = #"{"bindings": [{"keys": "a", "modal": {}, "action": "undo"}]}"#
        expectThrows { _ = try SlatedConfiguration.decode(from: Data(noKeys.utf8)) }
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
        expectEqual(json5.windows.undoMaxStackSize, 1_000_000_000_000_000)
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
        expectEqual(try roundTripped(config), config)
      }
    ),
    (
      "display defaults are written as count or resolutions, and the old enum shape still reads",
      {
        let config = SlatedConfiguration(defaults: [
          ScreenDefault(target: "coding", condition: .count(2)),
          ScreenDefault(target: "big", condition: .resolutions(["2560x1440", "1920x1080"])),
        ])
        let text = String(decoding: try config.encodedConfigFile(), as: UTF8.self)
        expect(text.contains(#""count" : 2,"#) && text.contains(#""resolutions" : ["#), text)
        expect(!text.contains("condition") && !text.contains("_0"), text)
        expectEqual(try roundTripped(config), config)
        let old = #"""
          {"defaults": [{"target": "coding", "condition": {"count": {"_0": 2}}},
                        {"target": "big", "condition": {"resolutions": {"_0": ["2560x1440", "1920x1080"]}}}]}
          """#
        expectEqual(try SlatedConfiguration.decode(from: Data(old.utf8)).defaults, config.defaults)
        for (input, message) in [
          (#"{"defaults": [{"target": "x"}]}"#, #"A display default needs "count" or "resolutions""#),
          (
            #"{"defaults": [{"target": "x", "count": 2, "resolutions": ["1x1"]}]}"#,
            #"A display default takes one condition: "count" or "resolutions""#
          ),
          (
            #"{"defaults": [{"target": "x", "count": 2, "condition": {"count": {"_0": 2}}}]}"#,
            #"A display default takes one condition: "count" or "resolutions""#
          ),
        ] {
          do {
            _ = try SlatedConfiguration.decode(from: Data(input.utf8))
            expect(false, "decoded \(input)")
          } catch DecodingError.dataCorrupted(let context) {
            expectEqual(context.debugDescription, message)
            expectEqual(context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }, ["defaults", "0"])
          }
        }
      }
    ),
    (
      "an unknown Hyper modifier is an error that says which and where, not dropped",
      {
        let input = #"{"keyboard":{"capsLock":"hyper","hyperModifiers":["ctrl","alt","bogus","cmd"]}}"#
        do {
          _ = try SlatedConfiguration.decode(from: Data(input.utf8))
          expect(false, "decoded \(input)")
        } catch DecodingError.dataCorrupted(let context) {
          expectEqual(context.debugDescription, #"Unknown modifier "bogus". Use ctrl, alt, shift, cmd, fn, hyper or meh."#)
          expectEqual(
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }, ["keyboard", "hyperModifiers", "2"])
        }
        // Every alias still reads.
        let aliases = #"["Control","⌃","opt","option","⌥","shift","⇧","Command","⌘","fn","function"]"#
        let all = try SlatedConfiguration.decode(from: Data(#"{"keyboard":{"hyperModifiers":\#(aliases)}}"#.utf8))
        expectEqual(all.keyboard.hyperModifiers, [.control, .option, .shift, .command, .function])
        let hyper = try SlatedConfiguration.decode(from: Data(#"{"keyboard":{"hyperModifiers":["✦"]}}"#.utf8))
        expectEqual(hyper.keyboard.hyperModifiers, .hyper)
        let meh = try SlatedConfiguration.decode(from: Data(#"{"keyboard":{"hyperModifiers":["MEH"]}}"#.utf8))
        expectEqual(meh.keyboard.hyperModifiers, .meh)
      }
    ),
    (
      "top-level sections from a newer Slated survive a save; unknown fields inside known sections don't",
      {
        let input = #"""
          {"zzz": {"b": [1, 2.5, "x", null, true, {}], "a": 9007199254740993}, "aaa": "first",
           "general": {"launchAtLogin": true, "someday": 1}}
          """#
        let config = try SlatedConfiguration.decode(from: Data(input.utf8))
        expectEqual(
          config.unknownSections,
          [
            "aaa": .string("first"),
            "zzz": .object([
              "a": .int(9_007_199_254_740_993),
              "b": .array([.int(1), .double(2.5), .string("x"), .null, .bool(true), .object([:])]),
            ]),
          ])
        let text = String(decoding: try config.encodedConfigFile(), as: UTF8.self)
        expectEqual(
          topLevelKeys(try config.encodedConfigFile()),
          ["aaa", "bindings", "defaults", "hotstrings", "keyboard", "layouts", "version", "zzz"])
        expect(text.contains(#""a" : 9007199254740993,"#), text)
        let settings = String(decoding: try config.encodedSettingsFile(), as: UTF8.self)
        expect(settings.contains(#""launchAtLogin" : true"#) && !settings.contains("someday"), settings)
        expectEqual(try roundTripped(config), config)
        // Known sections win over unknown ones of the same name, and the initializer doesn't need them.
        // Neither file takes the other's sections: config.json would read as version 1 again.
        var edited = SlatedConfiguration(bindings: [])
        expectEqual(edited.unknownSections, [:])
        edited.unknownSections = ["bindings": .string("not a list"), "general": .null, "later": .null]
        edited.unknownSettings = ["island": .null, "keyboard": .int(1), "soon": .bool(true)]
        let again = try roundTripped(edited)
        expectEqual(again.bindings, [])
        expectEqual(again.unknownSections, ["later": .null])
        expectEqual(again.unknownSettings, ["keyboard": .int(1), "soon": .bool(true)])
      }
    ),
  ])
