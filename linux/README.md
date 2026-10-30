# Slated for Linux (GNOME)

On GNOME (Wayland), apps can't move other apps' windows, grab global shortcuts, or watch the
keyboard. So Slated for Linux is a **GNOME Shell extension**, the way GNOME window managers work. It
uses GNOME's own window and shortcut APIs from inside the desktop.

| Part | Where | Status |
|---|---|---|
| Engine (expressions, Slate syntax, window math, config, hotstring matching) | `gnome-extension/lib/core/` | JavaScript port of `SlatedCore`, held to the Swift behavior by golden vectors in `/fixtures` |
| Window management, hotkeys, overlays, logging | `gnome-extension/extension.js`, `lib/platform/` | GNOME Shell extension (GNOME 46–51; 50 and 51 untested) |
| Settings UI, Slate import, config migration | `gnome-extension/prefs.js`, `lib/prefs/` | libadwaita preferences window; the migration is shared with the extension |
| Opening Slated | `lib/platform/statusIcon.js`, `settingsWindow.js`; the installer's desktop entry | Top-bar icon with the Mac's menu, an app in the app grid, Get Started at login until it's done |
| Hyper key | GNOME keyboard option or `keyd` | Caps Lock → Hyper |
| Hotstrings | espanso, driven by Slated's config | Slated writes espanso's config from `config.json` |

The configuration is the same two files as on macOS: `~/.config/slated/config.json` (shortcuts,
hotstrings, the Hyper key) and `settings.json` beside it (how Slated behaves). `~/.slate.js` and
`~/.slate` aren't read: they're imported into `config.json` once.

Installing, development, how it compares with macOS, and troubleshooting: [docs/LINUX.md](../docs/LINUX.md).
