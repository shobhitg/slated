# Open questions

Decisions I made on my own while you were away, and questions only you can answer. Each has the
assumption I'm currently running with, so nothing is blocked.

## Please answer

1. **The third addition.** You mentioned three things to add on top of Slate; I counted two (Caps Lock
   → Hyper from Karabiner-Elements, hotstrings from Keyboard Maestro). What's the third?
   *Assumption:* those two only.

2. **Bundle ID and GitHub home.** *Answered (2026-10-30):* the author's personal account,
   github.com/shobhitg/slated. Bundle ID `io.github.shobhitg.slated`, GNOME extension
   `slated@shobhitg.github.io`. The rename reset Accessibility once, before any public release.

3. **Install Xcode?** Only the Command Line Tools are installed. Everything builds without Xcode,
   but Swift Testing/XCTest aren't available, so tests run through a small harness (`make test`).
   Installing Xcode would let us use Swift Testing, SwiftUI previews, and the debugger UI, and is
   needed for a future Mac App Store version.

4. **Apple Developer Program.** *Answered (2026-10-30):* no. Slated is a free open-source app; no
   yearly fee. Local builds keep the self-signed "Slated Dev" certificate (`make dev-cert`), which costs
   nothing and keeps Accessibility permission across rebuilds. Prebuilt downloads, if any, aren't
   notarized: macOS blocks the first open until you choose Open Anyway in System Settings → Privacy &
   Security. Building from source (`./install.sh`) never hits that.

5. **Mac App Store.** *Answered (2026-10-30):* no (it needs the paid program, and its sandbox blocks
   the Hyper key).

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
- **The GNOME island hangs from the top bar** of the monitor you're working on (from the top edge on
  the others and over fullscreen windows) instead of covering the clock at its center.

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
  deleting happen in the picker (Super+Shift+V): Ctrl+P, Ctrl+Backspace and Ctrl+Shift+Backspace
  stay there on GNOME, though the Mac's picker moved them to Settings → Clipboard, because showing
  the items in Settings would need another channel between the extension and the settings window.
  Ctrl+C (copy without pasting) went, as on the Mac: turn off "Paste after picking" for that.
- **The GNOME picker opens at the text cursor the input method last heard of** (Wayland
  text-input through Main.inputMethod, X11 apps through IBus), while that window and field still
  have focus; GNOME Shell can't ask an app on demand like macOS's Accessibility. Otherwise it opens
  at the pointer (there's no focused-field fallback as on the Mac). Placement is the core's
  PopupPlacement, the same vectors as Swift.
- **GNOME records copied images as PNG only** (what GNOME apps offer; a Mac history's TIFF files are
  kept and pasted as TIFF), stored and cleaned up like the Mac's. A history file that can't be read
  keeps its images, so fixing the file brings them back.
- **Get Started on GNOME** has the Mac's five steps, with the permission step's place taken by what
  GNOME needs instead: welcome → Hyper key (recommends keyd) → hotstrings (checks espanso) → Slate
  config → done. "Finished" lives in `~/.local/state/slated/settings-window.json`, so it isn't
  shared with the Mac through config.json, and a GNOME setup that predates the page sees it once.
- **The GNOME island reads Caps Lock's hold from the modifier state**, since GNOME reports no
  modifier presses: about 7 times a second while idle and 20 while a Hyper modifier is down, only
  while the cheat sheet can show. So a key that isn't a Slated shortcut doesn't cancel the sheet, and
  with GNOME's `caps:hyper` option holding Super alone shows it too (keyd doesn't have this).
- **With keyd's tap for Escape, a long hold sends nothing, as on the Mac** (done 2026-10-27).
  `linux/install.sh --hyper-keyd` sets keyd's `overload_tap_timeout` (in a `[global]` section of
  `/etc/keyd/slated.conf`) to the cheat-sheet delay (at most 1 s), or 1 s with the cheat sheet off,
  as the Mac does. Since the file is root's, changing the delay takes another run of the installer
  (the delay's row in Settings says so). keyd reads the option from 2.4.3 on; 2.4.0–2.4.2 skip it with a logged error and keep sending
  Escape after a long hold, and the installer warns about that. `overloadt()`/`overloadt2()` would
  have the same limit but hold the Hyper modifiers back until the timeout (slowing quick combos and
  the cheat sheet), and on older keyd they'd break the whole Caps Lock line.


## macOS runtime review (2026-10-27)

15. ~~**Window titles in saved snapshots.**~~ **Decided (2026-10-27): hashes.** Snapshots find windows
    again by comparing titles for equality only, so `snapshots.json` now keeps a SHA-256 of each title
    instead of the title. Windows are matched as before; an older file with titles is read and
    rewritten with hashes at the next launch.
16. ~~**Universal Clipboard.**~~ **Decided (2026-10-27): this Mac only.** Slated's temporary paste of a
    hotstring replacement or insert-text is written as this-Mac-only, so your other devices never get
    it. Real copies and clipboard history picks are left alone.
*17–19 are superseded by the config split (2026-10-29, below): Slate files no longer load, so
nothing "keeps loading" and `importedSlateShortcuts` is only read once, to migrate.*

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

## Clipboard picker and images (2026-10-27): decisions

- **⌘1–9 pick, not bare 1–9:** the filter takes typing at once, so digits filter (dates, prices).
  The hint in the picker says "⌘1–9 · esc".
- **The pointer selects the row under it** (one highlight, like a menu), except while it rests where
  it was when a key moved the selection, so the list scrolling under it doesn't steal it.
- **Opened from Slated's window, the picker opens at the pointer:** the caret of the app you
  were in is behind that window. It still pastes into that app.
- **A copy with text and an image counts as text** (spreadsheet cells, Finder files carry a picture of
  themselves). Images over 20 MB aren't kept (an uncompressed TIFF of a 5K screen is about 60 MB;
  as PNG, a few MB).
- **The picker still makes Slated the active app while it's open** (as the switcher did), so the
  app you're in shows as inactive for that moment; pasting brings it back first.

## Config split (2026-10-29): decisions

Your direction: everything configuration-based, in two files, without catering to the old Slate.
On the Mac side (the GNOME port follows the same spec):

- **Files:** `config.json` (version 2: `keyboard`, `bindings`, `hotstrings`, `layouts`, `defaults`)
  and `settings.json` (`general`, `windows`, `clipboard`, `automation`, `island`). One configuration
  in memory; a save writes only the file whose part changed, so a hand-formatted file with comments
  stays as it is until you change something in it. A missing `settings.json` is all defaults; a
  deleted `config.json` is written again on the next save (otherwise the next launch would be a
  first run).
- **`settings` is now `windows`**, in the model too (`SlatedConfiguration.windows`).
- **Slate files are never run.** The live loader, JavaScript hotkeys, event handlers, JavaScript
  layouts and display defaults, the read-only Slate rows in Windows and Layouts, and the Slate
  Compatibility page as it was are gone. That page is now **Import from Slate**: an Import button,
  what the last import did, and what couldn't be converted. The JavaScript engine stays, to import.
- **Import reads `~/.slate.js`, else `~/.slate`** (one file, as Slate does). The migration reads
  your old `slateConfigPaths` (both files when both exist), else the same.
- **A script whose import may not match this Mac** (it runs `slate.shell` or moves windows while
  loading, or stops with an error on the pretend Mac) is now imported anyway, as far as it got, and
  the alert and the Import page say it may not match. Before, nothing was imported and the file kept
  loading; with no loading, importing nothing would lose every shortcut. *Question:* or would you
  rather import nothing from such a file?
- **Merge rule:** what Slated has wins: a shortcut with the same keys, modal key and app filter
  (an off one counts), a layout of the same name, an equal display default, a setting already set.
  Within one Slate file, the first binding on a key wins. Re-importing adds nothing twice; a
  shortcut you deleted after importing comes back on the next manual import (there's no list of
  imported shortcuts any more).
- **Not converted, listed by keys** (`hyper+t`, shown as ⌃⌥⇧⌘T) with why: functions that depend on
  the window or app, every `slate.on` handler, layouts and display defaults with JavaScript steps,
  and `config` values from functions. A classic `~/.slate` line that doesn't parse is listed as
  `line N`.
- **Migration** happens at load on either platform, once: `config.v1.json` beside `config.json`
  (never overwritten; if it can't be written, nothing is migrated that launch); an existing
  `settings.json` wins over the old sections; settings.json is left untouched when it says the same.
  Logged as `config.migrated` with counts only.
- **The notice** ("Your ~/.slate.js shortcuts are now part of Slated's config…") is kept in
  `~/Library/Application Support/Slated/slate-import-notice.json` until you click Got It, so it shows
  whenever the window next opens (also after a first-run import; Get Started uses it too).
- **Fixtures:** `fixtures/config.json` now pins both files (`config`, `settings`, `legacy`,
  `errorFile`, and a `files` section). Until the GNOME port reads that shape, `make linux-test`
  fails on it.

## Screenshots and copied files in clipboard history (2026-10-30): decisions

Your request: screenshots saved as files should show up, and maybe other files, as a small
thumbnail and the name with a bigger preview on hover. On the Mac side (GNOME follows the same spec):

- **A file's name is the last part of its path** ("Report.pdf", a folder's name), not the Finder's
  display name: extensions show even where the Finder hides them, so searching "pdf" finds PDFs, and
  GNOME names files the same way. Folders in the path aren't searched.
- **File rows are text rows** (26 pt) with a 16×20 pt QuickLook thumbnail, so names line up with
  text. Image rows, screenshots included, are as before; a screenshot reads as its file name instead
  of "Image · W×H".
- **Only screenshots taken while the setting is on are added**: files created since Slated started
  watching (launch, or turning the setting on). One renamed later, or an older one moved into the
  folder, isn't new. A screenshot counts once its name is final (screencapture's hidden temporary
  file is skipped) and its size held for 0.3 s.
- **Where screenshots go is re-read every 5 seconds**, and a folder Slated couldn't see (or that
  wasn't there) is tried again then, so allowing access in System Settings works without a restart.
  The folder is listed off the main thread: macOS's access prompt blocks the call that triggers it.
- **JPEG, HEIC or GIF screenshots are kept as PNG** (the type every app pastes); PDF screenshots
  aren't kept (logged as unreadable). PNG and TIFF keep their bytes.
- **Some files gone:** the rest are pasted, and the log says how many were missing
  (`clipboard.files_missing`). **All gone:** the picker stays open and beeps (closing it would look
  like a paste happened), and Settings' Copy button is off for that row.
- **"Moved or deleted"** means the path no longer exists. A file Slated isn't allowed to look at
  counts as there: the app you paste into reads it, not Slated.
- **Screenshots aren't searched by name** (the spec searches text only, and images have none).
  *Question:* should typing "screenshot" find them? It's a small model change on both platforms.
- **The same image bytes copied again replace the item's name** (images dedupe by content as before),
  so a screenshot copied back in from elsewhere loses its name. Slated's own paste keeps it.
- **QuickLook thumbnails read the file**, so a file copied from Documents or Downloads may make
  macOS ask whether Slated may see that folder, the first time its thumbnail is shown. Saying no only
  costs the thumbnail (the file's icon shows instead); pasting still works. *Question:* would you
  rather have plain kind icons for files outside the Desktop, and never that prompt?
- **Tests and smoke runs never see your screenshot folder**: with `SLATED_HOME` set, Slated watches
  that home's Desktop and ignores the Screenshot app's preference.
- **Fixtures:** `fixtures/clipboard.json` gains `addFiles` steps, `files` on items, `name` on images,
  a `fileNames` section and coding vectors for both fields; `fixtures/config.json` and `starter.json`
  gain `clipboard.screenshots`. Until the GNOME core matches, `make linux-test` fails on those.

## Linux installer: one command (2026-10-31): decisions

Your request: `linux/install.sh` should do everything, keyd included, with Linux as prominent as the
Mac in the README, on any distribution that has GNOME 46 or later.

- **One command, no y/N questions on the way.** sudo's own password prompt is the consent; before the
  first one the installer says in one line what it's for. The only question is the last one, "Log
  out now to start Slated?". `--yes` asks nothing and never logs you out. `--hyper-keyd` no longer
  asks before writing keyd's config (removing it with `--remove` still asks).
- **Run as yourself, never with sudo:** the installer refuses to run as root, since the extension and
  config live in your home.
- **GNOME 46–51 only (your call, 2026-10-31)**, read from `metadata.json`'s `shell-version`. On
  another desktop, an older or newer GNOME, or a session that isn't GNOME's while GNOME is installed
  (Pop!_OS 24.04's COSMIC), the installer stops before changing anything and names what it found
  (the version, or `XDG_CURRENT_DESKTOP`). It must run in the GNOME session because keyd and espanso
  are set up for the session you're in (espanso has X11 and Wayland builds). Over ssh, espanso's
  build follows the graphical session logind reports.
- **keyd:** the distribution's package when the package manager knows one (Ubuntu 26.04, Debian 13,
  Arch, openSUSE), else v2.6.0 built from source at its pinned commit (Ubuntu 24.04 and so Pop!_OS
  24.04, Fedora, any other GNOME distribution with a C compiler). The build runs as you in `build/linux/keyd-src`
  (log in `build/linux/keyd-build.log`); only `make install` runs as root. Without systemd it asks
  you to start keyd with your init system.
- **espanso:** v2.4.1. With apt, the Debian package for the session (X11 or Wayland); elsewhere on
  Xorg, the AppImage in `~/opt` (espanso's own layout) plus FUSE 2; Wayland outside Debian and Ubuntu
  (Fedora; on Arch it's in the AUR) and ARM have no package, so it says so and carries on. espanso
  publishes no checksum files, so the pins are GitHub's SHA-256 digests of the release files.
- **Pins live at the top of `linux/install.sh`.** Updating means a new tag and commit for keyd and
  new digests for espanso (the `gh api` commands are in the comments).
- **Session type:** `XDG_SESSION_TYPE`; with none (over ssh), Wayland, the default on every supported
  GNOME.
- **No restarting GNOME Shell for you.** On Xorg (GNOME 48 and earlier) Alt+F2 `r` restarts it in
  place, but no program can: GNOME closed `org.gnome.Shell.Eval` in GNOME 41, and the systemd unit
  refuses a manual restart. So on Xorg the last step names Alt+F2 `r` and still offers to log out.
  Logging out uses `gnome-session-quit --logout --no-prompt`: you already said yes, and GNOME still
  asks about apps with unsaved work.
- **Re-runs change nothing that's current:** the extension is reinstalled only when its files differ,
  keyd's config is written only when it changed, and nothing runs as root when nothing needs to.
- **Uninstall leaves keyd and espanso installed** (other things may use them) and says so.
- **The Mac's `./install.sh`** was already one command; it's unchanged.

## Opening Slated on GNOME (2026-10-30): decisions

The Mac's way in (a Dock app, a menu bar icon, Get Started at launch) on GNOME, where Slated is an
extension with no app of its own.

- **A top-bar icon** (`lib/platform/statusIcon.js`): Slated's tiles as a symbolic icon. A click opens
  the settings window, or brings an open one forward (GNOME's preferences service won't do that
  itself); a right click or Ctrl+click shows the Mac's menu under the Mac's names, minus Grant
  Accessibility Access, Import Slate Config and Quit. Pause bars while paused, an exclamation mark
  for warnings (a file that can't be read, shortcuts GNOME refused).
- **`general.showStatusIcon`** (default on) in the shared settings, Swift included, pinned by the
  fixtures. *Open:* should the Mac's menu bar icon follow it, with a switch in the Mac's General?
  *Assumption:* no for now; the Mac keeps its icon.
- **Pause Slated on GNOME** lets go of shortcuts, Caps Lock's GNOME option and espanso's match file,
  as on the Mac. It survives a screen lock (GNOME disables extensions while locked), not a login.
  keyd keeps mapping Caps Lock while paused: it's a system service.
- **Caps Lock → Hyper Key** in the menu writes `config.json` the way the settings window saves it.
- **Get Started at login:** 3 s after GNOME Shell starts Slated, until it's finished, once per GNOME
  Shell session (closing it isn't undone by unlocking the screen; the next login opens it again).
- **An app entry** (`io.github.shobhitg.Slated.desktop`, `Exec=gnome-extensions prefs <uuid>`) from the
  installer, not the extension: an extensions.gnome.org install has no app entry, only the top bar.
  The window it opens belongs to GNOME's preferences process, so the dash may group it under
  Extensions rather than Slated.
- **GNOME's Extensions switch:** the installer asks to turn it on (yes by default, `--yes` turns it
  on), since that starts every extension you had enabled. Settings offers **Turn On Extensions**
  (the UserExtensionsEnabled property, as the Extensions app sets it).
- **Settings never shows a bare "Waiting":** each status row names what's missing and offers the fix.
  Whether espanso runs comes from `espanso status`, asked by the settings window while it's open;
  whether keyd runs comes from the extension (`status.json`'s `hyper.keyd`).
