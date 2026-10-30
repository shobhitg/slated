# Slated

Slated is a keyboard-first macOS productivity app: a modern successor to the Slate window manager
(https://github.com/jigish/slate), plus the parts of Karabiner-Elements (Caps Lock → Hyper key) and
Keyboard Maestro (hotstrings, clipboard history) its author relies on, AutoHotkey-style game
automation, a notch island and a GNOME Shell port, with a polished settings UI.
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
| Shape | One regular app, `Slated.app`: always in the Dock, one main window (Get Started during setup, then the panes) that a menu bar icon also opens; AppKit shell + SwiftUI. Closing the window keeps it running | Accessibility permission is granted per signed app bundle. A menu-bar-only agent with separate windows confused the author (2026-10-27). |
| Build | SwiftPM + `Makefile`; `scripts/bundle.sh` assembles and signs the `.app`. No Xcode project | Machine has only the Command Line Tools; plain-text project files. |
| Platform | macOS 14+, Swift 6 language mode, Apple Silicon first (universal for releases) | |
| Native config | Two JSON files in `~/.config/slated`, read with JSON5 allowed, the only source of truth (2026-10-29): `config.json` (version 2: keyboard, bindings, hotstrings, layouts, defaults) and `settings.json` (general, windows, clipboard, automation, island). One `SlatedConfiguration` in memory (`ConfigFiles.swift`); `ConfigFileStore` writes only the file whose part changed and migrates a version 1 `config.json` once (kept as `config.v1.json`) | The UI must write it; Codable round-trips with zero dependencies. The author: "everything configuration-based", two files are fine. |
| Slate compatibility | `~/.slate.js` (JavaScriptCore, on a pretend Mac) and `~/.slate` (classic syntax) are only imported into the native config (`SlateConfigImport`, merge: what Slated has wins), never run | No compatibility promise beyond migrating the author's files; one source of truth. |
| Actions on disk | JSON objects with `"op"` + Slate's JS parameter names (same shape as `slate.operation(name, {...})`); a bare string is Slate operation syntax | One shape for JSON, JS and the UI. |
| Hyper key | `hidutil` maps Caps Lock → F18; a `CGEventTap` adds ⌃⌥⇧⌘ while F18 is held | No driver/system extension (unlike Karabiner). Doesn't work under Secure Input. |
| Hotstrings | Same event tap: in-memory buffer → delete trigger with backspaces → type or paste replacement | |
| Hotkeys | Carbon `RegisterEventHotKey` | Standard, needs no extra permission. |
| Tests | `Tests/SlatedTests` is an executable harness (`make test`) mirroring Swift Testing's API | Swift Testing and XCTest ship with Xcode, not the CLT. Migrate when Xcode is installed. |
| Distribution | Free and open source: no Apple Developer Program, no Mac App Store. Build from source with `./install.sh` (signed with the local self-signed "Slated Dev" certificate); prebuilt downloads, if any, aren't notarized | The author doesn't want a yearly fee (2026-10-30). The self-signed certificate keeps Accessibility permission across rebuilds. |
| Bundle ID | `io.github.shobhit-aida.slated` (provisional, see `docs/QUESTIONS.md`) | Changing it later resets Accessibility permission. |
| Defaults | First run: an existing Slate config is the default, imported into `config.json`; otherwise `SlatedConfiguration.starter`, the author's `~/.slate.js` in native form (a test checks they match). Both files are written | The author asked for their Slate config to be the default; JavaScript isn't required. |
| Linux | A GNOME Shell extension (GNOME 46–51, Wayland; 50–51 untested) in `linux/`: JavaScript port of the engine in `lib/core/` pinned to Swift by golden vectors (`fixtures/`, `make fixtures`), platform layer in `lib/platform/`, libadwaita prefs; hotstrings via espanso, Hyper via keyd (recommended, the author's choice) with xkb `caps:hyper` as the fallback | Wayland lets only the compositor manage windows, grab shortcuts or overlay UI. Same `config.json` and `settings.json` on both platforms. |
| Notch island | A borderless, non-activating panel at the top center of the active display (`Overlays/IslandPresenter`), drawn by `SlatedUI/Island`. Ordered out when idle; never takes focus; takes clicks only while the pointer is over running automations | Uses the notch's dead space with public API only; must never get in the way of the app you're in. |
| UI parity | The Mac and GNOME UIs mirror each other: the same main-window pages and first-run flow, the same minimal clipboard picker, and the island (at the top center on Linux). Platform differences only where the platform forces them | The author's plan (2026-10-27): one product on both systems. |
| Scripting | JavaScript (JavaScriptCore) only to import Slate configs; everyday config is JSON + the UI. `by-orientation` covers the one bit of logic the author's script had | Author doesn't need JS; JSC is built in if real scripting is ever wanted. |

## Architecture

```
Sources/
  SlatedCore/    Pure Swift (Foundation + CoreGraphics types). Model (SlatedConfiguration, Action,
                 KeyCombo, Hotstring…), Slate syntax + expression parsing, frame math, hotstring matching.
  SlatedSystem/  macOS boundary: Accessibility windows/apps, screens, Carbon hotkeys, key-code mapping,
                 event tap, Hyper key, text injection, permissions, the two config files on disk.
  SlatedScript/  Slate's JavaScript API (`slate.*`, `S.*`) on JavaScriptCore, run against a pretend
                 Mac to import `~/.slate.js` (`SlateConfigImport`).
  SlatedUI/      SwiftUI: the main window (sidebar, panes, Get Started). Talks to the app only through
                 the `AppServices` protocol (AppServices.swift); `PreviewServices` provides sample data.
  Slated/        The app: AppDelegate hosts the UI (main window, menus, status item);
                 Engine wires config → triggers (hotkeys, hotstrings, Hyper) → actions; Overlays/
                 (grid, hints, clipboard switcher, notch island, HUD); Logging/.
  SlatedUISnapshots/  Renders the UI to PNGs with PreviewServices (`make snapshots`) for visual review.
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
- **Logging:** use `Log.record("area.event", [...])` (`Sources/Slated/Logging/EventLog.swift`). It
  writes JSON Lines to `~/Library/Logs/Slated/slated.log` and mirrors to the unified log.
  - Every user interaction and its outcome gets an event: hotkey → `action.done`/`action.failed` via
    `ActionRunner.run`, hotstrings, menu (`menu.*`), settings (`ui.*`, `config.saved` with a diff),
    and errors at `.error` level.
  - Log state changes, not repeats.
  - Never log typed text, hotstring replacements or window titles.
- **Debugging a report from the user: read the log first.** Start with
  `scripts/logs.py --session last`, `--errors --since 1h`, or `--summary`.
  - Each `app.start` records the version, commit (`-dirty` = uncommitted changes), signing and
    Accessibility state.
  - `app.previous_run_crashed` lists macOS crash reports.
- User-facing text: plain, friendly, specific. Errors say what happened and what to do.

## Commands

- `./install.sh` (`make install`) — build, sign with "Slated Dev", replace `~/Applications/Slated.app`,
  relaunch, verify via the log. Run it after every change; `--debug` (`make run`) builds faster.
- `make logs` / `scripts/logs.py` — read the event log; `make test-install` — installer test
- `make snapshots` — render every screen to `build/ui-snapshots` (look at them after UI changes)
- `make check` — all automated tests (`make test [FILTER=name]` for unit/contract, `make smoke` end-to-end)
- `make dev-cert` — one-time self-signed signing identity so permissions survive rebuilds
- `make reset-permissions`, `make logs`, `make fmt`, `make lint`, `make clean`

When testing on the author's Mac, quit Slate.app and Karabiner-Elements first: they grab the same
hotkeys and Caps Lock.
