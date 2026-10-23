# Slated

Slated is a keyboard-first macOS productivity app: a modern successor to the Slate window manager
(https://github.com/jigish/slate), plus the parts of Karabiner-Elements (Caps Lock → Hyper key) and
Keyboard Maestro (hotstrings / text expansion) its author relies on, with a polished settings UI.
Primary user: the author, daily, for a few months before a public release. Open source, MIT.

## Ground rules

- **The original Slate (cloned at `../slate-original`) is GPLv3: use it as a behavioral reference
  only.** Never copy its code, comments, or assets (icons) into this repo. Re-derive behavior from
  its README and by reading what the code does, then write our own implementation.
- Work in small, working increments. Each increment ends with a commit and concrete manual test
  steps for the user. Collect open questions for the user in `docs/QUESTIONS.md` instead of guessing
  silently; record decisions in the "Decisions" section below.
- Public macOS APIs only (no private SkyLight/CGS calls, no SIP changes). If a feature truly needs
  private API, stop and ask.
- Never log, persist, or transmit keystrokes. The keyboard event tap keeps only a short in-memory
  buffer for hotstring matching.

## Decisions (2026-10-22)

| Topic | Decision | Why |
|---|---|---|
| License | MIT | Author's choice. |
| Shape | One menu-bar agent app, `Slated.app` (`LSUIElement`), AppKit shell + SwiftUI windows | Accessibility permission is granted per signed app bundle. |
| Build | SwiftPM + `Makefile`; `scripts/bundle.sh` assembles and signs the `.app`. No Xcode project | Machine has only the Command Line Tools; plain-text project files. |
| Platform | macOS 14+, Swift 6 language mode, Apple Silicon first (universal for releases) | |
| Native config | JSON at `~/.config/slated/config.json` (`SlatedConfiguration`), read with JSON5 allowed | The UI must write it; Codable round-trips with zero dependencies. |
| Slate compatibility | `~/.slate.js` (JavaScriptCore) and `~/.slate` (classic syntax) are loaded live alongside the native config, read-only in the UI | The author's existing config is `~/.slate.js` and uses JS logic. |
| Actions on disk | JSON objects with `"op"` + Slate's JS parameter names (same shape as `slate.operation(name, {...})`); a bare string is Slate operation syntax | One shape for JSON, JS and the UI. |
| Hyper key | `hidutil` maps Caps Lock → F18; a `CGEventTap` adds ⌃⌥⇧⌘ while F18 is held | No driver/system extension (unlike Karabiner). Doesn't work under Secure Input. |
| Hotstrings | Same event tap: in-memory buffer → delete trigger with backspaces → type or paste replacement | |
| Hotkeys | Carbon `RegisterEventHotKey` | Standard, needs no extra permission. |
| Tests | `Tests/SlatedTests` is an executable harness (`make test`) mirroring Swift Testing's API | Swift Testing and XCTest ship with Xcode, not the CLT. Migrate when Xcode is installed. |
| Bundle ID | `io.github.shobhit-aida.slated` (provisional, see `docs/QUESTIONS.md`) | Changing it later resets Accessibility permission. |
| Defaults | First run: an existing Slate config is the default (loaded as-is); otherwise `SlatedConfiguration.starter`, the author's `~/.slate.js` in native form (a test checks they match) | The author asked for their Slate config to be the default; JavaScript isn't required. |
| Scripting | JavaScript (JavaScriptCore) only for Slate compatibility; everyday config is JSON + the UI. `by-orientation` covers the one bit of logic the author's script had | Author doesn't need JS; JSC is built in if real scripting is ever wanted. |

## Architecture

```
Sources/
  SlatedCore/    Pure Swift (Foundation + CoreGraphics types). Model (SlatedConfiguration, Action,
                 KeyCombo, Hotstring…), Slate syntax + expression parsing, frame math, hotstring matching.
  SlatedSystem/  macOS boundary: Accessibility windows/apps, screens, Carbon hotkeys, key-code mapping,
                 event tap, Hyper key, text injection, permissions.
  SlatedScript/  Slate's JavaScript API (`slate.*`, `S.*`) on JavaScriptCore, talking to the app
                 through a host protocol.
  SlatedUI/      SwiftUI: settings window, onboarding, menu bar content. Talks to the app only through
                 the `AppServices` protocol (AppServices.swift); `PreviewServices` provides sample data.
  Slated/        The app: AppDelegate, wiring config → triggers (hotkeys, hotstrings) → actions.
Tests/SlatedTests/  Test harness executable; one file per suite, registered in main.swift.
```

Dependency rules: `SlatedCore` imports nothing above it. `SlatedUI` and `SlatedScript` depend only on
`SlatedCore`. Only the `Slated` target ties everything together.

## Conventions

- **Coordinates:** everything in `SlatedCore` uses top-left-origin global coordinates (Accessibility
  convention; `y` grows down from the top of the primary display). Convert AppKit's bottom-left
  `NSScreen` frames once, in `SlatedSystem`.
- Slate's screen variables (`screenOriginX`, `screenSizeY`, …) refer to the screen's *visible*
  frame (minus menu bar and Dock).
- Style: 2-space indentation, 120 columns, `swift format` (`make fmt`). Doc comments on public API,
  explaining *why* where it isn't obvious. Small focused files.
- Pure logic goes in `SlatedCore` with tests; keep system wrappers thin.
- **Testing** (see `docs/TESTING.md`): `make check` must pass before every commit. Every check you
  run while developing becomes part of the suite, so nothing stays only in a scratch folder:
  - scratch probes of macOS APIs become contract tests;
  - one-off runs become smoke tests (`Tests/Smoke`);
  - behaviors only a real Mac can show go on the manual checklist.
- Concurrency: UI and app code is `@MainActor` (default isolation in `Slated` and `SlatedUI`). The
  event tap runs on its own thread; hand work to the main actor explicitly.
- Logging: `os.Logger(subsystem: <bundle id>, category: ...)`; view with `make logs`. Never log keys.
- User-facing text: plain, friendly, specific. Errors say what happened and what to do.

## Commands

- `make app` / `make run` — build, bundle into `build/Slated.app`, sign, (and launch)
- `make check` — all automated tests (`make test [FILTER=name]` for unit/contract, `make smoke` end-to-end)
- `make dev-cert` — one-time self-signed signing identity so permissions survive rebuilds
- `make reset-permissions`, `make logs`, `make fmt`, `make lint`, `make clean`

When testing on the author's Mac, quit Slate.app and Karabiner-Elements first: they grab the same
hotkeys and Caps Lock.
