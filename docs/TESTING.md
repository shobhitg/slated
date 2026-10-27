# Testing

`make check` runs everything automated. Run it before every commit.

| Layer | Where | Run | What it covers |
|---|---|---|---|
| Unit | `Tests/SlatedTests/*Tests.swift` | `make test` | Pure logic: model and JSON, key combos, expressions, Slate syntax, `.slate` parsing, frame math, screen resolution, hotstring matching and templates, log redaction. From `SlatedSystem`: the keyboard tap's decisions (fed events that are never posted) and `hidutil` parsing. |
| Script engine | `Tests/SlatedTests/SlateScriptTests.swift` | `make test` | The Slate JavaScript API against a fake Mac (`FakeScriptHost`). |
| Platform contract | `Tests/SlatedTests/JavaScriptCoreContractTests.swift`, `MacOSContractTests.swift`, `HIDRemapperTests.swift` | `make test` | macOS behavior Slated depends on: JavaScriptCore's error lines, stacks and exceptions inside callbacks; `hidutil`'s output; what folder watchers and atomic saves do with edited and symlinked files. Fails first if a macOS update changes it. |
| Your config | `StarterTests.swift` | `make test` | The built-in starter bindings behave exactly like `~/.slate.js` on landscape, portrait and square screens, and the importer converts it completely. Skipped when `~/.slate.js` doesn't exist (e.g. CI). |
| Smoke | `Tests/Smoke/run.sh`, fixtures in `Tests/Smoke/fixtures/` | `make smoke` | The real app binary (`Slated --smoke`) against temporary home folders: first run with and without Slate configs, hand-edited JSON, broken files, unknown operations, duplicate shortcuts. It also checks what lands in the event log, including crash detection. `SLATED_SMOKE_SECONDS` keeps it running longer and `SLATED_SMOKE_STEPS` drives it half way through (`Sources/Slated/SmokeSteps.swift`): saving over a broken or symlinked config.json, edits made while it runs, pausing then switching apps, reloading `~/.slate.js`. |
| Installer | `Tests/Installer/run.sh` | `make test-install` | `./install.sh` in a throwaway folder and home: install, launch, confirm the start via the log, reinstall over the running app (clean quit, new session, no crash), uninstall, `--purge`. Launches the app for a few seconds. |
| Golden vectors | `fixtures/`, written by the `SlatedFixtures` target | `make fixtures`, `make check-fixtures` | SlatedCore's results (errors included) for ~4,500 curated inputs, ~16,400 expected results: every input in the unit tests and many more. `check-fixtures` fails when `fixtures/` is stale or the generator isn't deterministic. |
| Linux engine | `linux/tests/run.mjs` (+ `harness.mjs`, `fixtures.mjs`, `unit.mjs`) | `make linux-test` | The JavaScript port of SlatedCore (`linux/gnome-extension/lib/core`) against every golden vector, plus tests for its JavaScript-only API (GNOME accelerators). Runs on Node if installed, else macOS's JavaScriptCore; `make linux-test-all` runs every runtime available (Node, GJS, JavaScriptCore). |
| UI snapshots | `SlatedUISnapshots` target | `make snapshots` | Renders every settings pane, onboarding step and the menu bar panel to PNGs (light and dark) for review. |
| Toolchain | `scripts/check-swift-testing.sh` | `make check-swift-testing` | Whether Swift Testing works yet (needs Xcode). |
| Manual | below | by hand | Things only a real Mac with a keyboard can tell. |

`make test FILTER=Expression` runs only matching suites or tests.

**Linux** (the GNOME Shell extension) has its own tests, with Node and GJS instead of Swift:
`make linux-test`, `make linux-test-extension`, `make linux-test-prefs`, `make linux-test-prefs-gjs`,
`make linux-test-gtk` and `make linux-test-installer`. [LINUX.md](LINUX.md#development) explains what
each one covers. CI runs them in the `linux` job on Ubuntu 24.04.

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
   | `operations.json` | Every operation form and error (automation and clipboard history included); canonical Action JSON; `format`; Action decoding. |
   | `keys.json` | Key combos (parse, canonical string, display), key names (modifier keys, mouse buttons 3–5), Slate keystrokes. |
   | `automation.json` | `press`/`hold` inputs, `RepeatSchedule` timing with fixed random values, `Action.isAutomation`. |
   | `clipboard.json` | `ClipboardHistory` sessions with fixed dates (add, dedupe, limit, retention, pin, remove, clear), Foundation's case- and diacritic-insensitive search, and the clipboard.json the Mac app writes. |
   | `screens.json` | Screen setups, screen references and their resolution, ordering. |
   | `frames.json` | `targetFrame` for every geometry operation × setup × window × settings, and `targetOrigin`. |
   | `slate-config.json` | Classic `.slate` files with sourced files, diagnostics and line numbers. |
   | `config.json` | `config.json` decoding (JSON5 included, `onlyInApps`, clipboard and automation settings) and the exact text Swift writes. |
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

**Differential fuzzing.** `make fuzz [SEED=n]` writes the same files from ~120,000 seeded random inputs
(`Sources/SlatedFixtures/Fuzz.swift`) and checks the JavaScript engine against them, in about a minute.
It isn't part of `make check`; run it after changing either engine. A failure is a difference the golden
vectors don't cover yet: add that input to the curated lists and fix whichever side is wrong.

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
- [ ] With a mouse button binding (mouse4), turning the permission on or off updates its status in
      Settings right away, without another edit.

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
      With the Hyper key turned off in config.json before relaunching, Caps Lock works again.
- [ ] Your own `hidutil` key mappings (if any) survive Slated starting and quitting.
- [ ] Running the binary from a terminal and pressing Ctrl-C restores Caps Lock too.
- [ ] After sleep and wake, the Hyper key still works.
- [ ] Hold Caps Lock while a password field takes focus (a Hyper shortcut that opens a login
      prompt, say), let go there, then type in another app: keys arrive without ⌃⌥⇧⌘.

**Hotstrings** (try TextEdit, Safari, Notes, Terminal, Slack)
- [ ] `;shrug` expands immediately; `afterDelimiter` triggers wait for space or punctuation and keep it.
- [ ] Long replacements paste, and the previous clipboard comes back. They never show up in
      clipboard history, even with "Ignore passwords and other concealed items" turned off.
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
- [ ] Renaming a layout keeps the name field focused, and its shortcuts (also one that applies it in
      a sequence or by orientation) still apply it. Typing another layout's name, or a Slate file's,
      shows "Another layout already has this name." and that layout's shortcut still applies it. A
      layout block copied in config.json selects its own row and editor, and deleting it keeps the
      original.
- [ ] The sidebar renders correctly (the Liquid Glass sidebar can't be captured by `make snapshots`).

**Clipboard history**
- [ ] Copying text in a few apps adds it to Settings → Clipboard, newest first. Copying a password
      from 1Password, Bitwarden or Keychain Access doesn't.
- [ ] ⇧⌘V opens the switcher over the app you're in. ↩ pastes the selected item into that app; ⌘1–9,
      search, ⌘P pin and ⌘⌫ delete work.
- [ ] Opening the switcher from the menu bar panel or Settings still pastes into the last app you used,
      not into Slated.
- [ ] ⇧⌘V, Esc, ⇧⌘V again right away, then pick an item a second later: it pastes into your app.
- [ ] Esc closes the switcher and typing goes straight back to the app you were in.
- [ ] Quit the app you were in while the switcher is open, then pick an item: nothing is pasted
      anywhere (`clipboard.paste_skipped` in the log), and the item is on the clipboard.
- [ ] After a restart the history is still there (with "Keep across restarts" on).
      `~/Library/Application Support/Slated/clipboard.json` is readable only by you (`-rw-------`).

**Game automation** (try in a game and in TextEdit)
- [ ] An auto-click recipe clicks at the set speed; pressing its shortcut again stops it. The
      island (or, with the island off, the red pill) shows while it runs.
- [ ] Hold right click / Hold W keep the button or key down until pressed again; Hold Shift keeps
      sprint on.
- [ ] A while-held repeat stops when you let go. A "click N times" repeat stops by itself.
- [ ] A binding limited to one game doesn't fire, or steal its key, in other apps.
- [ ] Mouse 4/5 work as triggers (after granting Accessibility).
- [ ] Hyper+Esc stops everything. Switching apps stops automations (if enabled). Pausing, sleeping,
      locking the screen and quitting release anything held: no stuck button or key.
- [ ] Hold W, switch the input source (e.g. to French, where W is another key), then stop: W is
      released, in the game and in Keyboard Viewer.

**Notch island** (try the built-in display, an external display, and a full-screen app)
- [ ] Holding Caps Lock about half a second shows the cheat sheet on the display you're working on;
      releasing hides it. Quick Hyper combos never show it.
- [ ] While the cheat sheet is up, Hyper+A still moves the window, and its row lights up.
- [ ] With "Caps Lock alone sends Escape" on, a quick tap sends Escape; a long hold that showed the
      cheat sheet doesn't.
- [ ] With "Show what just happened" on, a window shortcut shows "Left half · App" with a glyph of
      where the window went, on that window's display.
- [ ] A window shortcut with nothing focused (click the desktop first) says "No focused window to
      move".
- [ ] A running auto-clicker shows a red dot and a timer beside the notch. Hovering expands it;
      Stop stops it without taking focus from the game. Clicks elsewhere in the menu bar still work.
- [ ] A modal key shows its key beside the notch, then lists its keys after the delay.
- [ ] A modal binding on keys another binding already uses: entering the mode logs
      `modal.key_failed`, and Settings shows that binding as failed instead of active.
- [ ] Turning the island off in Settings → General brings back the bottom HUD and the top pill.
- [ ] No black shape stays at the notch once the island has nothing to show.

**Slate compatibility**
- [ ] `~/.slate.js` loads (the menu shows 21 hotkeys). Editing and saving it reloads within 2 seconds.
- [ ] "Import Slate Config into Slated…" converts all bindings and stops loading the file.

**Displays**
- [ ] Plugging in or removing a display applies a matching `default` layout.
- [ ] Changing the keyboard layout (e.g. to AZERTY) keeps letter shortcuts on the labeled keys.

## Manual checklist: GNOME settings window

Run on GNOME 46 (Ubuntu 24.04) and GNOME 49 after changes to `linux/gnome-extension/prefs.js` or
`lib/prefs/`, after `linux/install.sh` and a new login.
- [ ] `gnome-extensions prefs slated@shobhit-aida.github.io` opens the window on the Overview, which
      says "Everything's running". `linux/install.sh --verify` agrees.
- [ ] Narrowing the window collapses the sidebar into a back button. Light, dark and (on GNOME 47+)
      the accent color all look right.
- [ ] Recording a shortcut: the first time, GNOME asks whether to let the window take shortcuts.
      Caps Lock+A records ✦A, both with GNOME's option and with keyd. Super+A records Super+A, not ✦A.
- [ ] While recording, clicking the Name field stops the recording and the field takes typing, and
      clicking another section in the sidebar stops it and shows that section. Clicking the recorder
      again, or its row's title, stops it without starting over. With a modal key on, a plain key
      such as 1 records.
- [ ] Renaming a layout keeps its editor open. Typing another layout's name, or a Slate file's, shows
      "Another layout already has this name." and its shortcut still applies it (`scripts/logs.py --grep
      config.saved`). A layout block copied in config.json opens its own editor, and deleting it keeps
      the original.
- [ ] Editing a binding reaches the extension within a second (`scripts/logs.py --grep config`),
      and its status badge turns Active, or Couldn't register for a key GNOME owns (Super+A).
- [ ] The preview shows your real displays once the extension writes `screens` to `status.json`.
- [ ] Import into Slated on your real `~/.slate.js` converts every binding and stops loading the file.
- [ ] Turning "Slated is on" off and on in General disables and enables the extension.
- [ ] Hotstrings: with espanso running, a new hotstring appears in `~/.config/espanso/match/slated.yml`
      and expands in another app.
- [ ] Automation: adding Auto-Click Left asks for a shortcut (F6 is suggested). Pressing it in a game
      clicks; Running Now lists it, its row says Running, and the stop shortcut stops it.
- [ ] Works In → Only in some apps lists the game you just played under Used Lately (a Proton game
      by its `steam_app_…` window class). Once limited, a plain key such as F records.
- [ ] Clipboard: the pill says Recording and the count grows as you copy. KeePassXC is offered under
      Password Managers when installed. Clearing the shortcut (Backspace while recording) turns off
      Super+Shift+V; Default puts it back.
