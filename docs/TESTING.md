# Testing

`make check` runs everything automated. Run it before every commit.

| Layer | Where | Run | What it covers |
|---|---|---|---|
| Unit | `Tests/SlatedTests/*Tests.swift` | `make test` | Pure logic (model and JSON, key combos, expressions, Slate syntax, `.slate` parsing, frame math, screen resolution, hotstring matching, clipboard history, repeat timing), the settings app's view models (validation, editors, layouts, clipboard picker and its placement, notch island, cheat sheet) and macOS contracts (event tap, hidutil parsing, log redaction, the screenshot folder watcher on temporary folders, copied files on private pasteboards). |
| Script engine | `Tests/SlatedTests/SlateScriptTests.swift` | `make test` | The Slate JavaScript API against a fake Mac (`FakeScriptHost`). |
| Platform contract | `Tests/SlatedTests/JavaScriptCoreContractTests.swift`, `MacOSContractTests.swift`, `HIDRemapperTests.swift` | `make test` | macOS behavior Slated depends on: JavaScriptCore's error lines, stacks and exceptions inside callbacks; `hidutil`'s output; what folder watchers and atomic saves do with edited and symlinked files. Fails first if a macOS update changes it. |
| Your config | `StarterTests.swift` | `make test` | The built-in starter bindings behave exactly like `~/.slate.js` on landscape, portrait and square screens, and the importer converts it completely. Skipped when `~/.slate.js` doesn't exist (e.g. CI). |
| Config files and import | `ConfigFileStoreTests.swift`, `SlateImportTests.swift`, `ConfigurationTests.swift` | `make test` | config.json and settings.json in temporary homes: the migration of a version 1 config.json and its Slate config (backup never overwritten, an existing settings.json winning, idempotent, broken files left alone), first runs, saves that write only their own file; the Slate import and its merge rule. |
| Smoke | `Tests/Smoke/run.sh`, fixtures in `Tests/Smoke/fixtures/` | `make smoke` | The real app binary (`Slated --smoke`) against temporary home folders: first run with and without Slate configs, the migration of a version 1 config.json, the Slate import, saves that write only their own file, hand-edited, broken and symlinked config.json and settings.json, unknown operations, duplicate shortcuts, automation config, island settings and the Hyper cheat sheet, config races and reloads, log privacy. It also checks what lands in the event log, including crash detection. |
| Installer | `Tests/Installer/run.sh` | `make test-install` | `./install.sh` in a throwaway folder and home: install, launch (a test run, which leaves the keyboard alone), confirm the start via the log, reinstall over the running app (clean quit, new session, no crash), SIGQUIT, uninstall, `--purge`, and a hung Slated forced to quit whose Caps Lock mapping comes off (a stand-in `hidutil` on `PATH`). Launches the app for a few seconds. |
| Installer scripts | `Tests/Installer/test_restore_caps_lock.py` | `make test-scripts` | `scripts/restore-caps-lock.py` against a stand-in `hidutil`, for every case in `Tests/Installer/caps-lock-cases.json`; `HIDRemapperTests` checks Slated against the same cases, so the installer and the app agree on which Caps Lock mapping is Slated's. |
| Golden vectors | `fixtures/`, written by the `SlatedFixtures` target | `make fixtures`, `make check-fixtures` | SlatedCore's results (errors included) for ~4,500 curated inputs, ~16,400 expected results: every input in the unit tests and many more. `check-fixtures` fails when `fixtures/` is stale or the generator isn't deterministic. |
| Linux engine | `linux/tests/run.mjs` (+ `harness.mjs`, `fixtures.mjs`, `unit.mjs`) | `make linux-test` | The JavaScript port of SlatedCore (`linux/gnome-extension/lib/core`) against every golden vector, plus tests for its JavaScript-only API (GNOME accelerators). Runs on Node if installed, else macOS's JavaScriptCore; `make linux-test-all` runs every runtime available (Node, GJS, JavaScriptCore). |
| Window widths | `Tests/SlatedTests/AdaptiveLayoutTests.swift` | `make test` | Every pane of the main window, with and without an item open, in offscreen windows 640, 851 and 1080 pt wide: no scroll view (every pane, list and editor has one) reaches past the window, the scroll view it's in, or its neighbor. A window under 640 pt keeps the layout anchored left and scrolls. |
| UI snapshots | `SlatedUISnapshots` target | `make snapshots` | Renders every pane of the main window (Get Started's steps included), the clipboard switcher and the notch island to PNGs (light and dark) for review. Main-window panes also render at 640, 756 and 900 pt wide (`w640-…`, `w756-…`, `w900-…`); `SNAPSHOT_WIDTHS=851` picks other widths. |
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
   | `clipboard.json` | `ClipboardHistory` sessions with fixed dates (add, dedupe, limit, retention, pin, remove, clear, images, screenshot names, files), Foundation's case- and diacritic-insensitive search, the name a file path shows (`fileNames`), and the clipboard.json the Mac app writes (image and files items too). |
   | `placement.json` | `PopupPlacement`: the clipboard picker below the caret or pointer (above near the bottom), its image preview beside it, clamping, the screen showing an anchor, and which caret rects apps report are usable (CoreGraphics' edge and empty-rect rules). |
   | `screens.json` | Screen setups, screen references and their resolution, ordering. |
   | `frames.json` | `targetFrame` for every geometry operation × setup × window × settings, and `targetOrigin`. |
   | `slate-config.json` | Classic `.slate` files with sourced files, diagnostics and line numbers. |
   | `config.json` | Reading config.json and settings.json (JSON5 included, `onlyInApps`, clipboard and automation settings, version 1 files and what they say about Slate) and the exact text Swift writes for each. |
   | `starter.json`, `settings.json`, `hotstrings.json` | The starter config; Slate settings; hotstring typing sessions and templates. |
   | `cheatsheet.json` | The island's cheat sheet (SlatedUI's `CheatSheet`): every kind of action's title, section, region and symbol, names and script summaries, and whole Hyper and modal sheets in keyboard order. |

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
- [ ] First launch (also from `./install.sh` in a terminal): the setup window comes to the front and
      macOS's own Accessibility prompt appears. After it's enabled in System Settings, the menu says
      "Slated is running" within a second, with no relaunch needed. The Hyper key step says how many
      of your shortcuts use ⌃⌥⇧⌘.
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
- [ ] Bind `snapshot work save` and `activate-snapshot work`. Take it, quit and relaunch Slated, move
      some windows, then activate it: they go back, each to its own place even within one app.
      `~/Library/Application Support/Slated/snapshots.json` holds `titleHash`es, no window titles.

**Hyper key**
- [ ] Holding Caps Lock + a bound key runs Slated's binding.
- [ ] Caps Lock + an unbound key reaches the app as ⌃⌥⇧⌘+key, for example another app's Hyper shortcut.
- [ ] Tapping Caps Lock alone does nothing, or sends Escape when that option is on. The Caps Lock
      light stays off.
- [ ] Quitting Slated restores Caps Lock: `hidutil property --get UserKeyMapping` prints `(null)`.
- [ ] After `kill -9` of Slated, relaunching it cleans up or re-applies the mapping correctly.
      With the Hyper key turned off in config.json before relaunching, Caps Lock works again.
- [ ] Your own `hidutil` key mappings (if any) survive Slated starting and quitting. A Caps Lock
      mapping of your own (`hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000029}]}'`,
      Caps Lock → Escape) is back after turning the Hyper key off or quitting Slated.
- [ ] A Caps Lock → F18 mapping made by another tool (the same command with `0x70000006D`) is still
      there after Slated starts and quits with its own Hyper key off. The log says
      `keyboard.caps_lock_mapped_elsewhere`.
- [ ] `kill -9` Slated with the Hyper key on, then `./install.sh --uninstall`: Caps Lock works again
      (only Slated's mapping is gone; `~/Library/Application Support/Slated/caps-lock-mapping.json`
      too).
- [ ] Running the binary from a terminal and pressing Ctrl-C or Ctrl-\ restores Caps Lock too, also
      when pressed right after launching it (before its window appears).
- [ ] After sleep and wake, the Hyper key still works.
- [ ] Caps Lock on, then turn the Hyper key on: Caps Lock goes off (its light too). The log has
      `hyper.caps_lock_cleared` with reason "hyper turned on". Also at launch: quit Slated, turn Caps
      Lock on, start Slated with the Hyper key on.
- [ ] Hold Caps Lock while a password field takes focus (a Hyper shortcut that opens a login
      prompt, say), let go there, then type in another app: keys arrive without ⌃⌥⇧⌘.
- [ ] When the log shows `tap.reenabled_after_timeout` or `tap.reenabled_after_user_input` while you
      were holding Caps Lock (or Caps Lock + a bound key), everything you still held kept working:
      Caps Lock + a bound key ran the binding, a held binding's key never typed its letter, and letting
      go of a long hold didn't send Escape. (Slated asks the keyboard what is still down.)

**Hotstrings** (try TextEdit, Safari, Notes, Terminal, Slack)
- [ ] `;shrug` expands immediately; `afterDelimiter` triggers wait for space or punctuation and keep it.
- [ ] Long replacements paste, and the previous clipboard comes back. They never show up in
      clipboard history, even with "Ignore passwords and other concealed items" turned off, and the
      previous clipboard isn't added to it again either (copy in Keychain Access, then expand one).
- [ ] With Handoff on, expand a long hotstring, then paste on your iPhone or iPad: you get what you
      copied before, never the replacement (Slated's temporary paste stays on this Mac).
- [ ] Nothing expands in a password field (Secure Input).
- [ ] `onlyInApps` / `exceptInApps` filters work.
- [ ] Two hotstrings with the same trigger: the one higher in Settings → Hotstrings expands, and the
      other says it never fires. Dragging that one to the top makes it expand instead, and the warning
      moves to the other.

**Settings UI**
- [ ] First launch (`make reset-permissions`, then `./install.sh`): the main window comes to the
      front on Get Started, also in front of the terminal, and macOS's Accessibility prompt appears.
      Switching Slated on in System Settings brings the window back in front within a second, past
      the permission step, with "Accessibility is on". Finishing lands on Overview, and Get Started
      leaves the sidebar (Help → Get Started and Overview's "Get Started" still open it).
- [ ] Get Started doesn't come back on later launches unless Accessibility permission goes missing;
      then the window opens on its permission step.
- [ ] Slated is always in the Dock and Cmd-Tab. Closing the window (⌘W) leaves it running and its
      shortcuts working; clicking the Dock icon, opening Slated from Finder or Spotlight, ⌘, or
      left-clicking the menu bar icon brings the window back (on Overview, or where you were if it was
      only behind other windows). Right-clicking the menu bar icon opens the small classic menu. ⌘Q
      quits and restores Caps Lock.
- [ ] The menus work: About Slated opens About, Settings… (⌘,), Pause Slated (checkmark), Hide,
      Quit; File → Reload Configuration (⌘R), Open Config File, Open Settings File, Close Window (⌘W); Edit → Undo, Cut,
      Copy, Paste and Select All in a text field (a hotstring's replacement); Window → Minimize.
- [ ] With Launch at Login on, logging in starts Slated without opening its window (once set up).
- [ ] The menu bar icon is Slated's three tiles, tinted like the other icons in light and dark menu
      bars; pause bars while paused, outlined tiles while a modal key waits, an exclamation mark when
      a shortcut couldn't be registered (the menu lists it).
- [ ] General → Show Slated in the menu bar off takes the icon away; on brings it back. The Dock icon
      still opens Slated.
- [ ] Half-screen window: snap Slated's window to the left and right half with ✦A/✦D, and again with
      macOS tiling (Window → Move & Resize → Left/Right, or drag it to the screen edge). On every pane
      nothing is cut off at either edge. Under 900 pt the sidebar is a column of icons: hovering one
      names it, counts and warnings sit on its corner. Windows, Hotstrings and Layouts show the list;
      clicking an item opens it full width under "‹ All …" (⌘[ goes back). Pane headers put the
      subtitle on its own line and "New Hotstring" reads "New". Drag the window narrower: it stops at
      640 × 480. Wider than about 850 pt the list and editor sit side by side again.
- [ ] On a MacBook with a full menu bar (the icon behind the notch): Overview and General say so, and
      `scripts/logs.py --grep menubar` shows `menubar.icon_hidden` with the icon's x and the notch.
      Got It hides the notice. Turn off a few other icons in System Settings → Menu Bar: the icon
      appears, the notice goes, the log has `menubar.icon_visible`.

**Key repeat (Settings → Keyboard → Key Repeat)**
- [ ] First launch of this version: config.json gains `keyboard.keyRepeat` equal to this Mac's
      setting (`defaults read -g InitialKeyRepeat` × 1000/60 ms, and `KeyRepeat`), and the log has
      `keyboard.key_repeat_captured`. Nothing changes in how keys repeat.
- [ ] Move "Delay until repeat" and "Repeat rate", then hold a key in "Try it here". Either it repeats
      the new way at once and the status says Applied, or Settings and Overview say macOS uses it after
      you log out and back in; after logging in, it does. `defaults read -g KeyRepeat` shows the new
      ticks either way; the log has `keyboard.key_repeat_applied` with `live` true or false.
- [ ] Use This Mac's Current Setting puts the sliders back to what macOS uses now.
- [ ] Switch off, quit and relaunch Slated: the setting isn't captured again, and key repeat stays as
      it was (nothing is undone).
- [ ] Copy a config.json with `"keyRepeat": {"delay": 200, "interval": 17}` from another computer:
      after Slated reloads it, keys repeat after 200 ms, 60 per second (maybe after logging in).
- [ ] The main window takes keyboard focus.
- [ ] Recording a shortcut with the real Caps Lock (Hyper) works: holding Caps Lock and pressing K
      records ✦K (⌃⌥⇧K with Keyboard → Meh), and whatever ✦K is bound to doesn't run. Global hotkeys,
      Hyper combos and hotstrings pause while recording (typing a hotstring's trigger into the
      recorder doesn't expand it). `hidutil property --get UserKeyMapping` still lists Caps Lock →
      F18 while recording, and is empty while Slated is paused (Slated → Pause Slated).
      With Caps Lock not set as the Hyper key, a real F18 key (an extended keyboard, a keyboard
      layer) records as F18.
- [ ] Give a hotstring the trigger `x`, click into its Try It field, switch to another app and back
      (Cmd-Tab), then type `x` right away: the field says "Expanded", and
      `scripts/logs.py --grep hotstring.expanded` shows no real expansion. The same after closing and
      reopening Settings.
- [ ] Editing a binding takes effect within about half a second, with no Save button.
      `scripts/logs.py --grep config.saved` shows the change.
- [ ] Break config.json by hand (delete a comma) with Settings open: the banner appears and says where
      the error is, and changing anything shows "Fix config.json first". Fix the file: Settings shows
      it within a second or two, and edits save again.
- [ ] Renaming a layout keeps the name field focused, and its shortcuts (also one that applies it in
      a sequence or by orientation) still apply it. Typing another layout's name, or a Slate file's,
      shows "Another layout already has this name." and that layout's shortcut still applies it. A
      layout block copied in config.json selects its own row and editor, and deleting it keeps the
      original.
- [ ] The sidebar shows every pane, in light and dark, right after launch and again after closing the
      window and reopening it. (Tests check its views and drawing offscreen; only a screen shows the
      final picture. It once came up empty on macOS 26, when it was a Liquid Glass sidebar.)
- [ ] VoiceOver reads icon-only controls by name: the app picker beside an app field says "Choose a
      running app", and a grid size from a Slate config keyed by resolution says "Remove the grid
      size for the 1680×1050 display" (the tests can only read the source).

**Clipboard history**
- [ ] Copying text in a few apps adds it to Settings → Clipboard, newest first. Copying a password
      from 1Password, Bitwarden or Keychain Access doesn't.
- [ ] ⇧⌘V opens the small picker just below the text caret, its left edge at the caret, in:
      TextEdit, Safari (a text field on a page, and the address bar), VS Code (an editor), Terminal
      (at the prompt). `clipboard.switcher_opened` in the log says `"anchor":"caret"`; an app that
      reports no caret says `"element"` (below the focused field) or `"pointer"`.
- [ ] Near the bottom of the screen it opens above the caret; near the right edge it moves left; it
      never covers the menu bar or the Dock. With two displays it opens on the caret's display.
- [ ] Where no text is focused (Finder with no rename, the desktop) it opens at the mouse pointer;
      from Slated's window (Overview → Clipboard → Open, or Settings → Clipboard → Open Picker), at
      the pointer too.
- [ ] Typing filters at once; ↑↓, ↩ pastes the selected item into the app you were in, a click pastes
      the row, ⌘1–9 pastes that row, esc closes and typing goes straight back to the app. Pinned
      items are at the top with a pin.
- [ ] While the picker is open, the menu bar still shows the app you were typing in (the picker
      takes the keyboard without activating Slated), and the very first click on a row pastes it.
      Typing in a CJK input method: ↩ and esc confirm or cancel the composition, not the picker.
- [ ] Moving the mouse over a row selects it; scrolling with the arrow keys under a mouse that isn't
      moving keeps the selection where the keys put it.
- [ ] Opening the picker from Slated's window still pastes into the last app you used, not into
      Slated.
- [ ] ⇧⌘V, Esc, ⇧⌘V again right away, then pick an item a second later: it pastes into your app.
- [ ] Esc closes the picker and typing goes straight back to the app you were in, also while
      Slated's window is open behind it. Clicking another app's window instead leaves you in that app,
      clicking Slated's window leaves you there, and opened from Slated's window, Esc leaves you in it.
- [ ] Quit the app you were in while the picker is open, then pick an item: nothing is pasted
      anywhere (`clipboard.paste_skipped` in the log), and the item is on the clipboard.
- [ ] Images: take a screenshot to the clipboard (⌃⇧⌘4), Copy Image in Safari, and copy an image in
      Preview. Each shows up once as "Image · width×height · app" with a thumbnail, also in
      Settings → Clipboard. Copying cells in Numbers records their text, not a picture of them.
- [ ] Selecting an image row (arrow keys or the mouse) shows it at about 240 pt beside the picker, on
      screen even when the picker is at the right edge; it never takes the keyboard or clicks, and
      goes away on a text row or when the picker closes. Picking it pastes the image into TextEdit
      (rich text), Notes, Keynote or Slack.
- [ ] `~/Library/Application Support/Slated/clipboard-images` is `drwx------` and its files
      `-rw-------`. Deleting an image in Settings (or Clear History) removes its file. The log's
      `clipboard.captured` for an image has only `bytes`, `width` and `height`.
- [ ] Screenshots saved as files (⇧⌘3, ⇧⌘4): the first one after installing makes macOS ask
      whether Slated may see your Desktop folder. Allow it: within a second or two of the file
      appearing (after the floating thumbnail goes, if it's on) the screenshot is in the picker under
      its file name, with its thumbnail and preview. The file on the Desktop is untouched. The log has
      `clipboard.captured` with `"source":"screenshot"`, and no file name.
- [ ] Renaming that screenshot on the Desktop, or dragging an older screenshot there, adds nothing.
      Turn "Add screenshots" off in Settings → Clipboard and take another: nothing is added.
- [ ] Denied access: `tccutil reset SystemPolicyDesktopFolder io.github.shobhitg.slated`, relaunch,
      take a screenshot and answer Don't Allow. Settings → Clipboard shows the notice under "Add
      screenshots", and "Open Privacy & Security" opens Files and Folders. The log has
      `clipboard.screenshots_unavailable` once. Turning Desktop Folder on there makes screenshots
      show up again within about 5 seconds, without relaunching.
- [ ] Screenshot folder moved (⇧⌘5 → Options → Save to → Documents): within about 5 seconds new
      screenshots are picked up from there (macOS may ask about that folder too).
- [ ] Copied files: ⌘C on two files in the Finder makes one row, a small thumbnail and
      "first-name + 1 more", the same height as a text row. Selecting it shows a QuickLook preview
      with name, "2 files" and size; a single picture shows the picture. Searching a file's name
      finds it. Pasting it in a Finder window copies the files; in Mail or Slack, they're attached.
      The log has `clipboard.captured` `{kind: "files", count: 2}`, never a name or path.
- [ ] Move one of those files to the Trash and pick the item: only the other one is pasted. Empty
      the Trash of both: the row is dimmed and says "Moved or deleted", picking it beeps and leaves
      the picker open, your clipboard is unchanged, and the log has `clipboard.paste_skipped` with
      `"reason":"files missing"`. In Settings the Copy button is off for it.
- [ ] Copying a link in Safari is still text (a web URL isn't a file).
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
- [ ] A macro `click left | wait 3 | click left` (and `shell 'sleep 3' wait | click left`): Hyper+Esc,
      Cmd-Tab to another app, or locking the screen during the wait, and the second click never
      comes. `scripts/logs.py --grep automation.stopped_all` shows the reason. Slated stays
      responsive during the shell command.
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
- [ ] A modal key that is another binding's shortcut: Settings shows every binding behind it as
      failed ("Its modal key can't be used: Another Slated shortcut already uses …").
- [ ] Turning the island off in Settings → General brings back the bottom HUD and the top pill.
      Settings → Automation → Show an indicator then previews the pill instead of the island.
- [ ] No black shape stays at the notch once the island has nothing to show.

**Config files and Slate import** (back up `~/.config/slated` first: `cp -R ~/.config/slated ~/slated-backup`)
- [ ] Migration of your version 1 config: with your old `config.json` (version 1, 0 bindings,
      `loadSlateConfigs` true) and `~/.slate.js` in place, install and launch. `~/.config/slated` now
      has `config.v1.json` (your old file, unchanged), `config.json` (version 2, your hotstrings, the
      Hyper key and 21 bindings from `~/.slate.js`) and `settings.json` (your general, island,
      clipboard and automation settings; Slate's `config` values under `windows`). Overview says
      "Your ~/.slate.js shortcuts are now part of Slated's config…" until you click Got It. Every
      Hyper shortcut works as before. `scripts/logs.py --grep config.migrated` shows counts only.
- [ ] Relaunch: nothing is migrated again, `config.v1.json` is unchanged, and the notice stays gone.
- [ ] Editing `~/.slate.js` now changes nothing in Slated. "Import Slate Config into Slated…" then
      says the shortcuts are already in Slated (adds only new keys).
- [ ] Hand edit of each file: change a binding's keys in `config.json`, save in your editor: Slated
      picks it up within a second and Settings shows it. Turn the island off in `settings.json`: the
      island goes away, and `config.json` is untouched (same modification time).
- [ ] In Settings, toggle a General or Island setting: only `settings.json` changes. Add a shortcut:
      only `config.json` changes. Comments you put in the other file stay.
- [ ] Break `settings.json` (delete a closing brace): the banner names `settings.json` and says
      where; Settings is read-only; nothing is written to either file. Fix it: everything comes back.
- [ ] File → Open Config File and Open Settings File (and the menu bar icon's menu) open each file.
- [ ] Settings → Import from Slate lists what the last import did and what couldn't be converted,
      by keys. With no `~/.slate.js` or `~/.slate`, its Import button is off.
- [ ] Get Started on a first run with a `~/.slate.js` (`make reset-permissions`, move
      `~/.config/slated` away): the Slate step says what was imported; without one, it offers the
      starter shortcuts.
- [ ] With Settings open, change something and import within half a second: Settings then shows the
      imported bindings, and the change is still there after reopening Settings.


**Displays**
- [ ] Plugging in or removing a display applies a matching `default` layout.
- [ ] Changing the keyboard layout (e.g. to AZERTY) keeps letter shortcuts on the labeled keys.

## Manual checklist: Linux installer

Run after changes to `linux/install.sh` on fresh installs (a VM is fine), from a clone, as a normal
user. `make linux-test-installer` covers the logic against stand-ins; these check the real
distributions, package managers and services.

**Fresh Ubuntu 24.04 (GNOME 46, Wayland)**
- [ ] `linux/install.sh` with nothing else installed: one line says what sudo is for, sudo asks for
      the password once, and the run ends with a summary of four ✔ (the extension, Slated in your
      apps, keyd, espanso), "Last step: log out and back in" and "Find Slated in your apps or click
      its icon in the top bar". apt installs gcc, make and libc6-dev; keyd v2.6.0 builds from source (`keyd --version`
      says 2.6.0); `systemctl status keyd` is active; espanso's Wayland package is installed
      (`getcap $(which espanso)` shows `cap_dac_override`) and `espanso status` says it's running.
- [ ] Answering y to "Log out now to start Slated?" logs out (GNOME asks about unsaved work first).
      After logging in, the settings window opens on Get Started within a few seconds, Slated's icon
      is in the top bar, and `linux/install.sh --verify` says "GNOME Shell runs Slated (Enabled: Yes,
      State: ACTIVE)" and reports the build. Caps Lock+A records ✦A in Settings → Keyboard, which says
      keyd, and a hotstring expands in gedit.
- [ ] Slated is in the app grid and in Activities search (type "sla"), with its icon; opening it
      opens the settings window, and opening it again brings that window forward.
      `linux/install.sh --uninstall` takes it out of both.
- [ ] With GNOME's Extensions switch off (Extensions app, main switch): `linux/install.sh --verify`
      says so first, with the fix, and changes nothing. `linux/install.sh` says the switch is off,
      asks "Turn on GNOME extensions? [Y/n]", and Enter turns it on: Slated and your other extensions
      start without logging out, and the run ends with "GNOME Shell runs Slated".
- [ ] With Slated turned off in the Extensions app: a re-run (nothing else to install) turns it back
      on and says GNOME Shell runs it.
- [ ] The same on an Xorg session: espanso's X11 package, no setcap, and the last step offers Alt+F2
      `r`, which starts Slated without logging out.

**Fresh Fedora (GNOME, Wayland)**
- [ ] dnf installs gcc, make and kernel-headers and keyd builds from source; SELinux lets
      systemd start `/usr/local/bin/keyd`. espanso is skipped with a plain message (no Wayland
      package) and the run still ends in ✔ for the extension and keyd.

**A re-run, and a distribution with a keyd package**
- [ ] Running `linux/install.sh` again right away: no password prompt, every step says it's
      already done, no package manager or download runs.
- [ ] After changing the Escape tap in Settings, a re-run rewrites only `/etc/keyd/slated.conf`
      (one sudo prompt) and reloads keyd.
- [ ] Ubuntu 26.04 or Debian 13: keyd comes from apt (`apt-get install keyd`), not built.
- [ ] Arch on Xorg: keyd from pacman; espanso's AppImage lands in `~/opt` with an `espanso` command.

**The author's setup: Pop!_OS 24.04, GNOME 46 session on Xorg**
- [ ] From the GNOME session: keyd builds from source, espanso's X11 package installs and starts,
      and the last step names Alt+F2 `r`, which starts Slated without logging out. Then Get Started
      opens by itself, and Slated's icon is in the top bar.
- [ ] From the COSMIC session: the installer stops at once, says this session is COSMIC and to run
      it from GNOME, and changes nothing.

**Unsupported systems**
- [ ] Pop!_OS 22.04 (GNOME 42): stops at once, naming GNOME 42 and Pop!_OS 22.04, and changes
      nothing (no sudo prompt).
- [ ] `sudo linux/install.sh` refuses and says to run it as yourself.

## Manual checklist: GNOME island

Run on GNOME 46 (Ubuntu 24.04) and GNOME 49 after changes to `lib/platform/island*.js`,
`hyperHold.js` or the island's styles, with keyd and again with GNOME's `caps:hyper` option.
- [ ] Holding Caps Lock about half a second shows the cheat sheet hanging from the top bar of the
      monitor you're working on; letting go hides it at once. Quick Caps Lock+A never shows it.
- [ ] With keyd and "Tap Caps Lock alone for Escape" on (then `linux/install.sh --hyper-keyd`;
      `/etc/keyd/slated.conf` has `overload_tap_timeout = 500`): with a menu open, a quick tap
      closes it (Escape), and letting go after the sheet showed leaves it open. With Long in
      General → Island and the installer run again, the file says 800.
- [ ] While the sheet is up, Caps Lock+A still moves the window, and its row lights up. It lists the
      same sections, order and names as the Mac's for the same `config.json` and `~/.slate.js`.
- [ ] With "Show what just happened" on, a window shortcut shows "Left half · Firefox" with a glyph of
      where the window went, on that window's monitor. With nothing focused (click the desktop), it
      says "No focused window to move".
- [ ] A running auto-clicker shows a red dot and a timer, over a fullscreen game too (then at the very
      top). Hovering opens it up; Stop stops it without taking focus from the game. Next to the
      island, clicks reach the window below, and with nothing running nothing is left to click.
- [ ] A modal key shows its key in the island, then lists its keys after the delay.
- [ ] `"island": {"enabled": false}` brings back the bottom HUD and the red pill.
- [ ] Growing, shrinking and fading look smooth; no black shape stays once there's nothing to show.
- [ ] In an Xorg session (GNOME 46–48) the island catches clicks only while automations show.
- [ ] GNOME Shell's CPU use stays flat while idle (the Hyper watcher reads the modifiers about 7 times a
      second). `scripts/logs.py --grep island` shows `island.cheat_sheet` and `island.stop_clicked`.
- [ ] Turning the extension off while the sheet or automations show removes everything; turning it
      back on works.

## Manual checklist: GNOME top bar and opening Slated

Run on GNOME 46 (Ubuntu 24.04, and the author's Pop!_OS on Xorg) and GNOME 49 after changes to
`lib/platform/statusIcon.js`, `settingsWindow.js`, the icons or the installer's app entry.
- [ ] Slated's icon (three tiles) sits in the top bar's status area and reads well in light and dark
      top bars, next to GNOME's own icons.
- [ ] A click opens the settings window; another click with it open (behind other windows) brings it
      forward instead of doing nothing. A right click, or Ctrl+click, opens the menu instead.
- [ ] The menu: "Slated is running", Open Slated, Caps Lock → Hyper Key (its switch matches Settings →
      Keyboard and turns the Hyper key off and on within a second), Pause Slated, Reload Configuration,
      Open Config File, Open Settings File (both in the text editor), Show Log (Files, in
      `~/.local/state/slated`). `scripts/logs.py --grep menu` shows each.
- [ ] Pause Slated: the icon shows pause bars, the menu says "Slated is paused", shortcuts, ✦ (with
      GNOME's option) and hotstrings stop, Settings → Overview says Slated is paused. Locking and
      unlocking the screen keeps it paused; turning Pause off brings everything back.
- [ ] A binding on Super+A: the icon shows an exclamation mark, and the menu lists the shortcut that
      couldn't be registered.
- [ ] General → Show Slated in the top bar off takes the icon away within a second; on brings it back.

**Keyboard: key repeat and Caps Lock (GNOME)**
- [ ] Caps Lock on, then turn the Hyper key on: Caps Lock goes off. Check it with keyd (Settings →
      Keyboard on, `linux/install.sh --hyper-keyd` run) and with GNOME's option (`--no-keyd`).
      `scripts/logs.py --grep hyper.caps_lock` shows `hyper.caps_lock_cleared`.
- [ ] With Caps Lock on and Slated running, run `linux/install.sh --hyper-keyd`: within a second Caps
      Lock goes off (reason "hyper mode changed").
- [ ] Settings → Keyboard → Key Repeat: switch on, drag "Delay until repeat" and "Repeat rate", hold a
      key in "Try it here": the new timing applies at once, and GNOME Settings → Keyboard → Repeat Keys
      shows the same values. The status says Applied. Switch off: GNOME's values stay as they were.
- [ ] First start of this version on a fresh computer: config.json gains `keyboard.keyRepeat` equal to
      GNOME's delay and interval, and the log has `keyboard.key_repeat_captured`. Turn the switch off
      and restart Slated: it isn't captured again.
- [ ] Copy a config.json with `keyRepeat` {200, 17} to the GNOME machine: after Slated reloads, GNOME
      uses 200 ms and 17 ms.
- [ ] With no `~/.local/state/slated/settings-window.json`, a new login opens the settings window on Get
      Started about 3 seconds in, without taking focus from an app you already opened. Closing it,
      then locking and unlocking, doesn't open it again; the next login does, until it's finished.

## Manual checklist: GNOME settings window

Run on GNOME 46 (Ubuntu 24.04) and GNOME 49 after changes to `linux/gnome-extension/prefs.js` or
`lib/prefs/`, after `linux/install.sh` and a new login.
- [ ] Overview never shows a bare "Waiting": with GNOME's Extensions switch off, every row says so and
      offers Turn On Extensions, which starts Slated; with Slated turned off in the Extensions app, Turn
      On Slated. With keyd stopped (`sudo systemctl stop keyd`), the Hyper Key row says keyd isn't
      running, and Copy Command copies the command that starts it. With espanso stopped (`espanso
      stop`), the Hotstrings row says so within a few seconds and copies `espanso start`.
- [ ] Get Started opened while the Extensions switch or Slated is off leads with that and its button,
      above the welcome.
- [ ] With no `~/.local/state/slated/settings-window.json`, `gnome-extensions prefs
      slated@shobhitg.github.io` opens on Get Started, first in the sidebar with a "1 of 5" badge.
      The Hyper key step recommends keyd with its command until `linux/install.sh --hyper-keyd` has
      run, then says keyd is in charge. The hotstrings step says whether espanso is installed and in
      sync, and its button reads Skip for Now until it is. The Slate config step lists your
      `~/.slate.js` and its bindings. Done lists Slated running, the Hyper key, hotstrings and
      shortcuts, and its "Try it now" shortcut moves the settings window.
- [ ] Start Using Slated lands on the Overview, which says "Everything's running"
      (`linux/install.sh --verify` agrees), and Get Started leaves the sidebar. Closing and reopening
      the window opens on the Overview again. What's Next → Get Started opens it from the welcome.
- [ ] Settings → Windows names your `~/.slate.js` functions by what they do ("First Third", with
      "JavaScript function" under it), as on the Mac.
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
- [ ] Importing a `~/.slate.js` with a binding that moves the window itself keeps the file loading;
      the imported bindings show "Imported" in the Slate list, and deleting one in Shortcuts frees its
      keys (the extension no longer registers the file's copy).
- [ ] Turning "Slated is on" off and on in General disables and enables the extension.
- [ ] General → Island: turning "Show the island" off greys out its other three rows, and within a
      second feedback and running automations move to the bottom banner and the red pill; on again,
      they're back in the island. With
      "Hold Caps Lock to see your shortcuts" off, holding Caps Lock shows nothing and the delay is
      greyed out. Short makes the sheet appear sooner than Long. With "Explain shortcuts that can't
      run" off, a window shortcut with nothing focused shows no reason.
- [ ] Hotstrings: with espanso running, a new hotstring appears in `~/.config/espanso/match/slated.yml`
      and expands in another app.
- [ ] Automation: adding Auto-Click Left asks for a shortcut (F6 is suggested). Pressing it in a game
      clicks; Running Now lists it, its row says Running, and the stop shortcut stops it.
- [ ] Works In → Only in some apps lists the game you just played under Used Lately (a Proton game
      by its `steam_app_…` window class). Once limited, a plain key such as F records.
- [ ] Clipboard: the pill says Recording and the count grows as you copy. KeePassXC is offered under
      Password Managers when installed. Clearing the shortcut (Backspace while recording) turns off
      Super+Shift+V; Default puts it back.

## Manual checklist: GNOME clipboard picker

Run on GNOME 46 (Ubuntu 24.04) and GNOME 49 after changes to `lib/platform/clipboard*.js`,
`caret.js` or the stylesheet, at 100% and at 200% (or fractional) scaling, with a second display.
- [ ] Super+Shift+V in GNOME Text Editor, Firefox, a GTK3 app and an X11 app with IBus
      (`GDK_BACKEND=x11 gnome-text-editor`, or an Electron app) opens the picker 4 px below the
      text cursor, left edges aligned; near the bottom of the screen, above it. `scripts/logs.py
      --grep switcher_opened` says `"anchor":"caret"` with `"source":"input-method"` (Wayland) or
      `"ibus"` (X11), and nothing about where.
- [ ] Where nothing reports a cursor (the desktop, a game, Chrome without `--enable-wayland-ime`),
      it opens at the pointer (`"anchor":"pointer"`), kept on that display.
- [ ] It looks like the Mac's: 320 px wide, a filter field with only "Ctrl+1–9 · esc", one-line
      rows with the app's icon, pinned items first with a pin, Ctrl+1…Ctrl+9 on the first nine and
      half a row showing below when there are more. No header or footer.
- [ ] Typing filters at once (digits too). ↑↓ move the highlight; the pointer resting over the list
      doesn't take it back, moving it does. ↩, a click or Ctrl+1–9 paste into the window you were
      in; esc or a click outside closes. Ctrl+P pins, Ctrl+Backspace deletes, Ctrl+Shift+Backspace
      clears all but pinned items.
- [ ] Images: a screenshot copied to the clipboard (Print Screen → Copy), Copy Image in Firefox and
      a copy in GIMP each show a thumbnail row "Image · W×H · App". Selecting one shows it at about
      240 px beside the picker, level with its row (left of it near the right edge of the screen),
      with "W×H · size" under it. Pasting it into LibreOffice Writer or GIMP pastes the image, and
      it isn't recorded again. Copying cells in LibreOffice Calc records their text.
- [ ] `~/.local/state/slated/clipboard-images` is `drwx------` and its files `-rw-------`, named by
      SHA-256. Copying the same image twice keeps one file; deleting its item removes it. A PNG
      over 20 MB is skipped (`clipboard.skipped`, "image too large"). `clipboard.captured` for an
      image has only `kind`, `bytes`, `width` and `height`.
- [ ] With "Keep history across restarts" off, turning Slated off and on (or locking the screen)
      leaves `clipboard-images` empty.
