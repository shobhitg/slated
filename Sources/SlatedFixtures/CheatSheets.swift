import CoreGraphics
import Foundation
import SlatedUI

@testable import SlatedCore

// The notch island's cheat sheet (SlatedUI's CheatSheet, with ActionDescriber's titles and
// WindowPresets' regions): the GNOME island lists the same shortcuts, grouped, ordered and named the
// same way, from linux/gnome-extension/lib/core/cheatSheet.js.

/// Actions in config.json form, each the only Hyper shortcut on a sheet: its title, section, region
/// and symbol.
private let actionCases: [String] = [
  // Window presets, as the picker writes them and as Slate configs spell them.
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX/2","height":"screenSizeY"}"#,
  #"{"op":"push","direction":"left","style":"bar-resize:screenSizeX/2"}"#,
  #"{"op":"push","direction":"right","style":"bar-resize:screenSizeX/2"}"#,
  #"{"op":"push","direction":"up","style":"bar-resize:screenSizeY/2"}"#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY+screenSizeY/2","width":"screenSizeX","height":"screenSizeY/2"}"#,
  #"{"op":"corner","direction":"top-left","width":"screenSizeX/2","height":"screenSizeY/2"}"#,
  #"{"op":"corner","direction":"bottom-right","width":"screenSizeX/2","height":"screenSizeY/2"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX/2","y":"screenOriginY","width":"screenSizeX/2","height":"screenSizeY/2"}"#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX/3","height":"screenSizeY"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX/3","y":"screenOriginY","width":"screenSizeX/3","height":"screenSizeY"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX*2/3","y":"screenOriginY","width":"screenSizeX/3","height":"screenSizeY"}"#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX*2/3","height":"screenSizeY"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX*1/3","y":"screenOriginY","width":"screenSizeX*2/3","height":"screenSizeY"}"#,
  #"{"op":"move","x":"screenOriginX+(screenSizeX-windowSizeX)/2","y":"screenOriginY+(screenSizeY-windowSizeY)/2","width":"windowSizeX","height":"windowSizeY"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX/6","y":"screenOriginY+screenSizeY/6","width":"screenSizeX*2/3","height":"screenSizeY*2/3"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX/20","y":"screenOriginY+screenSizeY/20","width":"screenSizeX*0.9","height":"screenSizeY*0.9"}"#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX","height":"screenSizeY"}"#,
  #"{"op":"corner","direction":"top-left","width":"screenSizeX","height":"screenSizeY"}"#,
  #"{"op":"throw","screen":"next"}"#,
  #"{"op":"throw","screen":"previous"}"#,
  #"{"op":"throw","screen":"next","width":"screenSizeX","height":"screenSizeY"}"#,
  // Thirds that turn with the display, and other orientation pairs.
  #"{"op":"by-orientation","landscape":{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX/3","height":"screenSizeY"},"portrait":{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX","height":"screenSizeY/3"}}"#,
  #"{"op":"by-orientation","landscape":{"op":"move","x":"screenOriginX+screenSizeX*1/3","y":"screenOriginY","width":"screenSizeX*2/3","height":"screenSizeY"},"portrait":{"op":"move","x":"screenOriginX","y":"screenOriginY+screenSizeY*1/3","width":"screenSizeX","height":"screenSizeY*2/3"}}"#,
  #"{"op":"by-orientation","landscape":"push left bar-resize:screenSizeX/2","portrait":"push up bar-resize:screenSizeY/2"}"#,
  #"{"op":"by-orientation","landscape":"throw next","portrait":"throw previous"}"#,
  #"{"op":"by-orientation","landscape":"undo","portrait":"undo"}"#,
  // Moves named by their size when centered, else "Move & Resize".
  #"{"op":"move","x":"screenOriginX+screenSizeX/4","y":"screenOriginY+screenSizeY/4","width":"screenSizeX/2","height":"screenSizeY/2"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX*0.2","y":"screenOriginY+screenSizeY*0.1","width":"screenSizeX*0.6","height":"screenSizeY*0.8"}"#,
  #"{"op":"move","x":"screenOriginX+2","y":"screenOriginY+2","width":"screenSizeX-4","height":"screenSizeY-4"}"#,
  #"{"op":"move","x":"screenOriginX+100","y":"screenOriginY","width":"600","height":"400"}"#,
  #"{"op":"move","x":"screenOriginX+screenSizeX","y":"screenOriginY","width":"400","height":"400"}"#,
  #"{"op":"move","x":"screenOriginX-200","y":"screenOriginY-100","width":"800","height":"500"}"#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX/2","height":"screenSizeY","screen":"0"}"#,
  #"{"op":"move","x":"screenOriginX","y":"screenOriginY","width":"screenSizeX/2","height":"screenSizeY","screen":"2"}"#,
  // Other window operations.
  #"{"op":"resize","width":"+10%","height":"+0"}"#,
  #"{"op":"resize","width":"-100","height":"-10%","anchor":"bottom-right"}"#,
  #"{"op":"push","direction":"left"}"#,
  #"{"op":"push","direction":"right","style":"bar"}"#,
  #"{"op":"push","direction":"up","style":"bar"}"#,
  #"{"op":"push","direction":"down","style":"center"}"#,
  #"{"op":"push","direction":"left","style":"bar-resize:screenSizeX/3"}"#,
  #"{"op":"nudge","x":"+10%","y":"-5"}"#,
  #"{"op":"corner","direction":"top-left"}"#,
  #"{"op":"corner","direction":"bottom-left","width":"screenSizeX/3","height":"screenSizeY"}"#,
  #"{"op":"throw","screen":"0"}"#,
  #"{"op":"throw","screen":"ordered:1"}"#,
  #"{"op":"throw","screen":"1920x1080"}"#,
  #"{"op":"throw","screen":"left"}"#,
  #"{"op":"throw","screen":"right"}"#,
  #"{"op":"throw","screen":"up"}"#,
  #"{"op":"throw","screen":"down","width":"screenSizeX/2"}"#,
  #"{"op":"throw","screen":"next","width":"screenSizeX/2","height":"screenSizeY"}"#,
  #"{"op":"throw","screen":"1920x1080","width":"screenSizeX"}"#,
  #"{"op":"chain","operations":["push left bar-resize:screenSizeX/2","move screenOriginX;screenOriginY screenSizeX/3;screenSizeY","move screenOriginX;screenOriginY screenSizeX*2/3;screenSizeY"]}"#,
  #"{"op":"chain","operations":["throw next","throw previous","undo","grid"]}"#,
  #"{"op":"chain","operations":["focus left","focus right"]}"#,
  #"{"op":"chain","operations":[]}"#,
  #"{"op":"sequence","operations":["throw next","move screenOriginX;screenOriginY screenSizeX;screenSizeY"]}"#,
  #"{"op":"sequence","steps":[{"action":"focus 'Safari'","keepWindow":false},{"action":"push left","keepWindow":true}]}"#,
  #"{"op":"sequence","operations":["layout Work"]}"#,
  #"{"op":"sequence","operations":[]}"#,
  #"{"op":"layout","name":"Work"}"#,
  #"{"op":"layout","name":""}"#,
  // Focus, apps and snapshots.
  #"{"op":"focus","direction":"left"}"#,
  #"{"op":"focus","direction":"up"}"#,
  #"{"op":"focus","direction":"behind"}"#,
  #"{"op":"focus","app":"Safari"}"#,
  #"{"op":"focus","app":""}"#,
  #"{"op":"hint"}"#,
  #"{"op":"hint","characters":"ASDF"}"#,
  #"{"op":"grid","padding":5}"#,
  #"{"op":"hide","app":"current"}"#,
  #"{"op":"hide","app":"all"}"#,
  #"{"op":"show","app":"all-but:Finder"}"#,
  #"{"op":"toggle","app":["Safari"]}"#,
  #"{"op":"toggle","app":["Mail","Calendar"]}"#,
  #"{"op":"show","app":["Mail","Calendar","Notes"]}"#,
  #"{"op":"hide","app":[]}"#,
  #"{"op":"switch"}"#,
  #"{"op":"snapshot","name":"work","save":true}"#,
  #"{"op":"activate-snapshot","name":"work","delete":true}"#,
  #"{"op":"delete-snapshot","name":"work","all":true}"#,
  #"{"op":"undo"}"#,
  // Utilities.
  #"{"op":"shell","command":"open -a Terminal"}"#,
  #"{"op":"shell","command":"/usr/local/bin/some-long-script --with --many --arguments","wait":true}"#,
  #"{"op":"shell","command":""}"#,
  #"{"op":"insert-text","text":"Hello\nWorld"}"#,
  #"{"op":"insert-text","text":"A much longer piece of text to insert","method":"paste"}"#,
  #"{"op":"insert-text","text":"👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽"}"#,
  #"{"op":"insert-text","text":""}"#,
  #"{"op":"open-url","url":"https://github.com/shobhitg/slated"}"#,
  #"{"op":"open-url","url":"http://localhost:8080/status"}"#,
  #"{"op":"open-url","url":"https://user:secret@example.com/path"}"#,
  #"{"op":"open-url","url":"HTTPS://Example.COM"}"#,
  #"{"op":"open-url","url":"slack://open?team=T123"}"#,
  #"{"op":"open-url","url":"mailto:someone@example.com"}"#,
  #"{"op":"open-url","url":"example.com/a/very/long/path/that/goes/on"}"#,
  #"{"op":"keystroke","keys":"cmd+shift+4"}"#,
  #"{"op":"keystroke","keys":"hyper+a"}"#,
  #"{"op":"keystroke","keys":"ctrl+left"}"#,
  #"{"op":"relaunch"}"#,
  #"{"op":"clipboard-history"}"#,
  // Automation, whatever its shape.
  #"{"op":"click"}"#,
  #"{"op":"click","button":"right","count":2}"#,
  #"{"op":"click","button":"middle","count":3}"#,
  #"{"op":"press","input":"key:w","phase":"down"}"#,
  #"{"op":"press","input":"mouse:left","phase":"up"}"#,
  #"{"op":"hold","input":"key:shift"}"#,
  #"{"op":"hold","input":"mouse:right"}"#,
  #"{"op":"repeat","action":"click","interval":0.1}"#,
  #"{"op":"repeat","action":{"op":"press","input":"key:w","phase":"down"},"interval":1.5,"mode":"while-held","times":50}"#,
  #"{"op":"repeat","action":"click right","interval":1.25}"#,
  #"{"op":"repeat","action":"click","interval":2.25,"times":3}"#,
  #"{"op":"repeat","action":"click","interval":1.05}"#,
  #"{"op":"repeat","action":"click","interval":2}"#,
  #"{"op":"repeat","action":"click","interval":0.0005}"#,
  #"{"op":"wait","seconds":1}"#,
  #"{"op":"wait","seconds":0.25}"#,
  #"{"op":"wait","seconds":0}"#,
  #"{"op":"stop-automations"}"#,
  #"{"op":"sequence","operations":["press key:w down","wait 2","press key:w up"]}"#,
  #"{"op":"chain","operations":["hold key:w","stop-automations"]}"#,
  #"{"op":"by-orientation","landscape":"click","portrait":"undo"}"#,
]

/// A shortcut as the fixture records it: config strings for keys, the action in canonical form.
@MainActor private func shortcutJ(_ s: CheatSheet.Shortcut) -> J {
  var members: [String: J] = ["keys": .string(s.keys.string)]
  if let modal = s.modal { members["modal"] = .string(modal.string) }
  if let name = s.name { members["name"] = .string(name) }
  if let action = s.action { members["action"] = actionJ(action) }
  if let summary = s.summary { members["summary"] = .string(summary) }
  return .object(members)
}

@MainActor private func itemJ(_ item: CheatSheet.Item) -> J {
  [
    "id": .string(item.id), "label": .string(item.label), "title": .string(item.title),
    "region": item.region.map(rectJ) ?? .null, "symbol": .string(item.symbol),
  ]
}

@MainActor private func sheetJ(_ sheet: CheatSheet) -> J {
  [
    "title": .string(sheet.title), "isHyper": .bool(sheet.isHyper),
    "sections": .array(
      sheet.sections.map { ["title": .string($0.title), "items": .array($0.items.map(itemJ))] }),
  ]
}

private func combo(_ text: String) -> KeyCombo { KeyCombo(string: text)! }

private func decodeAction(_ json: String) -> Action {
  try! JSONDecoder().decode(Action.self, from: Data(json.utf8))
}

/// Every key Slated knows, bound to Hyper in a scrambled order, to pin the keyboard order.
private let orderedKeys: [String] = [
  "f10", "pad1", "z", "0", "space", "up", "1", ",", "mouse3", "a", "f2", "/", "right", "padEnter", "return", "pad=",
  "left", "é", "esc", "9", "[", "down", "f1", "tab", "m", "pageUp", "home", "delete", "f20", "pad0", "'", "volumeUp",
  "help", "rightShift", "-", "end", "forwardDelete", "pageDown", "backslash", "caps",
]

@MainActor func cheatSheetFixtures() -> FixtureFile {
  let hyperA = combo("hyper+a")
  let actions: [J] = actionCases.map { json in
    let action = decodeAction(json)
    let sheet = CheatSheet.hyper([CheatSheet.Shortcut(keys: hyperA, action: action)], hyperModifiers: .hyper)
    let section = sheet.sections[0]
    let item = section.items[0]
    return [
      "action": actionJ(action), "title": .string(item.title), "section": .string(section.title),
      "region": item.region.map(rectJ) ?? .null, "symbol": .string(item.symbol),
    ]
  }

  // Names win over the action's title once trimmed; a shortcut with neither is a script.
  let undo = decodeAction(#"{"op":"undo"}"#)
  let left = decodeAction(#"{"op":"throw","screen":"left"}"#)
  let named: [CheatSheet.Shortcut] = [
    CheatSheet.Shortcut(keys: hyperA, name: "  Spaced  ", action: undo),
    CheatSheet.Shortcut(keys: hyperA, name: "\tTabbed", action: undo),
    CheatSheet.Shortcut(keys: hyperA, name: "   ", action: undo),
    CheatSheet.Shortcut(keys: hyperA, name: "", action: undo),
    CheatSheet.Shortcut(keys: hyperA, name: "\nNew line", action: undo),
    CheatSheet.Shortcut(keys: hyperA, name: "Throw to the left", action: left),
    CheatSheet.Shortcut(keys: hyperA, name: "Throw to the left, Resized", action: left),
    CheatSheet.Shortcut(keys: hyperA, name: "Throw to ", action: left),
    CheatSheet.Shortcut(keys: hyperA, name: "Throw to x", action: left),
    CheatSheet.Shortcut(keys: hyperA, name: "Throw to émigré", action: left),
    CheatSheet.Shortcut(keys: hyperA, summary: "JavaScript function"),
    CheatSheet.Shortcut(keys: hyperA, name: "Named script", summary: "JavaScript function"),
    CheatSheet.Shortcut(keys: hyperA),
    CheatSheet.Shortcut(keys: hyperA, action: left, summary: "throw left"),
  ]
  let names: [J] = named.map { shortcut in
    let sheet = CheatSheet.hyper([shortcut], hyperModifiers: .hyper)
    let item = sheet.sections[0].items[0]
    return [
      "shortcut": shortcutJ(shortcut), "title": .string(item.title), "section": .string(sheet.sections[0].title),
      "symbol": .string(item.symbol),
    ]
  }

  var sheets: [J] = []
  func hyper(_ name: String, _ shortcuts: [CheatSheet.Shortcut], modifiers: Modifiers = .hyper) {
    let sheet = CheatSheet.hyper(shortcuts, hyperModifiers: modifiers)
    sheets.append([
      "name": .string(name), "hyperModifiers": modifierList(modifiers), "shortcuts": .array(shortcuts.map(shortcutJ)),
      "sheet": sheetJ(sheet),
    ])
  }
  func modal(_ name: String, _ key: String, _ shortcuts: [CheatSheet.Shortcut]) {
    let sheet = CheatSheet.modal(combo(key), shortcuts)
    sheets.append([
      "name": .string(name), "modal": .string(key), "shortcuts": .array(shortcuts.map(shortcutJ)),
      "sheet": sheetJ(sheet),
    ])
  }
  func shortcut(_ keys: String, _ action: String, name: String? = nil, modal: String? = nil) -> CheatSheet.Shortcut {
    CheatSheet.Shortcut(
      keys: combo(keys), modal: modal.map(combo), name: name,
      action: try! SlateSyntax.parseOperation(action))
  }

  hyper(
    "starter configuration",
    SlatedConfiguration.starter.bindings.map {
      CheatSheet.Shortcut(keys: $0.keys, modal: $0.modal?.keys, name: $0.name, action: $0.action)
    })
  hyper(
    "keyboard order",
    orderedKeys.map { CheatSheet.Shortcut(keys: KeyCombo(key: KeyNames.canonical($0), modifiers: .hyper), action: undo) })
  hyper(
    "first shortcut for a key wins; modal and other shortcuts aren't listed",
    [
      shortcut("hyper+a", "undo", name: "First"),
      shortcut("hyper+a", "relaunch", name: "Duplicate"),
      shortcut("cmd+shift+v", "clipboard-history", name: "Clipboard"),
      shortcut("h", "undo", name: "Modal", modal: "hyper+m"),
      shortcut("fn+hyper+a", "undo", name: "With fn"),
      shortcut("hyper+b", "throw next"),
      shortcut("hyper+1", "focus 'Terminal'"),
      shortcut("hyper+c", "layout Work"),
      shortcut("hyper+d", "repeat 0.1 'click left'"),
      shortcut("hyper+e", "shell 'open -a Mail'"),
      CheatSheet.Shortcut(keys: combo("hyper+j"), summary: "JavaScript function"),
      CheatSheet.Shortcut(keys: combo("hyper+esc"), name: "Stop automations", action: .stopAutomations),
      CheatSheet.Shortcut(keys: combo("hyper+v"), name: "Clipboard history", action: .clipboardHistory),
    ])
  hyper(
    "Meh: ⌘ is an extra modifier",
    [
      shortcut("ctrl+alt+shift+h", "undo"),
      shortcut("ctrl+alt+shift+cmd+h", "relaunch"),
      shortcut("ctrl+alt+j", "undo"),
      shortcut("hyper+k", "throw next"),
    ],
    modifiers: .meh)
  hyper("nothing bound", [])
  modal(
    "a modal key's shortcuts",
    "ctrl+e",
    [
      shortcut("h", "push left bar-resize:screenSizeX/2", name: "Left", modal: "ctrl+e"),
      shortcut("shift+k", "undo", name: "Top", modal: "ctrl+e"),
      shortcut("j", "undo", name: "Elsewhere", modal: "ctrl+f"),
      shortcut("hyper+a", "undo", name: "Not modal"),
      shortcut("hyper+x", "throw next", modal: "ctrl+e"),
      shortcut("1", "focus 'Safari'", modal: "ctrl+e"),
      shortcut("h", "relaunch", name: "Duplicate", modal: "ctrl+e"),
    ])
  modal("a modal key with nothing bound", "hyper+m", [shortcut("h", "undo", modal: "ctrl+e")])

  return FixtureFile(
    name: "cheatsheet.json",
    description:
      "The notch island's cheat sheet (SlatedUI CheatSheet): `actions` binds each action alone to hyper+a and "
      + "records its item (title from ActionDescriber, section, region on a 1600×1000 sample screen, SF Symbol); "
      + "`names` how names and summaries title a shortcut; `sheets` whole Hyper (hyperModifiers) and modal sheets, "
      + "with sections in order and items in keyboard order.",
    sections: ["actions": actions, "names": names, "sheets": sheets],
    depth: ["sheets": 1])
}
