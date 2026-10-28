# Configuration

Slated reads two kinds of configuration and uses both at once:

1. **Its own file**, `~/.config/slated/config.json`. The Settings window edits it, and you can too:
   it's plain JSON, and comments and trailing commas are allowed. Slated reloads it when it changes.
2. **Slate files**, `~/.slate.js` and `~/.slate`. They run exactly as they did in Slate. Their
   bindings show up read-only in Settings. Turn this off with `general.loadSlateConfigs`.

If both define the same shortcut, Slated's own binding wins and the other is marked as a duplicate.

**Importing.** "Import Slate Config into Slated…" copies what it can into `config.json`. When
everything converts, Slate files stop loading. When something can't (a function that needs the
script, say), they keep loading for it, and the shortcuts that were imported are listed in
`general.importedSlateShortcuts` (`"ctrl+alt+f16"`, or `"ctrl+alt+f6 x"` behind a modal key). Slated
ignores the Slate files' own bindings on those keys, so the imported copies are yours to change or
delete in Settings.

**Sections Slated doesn't know**, such as ones a newer version added, are kept as they are when
Slated saves `config.json`. Unknown fields inside a section it does know (say, a typo in `general`)
are ignored, and the next save drops them.

**Defaults.** On first launch Slated creates `config.json`:
- If you have a Slate config, Slated starts with no bindings of its own and your Slate file is the
  default.
- Otherwise it starts with the built-in bindings: the author's Slate setup on the Hyper key.
  - Halves: Hyper+A/D (left/right), W/X (top/bottom).
  - Quarters: Q/E/Z/C.
  - Thirds and two-thirds: F/G/H and V/B. They sit side by side on wide screens and stack on vertical
    and square ones.
  - Center: ' (small) and Return (large).
  - Maximize: S.
  - Grid: Tab.
  - Throw to the screen on the left/right/above: the arrow keys; ↓ throws to the second screen.

## Example

```jsonc
{
  "general": {
    "launchAtLogin": true,
    "loadSlateConfigs": true,          // also load ~/.slate.js and ~/.slate
    "showActionHUD": false             // name each action as it runs (in the notch island)
  },

  // Caps Lock becomes ⌃⌥⇧⌘ (Hyper) while held.
  "keyboard": {
    "capsLock": "hyper",               // "off" | "hyper"
    "capsLockAlone": "nothing",        // "nothing" | "escape"
    "hyperModifiers": ["ctrl", "alt", "shift", "cmd"]
  },

  "bindings": [
    {
      "name": "Left half",
      "keys": "hyper+a",
      "action": { "op": "move", "x": "screenOriginX", "y": "screenOriginY",
                  "width": "screenSizeX/2", "height": "screenSizeY" }
    },
    { "keys": "hyper+w", "action": "push top bar-resize:screenSizeY/2" },   // Slate syntax works too
    { "keys": "hyper+right", "action": { "op": "throw", "screen": "right",
                                         "width": "screenSizeX", "height": "screenSizeY" } },
    { "keys": "hyper+tab", "action": "grid padding:4 0:6,6 1:6,6" }
  ],

  "hotstrings": [
    { "trigger": ";shrug", "replacement": "¯\\_(ツ)_/¯" },
    { "trigger": "brb", "replacement": "be right back", "fire": "afterDelimiter", "wordBoundary": true },
    { "trigger": ";today", "replacement": "{date:yyyy-MM-dd}" }
  ],

  // Slate's global settings (`config name value` in .slate files).
  "settings": { "defaultToCurrentScreen": true, "nudgePercentOf": "screenSize" }
}
```

## Shortcuts

`keys` is modifiers plus a key joined with `+`: `hyper+a`, `ctrl+cmd+left`, `cmd+shift+'`.

- **Modifiers:** `ctrl`, `alt` (or `opt`), `shift`, `cmd`, `fn`, plus the shorthands `hyper`
  (all four) and `meh` (all but `cmd`). `keyboard.hyperModifiers` takes the same names; an unknown
  one is an error, so Slated never guesses what Caps Lock should send.
- **Keys:** use Slate's names:
  - letters, digits and punctuation;
  - `left` `right` `up` `down` `return` `tab` `space` `delete` `esc` `home` `end` `pageUp` `pageDown`;
  - `f1`…`f20`;
  - keypad keys `pad0`…`pad9`, `pad+`, `padEnter`.

Letters follow your keyboard layout: `hyper+a` means the key labeled A on AZERTY too.

Slate's modal keys: `"modal": { "keys": "ctrl+alt+f4", "toggle": false }` means press ⌃⌥F4, then the
binding's own `keys`.

## Actions

An action is either Slate operation syntax (`"push left bar-resize:screenSizeX/2"`) or an object
with `"op"` plus Slate's JavaScript parameter names. The object form is exactly what
`slate.operation(name, params)` takes in `.slate.js`.

| op | parameters |
|---|---|
| `move` | `x`, `y`, `width`, `height` (expressions), `screen` |
| `resize` | `width`, `height` (`"+10%"`, `"-100"`, or expressions), `anchor` (`top-left`…) |
| `push` | `direction` (`left` `right` `top` `bottom`), `style` (`none` `center` `bar` `bar-resize:<expr>`), `screen` |
| `nudge` | `x`, `y` (`"+10%"`, `"-100"`) |
| `throw` | `screen`, optional `width`/`height` |
| `corner` | `direction` (`top-left` `top-right` `bottom-left` `bottom-right`), optional `width`/`height`, `screen` |
| `chain` | `operations`: each press runs the next one |
| `sequence` | `operations` (or `steps` with `keepWindow` for Slate's `>`) |
| `layout` | `name` |
| `focus` | `direction` (`left` `right` `up` `down` `behind`) or `app` |
| `snapshot` / `activate-snapshot` / `delete-snapshot` | `name`, plus `save`/`stack`, `delete`, `all` |
| `hint` | optional `characters` |
| `grid` | `padding`, `grids` (`{"0": {"width": 6, "height": 6}}`) |
| `hide` / `show` / `toggle` | `app`: `"current"`, `"all"`, `"all-but:Name"`, or a list of names |
| `shell` | `command`, `wait`, `path` |
| `undo`, `relaunch` | — |
| `switch` | — (Slate's app switcher: accepted so Slate files load, but it does nothing yet and says so when run) |
| `by-orientation` | `landscape`, `portrait`: two actions; runs the one matching the shape of the window's screen (a square screen counts as portrait) |
| `insert-text` | `text`, `method` (`auto` `type` `paste`) |
| `open-url` | `url` |
| `keystroke` | `keys` (e.g. `"cmd+shift+4"`) |
| `clipboard-history` | — (opens the [clipboard switcher](#clipboard-history), like `clipboard.shortcut`) |

**Screens** (`screen`): an index (`0` is the leftmost display), `ordered:N`, a resolution
(`1680x1050`), a direction (`left` `right` `up` `down`), or `next`/`previous`.

**Expressions** are Slate's:
- Variables: `screenOriginX`, `screenOriginY`, `screenSizeX`, `screenSizeY` (the target screen,
  minus menu bar and Dock), and `windowTopLeftX`, `windowTopLeftY`, `windowSizeX`, `windowSizeY`.
- Operators: `+ - * / **` and parentheses.
- Functions: `min({a,b})`, `max`, `floor`, `ceiling`, `abs`, `sqrt`, and the rest of Slate's list.
- Unlike Slate, spaces are fine.
- An expression can have up to 1,000 numbers, variables and function calls, nested up to 200 levels.

## Display defaults

Slate's `default`: when your displays change to match a setup, run a layout or snapshot. Each one has
a `target` (the layout or snapshot's name) and one condition:

```jsonc
"defaults": [
  { "target": "coding", "count": 2 },                              // any two displays
  { "target": "big", "resolutions": ["2560x1440", "1920x1080"] }  // exactly these, in any order
]
```

Resolutions are each display's full size. Slated used to write the condition as
`"condition": {"count": {"_0": 2}}`; that still reads, and the next save writes the shape above.

## Game automation

Bind these like any other action. They're deliberately simple: no scripting language.

| op | parameters | what it does |
|---|---|---|
| `click` | `button` (`left` `right` `middle`), `count` (2 = double-click) | Click where the pointer is |
| `hold` | `input` (`mouse:left`, `mouse:right`, `key:w`, `key:shift`…) | First press holds it down, next press releases |
| `press` | `input`, `phase` (`down` / `up`) | One half of a press, for macros |
| `repeat` | `action`, `interval` (seconds), `mode` (`toggle` / `while-held`), `times`, `jitter` (0–0.5) | Auto-repeat: an auto-clicker or key spammer |
| `wait` | `seconds` | Pause inside a `sequence` (macro) |
| `stop-automations` | — | Stop everything and release anything held |

Modifier keys can be held (`key:shift`, `key:ctrl`, `key:alt`, `key:cmd`, `key:rightShift`…) but
aren't shortcuts on their own. Mouse buttons 3–5 (`mouse3` middle, `mouse4`, `mouse5` side buttons)
can be shortcuts, with or without modifiers (macOS).

Add `"onlyInApps"` to a binding to make it work only in a game. Then plain keys are fine as triggers.
Find a game's bundle identifier with `osascript -e 'id of app "Minecraft"'`.

```jsonc
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
```

Safety rails:
- Slated never leaves a button or key held down. Pausing Slated, sleep, locking the screen and
  quitting all release everything.
- A macro waiting between steps (a `wait`, or a `shell` step with `wait`) counts as running even if
  it holds nothing: the stop shortcut, leaving its app, the time limit, pausing, sleep, locking the
  screen and quitting drop the steps it has left. The indicator doesn't list it.
- Many games accept synthesized input, but online games with anti-cheat may block it or forbid it in
  their terms.

**On Linux (GNOME)** the same config works, with a few differences:
- GNOME can't use mouse buttons as shortcuts, so `mouse3`–`mouse5` show as "Couldn't register". Map
  the side button to a key with keyd (e.g. `mouse1 = f13`) and bind that key (`f13`…`f20`).
- `while-held` notices you let go through GNOME's key repeat, so it stops about 0.1 s after you let
  go, and right away if you press another key. With key repeat off (GNOME Settings → Keyboard), when
  the repeated action types keys (`keystroke`, `insert-text`, `key:` inputs), or behind a modal key,
  it works like `toggle`: press the shortcut again to stop.
- In `onlyInApps`, write the app's desktop file id, with or without `.desktop`
  (`org.prismlauncher.PrismLauncher`). Games without one, such as Steam/Proton games, go by their
  window's WM_CLASS (`steam_app_1086940`). `recentApps` in `~/.local/state/slated/status.json`
  lists the ids of the apps you used lately.
- The overview counts as leaving the app: automations stop, and a game's plain-key bindings let go
  of their keys while it's open.
- `cmd` is the Super key, so the stop shortcut `hyper+esc` is Ctrl+Alt+Shift+Super+Esc. With Caps
  Lock as Hyper through GNOME's own option, Hyper often shares Super's modifier, and Super+Esc is
  GNOME's; pick another stop shortcut if it shows "Couldn't register".
- Slated's Settings → Automation has the recipes and the safety settings, and a shortcut's **Works
  In** picks `onlyInApps` from the apps you used lately or installed apps.

## Notch island (macOS)

A black capsule that grows out of the MacBook notch, or hangs from the top center of a display
without one. It shows:
- **Running automations.** Hover over it to see each one and a Stop button.
- **The Hyper cheat sheet.** Hold Caps Lock for a moment and every Hyper shortcut appears, grouped
  and in keyboard order. Shortcuts still work while it's up; the one you press lights up.
- **Modal keys.** After a modal key, the island shows it, then lists the keys it offers.
- **Feedback** when `general.showActionHUD` is on ("Left half · Safari"), and why a shortcut
  couldn't run ("No focused window to move").

```jsonc
"island": {
  "enabled": true,          // false: no island; feedback and the automation indicator use pills
  "cheatSheet": true,       // hold Caps Lock (or press a modal key) to list its shortcuts
  "cheatSheetDelay": 0.5,   // seconds; quick Hyper combos never show it
  "showFailures": true      // briefly say why a shortcut couldn't run
}
```

With `"capsLockAlone": "escape"`, holding Caps Lock longer than the cheat-sheet delay doesn't send
Escape when you let go.

The GNOME version reads and keeps these settings but doesn't show an island yet.

## Clipboard history

```jsonc
"clipboard": {
  "enabled": true,
  "shortcut": "cmd+shift+v",      // opens the picker; null turns it off
  "maxItems": 200,
  "persist": true,                // kept across restarts, readable only by you
  "retentionDays": 30,            // pinned items are kept regardless
  "ignoreConcealed": true,        // skip what password managers mark as secret
  "excludedApps": ["com.1password.1password", "com.bitwarden.desktop"],
  "pasteAfterSelecting": true
}
```

The picker opens just below the text caret of the app you're typing in (above it near the bottom
of the screen). When the app doesn't say where its caret is, it opens below the focused field, and
failing that at the mouse pointer; opened from Slated's own window, at the pointer.
- Type to filter; ↑↓ (or the pointer) select an item and ↩ or a click pastes it into the app you
  were using (with `pasteAfterSelecting` off, it's only copied).
- ⌘1–9 picks one of the first nine directly, and esc closes.
- Pinned items come first. Pin, copy, delete, search and browse everything in Settings → Clipboard.

Copied images (PNG or TIFF without text: screenshots, Copy Image in a browser, Preview) are kept
too, up to 20 MB each, as files readable only by you in
`~/Library/Application Support/Slated/clipboard-images/`. A row shows a thumbnail; selecting it
shows the image larger beside the picker. Searching matches text only. Deleting, clearing or
expiring an image deletes its file, and with `persist` off they're deleted at quit. In clipboard.json
an image is an item with empty `text` and an `image` object (`file`, `width`, `height`, `bytes`).

**On the Mac** the old switcher's ⌘C, ⌘P and ⌘⌫ are gone: copy, pin and delete in Settings.

**On Linux (GNOME)** the history opens in a switcher (↑↓, ↩, esc, and Ctrl+1–9, Ctrl+C copy,
Ctrl+P pin, Ctrl+Backspace delete), and Ctrl+Shift+Backspace clears everything but pinned items.
Picking an item pastes with Ctrl+V, or Ctrl+Shift+V in terminals. It records and lists text only;
image items in a clipboard.json from the Mac are kept, not shown.
- The default shortcut `cmd+shift+v` is Super+Shift+V.
- History is kept in `~/.local/state/slated/clipboard.json`, readable only by you, in the same format
  as on the Mac.
- `ignoreConcealed` skips copies that password managers mark as secret (KeePassXC, Firefox and
  others add `x-kde-passwordManagerHint`). Chrome and other Chromium browsers don't mark copied
  passwords on Linux, so from those it also skips anything that looks like a password: one word with
  upper- and lowercase letters plus a digit or symbol. On the Mac, Chrome and Firefox mark them.
- `excludedApps` takes GNOME app ids, such as `org.keepassxc.KeePassXC` or `com.bitwarden.desktop`.
- Only text is kept, not images or files.
- Slated's Settings → Clipboard edits all of these and shows how many items are saved; on GNOME
  the items themselves are in the switcher.

## Hotstrings

| field | meaning |
|---|---|
| `trigger` | What you type, e.g. `;sig`. |
| `replacement` | The text that replaces it. Placeholders: `{date}`, `{time}`, `{datetime}`, `{clipboard}`, `{date:yyyy-MM-dd}`. Use `{{` / `}}` for literal braces. |
| `fire` | `immediately` (default) or `afterDelimiter`: wait for a space, return or punctuation, which is kept. |
| `caseSensitive` | Default `true`. |
| `wordBoundary` | Only when the trigger starts a word. Default `false`. |
| `method` | `auto` (type short text, paste long text), `type`, or `paste`. Pasting restores your clipboard afterwards. |
| `onlyInApps` / `exceptInApps` | Bundle identifiers, e.g. `com.apple.mail`. |
| `action` | Optional action to run after inserting. |

Hotstrings and the Hyper key don't work while macOS Secure Input is on: password fields, or
Terminal with Secure Keyboard Entry enabled. macOS hides keystrokes from every app then.
