# Slated for Linux (GNOME)

Slated for Linux is a **GNOME Shell extension** with a settings window. It uses the same files as
the Mac app: your Slated `config.json`, `~/.slate.js` and `~/.slate`.

> **Status:** early development, for GNOME 46–51 (Ubuntu 24.04 to 26.04, Fedora 40 to 45). It was
> written and reviewed against GNOME 46–49; 50 and 51 load it but haven't been tested yet. There's no
> extensions.gnome.org release yet, so install from source.

## Why an extension

On Wayland, apps can't move other apps' windows or watch the keyboard. Only GNOME Shell can, so
Slated runs inside it, like other GNOME window-management tools. That brings some limits, covered
under [Limitations](#limitations): it works only on GNOME, and updates load when you next log in.

| Part | What it does | Where |
|---|---|---|
| Extension | Window management, shortcuts, overlays, Slate configs, the Hyper key, espanso's match file, game automation, clipboard history, status and log | `linux/gnome-extension/extension.js`, `lib/platform/` |
| Engine | Expressions, Slate syntax, window math and config: the JavaScript port of `SlatedCore` | `linux/gnome-extension/lib/core/` |
| Settings | The libadwaita preferences window: GNOME's version of the Mac settings app | `linux/gnome-extension/prefs.js`, `lib/prefs/` |

## Install

You need GNOME 46–51, `git`, `python3` and `gnome-extensions` (it comes with GNOME Shell).

```sh
git clone https://github.com/shobhit-aida/slated && cd slated
linux/install.sh
linux/install.sh --hyper-keyd     # once: the recommended Hyper key (needs keyd; asks for your password)
```

You can run `linux/install.sh` as often as you like. Each run:

1. Packs the extension and stamps it with `build-info.json` (version, git commit, build date).
2. Installs it into `~/.local/share/gnome-shell/extensions/`, replacing the previous copy, and enables it.
3. Checks Slated's log to see which build GNOME Shell is running.

**Then log out and back in.** On Wayland, GNOME Shell loads a new or updated extension only at
login. Once you're back:

```sh
linux/install.sh --verify     # prints "Running: build abc1234" once the new build is live
gnome-extensions prefs slated@shobhit-aida.github.io    # opens Slated's settings (also in the Extensions app)
```

| | |
|---|---|
| `linux/install.sh --nested` | Also start a nested GNOME Shell with the new build, so you don't have to log out (see [Development](#development)) |
| `linux/install.sh --verify` | Only report which build GNOME Shell is running |
| `linux/install.sh --check` | Run the Linux tests first (needs Node), and install only if they pass |
| `linux/install.sh --uninstall` | Remove the extension but keep config and logs. Add `--purge` to also remove those, Slated's espanso match file and its keyd config |
| `linux/install.sh --hyper-keyd` | Make Caps Lock the Hyper key through keyd (asks before using sudo) |
| `make linux-install`, `make linux-pack` | Same as `linux/install.sh` and `linux/install.sh --pack-only` |

Below, "Settings" means Slated's settings window, and "GNOME Settings" means GNOME's.

### The Hyper key

Turn on **Use Caps Lock as Hyper** in **Settings → Keyboard**. **keyd is the recommended way:**
Caps Lock then works exactly like the Mac's Hyper key. Install keyd from your distribution (or
[github.com/rvaiya/keyd](https://github.com/rvaiya/keyd)) and run `linux/install.sh --hyper-keyd`
once. Until keyd is set up, Slated uses GNOME's own keyboard option (`caps:hyper`), which it sets
itself and removes again when you turn the Hyper key off. The Keyboard page shows which method is
active, and `linux/install.sh` reminds you while keyd isn't set up.

| | GNOME's keyboard option (xkb) | keyd |
|---|---|---|
| Setup | Nothing to install | `linux/install.sh --hyper-keyd` (installs `/etc/keyd/slated.conf`; asks for sudo) |
| What Caps Lock does | Acts as the Hyper modifier | Sends Ctrl+Alt+Shift+Super, like the Mac's Hyper key |
| Tap alone for Escape | Not possible | Yes, if the tap is turned on |
| Meh (Ctrl+Alt+Shift, no Super) | Not possible | Yes |

In many keyboard layouts, GNOME's option puts Hyper on the same modifier as Super. GNOME then treats
✦A and Super+A as the same shortcut. keyd avoids that.

keyd's configuration is a system file that the extension can't change. The installer writes it from
`config.json`, using `keyboard.capsLockAlone` (tap for Escape) and `keyboard.hyperModifiers` (Meh).
**After changing either in Settings, run `linux/install.sh --hyper-keyd` again.** `--tap-escape`
turns the tap on whatever `config.json` says. If keyd already has another configuration, the
installer doesn't write its own. Instead it prints the lines to add to yours. To remove it, run
`linux/install.sh --hyper-keyd --remove`.

### Hotstrings

On GNOME, an extension can't type into other apps, so Slated hands your hotstrings to
[espanso](https://espanso.org). It writes them to `~/.config/espanso/match/slated.yml` and keeps
that file in sync with `config.json`. Install espanso's Wayland build
([instructions](https://espanso.org/install/linux/)), then run:

```sh
espanso service register && espanso start
```

**Settings → Hotstrings** shows whether espanso is installed and in sync. espanso can't tell which
app you're typing in on GNOME, so app filters only work on the Mac. A hotstring limited to some apps
(`onlyInApps`) doesn't expand on GNOME at all. A hotstring with exceptions (`exceptInApps`) expands
everywhere. Hotstrings that run Slated actions don't work through espanso. Slated logs once which
hotstrings it couldn't pass on.

## Settings

The settings window has the same sections as the Mac app, listed in a sidebar:

| Section | What's there |
|---|---|
| Overview | Whether Slated is running (from GNOME Shell and `status.json`) and what to do if it isn't, the last action and error, a getting-started checklist, and tips |
| Windows | Your shortcuts plus your Slate files' shortcuts (read-only), searchable, with keycaps and status. Automations get their own group. The editor records shortcuts (✦ for Hyper), offers every action and the Mac presets, previews where the window will land, and limits a shortcut to some apps (**Works In**) |
| Hotstrings | Triggers, replacements, a try-it field, espanso's status, and app filters (Mac only) |
| Clipboard | Clipboard history on or off, its shortcut, paste after picking, how much to keep and for how long, privacy (secrets, excluded apps), and the switcher's keys. Shows how many items are saved |
| Automation | What runs now, your automations, eleven recipes (auto-click, hold a button or key, sprint and crouch toggles, spam a key, click N times, double-click, a walk-then-click macro), the safety settings, and what GNOME does differently |
| Keyboard | Caps Lock as Hyper, which method is active, tap for Escape, Hyper or Meh |
| Layouts | Arrange several apps at once. Layouts from Slate files are read-only |
| Slate Compatibility | Your Slate files' status and problems, **Import into Slated**, and which files to load |
| General | Turn Slated on or off, the action banner, window behavior, where the config and log are, and this build |
| About | Version, credits, license, and debug information for bug reports |

Adding a recipe makes an ordinary shortcut and opens its editor with the shortcut recorder running;
free function keys are suggested. **Works In → Only in some apps** offers the apps you used lately
(from `recentApps` in `status.json`, so games without a desktop file are there too, by window class)
and your installed apps, or takes an id you type. Limited to apps, a shortcut can be a plain key like
F. A shortcut on a mouse button (from the Mac) says GNOME can't use it and how to map the button
with keyd. The editor has the Mouse & Keys actions: click, press or release, hold down, auto-repeat
(what repeats, how often, toggle or while held, a number of runs, humanized timing), wait and stop
automations.

Changes save as you make them, after a short pause. Anything with an error, such as a half-typed
expression or an empty trigger, is flagged where you edit it and isn't written to `config.json`
until you fix it. If `config.json` can't be read, Settings stops saving so nothing in the file is
lost, and the Overview shows the error.

**Import into Slated** runs your `~/.slate.js` on a stand-in desktop with one landscape and one
portrait screen. Each shortcut whose function always does the same thing becomes an ordinary
Slated shortcut. One that does different things on the two screens becomes a `by-orientation`
shortcut. Shortcuts that need JavaScript while they run stay in your Slate file, and the import
lists them with the reason. If everything converts, Slated stops loading your Slate files. You can
turn that back on in Slate Compatibility. Otherwise the Slate files keep loading for the rest.

## Files

| File | Written by | |
|---|---|---|
| `~/.config/slated/config.json` | Settings (and you) | The configuration, shared with the Mac app (see [CONFIG.md](CONFIG.md)). The extension watches it and applies changes. |
| `~/.local/state/slated/status.json` | Extension | What's running, read by the settings window (format below) |
| `~/.local/state/slated/slated.log` | Extension and settings | The event log: JSON Lines with the same events as on the Mac (`app.start`, `action.done`, `config.saved`, `ui.*`…) |
| `~/.local/state/slated/snapshots.json` | Extension | Saved window snapshots |
| `~/.local/state/slated/clipboard.json` | Extension | Clipboard history, readable only by you (mode 0600), in the Mac app's format. Not written when `clipboard.persist` is off |
| `~/.config/espanso/match/slated.yml` | Extension | Your hotstrings, for espanso |
| `~/.local/share/gnome-shell/extensions/<uuid>/build-info.json` | `linux/install.sh` | `{"version", "commit", "builtAt", "build"}` of the installed build |

These locations follow `$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` if you set them. As on the Mac,
`SLATED_HOME` replaces the home folder and `SLATED_CONFIG` replaces the config file path. Tests use
these to point everything at a throwaway home.

`status.json`:

```json
{"session": "abcd1234", "version": "0.1.0", "running": true, "updatedAt": "2026-10-22T18:00:00.000Z",
 "hyper": {"wanted": true, "mode": "xkb", "active": true},
 "hotstrings": {"engine": "espanso", "espansoInstalled": true, "matchFile": "~/.config/espanso/match/slated.yml", "count": 3},
 "hotkeys": {"hyper+a": "active", "hyper+q": "failed: <reason>", "hyper+w": "duplicate", "hyper+z": "disabled"},
 "sources": [{"path": "~/.slate.js", "kind": "javascript", "exists": true, "loaded": true, "bindings": 21, "diagnostics": []}],
 "screens": [{"displayID": 1, "name": "Built-in display", "isMain": true, "scale": 1,
              "frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
              "visibleFrame": {"x": 0, "y": 32, "width": 1920, "height": 1048}}],
 "automation": {"running": ["Repeat click left every 100 ms"], "shortcuts": ["f6"], "stopShortcut": "hyper+esc", "whileHeld": "key-repeat"},
 "clipboard": {"enabled": true, "items": 12},
 "recentApps": [{"id": "steam_app_1086940", "name": "steam_app_1086940"}, {"id": "firefox", "name": "Firefox"}],
 "lastAction": "Left half · firefox", "lastError": null}
```

- The keys in `hotkeys` are config key strings. For modal bindings, the modal key and a space come
  first: `"ctrl+alt+f4 1"`.
- `screens` is optional, in top-left global coordinates. When it's there, previews use your real
  displays. Otherwise they use two sample displays.
- While the extension is running, the settings window logs under its `session`, so
  `scripts/logs.py --session last` shows events from both.
- `automation.running` lists what runs now, as the indicator shows it, and `shortcuts` the keys (as in
  `hotkeys`) of the shortcuts that started it. `whileHeld` is `key-repeat` when `while-held` repeats
  stop as you let go, or `toggle` when keyboard repeat is off in GNOME Settings and they need a
  second press.
- `recentApps` are the apps you used lately, newest first: the ids `onlyInApps` takes.

## Feature parity with macOS

| Feature | macOS | GNOME |
|---|---|---|
| Window operations: move, resize, push, nudge, throw, corner, chain, sequence, by-orientation | Accessibility API | Inside GNOME Shell (Mutter) |
| Layouts, applied automatically when your displays change | ✓ | ✓ |
| Directional focus, window hints, grid, snapshots, undo | ✓ | ✓ (overlays drawn by GNOME Shell) |
| Global shortcuts | Carbon hot keys | GNOME Shell key bindings. Shortcuts GNOME already uses can't be taken and show as failed |
| Hyper key (Caps Lock → ⌃⌥⇧⌘) | Built in (key remapping and an event tap) | GNOME's `caps:hyper` option, or keyd for the full Ctrl+Alt+Shift+Super |
| Caps Lock tapped alone → Escape | ✓ | With keyd |
| Hotstrings | Built in, with per-app filters | Through espanso, which Slated keeps in sync. No per-app filters |
| `insert-text`, `keystroke`, `open-url`, `shell` actions | ✓ | ✓ |
| `~/.slate.js`, `~/.slate` | JavaScriptCore | GJS, inside GNOME Shell |
| Settings | SwiftUI window | libadwaita window |
| Status at a glance | Menu bar | Settings → Overview |
| Start at login | Login item | Runs with your session while the extension is enabled |
| Permissions | Accessibility, granted once | None needed |
| Installing an update | `./install.sh` relaunches the app | Log out and back in (Wayland) or Alt+F2 `r` (Xorg). A nested shell lets you try it first |
| Logs | `~/Library/Logs/Slated`, Console.app | `~/.local/state/slated`, `journalctl` |
| Game automation: `click`, `press`, `hold`, `repeat` (`times`, `jitter`), `wait` in macros, `stop-automations` | Synthesized events | ✓ Through a virtual pointer and keyboard, like GNOME's on-screen keyboard |
| `repeat … while-held` | Stops on key-up | Stops about 0.1 s after you let go, noticed through key repeat. Works like `toggle` with key repeat off or for repeats that type keys |
| Mouse buttons 3–5 as shortcuts | ✓ | Not possible in GNOME. Map them to F13–F20 with keyd |
| Shortcuts only in some apps (`onlyInApps`) | Bundle ids | Desktop ids or WM_CLASS. Grabbed only while the app has focus |
| Automation safety: stop shortcut, stop on app switch, time limit, the "running" indicator | ✓ | ✓ The overview counts as leaving the app, and a macro waiting on a `wait` counts as running even when it holds nothing. Disabling, locking the screen and config reloads release everything |
| Clipboard history and its switcher | ✓ | ✓ Text only. Ctrl instead of ⌘ in the switcher |
| Settings → Clipboard | Recent items with pin, copy and delete | Settings only, and how many items are saved. Pin, delete and clear in the switcher |
| Settings → Automation | Running Now with Stop All | Lists what runs. Stop it with the stop shortcut |
| Notch island (automation status, Hyper cheat sheet, feedback) | ✓ | Not yet. Its `island` settings are kept as they are |

## Limitations

- **GNOME only, within Wayland's rules.** Other desktops would need their own extension or a
  different approach.
- **GNOME 46–51.** The extension declares those versions; newer ones mark it as unsupported until
  it's tested and added. GNOME 50 and 51 are declared but not yet tested.
- **Updates load at your next login.** GNOME Shell can't reload an extension's code while it's
  running. In an Xorg session (GNOME 48 and earlier), Alt+F2 `r` restarts GNOME Shell instead. Use
  the nested shell while developing (see below). The settings window runs as a separate process, so
  closing and reopening it picks up a new build right away.
- **Hotstrings need espanso**, which has its own setup on Wayland. App filters and action hotstrings
  only work on the Mac.
- **The full Hyper key needs keyd**, a system service installed with sudo. GNOME's own option can't
  do the tap-for-Escape or Meh, and in many layouts it shares a modifier with Super.
- **Shortcuts GNOME already uses** (Super+A, Super+Tab…) stay GNOME's, and Slated reports them as
  failed. Pick other keys, or change GNOME's in GNOME Settings → Keyboard → Keyboard Shortcuts.
- **`~/.slate.js` runs inside GNOME Shell.** An endless loop in it freezes the whole desktop, not
  just Slated. Errors show up in Settings → Slate Compatibility.
- **GNOME reports only key presses, not releases.** `repeat … while-held` notices that you let go
  when the key's auto-repeat stops: about 0.1 s later, or as soon as you press or release another
  key, since GNOME repeats only the last key pressed. With key repeat turned off in GNOME Settings, or
  for repeats that type keys themselves, a second press stops it instead.
- **Mouse buttons can't be shortcuts in GNOME.** Bindings on `mouse3`–`mouse5` show as failed. Map
  the side buttons to keys with keyd, then bind those keys (`f13`…`f20`). In keyd the side buttons
  are usually `mouse1` and `mouse2`, and keyd only reads a mouse that its `[ids]` section lists.
  Check `man keyd` for your version's syntax; for example:

  ```ini
  [ids]
  m:046d:c52b        # your mouse's vendor:product (`keyd monitor` shows it)

  [main]
  mouse1 = f13       # back
  mouse2 = f14       # forward
  ```
- **Synthesized input in games.** Most games take it, like input from an on-screen keyboard, but
  online games with anti-cheat may ignore it or forbid it in their terms.
- **Clipboard history keeps text only**, from any app. Only copies made while Slated runs are
  recorded.

## Development

```sh
linux/install.sh --nested    # install, then start a nested GNOME Shell running the new build
```

The nested shell is a GNOME Shell in a window. On GNOME 49 it starts with
`dbus-run-session gnome-shell --devkit`, which needs Mutter's devkit viewer (Fedora packages it as
`mutter-devkit`). On GNOME 48 and earlier it starts with
`dbus-run-session -- gnome-shell --nested --wayland`. It loads the extension fresh, so you can see a
change without logging out. It shares your settings, `config.json` and log with your real session.
`--nested` waits for the new build's `app.start` in the log and reports it.

| What you changed | How to see it |
|---|---|
| Settings window (`prefs.js`, `lib/prefs/`) | Run `linux/install.sh`, then close and reopen the settings window |
| Extension or engine | Run `linux/install.sh --nested`, or run `linux/install.sh` and log out and back in |

Tests (CI runs all of them on Ubuntu 24.04, which has GNOME 46):

| Command | What it covers |
|---|---|
| `make linux-test` | The engine under Node, held to the Swift behavior by golden vectors. `gjs -m linux/tests/run.mjs` runs the same tests under GJS |
| `make linux-test-prefs` | The settings logic (model, validation, presets, automation recipes, import, status), plus the whole settings UI driven on mock GTK and libadwaita |
| `make linux-test-prefs-gjs` | The settings logic tests under GJS |
| `make linux-test-gtk` | The settings window on real GTK 4 and libadwaita (needs `gjs gir1.2-adw-1 xvfb dbus`) |
| `make linux-test-extension` | The extension's runtime against a simulated GNOME Shell: shortcuts, per-app grabs, automation timing and safety stops, clipboard history, status and log (Node 22.15+) |
| `make linux-test-installer` | `linux/install.sh` against stand-ins for GNOME's tools, plus `scripts/logs.py`'s log locations |
| `linux/tests/gnome/run.sh` | The extension in a real GNOME Shell |
| `node linux/tests/prefs/coverage.mjs` | Which settings code no test runs |

The UI test's mocks are built from GObject introspection data. `linux/tests/prefs/gi/api.json` lists
every class, method, property and signal in GTK 4.14 and libadwaita 1.5 (GNOME 46). It also lists
what GTK 4.20 and libadwaita 1.8 (GNOME 49) added or deprecated. Code may use newer API only behind
an `'name' in object` check. The test runs twice: once with only GNOME 46's API, and once with
GNOME 49's. `gi/build-api.py` regenerates `api.json` from the `.gir` files in the distributions'
`-dev` packages (its header explains how). `gi/adwaita-icons.txt` lists the symbolic icons that both
Adwaita versions have, and the test checks every icon name against it.

## Troubleshooting

Start with the logs:

```sh
journalctl -f -o cat /usr/bin/gnome-shell    # GNOME Shell's log: extension errors and stack traces
scripts/logs.py --session last               # Slated's events since GNOME Shell last started it
scripts/logs.py --errors --since 1h          # problems in the last hour
make logs                                    # follow Slated's log live
journalctl --user -f -o cat                  # everything in your session, including the settings window
```

| Problem | What to do |
|---|---|
| Settings says "Log out and back in to start Slated" | GNOME Shell hasn't loaded the extension yet (a new install or an update on Wayland). Log out and back in, then run `linux/install.sh --verify`. |
| The Extensions app shows Slated with an error | The error is in `journalctl -o cat /usr/bin/gnome-shell`. **Settings → Overview** also shows GNOME Shell's message. |
| Settings says "A newer build is installed" | GNOME Shell is still running the previous build. Log out and back in. |
| Settings says "This GNOME version isn't supported yet" | You're on GNOME 50 or later (see [Limitations](#limitations)). |
| A shortcut says "Couldn't register" | GNOME or another extension already uses those keys. Pick other keys, or free them in GNOME Settings → Keyboard → Keyboard Shortcuts. |
| Caps Lock isn't Hyper | Settings → Keyboard shows which method is active and whether it works. With keyd, check `sudo systemctl status keyd`. |
| Hotstrings don't expand | Settings → Hotstrings shows espanso's status. Check `espanso status` and `espanso log`. |
| Editing `config.json` by hand changes nothing | The file must be valid JSON (comments and trailing commas are fine). Settings → Overview shows what's wrong, and `scripts/logs.py --errors` shows what the extension saw. |
| Settings says it can't read `config.json` | The message names the spot, such as `bindings[2].id`. Ids must be UUIDs: delete a bad `"id"` line and Slated makes a new one. Settings won't save until the file reads, so nothing in it is lost. Operations from a newer Slated for Mac than the engine knows also stop it here. |
| A `while-held` repeat keeps going after I let go | Check that Repeat Keys is on in GNOME Settings → Keyboard (`status.json` says `"whileHeld": "toggle"` otherwise). A repeat that types keys always needs a second press. `scripts/logs.py --grep automation.while_held` says which bindings work like toggles and why. |
| An automation stops by itself | `scripts/logs.py --grep automation.stopped` gives the reason: switching apps or opening the overview (`automation.stopOnAppSwitch`), the time limit (`automation.maxRunMinutes`), the stop shortcut, or a config change. |
| The stop or clipboard shortcut says "Couldn't register" | GNOME or another extension uses those keys (`cmd` is Super, so the clipboard's `cmd+shift+v` is Super+Shift+V). With Caps Lock as Hyper through GNOME's own option, `hyper+esc` can collide with GNOME's Super+Esc. Set `automation.stopShortcut` or `clipboard.shortcut` to other keys, such as `ctrl+alt+esc` or `ctrl+alt+v`. |
| An `onlyInApps` shortcut never works | It's grabbed only while that app has focus. Use the id from `recentApps` in `status.json` (desktop id, or WM_CLASS for games without a desktop file). |
| Clipboard history stays empty | `clipboard.enabled` must be on. Copies from `excludedApps` and secrets marked by password managers are skipped by design, and only text is kept. `scripts/logs.py --grep clipboard` shows what was skipped and why. |
| User extensions are turned off | Run `gsettings set org.gnome.shell disable-user-extensions false`, or turn them on in the Extensions app. |
