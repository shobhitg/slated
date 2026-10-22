# Slated

**Keyboard-first window management, Hyper key and text expansion for macOS — one app.**

Slated is a modern successor to [Slate](https://github.com/jigish/slate), the configurable window
manager that has been unmaintained since 2013. It keeps everything that made Slate great, runs your
existing `~/.slate` or `~/.slate.js` unchanged, and adds:

- **A Hyper key**: Caps Lock becomes ⌃⌥⇧⌘ while held, without a kernel or driver extension.
- **Hotstrings**: type `;shrug` and get `¯\_(ツ)_/¯`, Keyboard Maestro-style.
- **A real settings app** for bindings, hotstrings and keyboard options, with live window previews.

> Status: early development. Built for macOS 14+ on Apple Silicon.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is optional.

```sh
make dev-cert   # once: local signing identity so macOS remembers Slated's permissions
make run        # build, bundle, sign and launch build/Slated.app
make test       # run the test suite
```

## License

MIT. Slated is an independent reimplementation; it contains no code from the original Slate (GPLv3).
