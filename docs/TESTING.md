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
| Golden vectors | `fixtures/`, written by the `SlatedFixtures` target | `make fixtures`, `make check-fixtures` | SlatedCore's results (errors included) for ~3,900 curated inputs, ~15,800 expected results: every input in the unit tests and many more. `check-fixtures` fails when `fixtures/` is stale or the generator isn't deterministic. |
| Linux engine | `linux/tests/run.mjs` (+ `harness.mjs`, `fixtures.mjs`, `unit.mjs`) | `make linux-test` | The JavaScript port of SlatedCore (`linux/gnome-extension/lib/core`) against every golden vector, plus tests for its JavaScript-only API (GNOME accelerators). Runs on Node if installed, else macOS's JavaScriptCore; `make linux-test-all` runs every runtime available (Node, GJS, JavaScriptCore). |
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

## Golden vectors: one engine, two languages

The Linux (GNOME) version runs a JavaScript port of `SlatedCore`. Instead of maintaining two test
suites, Swift writes its answers down and JavaScript must give the same ones:

1. `Sources/SlatedFixtures` runs the real Swift functions on curated inputs and writes the results to
   `fixtures/*.json` (`make fixtures`). One file per area, with a `manifest.json` listing the case counts:

   | File | Covers |
   |---|---|
   | `expressions.json` | Expression values and errors, every function, precedence, spaces, Unicode. |
   | `tokenizer.json` | Slate words and quoting, shell arguments, text escapes, Foundation's whitespace sets. |
   | `operations.json` | Every operation form and error; canonical Action JSON; `format`; Action decoding. |
   | `keys.json` | Key combos (parse, canonical string, display), key names, Slate keystrokes. |
   | `screens.json` | Screen setups, screen references and their resolution, ordering. |
   | `frames.json` | `targetFrame` for every geometry operation × setup × window × settings, and `targetOrigin`. |
   | `slate-config.json` | Classic `.slate` files with sourced files, diagnostics and line numbers. |
   | `config.json` | `config.json` decoding (JSON5 included) and the exact text Swift writes. |
   | `starter.json`, `settings.json`, `hotstrings.json` | The starter config; Slate settings; hotstring typing sessions and templates. |

2. `linux/tests/run.mjs` loads every fixture and checks the JavaScript engine against each case, plus
   handwritten tests for what fixtures can't express. Error messages must match word for word, and the
   encoded config.json byte for byte.

Fixtures are byte-stable: sorted keys, fixed UUIDs and dates in the inputs, UUIDs that Swift generates
shown as `RANDOM-UUID`, and only Slated's own error messages recorded (Foundation's can depend on
dictionary order). `make check-fixtures` regenerates twice into a temporary folder and diffs.

**When you change SlatedCore:** run `make fixtures`, read the diff in `fixtures/` (it shows exactly what
changed in behavior), update the JavaScript port until `make linux-test` passes, and commit all three.
To cover a new behavior, add inputs to `Sources/SlatedFixtures/*.swift`; the JavaScript runner refuses
fixture files or sections it has no checks for.

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

**Settings UI**
- [ ] First launch shows onboarding. After finishing it, it doesn't come back unless Accessibility
      permission goes missing.
- [ ] Left-clicking the menu bar icon opens the status panel, and its toggles work. Right-click opens
      the classic menu.
- [ ] The settings window takes keyboard focus, and Slated shows in the Dock and Cmd-Tab only while
      it's open.
- [ ] Recording a shortcut with the real Caps Lock (Hyper) works. Global hotkeys pause while recording.
- [ ] Editing a binding takes effect within about half a second, with no Save button.
      `scripts/logs.py --grep config.saved` shows the change.
- [ ] The sidebar renders correctly (the Liquid Glass sidebar can't be captured by `make snapshots`).

**Slate compatibility**
- [ ] `~/.slate.js` loads (the menu shows 21 hotkeys). Editing and saving it reloads within 2 seconds.
- [ ] "Import Slate Config into Slated…" converts all bindings and stops loading the file.

**Displays**
- [ ] Plugging in or removing a display applies a matching `default` layout.
- [ ] Changing the keyboard layout (e.g. to AZERTY) keeps letter shortcuts on the labeled keys.
