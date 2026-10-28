# Open questions

Decisions I made on my own while you were away, and questions only you can answer. Each has the
assumption I'm currently running with, so nothing is blocked.

## Please answer

1. **The third addition.** You mentioned three things to add on top of Slate; I counted two (Caps Lock
   → Hyper from Karabiner-Elements, hotstrings from Keyboard Maestro). What's the third?
   *Assumption:* those two only.

2. **Bundle ID and GitHub home.** I used `io.github.shobhit-aida.slated` because `gh` is logged in as
   `shobhit-aida`. Will the repo live under that account, a personal one, or an org? Changing the
   bundle ID later resets the Accessibility permission (only for you, while you're the only user).

3. **Install Xcode?** Only the Command Line Tools are installed. Everything builds without Xcode,
   but Swift Testing/XCTest aren't available, so tests run through a small harness (`make test`).
   Installing Xcode would let us use Swift Testing, SwiftUI previews, and the debugger UI, and is
   needed for a future Mac App Store version.

4. **Apple Developer Program.** Needed for notarized releases (Homebrew cask, downloads) and the Mac
   App Store. Do you have a membership? *Assumption:* not yet; local builds use a self-signed
   "Slated Dev" certificate (`make dev-cert`).

5. **Mac App Store.** You mentioned making it a Mac app later. App Store apps must be sandboxed, and
   the sandbox blocks the Hyper key (`hidutil` + event tap) and likely hotstrings. Window management
   via Accessibility is possible there (Magnet does it). *Assumption:* the direct-download app stays
   the full-featured version; a store edition, if any, would be a reduced build.

6. **Caps Lock tapped alone.** Your Karabiner rule makes Caps Lock pure Hyper. Should a quick tap on
   its own send Escape (a common Karabiner rule)? *Assumption:* no, matching your current setup; it's
   a toggle in Settings → Keyboard.

7. **Your Keyboard Maestro hotstrings.** Should Slated import them? I didn't read your Keyboard
   Maestro macros file without asking, since macros can contain private text.

8. **Spaces.** Public APIs can't move windows between Spaces. *Assumption:* public APIs only;
   Slated works within the current Space. Tell me if "throw window to Space N" matters to you.

## Decisions I made (tell me if you disagree)

- **Config format changed from my earlier TOML recommendation to JSON** at
  `~/.config/slated/config.json`, because the settings UI has to write the file. JSON round-trips
  with Codable and no third-party parser; TOML would need one and would lose comments on save
  anyway. Hand edits may use comments and trailing commas (JSON5).
- **Your `~/.slate.js` runs as-is** (JavaScriptCore implementation of Slate's JS API), alongside
  bindings you create in the UI. No conversion needed. Classic `~/.slate` files work too.
- **The UI shows Slate-file bindings read-only** with a "Copy into Slated" option, rather than
  rewriting your JS file.
- **Slate's beta app switcher (`switch`)** is parsed but not implemented yet. It replaced Cmd-Tab
  via an event tap, which is fragile; I'd rather build a proper switcher later if you want one.
- **`~/.slate.js` gets Slate's whole JavaScript API**, plus a small built-in subset of underscore.js
  (`_`), which Slate preloaded for configs. Where Slated differs: a mistake is reported with its line
  and the rest of the file still loads (Slate showed a Quit/Skip alert); `slate.bind` only works
  while the config loads; and `repeatOnHoldOps` applies to every binding wherever it's set in the file.
- **A runaway loop in `~/.slate.js` would freeze Slated**, as it froze Slate: JavaScriptCore can only
  interrupt a script through private API. Tell me if that matters; the fix would be running scripts
  in a helper process.

## Slate engine: expressions, operation syntax, frame math

Where Slate's code and its README disagreed, or Slate had an obvious bug, here is what Slated does.
None of this affects your `~/.slate.js` except the first item, by at most a point or two.

### Please answer

1. **Division in expressions.** Slate evaluated expressions with `NSExpression`, which truncates
   when both sides are whole numbers (checked on this Mac: `10/4` is 2, `1366*2/3` is 910). Slated
   divides exactly (2.5, 910.67). On your screens `screenSizeX/3` and friends differ by under a point,
   and a mistake like `1/2*screenSizeX` works instead of giving 0. *Assumption:* exact division.
2. **`throw next` / `throw previous`.** Slate's README says "screen ID + 1", but its code steps
   through screens in macOS's internal order, not left to right. *Assumption:* Slate's code (macOS
   order). Left-to-right would feel more natural with three screens; say if you want that.

### Decisions I made (tell me if you disagree)

- **`throw down` / `throw bottom`** go to the screen below. In Slate they silently threw to screen 0
  (a bug: "down" was never matched).
- **A direction with no screen sharing that edge** (displays meeting only at a corner) picks the
  nearest screen lying entirely in that direction; Slate did nothing.
- **`push … bar-resize:expr` and `corner … resize:w;h`** treat the expression as one unit, as
  Slate's JavaScript API did. Slate's string form forgot the parentheses, so
  `push down bar-resize:screenSizeY-100` used to land 100 points too high.
- **Screens with the same left edge** are numbered lower one first, matching Slate (this changed
  `orderedLeftToRight()`).
- **Stricter, clearer parsing:** unknown options, extra parameters and bad expressions are errors
  with a message and line number, instead of being silently ignored. Expressions may contain spaces.
- **Small extensions:** `resize screenSizeX/2 50%` (no sign) sets an absolute size, `nudge 50 0`
  counts as `+50`, `push up 1` and `corner top-left 1` accept a screen without a style, and app names
  in `hide`/`focus` may contain commas or `|` when quoted.
- **Slated's own operations** in the same syntax: `insert-text [type|paste] 'text'` (with `\n`,
  `\t`, `\\` escapes), `open-url 'https://…'`, `keystroke cmd+shift+4`.
- **Not supported yet:** per-app settings (`config snapshotTitleMatch:'App' …`) and sourcing a
  `.js` file from a `.slate` file; both load with a warning.

## Settings UI: decisions and open items

- **Hotstrings on/off switch** is saved in `config.json` as `general.hotstringsEnabled`, so it
  survives restarts and can be set by hand. **Pause Slated** (Slated menu, menu bar icon) lasts only until you resume
  or relaunch.
- **One main window (2026-10-27, the author's call):** Slated is a regular app, always in the Dock.
  Setup is Get Started, a page of the main window; closing the window keeps Slated running.
- **Menu bar icon:** left click opens the main window; right click opens a small classic menu
  (Pause, Reload, Import Slate Config, Open Config File, Show Log, Quit).
- **Not built yet:**
  - an editor for Slate's display-change defaults (`default` / `ScreenDefault`);
  - reordering layouts by drag;
  - Hyper modifier sets other than Hyper (⌃⌥⇧⌘) or Meh (⌃⌥⇧).

  Tell me which matter.
- **About pane link** to the GitHub repo waits on question 2 (where the repo will live).

## Notch island

13. **Feedback on by default?** Naming each action as it runs ("Left half · Safari") is still off by
    default, as before; now that it shows at the notch instead of mid-screen it's less intrusive.
    *Assumption:* off (Settings → General → "Show what just happened"). Failures ("No focused window
    to move") are explained by default.

### Decisions I made (tell me if you disagree)

- **Hold Caps Lock half a second** to see every Hyper shortcut. Quick combos never show it.
- **With Caps Lock tapped alone sending Escape**, a hold longer than that delay sends nothing, so
  looking at the cheat sheet never sends Escape (like Karabiner's `to_if_alone` timeout).
- **Running automations show beside the notch** instead of the red pill; hover to see them and stop
  them. With the island off, the pill comes back.
- **No GNOME island yet.** Linux keeps the settings; a GNOME version could follow.

## Linux (GNOME) port

9. **Which Linux?** Distro, GNOME version (`gnome-shell --version`) and session type
   (`echo $XDG_SESSION_TYPE`). *Assumption:* GNOME 46–51 on Wayland (Ubuntu 24.04+, Fedora 40+);
   50 and 51 are declared but untested.
10. **Docker for GNOME tests.** Docker Desktop is installed here but not running. If you start it,
    the headless GNOME Shell tests can run on this Mac, verifying the extension without a Linux
    machine. *Assumption:* left off; CI runs them.
11. **Hotstrings on Linux via espanso.** GNOME blocks apps from watching the keyboard. Slated
    generates espanso's config from your hotstrings (espanso is a mature open-source text expander
    that works on GNOME). OK to depend on it, or do you want a native engine (which needs keyboard
    device permissions: the `input` group and a udev rule)?
12. ~~**Hyper key on Linux.**~~ **Answered (2026-10-27): keyd, as recommended.** Settings → Keyboard
    lists keyd first and marks it Recommended, and `linux/install.sh` points at
    `--hyper-keyd` (sudo, once) while it isn't set up. GNOME's own option stays as the fallback.
14. ~~**Games and app ids on Linux.**~~ **Answered (2026-10-27):** mostly Factorio, and no password
    manager: passwords live in the browsers' own managers.
    - Factorio is a native Linux game, so a per-game shortcut goes by its window class. Run it once
      and pick it from Recent Apps under "Works In" (older Factorio versions set no window class;
      tell me if it doesn't show up there). It has no anti-cheat, so synthesized input is fine.
    - On the Mac, Chrome and Firefox mark copied passwords as secret, and clipboard history skips
      them; Safari fills passwords without the clipboard, and Apple's Passwords app is excluded.
      On Linux, Firefox marks them but Chrome reportedly doesn't, so GNOME's clipboard history now
      also skips anything from a Chromium browser that looks like a password (one word with upper-
      and lowercase letters plus a digit or symbol).

### Linux decisions (tell me if you disagree)

- **Mouse buttons can't be shortcuts in GNOME.** Bindings on mouse buttons 3–5 show as failed there;
  keyd can turn the side buttons into F13–F20, and Settings shows the hint. Kept as a warning, not
  an error, so a shared config still saves for the Mac.
- **`while-held` repeats stop through key repeat**, because GNOME only reports key presses: about
  0.1 s after you let go, or right away when you press another key. With key repeat off, or for
  repeats that type keys themselves, a second press stops them.
- **Opening the overview counts as leaving the app:** automations stop, like switching apps.
- **The Clipboard settings page shows only how many items are saved.** Picking, pinning and
  deleting happen in the switcher (Super+Shift+V); showing the items in Settings would need another
  channel between the extension and the settings window.
- **No notch island on GNOME yet.** Running automations show as a pill at the top of the primary
  display, like the Mac's classic indicator.
- **Get Started on GNOME** has the Mac's five steps, with the permission step's place taken by what
  GNOME needs instead: welcome → Hyper key (recommends keyd) → hotstrings (checks espanso) → Slate
  config → done. "Finished" lives in `~/.local/state/slated/settings-window.json`, so it isn't
  shared with the Mac through config.json, and a GNOME setup that predates the page sees it once.


## macOS runtime review (2026-10-27)

15. ~~**Window titles in saved snapshots.**~~ **Decided (2026-10-27): hashes.** Snapshots find windows
    again by comparing titles for equality only, so `snapshots.json` now keeps a SHA-256 of each title
    instead of the title. Windows are matched as before; an older file with titles is read and
    rewritten with hashes at the next launch.
16. ~~**Universal Clipboard.**~~ **Decided (2026-10-27): this Mac only.** Slated's temporary paste of a
    hotstring replacement or insert-text is written as this-Mac-only, so your other devices never get
    it. Real copies and clipboard history picks are left alone.
17. **Importing a `~/.slate.js` with `slate.on` handlers.** *Now:* handlers for events Slated
    delivers (app events, display changes) are listed as staying in the file, which keeps loading.
    Window-event handlers, which Slated never runs, are reported as such and don't keep it loading
    (on GNOME the same for `appHidden`/`appUnhidden`). (Your `~/.slate.js` has none.)
18. **Partial imports (2026-10-27).** When a Slate file keeps loading after an import (something in it
    needs JavaScript), the shortcuts that were imported are listed in
    `general.importedSlateShortcuts` and the file's own copies are ignored, so Settings owns them; a
    later full import or turning Slate files off makes the list moot. Questions: is the name right
    (it's in config.json for good, shared with GNOME), and should "Load Slate configs" turned back on
    later bring the file's copies back? *Assumption:* the list stays and keeps them ignored.
19. **Imports that may not match this Mac.** The importer runs the script on pretend Macs. If loading
    it there hits an error, or the script runs `slate.shell` (or moves windows) while loading, nothing
    is imported from that file and it keeps loading; the alert says why. *Assumption:* safer than
    importing what it could, since an imported copy would win over the file's real one. A bound
    function that reads the app's name or a window's title is likewise left in the file.

## End-to-end review (2026-10-27): decisions

Made while fixing what the review found; each is easy to change if you disagree.

- **Square displays count as portrait** for `by-orientation`, matching your `~/.slate.js`
  (`width > height` means landscape).
- **Unknown Hyper modifier names are an error** (`"cmmd"` used to vanish silently and drop ⌘).
- **Display defaults on disk** are `{"target": "x", "count": 2}` or
  `{"target": "x", "resolutions": [...]}`; the old `{"condition": {"count": {"_0": 2}}}` still reads.
- **Unknown top-level sections of config.json are kept** when Slated saves, so a newer version's
  settings survive an older one. Unknown fields inside known sections are still dropped.
- **Expressions** may have at most 1,000 terms and 200 levels of nesting, instead of crashing.
- **Settings is read-only while config.json can't be read**, and a save never overwrites a hand
  edit Slated hasn't seen yet. A config.json symlink to a missing file is an error.
- **Caps Lock mapping:** Slated adopts a Caps Lock → F18 mapping only if it made it itself, puts back
  a Caps Lock mapping it replaced, and leaves other tools' mappings alone.
- **Test runs** (`SLATED_HOME` set) never change the keyboard.
- **Hotstrings:** Settings warns when one trigger fires while you type another (`sh` inside `;shrug`).
- **GNOME:** keyd counts as the Hyper key only when systemd runs it and a keyd config maps Caps
  Lock; automation shortcuts are ignored while the overview is open; sleep stops automations;
  auto-repeats type nothing while you hold a modifier (nothing reaches the Alt+Tab switcher).

Known small gaps left open: rare clipboard-search differences between the Mac and GNOME (ligatures
such as "ﬃ"), and keyd started by hand (not through systemd) isn't noticed on GNOME.
