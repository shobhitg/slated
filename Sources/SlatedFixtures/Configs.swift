import Foundation

@testable import SlatedCore

private let fullConfig = #"""
  {
    "version": 1,
    "general": {"launchAtLogin": true, "loadSlateConfigs": false, "slateConfigPaths": ["~/a.slate", "/b.js"],
                "showActionHUD": true, "hotstringsEnabled": false},
    "settings": {"defaultToCurrentScreen": true, "nudgePercentOf": "windowSize", "secondsBeforeRepeat": 0.25, "undoMaxStackSize": 20},
    "keyboard": {"capsLock": "hyper", "capsLockAlone": "escape", "hyperModifiers": ["ctrl", "alt", "cmd"]},
    "bindings": [
      {"id": "11111111-1111-4111-8111-111111111111", "name": "Left half", "keys": "hyper+a",
       "action": {"op": "move", "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY"}},
      {"id": "22222222-2222-4222-8222-222222222222", "keys": "ctrl+alt+f4", "modal": {"keys": "ctrl+f4", "toggle": true},
       "action": "push left bar", "repeats": true, "enabled": false},
      {"id": "33333333-3333-4333-8333-333333333333", "keys": "cmd+shift+'", "action": "chain push up | push down", "repeats": false},
      {"id": "44444444-4444-4444-8444-444444444444", "keys": "Hyper+Return",
       "action": {"op": "by-orientation", "landscape": "push left", "portrait": {"op": "push", "direction": "top"}}}
    ],
    "layouts": [
      {"name": "coding", "apps": [{"app": "Terminal", "operations": ["push left bar-resize:screenSizeX/2"],
                                   "options": {"ignoreFail": true, "titleOrder": ["a", "b"]}},
                                  {"app": "Safari"}],
       "before": ["undo"], "after": [{"op": "focus", "app": "Terminal"}]},
      {"name": "empty"}
    ],
    "defaults": [{"target": "coding", "count": 2}, {"target": "big", "resolutions": ["2560x1440", "1920x1080"]}],
    "hotstrings": [
      {"id": "55555555-5555-4555-8555-555555555555", "trigger": ";shrug", "replacement": "¯\\_(ツ)_/¯"},
      {"id": "66666666-6666-4666-8666-666666666666", "trigger": "brb", "replacement": "be right back", "fire": "afterDelimiter",
       "wordBoundary": true, "caseSensitive": false, "method": "paste", "onlyInApps": ["com.apple.mail"],
       "exceptInApps": ["com.apple.Terminal"], "notes": "office", "enabled": false, "action": "undo"}
    ]
  }
  """#

private let configMarkdownExample = #"""
  {
    "general": {
      "launchAtLogin": true,
      "loadSlateConfigs": true,          // also load ~/.slate.js and ~/.slate
      "showActionHUD": false             // flash a small confirmation after each action
    },

    // Caps Lock becomes ⌃⌥⇧⌘ (Hyper) while held.
    "keyboard": {
      "capsLock": "hyper",               // "off" | "hyper"
      "capsLockAlone": "nothing",        // "nothing" | "escape"
      "hyperModifiers": ["ctrl", "alt", "shift", "cmd"]
    },

    "bindings": [
      {
        "id": "A0000000-0000-4000-8000-000000000001",
        "name": "Left half",
        "keys": "hyper+a",
        "action": { "op": "move", "x": "screenOriginX", "y": "screenOriginY",
                    "width": "screenSizeX/2", "height": "screenSizeY" }
      },
      { "id": "A0000000-0000-4000-8000-000000000002", "keys": "hyper+w", "action": "push top bar-resize:screenSizeY/2" },   // Slate syntax works too
      { "id": "A0000000-0000-4000-8000-000000000003", "keys": "hyper+right", "action": { "op": "throw", "screen": "right",
                                           "width": "screenSizeX", "height": "screenSizeY" } },
      { "id": "A0000000-0000-4000-8000-000000000004", "keys": "hyper+tab", "action": "grid padding:4 0:6,6 1:6,6" }
    ],

    "hotstrings": [
      { "id": "B0000000-0000-4000-8000-000000000001", "trigger": ";shrug", "replacement": "¯\\_(ツ)_/¯" },
      { "id": "B0000000-0000-4000-8000-000000000002", "trigger": "brb", "replacement": "be right back", "fire": "afterDelimiter", "wordBoundary": true },
      { "id": "B0000000-0000-4000-8000-000000000003", "trigger": ";today", "replacement": "{date:yyyy-MM-dd}" }
    ],

    // Slate's global settings (`config name value` in .slate files).
    "settings": { "defaultToCurrentScreen": true, "nudgePercentOf": "screenSize" }
  }
  """#

/// docs/CONFIG.md's "Game automation" example, wrapped in an object.
private let configMarkdownAutomation = #"""
  {
  "bindings": [
    // Auto-click left every 100 ms; press F again to stop. Only in the game.
    { "name": "Auto-click", "keys": "f", "onlyInApps": ["com.mojang.minecraft"],
      "action": { "op": "repeat", "action": { "op": "click", "button": "left" }, "interval": 0.1 } },

    // Hold right click (e.g. to mine/block); press again to release.
    { "name": "Hold right click", "keys": "mouse4", "action": "hold mouse:right" },

    // Auto-run: hold W until pressed again.
    { "name": "Auto-run", "keys": "hyper+w", "action": "hold key:w" },

    // Toggle sprint by holding Shift.
    { "name": "Sprint", "keys": "hyper+r", "action": "hold key:shift" },

    // Spam E while the shortcut is held, with ±10% human-like timing.
    { "name": "Spam E", "keys": "mouse5", "action": "repeat 0.05 while-held jitter:0.1 'keystroke e'" },

    // Click 50 times, then stop by itself.
    { "name": "50 clicks", "keys": "hyper+5", "action": "repeat 0.1 times:50 'click left'" },

    // Macro: W down for 2 seconds, then click.
    { "name": "Dash and hit", "keys": "hyper+d",
      "action": "sequence press key:w down | wait 2 | press key:w up | click left" }
  ],
  "automation": {
    "stopShortcut": "hyper+esc",   // always stops everything (null turns it off)
    "stopOnAppSwitch": true,       // stop when you leave the app it started in
    "maxRunMinutes": 0,            // 0 = no limit
    "showIndicator": true          // show what's running (in the notch island, or a pill)
  }
  }
  """#

/// docs/CONFIG.md's "Clipboard history" example, wrapped in an object.
private let configMarkdownClipboard = #"""
  {
  "clipboard": {
    "enabled": true,
    "shortcut": "cmd+shift+v",      // opens the switcher; null turns it off
    "maxItems": 200,
    "persist": true,                // kept across restarts, readable only by you
    "retentionDays": 30,            // pinned items are kept regardless
    "ignoreConcealed": true,        // skip what password managers mark as secret
    "excludedApps": ["com.1password.1password", "com.bitwarden.desktop"],
    "pasteAfterSelecting": true
  }
  }
  """#

private let decodeCases: [(String, String)] = [
  ("empty object", "{}"),
  ("docs/CONFIG.md game automation example", configMarkdownAutomation),
  ("docs/CONFIG.md clipboard history example", configMarkdownClipboard),
  (
    "binding onlyInApps",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000010", "keys": "f", "onlyInApps": ["com.mojang.minecraft", "steam_app_1234", "org.gnome.Terminal.desktop"], "action": {"op": "repeat", "action": {"op": "click", "button": "left"}, "interval": 0.1}}]}"#
  ),
  (
    "binding onlyInApps empty is left out",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000011", "keys": "f", "onlyInApps": [], "action": "click"}]}"#
  ),
  (
    "binding onlyInApps null",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000012", "keys": "f", "onlyInApps": null, "action": "click"}]}"#
  ),
  ("binding onlyInApps not a list", #"{"bindings": [{"keys": "f", "onlyInApps": "steam", "action": "click"}]}"#),
  ("binding onlyInApps with a number", #"{"bindings": [{"keys": "f", "onlyInApps": ["a", 1], "action": "click"}]}"#),
  (
    "binding with an invalid action and onlyInApps",
    #"{"bindings": [{"keys": "f", "onlyInApps": 5, "action": {"op": "repeat", "action": "click", "interval": 0}}]}"#
  ),
  (
    "automation actions in both forms",
    #"""
    {"bindings": [
      {"id": "E0000000-0000-4000-8000-000000000020", "keys": "hyper+1", "action": {"op": "click", "button": "right", "count": 2}},
      {"id": "E0000000-0000-4000-8000-000000000021", "keys": "hyper+2", "action": "click middle 3"},
      {"id": "E0000000-0000-4000-8000-000000000022", "keys": "hyper+3", "action": {"op": "press", "input": "Key:Shift+W", "phase": "down"}},
      {"id": "E0000000-0000-4000-8000-000000000023", "keys": "hyper+4", "action": "hold mouse:left"},
      {"id": "E0000000-0000-4000-8000-000000000024", "keys": "hyper+5", "action": {"op": "repeat", "action": "keystroke e", "interval": 0.05, "mode": "while-held", "times": 10, "jitter": 0.1}},
      {"id": "E0000000-0000-4000-8000-000000000025", "keys": "hyper+6", "action": {"op": "sequence", "operations": ["press key:w down", {"op": "wait", "seconds": 1.5}, "press key:w up"]}},
      {"id": "E0000000-0000-4000-8000-000000000026", "keys": "hyper+esc", "action": "stop-automations"},
      {"id": "E0000000-0000-4000-8000-000000000027", "keys": "cmd+shift+v", "action": {"op": "clipboard-history"}},
      {"id": "E0000000-0000-4000-8000-000000000028", "keys": "mouse3", "action": "click right"},
      {"id": "E0000000-0000-4000-8000-000000000029", "keys": "ctrl+Mouse5", "action": "repeat 1 'click'"},
      {"id": "E0000000-0000-4000-8000-00000000002A", "keys": "shift", "action": "hold key:ctrl"}
    ]}
    """#
  ),
  (
    "automation action with a bad interval",
    #"{"bindings": [{"keys": "f", "action": {"op": "repeat", "action": "click", "interval": -1}}]}"#
  ),
  (
    "automation action with a bad input",
    #"{"bindings": [{"keys": "f", "action": {"op": "hold", "input": "key:bogus"}}]}"#
  ),
  ("automation action with bad syntax", #"{"bindings": [{"keys": "f", "action": "repeat 0.1 jitter:2 'click'"}]}"#),
  (
    "clipboard and automation settings",
    #"""
    {"clipboard": {"enabled": false, "shortcut": "Ctrl+Alt+V", "maxItems": 50, "persist": false, "retentionDays": 0,
                   "ignoreConcealed": false, "excludedApps": ["org.keepassxc.KeePassXC"], "pasteAfterSelecting": false},
     "automation": {"stopShortcut": "ctrl+alt+esc", "stopOnAppSwitch": false, "maxRunMinutes": 2.5, "showIndicator": false}}
    """#
  ),
  (
    "clipboard and automation shortcuts turned off",
    #"{"clipboard": {"shortcut": null}, "automation": {"stopShortcut": null}}"#
  ),
  ("clipboard partial", #"{"clipboard": {"maxItems": 5}, "automation": {}}"#),
  ("clipboard null", #"{"clipboard": null, "automation": null}"#),
  ("clipboard invalid shortcut", #"{"clipboard": {"shortcut": "bogus+v"}}"#),
  ("automation invalid stop shortcut", #"{"automation": {"stopShortcut": ""}}"#),
  ("automation wrong type", #"{"automation": {"stopOnAppSwitch": "yes"}}"#),
  ("automation maxRunMinutes as text", #"{"automation": {"maxRunMinutes": "5"}}"#),
  ("automation maxRunMinutes whole", #"{"automation": {"maxRunMinutes": 10}}"#),
  ("clipboard maxItems fraction", #"{"clipboard": {"maxItems": 1.5}}"#),
  ("clipboard excludedApps not a list", #"{"clipboard": {"excludedApps": "com.bitwarden.desktop"}}"#),
  ("clipboard excludedApps empty", #"{"clipboard": {"excludedApps": []}}"#),
  (
    "clipboard negative numbers are kept",
    #"{"clipboard": {"maxItems": -1, "retentionDays": -7}, "automation": {"maxRunMinutes": -2}}"#
  ),
  ("clipboard shortcut as a number", #"{"clipboard": {"shortcut": 5}}"#),
  ("automation is not an object", #"{"automation": []}"#),
  ("full configuration", fullConfig),
  ("docs/CONFIG.md example (JSON with comments)", configMarkdownExample),
  (
    "ConfigurationTests: missing keys and comments",
    "{\n  // JSON5 comments are allowed in hand-edited files\n  \"keyboard\": { \"capsLock\": \"hyper\" },\n"
      + "  \"hotstrings\": [ { \"id\": \"C0000000-0000-4000-8000-000000000001\", \"trigger\": \";shrug\", \"replacement\": \"¯\\\\_(ツ)_/¯\" } ],\n}"
  ),
  (
    "smoke fixture: hand-edited",
    #"""
    {
      // Hand-edited: comments and trailing commas are allowed.
      "version": 2,
      "keyboard": { "capsLock": "off" },
      "bindings": [
        { "keys": "hyper+w", "action": "push top bar-resize:screenSizeY/2" },
      ],
      "hotstrings": [
        { "trigger": ";shrug", "replacement": "¯\\_(ツ)_/¯" },
        { "trigger": ";today", "replacement": "{date:yyyy-MM-dd}", "fire": "afterDelimiter" },
      ],
    }
    """#
  ),
  (
    "smoke fixture: duplicates",
    #"{ "version": 2, "bindings": [ { "keys": "ctrl+alt+cmd+f13", "action": "push left" }, { "keys": "ctrl+alt+cmd+f13", "action": "push right" } ] }"#
  ),
  (
    "smoke fixture: unknown operation",
    #"{ "version": 2, "bindings": [ { "keys": "hyper+a", "action": { "op": "teleport" } } ] }"#
  ),
  ("smoke fixture: broken JSON", #"{ "bindings": [ { "keys": "hyper+a", "action":"#),
  // JSON5
  ("JSON5: block comments", "/* header */ {\"version\": /* inline */ 1 /* after */}"),
  ("JSON5: trailing commas", #"{"general": {"launchAtLogin": true,}, "bindings": [],}"#),
  ("JSON5: unquoted keys", #"{general: {launchAtLogin: true, $odd_key: 1}, settings: {_x1: 2}}"#),
  ("JSON5: single-quoted strings", #"{'settings': {'a': 'it\'s', "b": 'say "hi"'}}"#),
  ("JSON5: numbers", #"{"settings": {"hex": 0x1F, "plus": +1, "lead": .5, "trail": 5., "neg": -0x10, "exp": 1e2}}"#),
  ("JSON5: infinity", #"{"settings": {"inf": Infinity, "ninf": -Infinity}}"#),
  ("JSON5: NaN", #"{"settings": {"nan": NaN}}"#),
  ("JSON5: \\x escape", #"{"settings": {"x": "\x41"}}"#),
  ("JSON5: \\u escape", #"{"settings": {"x": "éÉ"}}"#),
  ("JSON5: line continuation", "{\"settings\": {\"x\": \"a\\\nb\"}}"),
  ("JSON5: line continuation CRLF", "{\"settings\": {\"x\": \"a\\\r\nb\"}}"),
  ("JSON5: \\0 escape", #"{"settings": {"x": "a\0b"}}"#),
  ("JSON5: escaped single quote in double quotes", #"{"settings": {"x": "it\'s"}}"#),
  ("JSON5: unknown escape", #"{"settings": {"x": "\a\c"}}"#),
  ("JSON5: escaped slash", #"{"settings": {"x": "a\/b"}}"#),
  ("JSON5: surrogate pair escape", #"{"settings": {"x": "😀"}}"#),
  ("JSON5: lone surrogate escape", #"{"settings": {"x": "\ud800"}}"#),
  ("JSON5: escaped U+2028", #"{"settings": {"x": "a b c"}}"#),
  ("JSON5: raw tab in a string", "{\"settings\": {\"x\": \"a\tb\"}}"),
  ("JSON5: raw newline in a string", "{\"settings\": {\"x\": \"a\nb\"}}"),
  ("JSON5: raw control character in a string", "{\"settings\": {\"x\": \"a\u{01}b\"}}"),
  ("JSON5: raw DEL in a string", "{\"settings\": {\"x\": \"a\u{7F}b\"}}"),
  ("JSON5: byte order mark", "\u{FEFF}{\"version\": 1}"),
  ("JSON5: no-break space", "{\u{00A0}\"version\": 1}"),
  ("JSON5: line separator", "{\"version\"\u{2028}: 1}"),
  ("JSON5: paragraph separator", "{\"version\":\u{2029}1}"),
  ("JSON5: vertical tab", "{\"version\": 1\u{000B}}"),
  ("JSON5: form feed", "{\u{000C}\"version\": 1}"),
  ("JSON5: ideographic space", "{\"version\":\u{3000}1}"),
  ("JSON5: carriage returns", "{\r\"version\":\r\n1\r}"),
  ("JSON5: unicode identifier key", #"{settings: {ключ: 1, $a_b: 2, café: 3}}"#),
  ("JSON5: identifier with a dash", #"{settings: {a-b: 1}}"#),
  ("JSON5: reserved words as keys", #"{settings: {true: 1, null: 2, Infinity: 3}}"#),
  ("JSON5: key starting with a digit", #"{settings: {1a: 1}}"#),
  ("JSON5: numeric key", #"{settings: {1: 2}}"#),
  ("JSON5: single-quoted key", #"{'version': 1}"#),
  ("JSON5: identifier key with escape", #"{settings: {ab: 1}}"#),
  ("JSON5: uppercase hex", #"{"settings": {"x": 0X1F}}"#),
  ("JSON5: hex with a fraction", #"{"settings": {"x": 0x1.8}}"#),
  ("JSON5: plus hex", #"{"settings": {"x": +0x10}}"#),
  ("JSON5: leading zeros", #"{"settings": {"x": 01}}"#),
  ("JSON5: negative leading dot", #"{"settings": {"x": -.5}}"#),
  ("JSON5: trailing dot with exponent", #"{"settings": {"x": 5.e2}}"#),
  ("JSON5: exponent with plus", #"{"settings": {"x": 1e+2, "y": 1E-2}}"#),
  ("JSON5: plus infinity", #"{"settings": {"x": +Infinity}}"#),
  ("JSON5: minus NaN", #"{"settings": {"x": -NaN}}"#),
  ("JSON5: Infinity as version", #"{"version": Infinity}"#),
  ("JSON5: huge number", #"{"settings": {"x": 1e400}}"#),
  ("JSON5: tiny number", #"{"settings": {"x": 1e-400}}"#),
  ("JSON5: comment between key and colon", #"{"version" /* c */ : 1}"#),
  ("JSON5: nested block comments", "{/* a /* b */ */ \"version\": 1}"),
  ("JSON5: line comment with CRLF", "{\"version\": 1 // one\r\n}"),
  ("JSON5: line comment with CR", "{\"version\": 1 // one\r}"),
  ("JSON5: comment inside a string", #"{"settings": {"x": "a // b /* c */"}}"#),
  ("JSON5: slash without comment", #"{"version": 1 / 2}"#),
  ("JSON5: trailing comma after comment", "{\"version\": 1, // last\n}"),
  ("JSON5: True with a capital", #"{"general": {"launchAtLogin": True}}"#),
  ("JSON5: undefined", #"{"version": undefined}"#),
  ("JSON5: byte order mark inside", "{\u{FEFF}\"version\": 1}"),
  ("JSON5: \\v and \\f escapes", #"{"settings": {"x": "a\vb\fc"}}"#),
  ("JSON5: escaped double quote in single quotes", #"{"settings": {"x": 'a\"b'}}"#),
  ("JSON5: hex version", #"{"version": 0x2}"#), ("JSON5: plus version", #"{"version": +1}"#),
  ("JSON5: leading-dot version", #"{"version": .5}"#), ("JSON5: huge version", #"{"version": 99999999999999999999}"#),
  ("JSON5: negative zero version", #"{"version": -0}"#), ("JSON5: hex fraction version", #"{"version": 0x1p4}"#),
  ("JSON5: empty key", #"{"settings": {"": 1}}"#), ("JSON5: identifier key escape at start", #"{settings: {$x: 1}}"#),
  ("JSON5: comment glued to a value", #"{"version": 1/*c*/}"#), ("JSON5: comment first", "// first\n{}"),
  ("JSON5: hash comment", "# no\n{}"), ("JSON5: unicode digit in identifier", #"{settings: {a١: 1}}"#),
  ("JSON5: dotted key", #"{settings: {a.b: 1}}"#), ("JSON5: unquoted string value", #"{"settings": {"a": hello}}"#),
  ("JSON5: number then identifier", #"{"version": 1x}"#),
  ("JSON5: hex digits in a decimal", #"{"settings": {"x": 1f}}"#),
  ("JSON5: lone minus", #"{"settings": {"x": -}}"#), ("JSON5: lone dot", #"{"settings": {"x": .}}"#),
  ("JSON5: exponent without digits", #"{"settings": {"x": 1e}}"#), ("JSON5: double sign", #"{"settings": {"x": --1}}"#),
  ("JSON5: Infinity spelled out in lowercase", #"{"settings": {"x": infinity}}"#),
  ("JSON5: 0x without digits", #"{"settings": {"x": 0x}}"#),
  ("JSON5: negative hex fraction", #"{"settings": {"x": -0x1.8p1}}"#),
  ("JSON5: max double", #"{"settings": {"x": 1.7976931348623157e308, "y": 5e-324, "z": 2.2250738585072014e-308}}"#),
  ("JSON5: exact zero forms", #"{"settings": {"a": 0e10, "b": 0.0e-500, "c": -0.0, "d": 0x0}}"#),
  ("JSON5: 1e309 in a string field", #"{"hotstrings": [{"trigger": 1e309}]}"#),
  ("duplicate keys nested", #"{"settings": {"a": 1, "a": 2}}"#),
  ("duplicate top-level objects", #"{"general": {"launchAtLogin": true}, "general": {"showActionHUD": true}}"#),
  (
    "duplicate keys in a binding",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000003", "keys": "a", "keys": "b", "action": "undo", "action": "relaunch"}]}"#
  ),
  ("duplicate keys with null first", #"{"version": null, "version": 3}"#),
  ("JSON5: line comment at end", "{\"version\": 1} // done"),
  ("JSON5: unterminated block comment", "{\"version\": 1} /* oops"),
  ("JSON5: lone trailing comma", "{,}"),
  ("JSON5: double trailing comma", #"{"bindings": [,,]}"#),
  // Strings and escaping on output
  (
    "string escaping",
    #"{"hotstrings": [{"id": "D0000000-0000-4000-8000-000000000001", "trigger": "x", "replacement": "a\u0001b\u001fc\u007fd e\"f\\g/h\ti\nj\rk\bl\fm😀n o​p"}]}"#
  ),
  ("non-ASCII keys and values", #"{"settings": {"ключ": "значение", "😀": "🎉", "é": "é"}}"#),
  // Numbers in settings
  (
    "setting numbers",
    #"{"settings": {"a": 0.1, "b": 20, "c": 1e20, "d": -0.0, "e": 1.5, "f": 100.0, "g": 12345678901234567890, "h": 1e-7, "i": 2.5e-5, "j": 1e15, "k": 1e16, "l": 123456.789, "m": 0, "n": -3, "o": 4.35, "p": 9007199254740993, "q": 1e300, "r": 0.000123}}"#
  ),
  ("setting types", #"{"settings": {"t": true, "f": false, "s": "x", "n": 1, "z": "", "zero": 0}}"#),
  // How .sortedKeys orders keys that differ in case, digits, punctuation and accents.
  (
    "sorted key order",
    #"{"settings": {"b": 1, "B": 2, "a": 3, "A10": 4, "A9": 5, "a2": 6, "_x": 7, "Z": 8, "z": 9, "10": 10, "9": 11, "é": 12, "f": 13, "-": 14, "": 15, "ä": 16, "e": 17, "E": 18, "x1y": 19, "x01y": 20, "x1.5": 21, "a b": 22, "ab": 23, "a_b": 24, "a-b": 25, "Ä": 26, "ß": 27, "ss": 28, "İ": 29, "i": 30, "I": 31, "😀": 32, "~": 33, "0": 34, "aB": 35, "Ab": 36, "AB": 37, "a10b": 38, "a9b": 39, "a010": 40, "a10": 41, "1.5": 42, "1,5": 43, "é": 44, "Straße": 45, "strasse": 46, "ǅ": 47, "ﬀ": 48, "ff": 49, "１": 50, "٣": 51, "3": 52}, "bindings": [{"id": "E0000000-0000-4000-8000-000000000004", "keys": "a", "action": "grid 10:1,1 2:1,1 1920x1080:1,1 0:1,1 -1:1,1 9:1,1 1920X1080:2,2 100x100:1,1 99x99:1,1"}]}"#
  ),
  ("setting null", #"{"settings": {"a": null}}"#),
  ("setting array", #"{"settings": {"a": [1]}}"#),
  ("settings not an object", #"{"settings": []}"#),
  // Top-level shapes
  ("top level array", "[]"), ("top level null", "null"), ("empty text", ""), ("whitespace only", "   \n"),
  ("trailing garbage", "{} x"),
  // Top-level sections Slated doesn't know (a newer version's) are kept and written back, sorted in
  // with the rest; unknown fields inside known sections are dropped.
  ("unknown top-level sections are kept", #"{"foo": 1, "bar": {"baz": [true]}}"#),
  (
    "unknown sections of every JSON type",
    #"""
    {"n": null, "t": true, "f": false, "i": -42, "d": 2.5, "s": "a \"quote\" \\ / é \n\t\u0001 😀",
     "a": [1, [2, []], {}], "o": {"z": 1, "a": {"nested": [null, -0.0, 1e-7]}}, "e": {}, "ea": []}
    """#
  ),
  (
    "unknown sections sort in with the known ones",
    #"{"zzz": 1, "aaa": 2, "Bindings": 3, "general2": 4, "_x": 5, "": 6, "é": 7, "10": 8, "9": 9, "B": 10}"#
  ),
  (
    "unknown section numbers stay exact",
    #"""
    {"future": {"max": 9223372036854775807, "min": -9223372036854775808, "over": 9223372036854775808,
                "safe": 9007199254740993, "ms": 1730000000000, "tiny": 5e-324, "big": 1.7976931348623157e308,
                "float": 0.1, "exp": 1e3, "fraction": 1.5e1, "third": 0.3333333333333333}}
    """#
  ),
  (
    "unknown fields inside known sections are dropped",
    #"""
    {"general": {"launchAtLogin": true, "future": 1}, "keyboard": {"capsLock": "hyper", "later": [1]},
     "island": {"newThing": true}, "clipboard": {"x": 1}, "automation": {"y": 2},
     "bindings": [{"id": "E0000000-0000-4000-8000-0000000000AB", "keys": "a", "action": "push left", "extra": 1}],
     "hotstrings": [{"id": "E0000000-0000-4000-8000-0000000000AC", "trigger": "x", "replacement": "y", "extra": 1}],
     "layouts": [{"name": "l", "extra": 1, "apps": [{"app": "A", "extra": 2}]}],
     "defaults": [{"target": "l", "count": 1, "extra": 3}]}
    """#
  ),
  (
    "unknown sections named like built-in properties",
    #"{"__proto__": {"a": 1}, "constructor": 2, "toString": [3], "hasOwnProperty": null}"#
  ),
  ("unknown section with duplicate keys", #"{"future": {"a": 1, "a": 2}, "later": 1, "later": [2]}"#),
  (
    "unknown section in JSON5",
    #"{future: {unquoted: 'single', hex: 0x1F, list: [1, 2,], plus: +1, lead: .5, trail: 5.,}, }"#
  ),
  ("unknown section keys that need escaping", #"{"a\"b": 1, "tab\tkey": 2, "/": 3, "\\": 4}"#),
  ("unknown section with infinity", #"{"future": {"x": Infinity}}"#),
  ("unknown section with NaN in a list", #"{"future": [1, NaN]}"#),
  ("unknown section with a number too big for a Double", #"{"future": {"x": [1e400]}}"#),
  ("unknown section after a broken known section", #"{"version": "1", "future": 1e400}"#),
  ("broken known section after an unknown one", #"{"future": 1, "keyboard": {"hyperModifiers": ["bogus"]}}"#),
  (
    "unknown section nested deeply",
    #"{"future": "# + String(repeating: "[", count: 30) + #"{"deep": [1]}"# + String(repeating: "]", count: 30) + "}"
  ),
  ("only unknown sections", #"{"later": {"enabled": true}}"#),
  ("duplicate keys", #"{"version": 1, "version": 2}"#), ("version as text", #"{"version": "1"}"#),
  ("version 2", #"{"version": 2}"#), ("version as float", #"{"version": 1.0}"#), ("version 1e3", #"{"version": 1e3}"#),
  ("version 1.5", #"{"version": 1.5}"#), ("version null", #"{"version": null}"#),
  // general
  ("general partial", #"{"general": {"slateConfigPaths": []}}"#),
  ("general wrong type", #"{"general": {"launchAtLogin": "yes"}}"#),
  ("general null", #"{"general": null}"#),
  // island (the macOS notch island; Linux keeps it so shared configs round-trip)
  ("island partial", #"{"island": {"cheatSheet": false}}"#),
  (
    "island all fields",
    #"{"island": {"enabled": false, "cheatSheet": true, "cheatSheetDelay": 1.25, "showFailures": false}}"#
  ),
  ("island delay as integer", #"{"island": {"cheatSheetDelay": 1}}"#),
  ("island wrong type", #"{"island": {"enabled": "yes"}}"#),
  ("island null", #"{"island": null}"#),
  // keyboard
  ("keyboard invalid capsLock", #"{"keyboard": {"capsLock": "on"}}"#),
  ("keyboard unknown modifier token is an error", #"{"keyboard": {"hyperModifiers": ["ctrl", "bogus"]}}"#),
  ("keyboard empty modifier token", #"{"keyboard": {"hyperModifiers": [""]}}"#),
  ("keyboard modifier token with spaces", #"{"keyboard": {"hyperModifiers": ["ctrl", " alt"]}}"#),
  ("keyboard super is not a modifier", #"{"keyboard": {"hyperModifiers": ["super", "ctrl"]}}"#),
  ("keyboard unknown modifier before a number", #"{"keyboard": {"hyperModifiers": ["bogus", 5]}}"#),
  (
    "keyboard every alias",
    #"{"keyboard": {"hyperModifiers": ["CTRL", "⌃", "Option", "⌥", "SHIFT", "⇧", "Command", "⌘", "Function"]}}"#
  ),
  ("keyboard hyper glyph", #"{"keyboard": {"hyperModifiers": ["✦", "fn"]}}"#),
  ("keyboard empty modifiers", #"{"keyboard": {"hyperModifiers": []}}"#),
  ("keyboard hyper token", #"{"keyboard": {"hyperModifiers": ["hyper"]}}"#),
  ("keyboard fn is dropped on output", #"{"keyboard": {"hyperModifiers": ["fn", "ctrl"]}}"#),
  ("keyboard aliases", #"{"keyboard": {"hyperModifiers": ["Control", "opt", "⌘", "meh"], "capsLockAlone": "escape"}}"#),
  ("keyboard modifiers not a list", #"{"keyboard": {"hyperModifiers": "hyper"}}"#),
  // bindings
  ("binding without keys", #"{"bindings": [{"action": "undo"}]}"#),
  ("binding with invalid keys", #"{"bindings": [{"keys": "bogus+a", "action": "undo"}]}"#),
  ("binding with empty keys", #"{"bindings": [{"keys": "", "action": "undo"}]}"#),
  ("binding with an invalid action", #"{"bindings": [{"keys": "hyper+a", "action": "push sideways"}]}"#),
  ("binding without action", #"{"bindings": [{"keys": "hyper+a"}]}"#),
  (
    "binding id lowercase",
    #"{"bindings": [{"id": "abcdef01-2345-4678-9abc-def012345678", "keys": "hyper+a", "action": "undo"}]}"#
  ),
  ("binding id invalid", #"{"bindings": [{"id": "not-a-uuid", "keys": "hyper+a", "action": "undo"}]}"#),
  (
    "binding id braces",
    #"{"bindings": [{"id": "{12345678-1234-1234-1234-123456789012}", "keys": "hyper+a", "action": "undo"}]}"#
  ),
  (
    "binding repeats null",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000001", "keys": "a", "action": "undo", "repeats": null, "name": null}]}"#
  ),
  ("binding modal without toggle", #"{"bindings": [{"keys": "a", "modal": {"keys": "ctrl+f4"}, "action": "undo"}]}"#),
  (
    "binding modal toggle null",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000013", "keys": "a", "modal": {"keys": "ctrl+f4", "toggle": null}, "action": "undo"}]}"#
  ),
  ("binding modal without keys", #"{"bindings": [{"keys": "a", "modal": {"toggle": true}, "action": "undo"}]}"#),
  (
    "sequence steps without keepWindow",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000014", "keys": "a", "action": {"op": "sequence", "steps": [{"action": "focus right"}, {"action": "push left", "keepWindow": true}]}}]}"#
  ),
  (
    "binding modal invalid keys",
    #"{"bindings": [{"keys": "a", "modal": {"keys": "x+y", "toggle": true}, "action": "undo"}]}"#
  ),
  ("binding name number", #"{"bindings": [{"keys": "a", "name": 5, "action": "undo"}]}"#),
  ("bindings not a list", #"{"bindings": {}}"#),
  (
    "binding keys canonicalized",
    #"{"bindings": [{"id": "E0000000-0000-4000-8000-000000000002", "keys": "shift+cmd+ctrl+alt+PageUp", "action": {"op": "keystroke", "keys": "4:cmd,shift"}}]}"#
  ),
  // hotstrings
  ("hotstring minimal", #"{"hotstrings": [{"id": "F0000000-0000-4000-8000-000000000001", "trigger": "x"}]}"#),
  ("hotstring without trigger", #"{"hotstrings": [{"replacement": "x"}]}"#),
  ("hotstring invalid fire", #"{"hotstrings": [{"trigger": "x", "fire": "later"}]}"#),
  ("hotstring invalid method", #"{"hotstrings": [{"trigger": "x", "method": "telepathy"}]}"#),
  (
    "hotstring with action object",
    #"{"hotstrings": [{"id": "F0000000-0000-4000-8000-000000000002", "trigger": ";x", "action": {"op": "open-url", "url": "https://example.com"}}]}"#
  ),
  ("hotstring without id", #"{"hotstrings": [{"trigger": "a"}, {"trigger": "b"}]}"#),
  ("hotstring empty trigger", #"{"hotstrings": [{"id": "F0000000-0000-4000-8000-000000000003", "trigger": ""}]}"#),
  // layouts and defaults
  ("layout minimal", #"{"layouts": [{"name": "x"}]}"#), ("layout without name", #"{"layouts": [{"apps": []}]}"#),
  (
    "layout app options partial",
    #"{"layouts": [{"name": "x", "apps": [{"app": "A", "options": {"repeat": true, "titleOrderRegex": ["^a"]}}]}]}"#
  ),
  ("layout app without app", #"{"layouts": [{"name": "x", "apps": [{"operations": []}]}]}"#),
  ("layout app options wrong type", #"{"layouts": [{"name": "x", "apps": [{"app": "A", "options": {"repeat": 1}}]}]}"#),
  ("default count", #"{"defaults": [{"target": "x", "count": 3}]}"#),
  ("default resolutions", #"{"defaults": [{"target": "x", "resolutions": ["1x1", "1920x1080"]}]}"#),
  ("default empty resolutions", #"{"defaults": [{"target": "x", "resolutions": []}]}"#),
  ("default count zero and negative", #"{"defaults": [{"target": "x", "count": 0}, {"target": "y", "count": -1}]}"#),
  ("default count as text", #"{"defaults": [{"target": "x", "count": "2"}]}"#),
  ("default count fraction", #"{"defaults": [{"target": "x", "count": 1.5}]}"#),
  ("default resolutions not a list", #"{"defaults": [{"target": "x", "resolutions": "1920x1080"}]}"#),
  ("default without a condition", #"{"defaults": [{"target": "x"}]}"#),
  ("default count and resolutions", #"{"defaults": [{"target": "x", "count": 2, "resolutions": ["1x1"]}]}"#),
  ("default null count with resolutions", #"{"defaults": [{"target": "x", "count": null, "resolutions": ["1x1"]}]}"#),
  ("default null condition", #"{"defaults": [{"target": "x", "count": null}]}"#),
  ("default bad count before both", #"{"defaults": [{"target": "x", "count": "2", "resolutions": ["1x1"]}]}"#),
  ("default unknown key", #"{"defaults": [{"target": "x", "screens": 2}]}"#),
  ("default without target", #"{"defaults": [{"count": 3}]}"#),
  ("default target not text", #"{"defaults": [{"target": 1, "count": 3}]}"#),
  ("default second one broken", #"{"defaults": [{"target": "x", "count": 1}, {"target": "y"}]}"#),
  // The shape Slated wrote before (Swift's synthesized enum coding) still reads; it's written in the new one.
  ("default count (old shape)", #"{"defaults": [{"target": "x", "condition": {"count": {"_0": 3}}}]}"#),
  (
    "default resolutions (old shape)",
    #"{"defaults": [{"target": "x", "condition": {"resolutions": {"_0": ["1x1"]}}}]}"#
  ),
  ("default bad condition (old shape)", #"{"defaults": [{"target": "x", "condition": {"count": 3}}]}"#),
  ("default unknown condition (old shape)", #"{"defaults": [{"target": "x", "condition": {"screens": {"_0": 3}}}]}"#),
  (
    "default two conditions (old shape)",
    #"{"defaults": [{"target": "x", "condition": {"count": {"_0": 3}, "resolutions": {"_0": []}}}]}"#
  ),
  ("default without target (old shape)", #"{"defaults": [{"condition": {"count": {"_0": 3}}}]}"#),
  ("default null condition (old shape)", #"{"defaults": [{"target": "x", "condition": null}]}"#),
  (
    "default old and new shapes together",
    #"{"defaults": [{"target": "x", "count": 2, "condition": {"count": {"_0": 2}}}]}"#
  ),
  (
    "default old and new shapes in one file",
    #"{"defaults": [{"target": "x", "condition": {"count": {"_0": 2}}}, {"target": "y", "resolutions": ["1x1"]}]}"#
  ),
]

/// JSON5 number spellings, including malformed ones Swift's scanner still reads as numbers. Each is
/// tried where Action decoding ignores a bad value (resize width), as an Int (version) and as a
/// Double (a setting).
private let numberTokens: [String] = [
  "1f", "-", ".", "1e", "0x", "1.2.3", "1e5e5", "1-2", "+-1", "0xg", "1a", "1g", ".e1", "0x1p4", "0X1P4", "0x1.8",
  "0x1.8p1", "1p4", "1_0", "0b1", "NaN", "Infinity", "-Infinity", "1e400", "1e-400", "01", "-01", "00", "0.0e0",
  "10e-1", "1.5e1", "1.25e1", "0x7FFFFFFFFFFFFFFF", "0x8000000000000000", "9223372036854775807",
  "9223372036854775808", "-9223372036854775808", "1e18", "1e19", "-0x0", "0xFFFFFFFFFFFFFFFFFF", "+.5", "5.", "-5.",
  "1E+2", "0x1F", "0xabc", "123456789012345678901234567890", "1x", "1z", "1Z", "-a", "+x", ".Z", "1.x", "Infinityx",
  "NaN1", "-NaN", "+NaN", "+Infinity", "Infinity1", "-Inf", "In", "N", "0x_1", "1+", "1.", "+", "+.", "-.", "e5", "x1",
  "9007199254740993", "-0", "0e5", "0x0p0", "0e0", "0e1", "0e9", "0e10", "0e15", "0e99", "0E5", "0e+5", "0e-5", "0.0e5",
  "0.e5", "1e5", "2e5", "0e05", "-0e5", "0e100", "0.5e1", "00e5", "0x0", "0.0", "0.00", "-0.0e1",
]

private let numberTokenCases: [(String, String)] = numberTokens.flatMap { token in
  [
    (
      "JSON5 number \(token) as an action parameter",
      #"{"bindings": [{"id": "E0000000-0000-4000-8000-0000000000AA", "keys": "a", "action": {"op": "resize", "width": \#(token), "height": "+1"}}]}"#
    ),
    ("JSON5 number \(token) as an Int", #"{"version": \#(token)}"#),
    ("JSON5 number \(token) as a Double", #"{"settings": {"x": \#(token)}}"#),
    ("JSON5 number \(token) in an unknown section", #"{"future": {"x": \#(token)}}"#),
  ]
}

/// Matches a UUID in Swift's uppercase form.
private let uuidPattern = try! NSRegularExpression(
  pattern: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")

/// Replaces UUIDs that Swift generated (they don't appear in `input`) with "RANDOM-UUID".
func maskRandomUUIDs(_ text: String, input: String) -> String {
  let known = input.uppercased()
  var result = text
  for match in uuidPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
    let range = Range(match.range, in: text)!
    if !known.contains(text[range]) { result.replaceSubrange(Range(match.range, in: result)!, with: "RANDOM-UUID") }
  }
  return result
}

/// Two files at once: a version 1 config.json and an existing settings.json, the shapes the migration
/// meets. `(name, config.json, settings.json)`.
private let fileCases: [(String, String, String?)] = [
  ("version 2 config.json, no settings.json", #"{"version": 2, "keyboard": {"capsLock": "hyper"}}"#, nil),
  (
    "version 2: both files",
    #"{"version": 2, "bindings": [{"id": "F0000000-0000-4000-8000-000000000001", "keys": "hyper+a", "action": "push left"}]}"#,
    #"{"version": 2, "general": {"showActionHUD": true}, "windows": {"nudgePercentOf": "screenSize"}, "island": {"enabled": false}}"#
  ),
  ("settings.json alone (config.json empty)", "{}", #"{"clipboard": {"maxItems": 5}}"#),
  (
    "legacy config.json: its settings move to settings.json, settings becomes windows",
    #"{"version": 1, "general": {"launchAtLogin": true, "loadSlateConfigs": true, "slateConfigPaths": ["~/.slate.js", "~/.slate"]}, "settings": {"undoMaxStackSize": 20}, "clipboard": {"maxItems": 50}, "keyboard": {"capsLock": "hyper"}}"#,
    nil
  ),
  (
    "legacy config.json with a settings.json there: settings.json wins",
    #"{"version": 1, "general": {"showActionHUD": true, "loadSlateConfigs": false}, "settings": {"undoMaxStackSize": 20}, "island": {"enabled": false}, "hotstrings": [{"id": "F0000000-0000-4000-8000-000000000002", "trigger": "brb", "replacement": "be right back"}]}"#,
    #"{"version": 2, "general": {"launchAtLogin": true}}"#
  ),
  (
    "legacy: imported Slate shortcuts are kept for the migration",
    #"{"general": {"importedSlateShortcuts": ["hyper+a", "ctrl+alt+f6 x"]}}"#, nil
  ),
  (
    "legacy fields of the wrong type are ignored",
    #"{"general": {"loadSlateConfigs": "no", "slateConfigPaths": 5, "importedSlateShortcuts": "hyper+a"}}"#, nil
  ),
  ("version 2 with a settings section is legacy", #"{"version": 2, "island": {"cheatSheet": false}}"#, nil),
  ("windows in config.json is unknown there", #"{"version": 2, "windows": {"a": 1}}"#, nil),
  ("settings in settings.json is unknown there", #"{"version": 2}"#, #"{"settings": {"a": 1}, "later": [1]}"#),
  ("a newer version in settings.json is kept", #"{"version": 2}"#, #"{"version": 3}"#),
  ("broken settings.json", #"{"version": 2}"#, #"{"general": {"launchAtLogin": "yes"}}"#),
  ("settings.json with a syntax error", #"{"version": 2}"#, #"{"general": "#),
  (
    "broken legacy section, settings.json there: dropped, not an error",
    #"{"version": 1, "general": {"launchAtLogin": "yes"}}"#, "{}"
  ),
  ("broken legacy section, no settings.json: an error in config.json", #"{"general": {"launchAtLogin": "yes"}}"#, nil),
]

/// `SlatedConfiguration.decodeFiles` on config.json `input` (and settings.json `settingsInput`), then
/// both files as Swift writes them.
func configFilesJ(_ name: String, _ input: String, _ settingsInput: String?) -> J {
  var item: [String: J] = ["name": .string(name), "input": .string(input)]
  if let settingsInput { item["settingsInput"] = .string(settingsInput) }
  do {
    let files = try SlatedConfiguration.decodeFiles(
      config: Data(input.utf8), settings: settingsInput.map { Data($0.utf8) })
    if let legacy = files.legacy {
      item["legacy"] = [
        "loadSlateConfigs": .bool(legacy.loadSlateConfigs),
        "slateConfigPaths": legacy.slateConfigPaths.map { .array($0.map(J.string)) } ?? .null,
        "importedSlateShortcuts": .array(legacy.importedSlateShortcuts.map(J.string)),
        "settingsMoved": .bool(legacy.settingsMoved), "hadSettings": .bool(legacy.hadSettings),
      ]
    } else {
      item["legacy"] = .null
    }
    let config = files.configuration
    do {
      let known = input + (settingsInput ?? "")
      let configText = String(decoding: try config.encodedConfigFile(), as: UTF8.self)
      let settingsText = String(decoding: try config.encodedSettingsFile(), as: UTF8.self)
      item["config"] = .string(maskRandomUUIDs(configText, input: known))
      item["settings"] = .string(maskRandomUUIDs(settingsText, input: known))
      // Whether reading what Swift wrote gives the same configuration back (fn in hyperModifiers isn't
      // written, so it doesn't).
      let again = try SlatedConfiguration.decodeFiles(
        config: config.encodedConfigFile(), settings: config.encodedSettingsFile()
      ).configuration
      item["roundTrips"] = .bool(again == config)
    } catch {
      // Decoded, but JSON can't hold the value (infinity or NaN).
      item["encodeError"] = errorJ(error)
    }
  } catch let error as ConfigFileError {
    item["error"] = errorJ(error.error)
    item["errorFile"] = .string(error.file.rawValue)
  } catch {
    item["error"] = errorJ(error)
  }
  return .object(item)
}

func configurationFixtures() -> FixtureFile {
  let decode = (decodeCases + numberTokenCases).map { configFilesJ($0.0, $0.1, nil) }
  let files = fileCases.map { configFilesJ($0.0, $0.1, $0.2) }
  return FixtureFile(
    name: "config.json",
    description:
      "SlatedConfiguration.decodeFiles(config:settings:) (JSON5 allowed) on config.json `input` and settings.json "
      + "`settingsInput` (missing: no settings.json), then encodedConfigFile() and encodedSettingsFile(): `config` and "
      + "`settings` are the exact texts Swift writes (pretty, sorted keys). A version 1 config.json (or one with "
      + "general/settings/clipboard/automation/island) is `legacy`: its settings sections become settings.json's "
      + "(`settings` as `windows`) unless settingsInput is given, which wins; `legacy` is what it said about Slate files. "
      + "`error` and `errorFile` when a file can't be read; `encodeError` when the value decodes but JSON can't hold it. "
      + "UUIDs Swift generated for entries without an id read \"RANDOM-UUID\". `decode`: one config.json each, as a "
      + "version 1 file with everything in it; `files`: both files.",
    sections: ["decode": decode, "files": files],
    depth: ["decode": 2, "files": 2])
}

func starterFixtures() -> FixtureFile {
  let starter = SlatedConfiguration.starter
  let encoded = maskRandomUUIDs(String(decoding: try! starter.encodedConfigFile(), as: UTF8.self), input: "")
  let settings = String(decoding: try! starter.encodedSettingsFile(), as: UTF8.self)
  let bindings: [J] = starter.bindings.map { binding in
    [
      "name": .optional(binding.name), "keys": .string(binding.keys.string), "action": actionJ(binding.action),
      "format": .string(SlateSyntax.format(binding.action)),
    ]
  }
  return FixtureFile(
    name: "starter.json",
    description:
      "SlatedConfiguration.starter: the configuration a new install starts with (the author's Slate setup on the Hyper "
      + "key). `encoded` is its config.json, `encodedSettings` its settings.json. Binding ids are random in Swift, so "
      + "they read \"RANDOM-UUID\".",
    sections: ["bindings": bindings],
    extra: [
      "encoded": .string(encoded), "config": parseJ(encoded), "encodedSettings": .string(settings),
      "settings": parseJ(settings),
    ],
    depth: ["config": 1, "settings": 1])
}

private let slateValueInputs: [String] = [
  "true", "TRUE", "yes", "Yes", "false", "no", "NO", "1", "0", "1.5", "-2", "+3", ".5", "5.", "1e3", "0x10", "0x1p4",
  "inf", "-inf", "infinity", "Infinity", "nan", "NaN", "  42  ", "", "  ", "value with spaces", "1_000", "1,5",
  "screenSize", "1e400", "-0", "0.1", "１", "\t7\t", "nan(0x1)", "0X1F", "1.e2", ".e2", "e2", "1e", "--1", "0x", "0b101",
]

private let settingValues: [SettingValue] = [
  .bool(true), .bool(false), .number(1), .number(0), .number(0.5), .number(-0.0), .number(1e20), .number(1e15),
  .number(999999999999999), .number(1.5e-7), .number(42), .number(-3.25), .number(100), .string("true"), .string("YES"),
  .string("no"), .string("0"), .string("1"), .string("2"), .string("1.5"), .string("abc"), .string(""),
  .string("False"),
  .string(" 1"), .string("1e3"), .string("inf"), .string("0x10"),
]

private let typedInputs: [[String: SettingValue]] = [
  [:],
  [
    "defaultToCurrentScreen": .bool(true), "nudgePercentOf": .string("windowSize"),
    "resizePercentOf": .string("windowSize"),
    "orderScreensLeftToRight": .bool(false), "repeatOnHoldOps": .string("resize, nudge ,push,"),
    "secondsBeforeRepeat": .number(0.25), "secondsBetweenRepeat": .string("0.05"), "undoMaxStackSize": .number(20.9),
    "focusCheckWidth": .bool(true), "focusCheckWidthMax": .string("x"), "focusPreferSameApp": .string("no"),
    "checkDefaultsOnLoad": .number(2), "windowHintsCharacters": .number(123),
  ],
  ["undoMaxStackSize": .number(-3.7), "repeatOnHoldOps": .string(""), "nudgePercentOf": .number(1e20)],
  [
    "defaultToCurrentScreen": .string("maybe"), "orderScreensLeftToRight": .string("0"), "repeatOnHoldOps": .bool(true),
  ],
  // undoMaxStackSize values Int() can't convert (they used to crash Slated on the next window move).
  ["undoMaxStackSize": .number(.infinity)], ["undoMaxStackSize": .number(-.infinity)],
  ["undoMaxStackSize": .number(.nan)], ["undoMaxStackSize": .string("inf")], ["undoMaxStackSize": .string("nan")],
  ["undoMaxStackSize": .number(1e20)], ["undoMaxStackSize": .number(-1e20)], ["undoMaxStackSize": .number(-0.5)],
  ["undoMaxStackSize": .number(1e15 + 0.5)], ["undoMaxStackSize": .string("12.9")],
]

func settingsFixtures() -> FixtureFile {
  let fromSlate: [J] = slateValueInputs.map { ["input": .string($0), "value": settingJ(SettingValue(slate: $0))] }
  let accessors: [J] = settingValues.map { value in
    [
      "value": settingJ(value), "bool": value.boolValue.map(J.bool) ?? .null,
      "double": value.doubleValue.map(J.number) ?? .null, "string": .string(value.stringValue),
    ]
  }
  let typed: [J] = typedInputs.map { values in
    let s = SlateSettings(values)
    return [
      "settings": settingsJ(s), "defaultToCurrentScreen": .bool(s.defaultToCurrentScreen),
      "nudgePercentOf": .string(s.nudgePercentOf), "resizePercentOf": .string(s.resizePercentOf),
      "orderScreensLeftToRight": .bool(s.orderScreensLeftToRight),
      "repeatOnHoldOps": .array(s.repeatOnHoldOps.map(J.string)), "secondsBeforeRepeat": .number(s.secondsBeforeRepeat),
      "secondsBetweenRepeat": .number(s.secondsBetweenRepeat), "undoMaxStackSize": .int(s.undoMaxStackSize),
      "focusCheckWidth": .number(s.focusCheckWidth), "focusCheckWidthMax": .number(s.focusCheckWidthMax),
      "focusPreferSameApp": .bool(s.focusPreferSameApp), "checkDefaultsOnLoad": .bool(s.checkDefaultsOnLoad),
      "windowHintsCharacters": .string(s.windowHintsCharacters),
    ]
  }
  return FixtureFile(
    name: "settings.json",
    description:
      "Slate `config` values: SettingValue(slate:) for .slate text, the bool/double/string readings of each value, "
      + "and SlateSettings' typed accessors with Slate's defaults.",
    sections: ["fromSlate": fromSlate, "accessors": accessors, "typed": typed])
}
