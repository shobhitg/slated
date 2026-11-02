import Foundation

@testable import SlatedCore

// The keys the settings window shows under each setting (SlatedCore's ConfigKeys): the registry
// itself, so GNOME's copy can't drift, how item keys are named and written, and what Copy Value
// copies for every setting of a sample configuration.

private let sampleConfig = #"""
  {
    "version": 2,
    "keyboard": {"capsLock": "hyper", "capsLockAlone": "escape", "hyperModifiers": ["ctrl", "alt", "cmd"],
                 "keyRepeat": {"delay": 200, "interval": 17}},
    "bindings": [
      {"id": "11111111-1111-4111-8111-111111111111", "name": "Left half", "keys": "hyper+a",
       "action": {"op": "push", "direction": "left", "style": "bar-resize:screenSizeX/2"}},
      {"id": "22222222-2222-4222-8222-222222222222", "keys": "x", "modal": {"keys": "ctrl+f4", "toggle": true},
       "action": {"op": "undo"}, "repeats": true, "enabled": false, "onlyInApps": ["com.example.game"]}
    ],
    "hotstrings": [
      {"id": "33333333-3333-4333-8333-333333333333", "trigger": ";s", "replacement": "¯\\_(ツ)_/¯"},
      {"id": "44444444-4444-4444-8444-444444444444", "trigger": ";sig", "replacement": "Thanks", "method": "paste",
       "onlyInApps": ["com.apple.mail"]},
      {"id": "55555555-5555-4555-8555-555555555555", "trigger": ";s", "replacement": "shadowed"}
    ],
    "layouts": [{"name": "Coding", "apps": [{"app": "Terminal", "operations": [{"op": "undo"}],
                 "options": {"ignoreFail": true}}], "before": [{"op": "undo"}]}],
    "defaults": []
  }
  """#

private let sampleSettings = #"""
  {
    "version": 2,
    "general": {"launchAtLogin": true, "showActionHUD": true, "showConfigKeys": false},
    "windows": {"orderScreensLeftToRight": false, "secondsBeforeRepeat": 0.25, "undoMaxStackSize": 20},
    "clipboard": {"maxItems": 42, "shortcut": null, "excludedApps": ["com.1password.1password"]},
    "automation": {"maxRunMinutes": 30, "showIndicator": false},
    "island": {"enabled": false, "cheatSheetDelay": 0.8}
  }
  """#

func configKeyFixtures() -> FixtureFile {
  let settings: [J] = ConfigKeys.settings.map { setting in
    [
      "id": .string(setting.id), "file": .string(setting.key.file.rawValue), "path": .string(setting.key.path),
      "display": .string(setting.key.display),
      "platforms": .array(setting.platforms.map(\.rawValue).sorted().map(J.string)),
    ]
  }
  let fields: [J] = [
    ["item": "binding", "fields": .array(ConfigKeys.Binding.all.map(J.string))],
    ["item": "hotstring", "fields": .array(ConfigKeys.Hotstring.all.map(J.string))],
    ["item": "layout", "fields": .array(ConfigKeys.Layout.all.map(J.string))],
    ["item": "layoutApp", "fields": .array(ConfigKeys.Layout.appFields.map(J.string))],
  ]
  let actions: [J] = ConfigKeys.Action.parameters.keys.sorted().map { op in
    ["op": .string(op), "parameters": .array(ConfigKeys.Action.parameters[op]!.map(J.string))]
  }
  let examples: [J] = ConfigKeys.Action.examples.map { example in
    let action = try! JSONDecoder().decode(Action.self, from: Data(example.utf8))
    guard case .object(let members) = toJ(action) else { fatalError("\(example) isn't an object") }
    return ["example": .string(example), "op": .string(action.name), "written": .array(members.keys.sorted().map(J.string))]
  }
  let config = try! SlatedConfiguration.decodeFiles(
    config: Data(sampleConfig.utf8), settings: Data(sampleSettings.utf8)
  ).configuration
  // Item keys: named by their natural key when unique, else by index, with a field below each.
  var items: [J] = []
  func item(_ list: String, _ key: ConfigKey, field: String) {
    let child = key.appending(field)
    items.append([
      "list": .string(list), "index": .int(key.components.last.flatMap { if case .item(let i, _) = $0 { i } else { nil } }!),
      "path": .string(key.path), "display": .string(key.display), "field": .string(field),
      "fieldPath": .string(child.path), "fieldDisplay": .string(child.display), "relative": .string(child.relative(to: key)),
    ])
  }
  for index in config.bindings.indices { item("bindings", ConfigKeys.binding(at: index, in: config), field: "keys") }
  for index in config.hotstrings.indices {
    item("hotstrings", ConfigKeys.hotstring(at: index, in: config), field: "replacement")
  }
  let layout = ConfigKeys.layout(at: 0, in: config)
  item("layouts", layout, field: "name")
  item("layoutApps", ConfigKeys.layoutApp(at: 0, of: config.layouts[0], under: layout), field: "options.ignoreFail")
  let nested = ConfigKeys.binding(at: 0, in: config)
  items.append([
    "list": "nested", "index": 0, "path": .string(nested.path), "display": .string(nested.display),
    "field": "action.operations[1].x",
    "fieldPath": .string(nested.appending("action.operations").item(1).appending("x").path),
    "fieldDisplay": .string(nested.appending("action.operations").item(1).appending("x").display),
    "relative": .string(nested.appending("action.operations").item(1).appending("x").relative(to: nested)),
  ])
  // What Copy Value copies for every setting, and for whole items.
  var values: [J] = ConfigKeys.settings.map { setting in
    [
      "id": .string(setting.id),
      "value": setting.key.value(in: config).map(toJ) ?? .null, "text": .optional(setting.key.valueText(in: config)),
    ]
  }
  for (id, key) in [
    ("hotstring[1]", ConfigKeys.hotstring(at: 1, in: config)), ("binding[1].modal", ConfigKeys.binding(at: 1, in: config).appending("modal")),
    ("layout[0].apps[0].options.ignoreFail", ConfigKeys.layoutApp(at: 0, of: config.layouts[0], under: layout).appending("options.ignoreFail")),
  ] {
    values.append([
      "id": .string(id), "file": .string(key.file.rawValue), "path": .string(key.path),
      "value": key.value(in: config).map(toJ) ?? .null, "text": .optional(key.valueText(in: config)),
    ])
  }
  let notShown: [J] = ConfigKeys.notShown.keys.sorted().map { ["key": .string($0), "reason": .string(ConfigKeys.notShown[$0]!)] }
  return FixtureFile(
    name: "config-keys.json",
    description:
      "ConfigKeys: the key under every setting in the settings window. `settings` is the registry of settings with "
      + "fixed keys, `fields` items' field keys, `actions` each operation's parameters and `examples` what each example "
      + "encodes to; `items` names items (natural key when unique, else index), and `values` is what Copy Value copies "
      + "for the sample config.json and settings.json in `input`.",
    sections: [
      "settings": settings, "fields": fields, "actions": actions, "examples": examples, "items": items, "values": values,
      "notShown": notShown,
    ],
    extra: ["input": ["config": .string(sampleConfig), "settings": .string(sampleSettings)]],
    depth: ["input": 1])
}
