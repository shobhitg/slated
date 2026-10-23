# Testing

`make check` runs everything automated. Run it before every commit.

| Layer | Where | Run | What it covers |
|---|---|---|---|
| Unit | `Tests/SlatedTests/*Tests.swift` | `make test` | Pure logic: model and JSON, key combos, expressions, Slate syntax, `.slate` parsing, frame math, screen resolution, hotstring matching and templates. |
| Script engine | `Tests/SlatedTests/SlateScriptTests.swift` | `make test` | The Slate JavaScript API against a fake Mac (`FakeScriptHost`). |
| Platform contract | `Tests/SlatedTests/JavaScriptCoreContractTests.swift` | `make test` | JavaScriptCore behavior the script engine depends on: error lines, stacks, exceptions inside callbacks. Fails first if a macOS update changes it. |
| Your config | `StarterTests.swift` | `make test` | The built-in starter bindings behave exactly like `~/.slate.js` on landscape and portrait screens, and the importer converts it completely. Skipped when `~/.slate.js` doesn't exist (e.g. CI). |
| Smoke | `Tests/Smoke/run.sh`, fixtures in `Tests/Smoke/fixtures/` | `make smoke` | The real app binary (`Slated --smoke`) against temporary home folders: first run with and without Slate configs, hand-edited JSON, broken files, unknown operations, duplicate shortcuts. It also checks what lands in the event log, including crash detection. |
| Installer | `Tests/Installer/run.sh` | `make test-install` | `./install.sh` in a throwaway folder and home: install, launch, confirm the start via the log, reinstall over the running app (clean quit, new session, no crash), uninstall, `--purge`. Launches the app for a few seconds. |
| UI snapshots | `SlatedUISnapshots` target | `make snapshots` | Renders every settings pane, onboarding step and the menu bar panel to PNGs (light and dark) for review. |
| Toolchain | `scripts/check-swift-testing.sh` | `make check-swift-testing` | Whether Swift Testing works yet (needs Xcode). |
| Manual | below | by hand | Things only a real Mac with a keyboard can tell. |

`make test FILTER=Expression` runs only matching suites or tests.

## Why a custom harness

Swift Testing and XCTest ship with Xcode, and this project builds with only the Command Line Tools
(`make check-swift-testing` shows the failure). So `Tests/SlatedTests` is an executable with a
~100-line harness (`Harness.swift`) whose API mirrors Swift Testing:

```swift
let exampleTests = Suite("Example", [
  ("adds numbers", {
    expectEqual(1 + 1, 2)
    let value = try require(Int("42"))   // stops the test if nil
    expect(value > 40, "message on failure")
    expectThrows { try SlateSyntax.parseOperation("bogus") }
  }),
])
```

To add tests:
1. Add a file to `Tests/SlatedTests`.
2. Register the suite in `main.swift`.
3. For code that must run on the main actor, wrap it in `MainActor.assumeIsolated { … }`: tests run on
   the main thread.

**Migrating to Swift Testing**, once `make check-swift-testing` passes:
- Mechanically, `expect(…)` becomes `#expect(…)`, `require` becomes `#require`, and each `Suite`
  becomes a `@Suite` struct with `@Test` functions.
- Move `SlatedTests` to a `.testTarget`.

## Rule: probes become tests

Anything run to check a behavior while developing gets folded into the suite. That includes a
scratch script, a probe of a macOS API, or a one-off smoke run. Assert what the probe printed, so
the knowledge isn't lost.

## Manual checklist

Run before a release, and after changes to `SlatedSystem` or the app target. Quit Slate.app first;
for Hyper key checks, also turn off Karabiner-Elements' Caps Lock rule.

**Install**
- [ ] `./install.sh` on a fresh checkout creates the "Slated Dev" certificate. It installs and
      launches, and prints "Running: session …".
- [ ] Running `./install.sh` again quits and replaces the running copy. Accessibility permission is
      kept, and Caps Lock works between the two runs.
- [ ] `scripts/logs.py --session last` shows the new build's commit in `app.start`.

**Permission**
- [ ] First launch asks for Accessibility. After it's enabled in System Settings, the menu says
      "Slated is running" within a second, with no relaunch needed.
- [ ] After a rebuild (`make run` again), the permission is still granted. This needs `make dev-cert`.
- [ ] Turning the permission off makes the menu say so. Caps Lock works normally again.

**Window management** (for each, try a regular app, Chrome or an Electron app, and Finder)
- [ ] Halves, quarters, maximize, centers land exactly at the screen edges, below the menu bar and
      above the Dock.
- [ ] Thirds lie side by side on a landscape screen and stack on a portrait screen.
- [ ] Throw left/right/up and to screen 2 move the window to the right display and resize it.
- [ ] The grid (Hyper+Tab): drag across cells places the window. Escape and clicking outside cancel.
- [ ] Undo puts the window back.
- [ ] A window with a minimum size (e.g. System Settings) still ends up flush with the screen edge.

**Hyper key**
- [ ] Holding Caps Lock + a bound key runs Slated's binding.
- [ ] Caps Lock + an unbound key reaches the app as ⌃⌥⇧⌘+key, for example another app's Hyper shortcut.
- [ ] Tapping Caps Lock alone does nothing, or sends Escape when that option is on. The Caps Lock
      light stays off.
- [ ] Quitting Slated restores Caps Lock: `hidutil property --get UserKeyMapping` prints `(null)`.
- [ ] After `kill -9` of Slated, relaunching it cleans up or re-applies the mapping correctly.
- [ ] After sleep and wake, the Hyper key still works.

**Hotstrings** (try TextEdit, Safari, Notes, Terminal, Slack)
- [ ] `;shrug` expands immediately; `afterDelimiter` triggers wait for space or punctuation and keep it.
- [ ] Long replacements paste, and the previous clipboard comes back.
- [ ] Nothing expands in a password field (Secure Input).
- [ ] `onlyInApps` / `exceptInApps` filters work.

**Slate compatibility**
- [ ] `~/.slate.js` loads (the menu shows 21 hotkeys). Editing and saving it reloads within 2 seconds.
- [ ] "Import Slate Config into Slated…" converts all bindings and stops loading the file.

**Displays**
- [ ] Plugging in or removing a display applies a matching `default` layout.
- [ ] Changing the keyboard layout (e.g. to AZERTY) keeps letter shortcuts on the labeled keys.
