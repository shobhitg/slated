# Configuration

Slated reads two kinds of configuration and uses both at once:

1. **Its own file**, `~/.config/slated/config.json`. The Settings window edits it, and you can too:
   it's plain JSON, and comments and trailing commas are allowed. Slated reloads it when it changes.
2. **Slate files**, `~/.slate.js` and `~/.slate`. They run exactly as they did in Slate. Their
   bindings show up read-only in Settings. Turn this off with `general.loadSlateConfigs`.

If both define the same shortcut, Slated's own binding wins and the other is marked as a duplicate.

**Defaults.** On first launch Slated creates `config.json`:
- If you have a Slate config, Slated starts with no bindings of its own and your Slate file is the
  default.
- Otherwise it starts with the built-in bindings: the author's Slate setup on the Hyper key.
  - Halves: Hyper+A/D (left/right), W/X (top/bottom).
  - Quarters: Q/E/Z/C.
  - Thirds and two-thirds: F/G/H and V/B. They sit side by side on wide screens and stack on vertical
    ones.
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
  (all four) and `meh` (all but `cmd`).
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
| `by-orientation` | `landscape`, `portrait`: two actions; runs the one matching the window's screen shape |
| `insert-text` | `text`, `method` (`auto` `type` `paste`) |
| `open-url` | `url` |
| `keystroke` | `keys` (e.g. `"cmd+shift+4"`) |

**Screens** (`screen`): an index (`0` is the leftmost display), `ordered:N`, a resolution
(`1680x1050`), a direction (`left` `right` `up` `down`), or `next`/`previous`.

**Expressions** are Slate's:
- Variables: `screenOriginX`, `screenOriginY`, `screenSizeX`, `screenSizeY` (the target screen,
  minus menu bar and Dock), and `windowTopLeftX`, `windowTopLeftY`, `windowSizeX`, `windowSizeY`.
- Operators: `+ - * / **` and parentheses.
- Functions: `min({a,b})`, `max`, `floor`, `ceiling`, `abs`, `sqrt`, and the rest of Slate's list.
- Unlike Slate, spaces are fine.

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
