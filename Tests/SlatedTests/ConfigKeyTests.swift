import Foundation

@testable import SlatedCore

// The keys the settings window shows under each setting (ConfigKey, ConfigKeys) must be exactly what
// the files have: every one is looked up in an encoded configuration, and every setting the encoder
// writes must have one.

/// A configuration that writes every key the registry names: optional values set, defaults changed.
func configurationWithEverySetting() throws -> SlatedConfiguration {
  var config = SlatedConfiguration.starter
  config.keyboard.keyRepeat = KeyRepeat(delay: 200, interval: 17)
  config.windows["orderScreensLeftToRight"] = .bool(false)
  config.windows["secondsBeforeRepeat"] = .number(0.25)
  config.windows["undoMaxStackSize"] = .number(20)
  config.general.showConfigKeys = false
  let binding = #"""
    {"id": "11111111-1111-4111-8111-111111111111", "name": "Clicker", "keys": "x", "modal": {"keys": "ctrl+f4", "toggle": true},
     "action": {"op": "undo"}, "repeats": true, "enabled": false, "onlyInApps": ["com.example.game"]}
    """#
  let hotstring = #"""
    {"id": "22222222-2222-4222-8222-222222222222", "trigger": ";sig", "replacement": "Thanks", "action": {"op": "undo"},
     "enabled": false, "caseSensitive": false, "fire": "afterDelimiter", "wordBoundary": true, "method": "paste",
     "onlyInApps": ["com.apple.mail"], "exceptInApps": ["com.apple.Terminal"], "notes": "office"}
    """#
  let layout = #"""
    {"name": "Coding", "apps": [{"app": "Terminal", "operations": [{"op": "undo"}],
      "options": {"ignoreFail": true, "repeat": true, "mainFirst": true, "sortTitle": true}}],
     "before": [{"op": "undo"}], "after": [{"op": "relaunch"}]}
    """#
  config.bindings.insert(try JSONDecoder().decode(HotkeyBinding.self, from: Data(binding.utf8)), at: 0)
  config.hotstrings.insert(try JSONDecoder().decode(Hotstring.self, from: Data(hotstring.utf8)), at: 0)
  config.layouts.insert(try JSONDecoder().decode(Layout.self, from: Data(layout.utf8)), at: 0)
  return config
}

/// The keys of the object at `key` in `config`'s file.
private func members(at key: ConfigKey, in config: SlatedConfiguration) -> Set<String> {
  guard case .object(let members)? = key.value(in: config) else { return [] }
  return Set(members.keys)
}

let configKeyTests = Suite(
  "ConfigKeys",
  [
    (
      "every setting's key is in the file the encoder writes",
      {
        let config = try configurationWithEverySetting()
        for setting in ConfigKeys.settings {
          expect(setting.key.value(in: config) != nil, "\(setting.key.display) isn't written")
        }
        expectEqual(Set(ConfigKeys.settings.map(\.id)).count, ConfigKeys.settings.count)
        expectEqual(Set(ConfigKeys.settings.map(\.key)).count, ConfigKeys.settings.count)
      }
    ),
    (
      "every setting the files have has a key in the registry, or a reason it isn't shown",
      {
        let config = try configurationWithEverySetting()
        let registered = Set(ConfigKeys.settings.map(\.key))
        let lists: Set<ConfigKey> = [ConfigKeys.bindings, ConfigKeys.hotstrings, ConfigKeys.layouts]
        var missing: [String] = []
        func walk(_ node: JSONValue, _ key: ConfigKey) {
          if ConfigKeys.notShown[key.display] != nil || lists.contains(key) { return }
          if case .object(let members) = node, !members.isEmpty {
            for (name, value) in members { walk(value, key.appending(name)) }
          } else if !registered.contains(key) {
            missing.append(key.display)
          }
        }
        for file in ConfigFile.allCases {
          let root = try JSONDecoder().decode(JSONValue.self, from: config.encoded(file))
          guard case .object(let sections) = root else { throw TestFailure(description: "\(file) isn't an object") }
          for (name, value) in sections { walk(value, ConfigKey(file, name)) }
        }
        // Settings with no key: add them to ConfigKeys.settings, or to notShown with a reason.
        expectEqual(missing.sorted(), [])
        for key in ConfigKeys.notShown.keys {
          let parts = key.components(separatedBy: " › ")
          let file = try require(ConfigFile(rawValue: parts[0]))
          expect(ConfigKey(file, parts[1]).value(in: config) != nil, "\(key) isn't in the file")
        }
      }
    ),
    (
      "item fields are the keys the encoder writes for shortcuts, hotstrings and layouts",
      {
        let config = try configurationWithEverySetting()
        let binding = ConfigKeys.binding(at: 0, in: config)
        let hotstring = ConfigKeys.hotstring(at: 0, in: config)
        let layout = ConfigKeys.layout(at: 0, in: config)
        let app = ConfigKeys.layoutApp(at: 0, of: config.layouts[0], under: layout)
        for field in ConfigKeys.Binding.all {
          expect(binding.appending(field).value(in: config) != nil, "binding \(field)")
        }
        for field in ConfigKeys.Hotstring.all {
          expect(hotstring.appending(field).value(in: config) != nil, "hotstring \(field)")
        }
        for field in ConfigKeys.Layout.all { expect(layout.appending(field).value(in: config) != nil, "layout \(field)") }
        for field in ConfigKeys.Layout.appFields { expect(app.appending(field).value(in: config) != nil, "app \(field)") }
        // And nothing the encoder writes is left out (an item's id isn't shown: Slated manages it).
        let topLevel = { (fields: [String]) in Set(fields.map { String($0.split(separator: ".")[0]) }) }
        expectEqual(members(at: binding, in: config).subtracting(["id"]), topLevel(ConfigKeys.Binding.all))
        expectEqual(members(at: hotstring, in: config).subtracting(["id"]), topLevel(ConfigKeys.Hotstring.all))
        expectEqual(members(at: layout, in: config), topLevel(ConfigKeys.Layout.all))
        expectEqual(members(at: app, in: config), topLevel(ConfigKeys.Layout.appFields).union(["options"]))
        expectEqual(
          members(at: app.appending("options"), in: config).intersection(["ignoreFail", "repeat", "mainFirst", "sortTitle"]),
          Set(ConfigKeys.Layout.appFields.filter { $0.hasPrefix("options.") }.map { String($0.dropFirst(8)) }))
      }
    ),
    (
      "each operation's parameters are what its example encodes to, for every operation",
      {
        var written: [String: Set<String>] = [:]
        for example in ConfigKeys.Action.examples {
          let action = try JSONDecoder().decode(Action.self, from: Data(example.utf8))
          let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(action))
          guard case .object(let members) = value, case .string(let op)? = members["op"] else {
            throw TestFailure(description: "\(example) didn't encode to an operation")
          }
          written[op, default: []].formUnion(members.keys.filter { $0 != "op" })
        }
        expectEqual(Set(written.keys), Set(ConfigKeys.Action.parameters.keys))
        for (op, parameters) in ConfigKeys.Action.parameters {
          expect(written[op] ?? [] == Set(parameters), "\(op): example writes \(written[op] ?? [])")
        }
        // Every operation Slated knows has an entry: ActionKind's operations, by name.
        let names = Set(ConfigKeys.Action.examples.compactMap { try? JSONDecoder().decode(Action.self, from: Data($0.utf8)).name })
        expectEqual(names, Set(ConfigKeys.Action.parameters.keys))
      }
    ),
    (
      "keys read the way the files are written",
      {
        expectEqual(ConfigKeys.islandCheatSheetDelay.display, "settings.json › island.cheatSheetDelay")
        expectEqual(ConfigKeys.islandCheatSheetDelay.path, "island.cheatSheetDelay")
        expectEqual(ConfigKeys.capsLock.display, "config.json › keyboard.capsLock")
        let named = ConfigKeys.hotstrings.item(2, name: ";sig")
        expectEqual(named.display, #"config.json › hotstrings › ";sig""#)
        expectEqual(named.appending("replacement").display, #"config.json › hotstrings › ";sig" › replacement"#)
        expectEqual(named.appending("replacement").path, "hotstrings[2].replacement")
        expectEqual(named.appending("replacement").relative(to: named), "replacement")
        let nested = named.appending("action.operations").item(1).appending("x")
        expectEqual(nested.relative(to: named), "action.operations[1].x")
        expectEqual(nested.path, "hotstrings[2].action.operations[1].x")
        let unnamed = ConfigKeys.bindings.item(3).appending("keys")
        expectEqual(unnamed.display, "config.json › bindings[3].keys")
        // Names are quoted as JSON, so quotes and backslashes read as the file has them.
        expectEqual(ConfigKeys.hotstrings.item(0, name: #"a"b\"#).display, #"config.json › hotstrings › "a\"b\\""#)
      }
    ),
    (
      "items go by their natural key when it's unique, else by index",
      {
        expectEqual(ConfigKey.itemName([";s", ";sig", ";s"], at: 1), ";sig")
        expectEqual(ConfigKey.itemName([";s", ";sig", ";s"], at: 0), nil)
        expectEqual(ConfigKey.itemName(["", "x"], at: 0), nil)
        expectEqual(ConfigKey.itemName(["x"], at: 4), nil)
        let config = try configurationWithEverySetting()
        // The first binding is behind a modal key, so it goes by index; the starter's go by their keys.
        expectEqual(ConfigKeys.binding(at: 0, in: config).display, "config.json › bindings[0]")
        let starterKeys = config.bindings[1].keys.string
        expectEqual(ConfigKeys.binding(at: 1, in: config).display, "config.json › bindings › \"\(starterKeys)\"")
        expectEqual(ConfigKeys.hotstring(at: 0, in: config).display, #"config.json › hotstrings › ";sig""#)
        expectEqual(ConfigKeys.layout(at: 0, in: config).display, #"config.json › layouts › "Coding""#)
      }
    ),
    (
      "Copy Value gives the value as the file has it, nil when the file doesn't",
      {
        var config = try configurationWithEverySetting()
        expectEqual(ConfigKeys.islandCheatSheetDelay.valueText(in: config), "0.5")
        expectEqual(ConfigKeys.undoMaxStackSize.valueText(in: config), "20")
        expectEqual(ConfigKeys.capsLock.valueText(in: config), "\"hyper\"")
        expectEqual(ConfigKeys.keyRepeat.valueText(in: config), "{\n  \"delay\" : 200,\n  \"interval\" : 17\n}")
        expectEqual(ConfigKeys.hotstring(at: 0, in: config).appending("onlyInApps").valueText(in: config),
          "[\n  \"com.apple.mail\"\n]")
        config.keyboard.keyRepeat = nil
        config.windows = SlateSettings()
        expectEqual(ConfigKeys.keyRepeatDelay.valueText(in: config), nil)
        expectEqual(ConfigKeys.secondsBeforeRepeat.valueText(in: config), nil)
        expectEqual(ConfigKeys.hotstrings.item(999).valueText(in: config), nil)
      }
    ),
    (
      "a configuration tells which file differs, and takes one file's sections from another",
      {
        let base = SlatedConfiguration.starter
        var edited = base
        edited.island.enabled.toggle()
        expect(edited.differs(from: base, in: .settings))
        expect(!edited.differs(from: base, in: .config))
        edited.bindings.removeAll()
        expect(edited.differs(from: base, in: .config))
        var merged = base
        merged.adopt(.config, of: edited)
        expectEqual(merged.bindings, [])
        expectEqual(merged.island, base.island)
        merged.adopt(.settings, of: edited)
        expectEqual(merged, edited)
      }
    ),
  ])
