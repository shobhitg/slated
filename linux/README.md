# Slated for Linux (GNOME)

On GNOME (Wayland), apps can't move other apps' windows, grab global shortcuts, or watch the
keyboard. So Slated for Linux is a **GNOME Shell extension**, the way GNOME window managers work. It
uses GNOME's own window and shortcut APIs from inside the desktop.

| Part | Where | Status |
|---|---|---|
| Engine (expressions, Slate syntax, window math, config, hotstring matching) | `gnome-extension/lib/core/` | JavaScript port of `SlatedCore`, held to the Swift behavior by golden vectors in `/fixtures` |
| Window management, hotkeys, overlays, Slate JS API, logging | `gnome-extension/extension.js`, `lib/platform/` | GNOME Shell extension (GNOME 46–49) |
| Settings UI | `gnome-extension/prefs.js`, `lib/prefs/` | libadwaita preferences window |
| Hyper key | GNOME keyboard option or `keyd` | Caps Lock → Hyper |
| Hotstrings | espanso, driven by Slated's config | Slated writes espanso's config from `config.json` |

The configuration is the same file as on macOS: `~/.config/slated/config.json`. `~/.slate.js` and
`~/.slate` work too.

Installing, development, how it compares with macOS, and troubleshooting: [docs/LINUX.md](../docs/LINUX.md).
