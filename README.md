<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Slated icon"></p>

<h1 align="center">Slated</h1>

<p align="center"><b>Keyboard-first window management, a Hyper key, and text expansion for macOS, in one app.</b></p>

Slated is a modern successor to [Slate](https://github.com/jigish/slate), the endlessly configurable
window manager that has been unmaintained since 2013. It keeps everything that made Slate great,
runs your existing `~/.slate` or `~/.slate.js` unchanged, and adds the two things Slate users
usually install other tools for:

- **Window management:** every Slate operation is supported:
  - move, resize, push, nudge, throw and corner;
  - chain, sequence, layouts, and layouts applied automatically when your displays change;
  - snapshots, undo, directional focus, window hints and the grid.
- **A Hyper key** (from Karabiner-Elements): Caps Lock becomes ⌃⌥⇧⌘ while held. No kernel or driver
  extension needed.
- **Hotstrings** (from Keyboard Maestro): type `;shrug` and get `¯\_(ツ)_/¯`. Placeholders like
  `{date}` and `{clipboard}`, per-app filters, and a choice of typing or pasting.
- **A settings app** for all of it, with live previews of where a window will land.

> **Status:** early development. Built for macOS 14+ on Apple Silicon. No releases yet: build from
> source.

## Getting started

Requires the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is optional.

```sh
git clone https://github.com/shobhit-aida/slated && cd slated
make dev-cert   # once: a local signing identity so macOS remembers Slated's permissions
make run        # build, bundle, sign and launch build/Slated.app
```

On first launch macOS asks you to allow Slated under **System Settings → Privacy & Security →
Accessibility**. Slated needs that permission to move other apps' windows and to run the Hyper key
and hotstrings.

**Coming from Slate or Karabiner-Elements?**
- Quit Slate first: both apps want the same shortcuts.
- If Karabiner-Elements turns Caps Lock into Hyper, either keep using it (Slated's bindings work
  with any Hyper key) or turn that rule off and enable Slated's own Hyper key.

## Configuration

- **Settings window:** use it for everyday changes.
- **`~/.config/slated/config.json`:** edit it by hand if you prefer; Slated reloads it on save.
- **Slate files:** `~/.slate.js` and `~/.slate` load as they are, alongside your Slated bindings.

See [docs/CONFIG.md](docs/CONFIG.md) for the format, every action, and hotstring options.

```jsonc
{
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
- Slated keeps only the last few characters in memory to match triggers.
- It never logs, stores or sends what you type.
- Like every such tool, it can't see keystrokes while macOS Secure Input is on (password fields).

## Development

| Command | What it does |
|---|---|
| `make run` | Build, bundle into `build/Slated.app`, sign, launch |
| `make check` | Run every automated test: unit, contract and end-to-end smoke tests (see [docs/TESTING.md](docs/TESTING.md)) |
| `make test` | Unit and contract tests only (`FILTER=name` to narrow) |
| `make logs` | Stream Slated's logs |
| `make install` | Release build into `~/Applications` |
| `make fmt` / `make lint` | Format / check with `swift format` |
| `make reset-permissions` | Make macOS forget Slated's Accessibility permission |

The code is a Swift package with no Xcode project:

| Module | Contents |
|---|---|
| `SlatedCore` | Pure logic: model, Slate syntax, expressions, window math, hotstring matching |
| `SlatedSystem` | macOS integration: Accessibility, hotkeys, event tap, Hyper key, text injection |
| `SlatedScript` | Slate's JavaScript API on JavaScriptCore |
| `SlatedUI` | The SwiftUI settings app |
| `Slated` | The menu-bar app that wires it all together |

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
