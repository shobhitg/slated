<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Slated icon"></p>

<h1 align="center">Slated</h1>

<p align="center"><b>Keyboard-first window management, a Hyper key, text expansion, clipboard history and game automation for macOS and GNOME, in one app.</b></p>

Slated is a modern successor to [Slate](https://github.com/jigish/slate), the endlessly configurable
window manager that has been unmaintained since 2013. It keeps everything that made Slate great,
imports your existing `~/.slate` or `~/.slate.js` into its own config, and adds what Slate users
usually install other tools for:

- **Window management:** every Slate operation is supported:
  - move, resize, push, nudge, throw and corner;
  - chain, sequence, layouts, and layouts applied automatically when your displays change;
  - snapshots, undo, directional focus, window hints and the grid.
- **A Hyper key** (from Karabiner-Elements): Caps Lock becomes ⌃⌥⇧⌘ while held. No kernel or driver
  extension needed.
- **Hotstrings** (from Keyboard Maestro): type `;shrug` and get `¯\_(ツ)_/¯`. Placeholders like
  `{date}` and `{clipboard}`, per-app filters, and a choice of typing or pasting.
- **Clipboard history** (like Keyboard Maestro's): text, images, copied files and screenshots saved
  as files. ⇧⌘V opens a small picker right at the text caret; type to filter, ↩ or ⌘1–9 pastes into
  the app you were in. Pin, delete and browse in Settings. Passwords that apps mark as secret are
  skipped.
- **Game automation** (like AutoHotkey, without a scripting language): auto-click, hold a mouse
  button or key, repeat while held or a set number of times, short macros with waits. A stop
  shortcut and automatic stops (switching apps, sleep, a time limit) make sure nothing stays held.
- **A notch island:** running automations (hover to stop them), a cheat sheet of your Hyper shortcuts
  while you hold Caps Lock, the active modal key, and a word on what each shortcut did. On displays
  without a notch it hangs from the top center.
- **One window for all of it**, with live previews of where a window will land. Slated stays in the
  Dock: close the window and it keeps working; click its Dock icon (or its menu bar icon) to come back.

> **Status:** early development. Built for macOS 14+ on Apple Silicon. No releases yet: build from
> source.

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is optional.

```sh
git clone https://github.com/shobhit-aida/slated && cd slated
./install.sh
```

`./install.sh` is safe to run as often as you like; rerun it after every `git pull` or code change.
Each run:
1. Builds the code.
2. Installs `~/Applications/Slated.app`, quitting the running copy cleanly first so Caps Lock is
   restored.
3. Relaunches it and checks its log to confirm the new build is the one running.

On first launch Slated's window opens on **Get Started**, and macOS asks to let Slated control your
Mac. Switch Slated on in System Settings and its window comes back to the front, ready for the
next step.

It signs every build with the same local certificate, created on the first run. That means you
grant Slated's Accessibility permission once (**System Settings → Privacy & Security →
Accessibility**), not after every reinstall.

| | |
|---|---|
| `./install.sh --check` | Run the test suite first; install only if it passes |
| `./install.sh --debug` | Debug build, which compiles faster (`make run`) |
| `./install.sh --uninstall` | Remove the app, keeping config and logs (`--purge` removes those too) |

**Coming from Slate or Karabiner-Elements?**
- Quit Slate first: both apps want the same shortcuts.
- On first launch Slated imports your `~/.slate.js` (or `~/.slate`) into its own config, and says
  which shortcuts it couldn't convert. It doesn't read the file after that; **File → Import Slate
  Config into Slated…** imports it again, adding only what's new.
- If Karabiner-Elements turns Caps Lock into Hyper, either keep using it (Slated's bindings work
  with any Hyper key) or turn that rule off and enable Slated's own Hyper key.

## Linux (GNOME)

Slated also runs on GNOME 46–51 as a GNOME Shell extension, with the same `config.json` and
`settings.json`. Run `linux/install.sh`, then log out and back in. [docs/LINUX.md](docs/LINUX.md) covers
installing, the Hyper key and hotstrings on GNOME, and how it differs from the Mac.

## Logs

Slated records every interaction and its outcome in `~/Library/Logs/Slated/slated.log`, one JSON
event per line: hotkeys, Hyper combos, hotstring expansions, menu and settings changes, errors,
permission changes and crashes.

```sh
make logs                              # follow live
scripts/logs.py --session last         # everything since the last launch
scripts/logs.py --errors --since 1h    # problems in the last hour
make log-summary                       # counts, app starts, recent errors
```

The same events also appear in Console.app under the subsystem `io.github.shobhit-aida.slated`.

## Configuration

- **Slated's window:** use it for everyday changes (click Slated in the Dock, or press ⌘, in Slated).
- **`~/.config/slated/config.json`:** what your keys do: shortcuts, hotstrings, the Hyper key,
  layouts. Edit it by hand if you prefer; Slated reloads it on save.
- **`~/.config/slated/settings.json`:** how Slated behaves: general, window, clipboard, automation
  and island settings.
- **Slate files:** `~/.slate.js` and `~/.slate` are imported into `config.json`, not run.

See [docs/CONFIG.md](docs/CONFIG.md) for the format, every action, and hotstring options.

```jsonc
{
  "version": 2,
  "keyboard": { "capsLock": "hyper" },
  "bindings": [
    { "name": "Left half", "keys": "hyper+a", "action": "push left bar-resize:screenSizeX/2" },
    { "keys": "hyper+right", "action": "throw right resize" }
  ],
  "hotstrings": [ { "trigger": ";today", "replacement": "{date:yyyy-MM-dd}" } ]
}
```

## Privacy

Hotstrings and the Hyper key work by watching keystrokes system-wide.
- The log contains shortcut names, hotstring triggers, app names and error messages.
- It never contains typed text, hotstring replacements or window titles, and it stays on your Mac.
- Slated keeps only the last few characters in memory to match triggers.
- It never logs, stores or sends what you type.
- Like every such tool, it can't see keystrokes while macOS Secure Input is on (password fields).
- Clipboard history stays on your Mac in a file only you can read
  (`~/Library/Application Support/Slated/clipboard.json`). It skips what password managers and
  browsers mark as secret, and the log notes only what kind of copy it was and how big, never its
  text, image or file names.

## Development

| Command | What it does |
|---|---|
| `make run` | Debug build, installed and relaunched (`./install.sh --debug`) |
| `make check` | Run every automated test: unit, contract and end-to-end smoke tests (see [docs/TESTING.md](docs/TESTING.md)) |
| `make test` | Unit and contract tests only (`FILTER=name` to narrow) |
| `make logs` | Follow Slated's event log |
| `make install` | Same as `./install.sh` |
| `make test-install` | Installer test in a throwaway folder (launches the app briefly) |
| `make fmt` / `make lint` | Format / check with `swift format` |
| `make reset-permissions` | Make macOS forget Slated's Accessibility permission |

The code is a Swift package with no Xcode project:

| Module | Contents |
|---|---|
| `SlatedCore` | Pure logic: model, Slate syntax, expressions, window math, hotstring matching |
| `SlatedSystem` | macOS integration: Accessibility, hotkeys, event tap, Hyper key, text injection, the config files |
| `SlatedScript` | Slate's JavaScript API on JavaScriptCore, to import `~/.slate.js` |
| `SlatedUI` | The SwiftUI settings app |
| `Slated` | The app (Dock icon, main window, menu bar icon) that wires it all together |

[CLAUDE.md](CLAUDE.md) records design decisions and conventions.

## Roadmap

- [ ] Signed, notarized releases and a Homebrew cask
- [ ] Automatic updates (Sparkle 2)
- [ ] A `slated` command-line tool
- [ ] Importer for Keyboard Maestro hotstrings
- [ ] Optional Mac App Store edition (window management only; the sandbox rules out the Hyper key)

## Credits & license

Inspired by [Slate](https://github.com/jigish/slate) by Jigish Patel. Slated is an independent
reimplementation that contains no code from Slate (GPLv3). MIT licensed; see [LICENSE](LICENSE).
