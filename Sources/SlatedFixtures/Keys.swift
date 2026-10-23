import Foundation

@testable import SlatedCore

private let comboInputs: [String] = [
  "ctrl+shift+alt+cmd+a", "hyper+a", "cmd++", "ctrl+pad+", "Return", "bogus+a", "", "  ", "+", "++", "a+", "cmd+",
  "pad+", "cmd+pad+", "PAD+", "ctrl++", "ctrl + a", " hyper+a ", "hyper+A", "shift+cmd+ctrl+alt+left", "meh+x",
  "fn+f1", "fn+ctrl+alt+shift+cmd+a", "Opt+Cmd+Up", "control+option+command+shift+pageup", "ctrl+PageDown",
  "ctrl+escape", "ctrl+enter", "ctrl+backspace", "ctrl+ab", "ctrl+", "⌃+⌥+⇧+⌘+a", "✦+a", "ctrl++a", "ctrl+a+b", "a",
  "A", "F5", "Space", "SPACE", "tab", "ForwardDelete", "volumeup", "PADENTER", "pad=", "pad*", "pad-", "pad.",
  "pad/", "pad0", "padClear", "ctrl+é", "cmd+É", "cmd+👍🏽", "cmd+e\u{301}", "hyper+'", "cmd+shift+4", "ctrl+cmd+left",
  "cmd+shift+'", "hyper+tab", "meh+cmd+a", "hyper+meh+a", "fn+a", "function+a", "option+a", "command+a",
  "ctrl+alt+cmd+f13", "ctrl\t+a", "ctrl+ ", "ctrl+'+'", "hyper+f20", "hyper+f21", "Hyper+Return", "cmd+ß",
  "alt+;", "alt+,", "shift+`", "cmd+\\", "cmd+backslash", "cmd+[", "cmd+]", "ctrl+-", "ctrl+=", "cmd+/", "cmd+.",
  "ctrl+caps", "ctrl+help", "ctrl+mute", "ctrl+volumeDown", "ctrl+home", "ctrl+end", "ctrl+delete",
  "ctrl+forwarddelete", "ctrl+esc", "ctrl+down", "ctrl+right", "x+y", "hyper+pad9", "ctrl+pad5", "a b", "cmd+a b",
  "ctrl+\u{00A0}a", "ctrl+İ",
]

/// Built with KeyCombo(key:modifiers:), the way the UI and the Slate importer create combos.
private let comboParts: [(String, Modifiers)] = [
  ("Return", .hyper), ("A", []), ("PageUp", .command), ("ESCAPE", .control), ("pad+", [.command, .shift]),
  ("F12", .meh), ("", .hyper), ("", []), ("ab", .control), ("É", .option), ("space", [.function]),
  ("tab", [.function, .control, .option, .shift, .command]), ("'", [.control, .command]), ("+", .shift),
  ("enter", []), ("backspace", .option), ("pagedown", []), ("padenter", .control), ("left", [.option, .command]),
  ("4", [.command, .shift]),
]

private let keyNames: [String] = [
  "left", "right", "up", "down", "return", "tab", "space", "delete", "forwardDelete", "esc", "home", "end", "pageUp",
  "pageDown", "help", "caps", "mute", "volumeUp", "volumeDown", "backslash", "padClear", "padEnter", "pad=", "pad*",
  "pad+", "pad-", "pad.", "pad/", "pad0", "pad1", "pad9", "f1", "f9", "f10", "f20", "f21", "f0", "escape", "enter",
  "backspace", "pageup", "pagedown", "RETURN", "Esc", "PAD1", "F5", "a", "A", "z", "0", "9", "'", ";", ",", ".", "/",
  "\\", "[", "]", "-", "=", "`", "+", "\"", ":", "é", "É", "ß", "😀", "👍🏽", "e\u{301}", "ab", "", " ", "pad10",
  "padEquals", "fn", "f", "ẞ", "İ", "Ω", "\u{915}\u{94D}\u{937}", "\u{915}\u{94D}", "\u{0E01}\u{0E33}",
]

private let modifierTokens: [String] = [
  "ctrl", "control", "⌃", "alt", "opt", "option", "⌥", "shift", "⇧", "cmd", "command", "⌘", "fn", "function", "hyper",
  "✦", "meh", "CTRL", "Shift", "HYPER", "Meh", "super", "win", "", " ctrl", "ctl", "Ctrl",
]

private let keystrokeInputs: [String] = [
  "a:ctrl,shift,alt,cmd", "left:ctrl;cmd", "':ctrl,shift,alt,cmd", ";:ctrl", "return:ctrl,shift,alt,cmd",
  "1:f4,ctrl,alt", "1:ctrl,f4:toggle", "a:ctrl,bogus", "a", "A:CTRL", "::ctrl", ",:ctrl", "pad+:cmd", "padEnter:cmd",
  "f13:ctrl,alt,cmd", "esc:cmd", "escape:cmd", "Enter:cmd", "space:hyper", "a:meh", "a:opt", "a:option", "a:command",
  "a:control", "a:fn", "a:function", "a:⌘", "a:ctrl;;cmd", "a:ctrl, cmd", "a: ctrl", "a:", ":", "", "  a:ctrl  ",
  "ab:ctrl", "a:ctrl:toggle", "1:f4,f5", "1:f4:TOGGLE", "a:ctrl,b", "a:ctrl, ", "a :ctrl", "left:ctrl;cmd:toggle",
  "é:ctrl", "É:ctrl", "e\u{301}:ctrl", "👍🏽:cmd", "ß:ctrl", "ẞ:ctrl", "right:alt", "left:ctrl;alt", "up:ctrl;cmd",
  "1:ctrl;alt", "down:ctrl;alt;cmd", "up:cmd;alt", "esc:cmd", "pad1:ctrl", "up:alt,ctrl", "left:ctrl,shift",
  "pad1:alt,ctrl", "tab:cmd", "\":ctrl", "#:ctrl", "1:f4", "1:f4:toggle", ":toggle", "a:toggle", "1:ctrl,f4,shift",
  "x:hyper,cmd", "pageUp:ctrl", "PAGEUP:CTRL", "f20:shift", "f21:shift", "a:ctrl,,alt", "a;ctrl", "a,ctrl",
  "a:ctrl:alt", "1:F4,CTRL:Toggle", "space:ctrl", "1:ctrl,space", "tab:ctrl:toggle", "a\u{00A0}:ctrl",
]

private func comboDetails(_ combo: KeyCombo) -> [String: J] {
  [
    "combo": comboJ(combo), "string": .string(combo.string), "display": .string(combo.display()),
    "displayPlain": .string(combo.display(hyperGlyph: false)), "keyIsValid": .bool(KeyNames.isValid(combo.key)),
  ]
}

func keyFixtures() -> FixtureFile {
  let combos: [J] = comboInputs.map { input in
    var item: [String: J] = ["input": .string(input)]
    if let combo = KeyCombo(string: input) {
      item.merge(comboDetails(combo)) { a, _ in a }
    } else {
      item["combo"] = .null
    }
    return .object(item)
  }
  let parts: [J] = comboParts.map { key, modifiers in
    .object(
      ["key": .string(key), "modifiers": modifierList(modifiers)].merging(
        comboDetails(KeyCombo(key: key, modifiers: modifiers))
      ) { a, _ in a })
  }
  let names: [J] = keyNames.map { name in
    let canonical = KeyNames.canonical(name)
    return [
      "name": .string(name), "canonical": .string(canonical), "valid": .bool(KeyNames.isValid(name)),
      "display": .string(KeyNames.displayName(for: canonical)), "displayRaw": .string(KeyNames.displayName(for: name)),
    ]
  }
  let tokens: [J] = modifierTokens.map { token in
    ["token": .string(token), "modifiers": Modifiers.token(token).map(modifierList) ?? .null]
  }
  let keystrokes: [J] = keystrokeInputs.map { input in
    var item: [String: J] = ["input": .string(input)]
    do {
      let parsed = try SlateSyntax.parseKeystroke(input)
      item["keys"] = comboJ(parsed.keys)
      item["modal"] = parsed.modal.map { ["keys": comboJ($0.keys), "toggle": .bool($0.toggle)] } ?? .null
    } catch {
      item["error"] = errorJ(error)
    }
    return .object(item)
  }
  return FixtureFile(
    name: "keys.json",
    description:
      "KeyCombo(string:) parsing, canonical strings and display (with and without the ✦ Hyper glyph), "
      + "KeyCombo(key:modifiers:) canonicalization, KeyNames, modifier tokens, and Slate keystrokes "
      + "(SlateSyntax.parseKeystroke). Modifiers are listed in the order ctrl, alt, shift, cmd, fn.",
    sections: [
      "keyCombos": combos, "comboParts": parts, "keyNames": names, "modifierTokens": tokens, "keystrokes": keystrokes,
    ])
}
