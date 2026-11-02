# Slated for Linux (GNOME)

Slated for Linux is a **GNOME Shell extension** with a settings window. It uses the same files as
the Mac app: `~/.config/slated/config.json` (what your keys do) and `settings.json` beside it (how
Slated behaves). A `~/.slate.js` or `~/.slate` is imported into them once; Slated doesn't read
Slate files after that ([Your Slate config](#your-slate-config)).

> **Status:** early development, for GNOME 46–51 (Ubuntu 24.04 to 26.04, Fedora 40 to 45). It was
> written and reviewed against GNOME 46–49; 50 and 51 load it but haven't been tested yet. There's no
> extensions.gnome.org release yet, so install from source.

## Why an extension

On Wayland, apps can't move other apps' windows or watch the keyboard. Only GNOME Shell can, so
Slated runs inside it, like other GNOME window-management tools. That brings some limits, covered
under [Limitations](#limitations): it works only on GNOME, and updates load when you next log in.

| Part | What it does | Where |
|---|---|---|
| Extension | Window management, shortcuts, overlays, the island, the Hyper key, espanso's match file, game automation, clipboard history, status and log | `linux/gnome-extension/extension.js`, `lib/platform/` |
| Engine | Expressions, Slate syntax, window math and config: the JavaScript port of `SlatedCore` | `linux/gnome-extension/lib/core/` |
| Settings | The libadwaita preferences window: GNOME's version of the Mac settings app. Also the Slate importer and the config migration, which the extension shares | `linux/gnome-extension/prefs.js`, `lib/prefs/` |

## Install

You need `git` and `python3`; the installer brings everything else.

```sh
git clone https://github.com/shobhitg/slated && cd slated
linux/install.sh
```

That's the whole setup. Run it again whenever you like (after a `git pull`, say): it redoes only what's
out of date, and when nothing is, it changes nothing and asks for no password. Each run:

1. **Looks first, changing nothing:** GNOME Shell's version, X11 or Wayland, the distribution and
   the package manager (apt, dnf, pacman or zypper). Slated needs GNOME 46–51 and the installer must
   run in that GNOME session (or over ssh): elsewhere it stops here, naming the GNOME version or the
   desktop (`XDG_CURRENT_DESKTOP`) it found.
2. **Installs Slated's extension:** packs it with `build-info.json` (version, git commit, build
   date), installs it into `~/.local/share/gnome-shell/extensions/` and enables it, on every run (you
   may have turned it off). If GNOME's Extensions switch is off (the Extensions app's main switch,
   `org.gnome.shell disable-user-extensions`), no extension runs at all: the installer says so and
   asks to turn it on ("Turn on GNOME extensions? [Y/n]", yes by default; `--yes` turns it on), since
   that also starts the other extensions you had turned on. It also **puts Slated in your apps**: a
   desktop entry, `~/.local/share/applications/io.github.shobhitg.Slated.desktop`, and its icon in
   `~/.local/share/icons/hicolor`, which open Slated's settings window.
3. **Sets up the Hyper key** when Slated's config wants Caps Lock as Hyper (the default): installs keyd
   from your distribution's packages, or builds a pinned keyd release from source where there's no
   package (Ubuntu 24.04, Fedora; it installs gcc and make first). Then it writes
   `/etc/keyd/slated.conf` from your settings and starts keyd ([The Hyper key](#the-hyper-key)).
4. **Sets up hotstrings**, unless they're off in Settings: installs espanso for your session and
   starts it ([Hotstrings](#hotstrings)).
5. **Checks what GNOME says** about Slated (`gnome-extensions info`): enabled and running, or that it
   starts at your next login, or what's wrong and how to fix it.
6. **Sums up** each step (✔ done, • skipped and why, ✘ failed and what to do), says how to open
   Slated, and names the one step left. GNOME Shell loads extensions when it starts, so that's logging out and back in, which the
   installer offers to do. In an Xorg session (GNOME 48 and earlier) you can press Alt+F2, type `r`
   and press Enter instead: GNOME Shell restarts in place and your windows stay open. Only you can
   do that; the D-Bus call other programs used for it is closed since GNOME 41.

Steps 3 and 4 need root, for packages and `/etc/keyd`. Before the first `sudo`, the installer says in
one line what it's for; then sudo asks for your password as usual. Nothing else runs as root, and you
run the installer as yourself, not with sudo.

Once you're back, Slated's settings window opens on Get Started after a few seconds. Afterwards,
find Slated in your apps or click its icon in the top bar ([Opening Slated](#opening-slated)).

```sh
linux/install.sh --verify     # checks GNOME runs Slated, then prints "Running: build abc1234"
```

`--verify` changes nothing. It checks, in order, GNOME's Extensions switch, whether Slated is enabled,
its state (`ACTIVE`; `ERROR` with GNOME's error message; `OUT OF DATE`; `INITIALIZED`, which a login
fixes), and only then which build runs. Each problem gets one line with the fix, usually "run
`linux/install.sh`", which turns both switches on.

| | |
|---|---|
| `linux/install.sh --yes` | Ask nothing, for scripts. It never logs you out |
| `linux/install.sh --no-keyd` | Leave keyd out: Slated uses GNOME's own Caps Lock option ([The Hyper key](#the-hyper-key)) |
| `linux/install.sh --no-espanso` | Leave espanso out: hotstrings don't expand |
| `linux/install.sh --hyper-keyd` | Only the keyd step, after changing the Hyper key's settings. `--remove` removes Slated's keyd config |
| `linux/install.sh --nested` | Also start a nested GNOME Shell with the new build, so you don't have to log out (see [Development](#development)) |
| `linux/install.sh --verify` | Only check that GNOME Shell runs Slated, and which build. Changes nothing |
| `linux/install.sh --check` | Run the Linux tests first (needs Node), and install only if they pass |
| `linux/install.sh --uninstall` | Remove the extension and Slated's app entry but keep config and logs. Add `--purge` to also remove those, Slated's espanso match file and its keyd config. keyd and espanso stay installed: remove them with your package manager |
| `make linux-install`, `make linux-pack` | Same as `linux/install.sh` and `linux/install.sh --pack-only` |

The installer downloads only pinned releases, listed at the top of `linux/install.sh`:

| | Version | From | Checked by |
|---|---|---|---|
| keyd, where your distribution has none | v2.6.0 | `git clone` of [rvaiya/keyd](https://github.com/rvaiya/keyd) | the commit the tag must point at |
| espanso | v2.4.1 | [its GitHub release](https://github.com/espanso/espanso/releases): `espanso-debian-x11-amd64.deb` or `espanso-debian-wayland-amd64.deb` with apt, `Espanso-X11.AppImage` elsewhere on Xorg | SHA-256: GitHub's digest of each file, since espanso publishes no checksum files |

Below, "Settings" means Slated's settings window, and "GNOME Settings" means GNOME's.

### Opening Slated

As on the Mac, where Slated is a Dock app with a menu bar icon:

- **The first login** after installing: the settings window opens on Get Started a few seconds in.
  It does that at each login until Get Started is finished, and once per session: closing it isn't
  undone by locking and unlocking the screen.
- **Your apps:** Slated is in the app grid and in Activities search, like any app (the installer's
  desktop entry).
- **The top bar:** Slated's icon (three tiles). A click opens the settings window, or brings it
  forward when it's open. A right click (or Ctrl+click) shows the Mac's menu, as far as it applies
  on GNOME:

  | Item | What it does |
  |---|---|
  | Slated is running / paused | What's going on, then a ⚠ line for anything that needs attention (a file that can't be read, shortcuts GNOME refused) |
  | Open Slated | The settings window |
  | Caps Lock → Hyper Key | Turns the Hyper key on or off (`keyboard.capsLock` in `config.json`) |
  | Pause Slated | No shortcuts, Hyper key or hotstrings until you turn it off again, as on the Mac. It lasts until you log out; locking the screen keeps it. With keyd, Caps Lock still sends Ctrl+Alt+Shift+Super: keyd is a system service |
  | Reload Configuration | Reads `config.json` and `settings.json` again |
  | Open Config File, Open Settings File | Open them in your text editor |
  | Show Log | Opens `~/.local/state/slated` in Files |

  The Mac's Grant Accessibility Access (GNOME asks for no permission), Import Slate Config (it's in
  the settings window) and Quit (turn Slated off in General or the Extensions app) aren't there. The
  icon shows pause bars while Slated is paused, and an exclamation mark when the menu has a warning.
  **Settings → General → Show Slated in the top bar** (`general.showStatusIcon`) hides it.
- `gnome-extensions prefs slated@shobhitg.github.io` and the Extensions app's gear still work.

### The Hyper key

Turn on **Use Caps Lock as Hyper** in **Settings → Keyboard** (a new config starts with it on).
**keyd is the recommended way:** Caps Lock then works exactly like the Mac's Hyper key, and
`linux/install.sh` installs and sets it up. Without keyd (`--no-keyd`, or until the installer has
run), Slated uses GNOME's own keyboard option (`caps:hyper`), which it sets itself and removes again
when you turn the Hyper key off. The Keyboard page shows which method is active.

Slated uses keyd only while keyd runs (systemd says `keyd` is active; without systemd, keyd's socket
is there) and one of its configs maps Caps Lock: Slated's own `/etc/keyd/slated.conf`, or a
`capslock =` line in the `[main]` section of another `/etc/keyd/*.conf`. A keyd that only maps a
mouse's side buttons leaves Caps Lock to GNOME's option. Slated notices keyd starting or stopping,
and its configs changing, without logging out.

| | GNOME's keyboard option (xkb) | keyd |
|---|---|---|
| Setup | Nothing to install | `linux/install.sh` (installs keyd and `/etc/keyd/slated.conf`; asks for sudo) |
| What Caps Lock does | Acts as the Hyper modifier | Sends Ctrl+Alt+Shift+Super, like the Mac's Hyper key |
| Tap alone for Escape | Not possible | Yes, if the tap is turned on |
| Meh (Ctrl+Alt+Shift, no Super) | Not possible | Yes |

In many keyboard layouts, GNOME's option puts Hyper on the same modifier as Super. GNOME then treats
✦A and Super+A as the same shortcut. keyd avoids that.

keyd's configuration is a system file that the extension can't change. The installer writes it from
`config.json`'s `keyboard.capsLockAlone` (tap for Escape) and `keyboard.hyperModifiers` (Meh), and
`settings.json`'s island cheat-sheet settings (how long a tap can be, below). **After changing any of them in
Settings, run `linux/install.sh --hyper-keyd` again.** `--tap-escape` turns the tap on whatever
`config.json` says. If keyd already has another configuration, the installer doesn't write its own.
Instead it prints the lines to add to yours. To remove the file the installer wrote, run
`linux/install.sh --hyper-keyd --remove`; lines you added to your own configuration you take out
there, then run `sudo keyd reload`. keyd keeps Caps Lock as Hyper until then, even with Slated or its
Hyper key turned off.

Once Caps Lock is the Hyper key, no key can turn the Caps Lock lock off. So when Hyper comes on
(Slated starts with it on, you turn it on, or the installer sets up keyd), Slated turns a lock that's
on off first, by tapping Caps Lock on its own virtual keyboard (`hyper.caps_lock_cleared` in the
log), and again whenever the lock comes on while Hyper is active. keyd remaps the real keyboards
below GNOME, so it doesn't see that tap. With GNOME's option already set, the keyboard layout has no
Caps Lock key to tap; if the lock is on then (rare), the log says so (`hyper.caps_lock_clear_failed`):
turn the Hyper key off, press Caps Lock, and turn Hyper on again.

### Key repeat

**Settings → Keyboard → Key Repeat** sets how long a held key waits before it repeats and how fast
it repeats then, the same as GNOME Settings → Keyboard → Repeat Keys, but saved in `config.json`
(`keyboard.keyRepeat`, in milliseconds) so every computer you use Slated on gets the same, a Mac
too. The extension writes GNOME's `org.gnome.desktop.peripherals.keyboard` settings (`repeat`,
`delay`, `repeat-interval`) when they differ, and GNOME uses them right away. Turning the switch off
leaves GNOME's setting as it is; disabling Slated doesn't undo it either.

The first time this version runs on a computer, it copies GNOME's current key repeat into
`config.json` if `config.json` has none, once (`~/.local/state/slated/key-repeat.json` remembers it,
so turning the switch off sticks). With Repeat Keys off in GNOME it copies nothing, since applying a
setting turns repeating on. **Use this computer's current setting** copies it again any time.

With the tap on, a hold longer than the cheat-sheet delay isn't a tap, as on the Mac: letting go
sends nothing, so looking at the cheat sheet never sends Escape. The installer sets keyd's
`overload_tap_timeout` (in a `[global]` section) to `island.cheatSheetDelay`, between 0.15 and 1
second, or to 1 second with the island or its cheat sheet off. keyd reads it from version 2.4.3 on
(2.4.3, 2.5 and 2.6). keyd 2.4.0–2.4.2 log the line as invalid and skip it, so there a long hold
still sends Escape; the installer says so when it finds one. (`overloadt()` isn't used: it holds the
Hyper modifiers back until its timeout, and a keyd before 2.4.3 would drop the whole Caps Lock line.)

### Hotstrings

On GNOME, an extension can't type into other apps, so Slated hands your hotstrings to
[espanso](https://espanso.org). It writes them to `~/.config/espanso/match/slated.yml` and keeps
that file in sync with `config.json`. `linux/install.sh` installs espanso's release for your
session and starts it: the Debian package for X11 or Wayland with apt (Debian, Ubuntu, Pop!_OS,
Mint), the X11 AppImage on other distributions. On Wayland it also gives espanso the
`cap_dac_override` capability, as espanso's own instructions do. espanso has no package for Wayland
outside Debian and Ubuntu (Fedora, openSUSE; on Arch it's `espanso-wayland` in the AUR), nor for ARM:
there the installer says so, and once you've installed espanso
([instructions](https://espanso.org/docs/install/linux/)), running `linux/install.sh` again starts it.

**Settings → Hotstrings** shows whether espanso is installed and in sync. espanso can't tell which
app you're typing in on GNOME, so app filters only work on the Mac. A hotstring limited to some apps
(`onlyInApps`) doesn't expand on GNOME at all. A hotstring with exceptions (`exceptInApps`) expands
everywhere. Hotstrings that run Slated actions don't work through espanso. Slated logs once which
hotstrings it couldn't pass on.

## The island

Like the Mac's notch island, a black shape at the top center of the monitor you're working on shows
what Slated is doing. It hangs from the top bar on the primary monitor, from the top edge on the
others, and from the very top over a fullscreen window. It shows:

- **Running automations:** a red dot and a timer. Hover over it to see each one and a Stop button.
  Only then does it take the pointer; otherwise clicks go to the window below.
- **The Hyper cheat sheet:** hold Caps Lock for a moment (`island.cheatSheetDelay`, half a second by
  default) and every Hyper shortcut appears, grouped and in keyboard order, exactly as on the Mac.
  Shortcuts still work while it's up, and the one you press lights up.
- **Modal keys:** after a modal key, the island shows it, then lists the keys it offers.
- **Feedback** with `general.showActionHUD` on ("Left half · Firefox"), and why a shortcut couldn't
  run (`island.showFailures`).

Settings → General → Island has the Mac's switches and the cheat-sheet delay. Turning the island
off (`"island": {"enabled": false}` in `settings.json`) brings back the bottom HUD and the red pill
([CONFIG.md](CONFIG.md#notch-island)).

GNOME tells an extension about keys only through its own shortcuts, never about Caps Lock going down
or up. So:

- Slated reads the keyboard's modifier state to tell that Caps Lock is held: about 7 times a second,
  20 while one of the Hyper modifiers is down, and only while the cheat sheet can show (the island
  and its cheat sheet on, the Hyper key set up, a Hyper shortcut to list). The sheet can appear up to
  0.15 s after the delay.
- A key that isn't a Slated shortcut doesn't count as a quick combo: held with Caps Lock past the
  delay, the sheet still appears.
- With GNOME's `caps:hyper` option, Hyper shares Super's modifier, so holding Super alone shows the
  sheet too. keyd doesn't have this problem.
- With keyd's tap for Escape, letting go of Caps Lock after a hold longer than the delay sends
  nothing, as on the Mac, once `linux/install.sh --hyper-keyd` has written the delay into keyd's
  configuration (keyd 2.4.3 or later; see [The Hyper key](#the-hyper-key)). Change the delay, then
  run it again.

## Settings

The settings window has the Mac app's pages, in the same order and with the same names, listed in
a sidebar. Until Get Started is finished it opens on **Get Started** (the extension opens it after
login); afterwards it opens on the Overview, never on the page you left it on.

| Section | What's there |
|---|---|
| Get Started | First-run setup, as on the Mac: welcome, the Hyper key, hotstrings, your Slate config, done. Where the Mac asks for Accessibility access, the welcome step leads with whatever keeps Slated from running, and the button that fixes it: GNOME's Extensions switch off (**Turn On Extensions**), Slated turned off (**Turn On Slated**), a login still needed (**Log Out…**) or an error. GNOME needs no permission, so instead the Hyper key step recommends keyd (with the `linux/install.sh --hyper-keyd` command until it's set up) and the hotstrings step checks espanso, with "Skip for Now" until it's in sync. The Slate config step says what was imported from your Slate config (and what couldn't be converted), offers **Import…** when one is there but wasn't imported, or the starter shortcuts when there's none. Done lists what works and a shortcut to try. It leads the sidebar until you finish it (the badge says which step you're on); Overview → What's Next → **Get Started** opens it again |
| Overview | Whether Slated is running (from GNOME Shell and `status.json`) and what to do if it isn't, with a status row each for Slated, the Hyper key, hotstrings and shortcuts. A row never just waits: it says what's missing and offers the fix, such as GNOME's Extensions switch being off, Slated turned off or not loaded yet, an error, Pause Slated, keyd set up but stopped, or espanso stopped or missing (**Copy Command** copies what starts it). Then the last action and error, tips from your own shortcuts, and what to do next. After the move to two files imported your Slate config, it says so once, until you dismiss it. A file that can't be read is named, with **Open Config File** or **Open Settings File** |
| Windows | Your shortcuts, searchable, with keycaps and status (imported Slate shortcuts are ordinary ones). Automations get their own group. The editor records shortcuts (✦ for Hyper), offers every action and the Mac presets, previews where the window will land, and limits a shortcut to some apps (**Works In**) |
| Hotstrings | Triggers, replacements, a try-it field, espanso's status, and app filters (Mac only) |
| Clipboard | Clipboard history on or off, its shortcut, paste after picking, how much to keep and for how long, whether screenshots go in (GNOME copies each one to the clipboard, so the switch is about those copies), privacy (secrets, excluded apps), and the picker's keys. Shows how many items are saved |
| Automation | What runs now, your automations, eleven recipes (auto-click, hold a button or key, sprint and crouch toggles, spam a key, click N times, double-click, a walk-then-click macro), the safety settings, and what GNOME does differently |
| Keyboard | Caps Lock as Hyper, which method is active, tap for Escape, Hyper or Meh; key repeat (delay and rate, with a field to try it) |
| Layouts | Arrange several apps at once |
| General | Turn Slated on or off, Show Slated in the top bar, the action banner, the island (on or off, the Caps Lock cheat sheet and its delay, explaining shortcuts that can't run), window behavior, **Files** (where things live, **Open Config File**, **Open Settings File**, **Import Slate Config into Slated…**), the log, and this build |
| About | Version, credits, license, and debug information for bug reports |

Adding a recipe makes an ordinary shortcut and opens its editor with the shortcut recorder running;
free function keys are suggested. **Works In → Only in some apps** offers the apps you used lately
(from `recentApps` in `status.json`, so games without a desktop file are there too, by window class)
and your installed apps, or takes an id you type. Limited to apps, a shortcut can be a plain key like
F. A shortcut on a mouse button (from the Mac) says GNOME can't use it and how to map the button
with keyd. The editor has the Mouse & Keys actions: click, press or release, hold down, auto-repeat
(what repeats, how often, toggle or while held, a number of runs, humanized timing), wait and stop
automations.

Changes save as you make them, after a short pause, to the file they belong in: a shortcut,
hotstring or Hyper key change rewrites only `config.json`, an island or clipboard setting only
`settings.json`. Anything with an error, such as a half-typed expression or an empty trigger, is
flagged where you edit it and isn't written until you fix it. If either file can't be read,
Settings stops saving so nothing in it is lost, and the Overview names the file and the problem.

There's no Slate Compatibility page any more: Slated doesn't load Slate files, so there's nothing
live to show. **Import Slate Config into Slated…** (General → Files, and Get Started) is the Mac's
menu command of that name.

## Your Slate config

Slated doesn't read `~/.slate.js` or `~/.slate` while it runs. Their shortcuts, layouts, display
defaults and settings become part of Slated's own files, once:

- **On a first run** (no `config.json` yet), Slated imports `~/.slate.js`, else `~/.slate`. Without
  either it starts from the starter shortcuts.
- **When an older Slated's `config.json` is found** (below), Slated imports the Slate files it used
  to load.
- **Any time**, with **Import Slate Config into Slated…**.

Importing runs your `~/.slate.js` on stand-in desktops with a landscape and a portrait screen. Each
shortcut whose function always does the same thing becomes an ordinary Slated shortcut; one that
does different things on the two screens becomes a `by-orientation` shortcut. A shortcut whose keys,
modal key and app filter Slated already has is left alone, so importing again only brings over
what's new. What needs JavaScript while it runs can't be converted, and the import lists it by its
keys, with the reason. Your Slate file is never changed.

### From one file to two

Slated used to keep everything in `config.json` (version 1) and load your Slate files live. Now
`config.json` (version 2) holds the keyboard, bindings, hotstrings, layouts and display defaults,
and `settings.json` the rest. When the extension or the settings window finds a version 1
`config.json`, it:

1. copies it to `config.v1.json` beside it (an existing copy is never overwritten);
2. moves `general`, `settings` (now `windows`), `clipboard`, `automation` and `island` to
   `settings.json`, unless `settings.json` exists already (then that wins);
3. imports the Slate files it loaded (`general.slateConfigPaths`, else `~/.slate.js`, else `~/.slate`),
   unless `general.loadSlateConfigs` was false, skipping the shortcuts in
   `general.importedSlateShortcuts` (imported before, maybe changed or deleted since);
4. writes `settings.json`, then `config.json`, and logs `config.migrated` with counts only;
5. records what it imported in `~/.local/state/slated/config-migration.json`. The settings window's
   Overview then says, once: "Your ~/.slate.js shortcuts are now part of Slated's config. Slated
   doesn't read ~/.slate.js any more: edit them here or in ~/.config/slated/config.json." It adds how
   many couldn't be converted, and which.

A file that doesn't parse isn't migrated: Settings shows what's wrong, and nothing is written until
it's fixed. The next start finds version 2, so nothing happens twice.

**Where it runs.** Whichever process reads the old file first: usually the extension, as GNOME Shell
starts it at login after an update. Both use the same code, `lib/prefs/migration.js` and the Slate
importer, which are plain JavaScript without GTK (a test checks that), so the extension migrates
completely, Slate import included. That keeps your shortcuts working from the first login after the
update, before the settings window is ever opened: the extension doesn't load Slate files any more,
so a migration that left the import to the settings window would leave them dead until then. Your
`~/.slate.js` ran inside GNOME Shell at every login before; the import runs it there one last time,
on stand-in desktops. The settings window, a separate process, migrates when it's opened first, for
example right after `linux/install.sh` while GNOME Shell still runs the previous build. Either way the
record tells the settings window what to say, and dismissing the notice is remembered there.
The Mac app reads both layouts too, so files shared between the two migrate on whichever opens them
first.

## Files

| File | Written by | |
|---|---|---|
| `~/.config/slated/config.json` | Settings (and you) | What your keys do: the Hyper key, shortcuts, hotstrings, layouts and display defaults. Shared with the Mac app (see [CONFIG.md](CONFIG.md)). The extension watches it and applies changes |
| `~/.config/slated/settings.json` | Settings (and you) | How Slated behaves: `general`, `windows` (Slate's window settings), `clipboard`, `automation`, `island`. Watched like `config.json` |
| `~/.config/slated/config.v1.json` | The migration | The version 1 `config.json`, as it was before the move to two files. Never overwritten |
| `~/.local/state/slated/config-migration.json` | The migration | What a first run or the migration imported from your Slate config, for Get Started and the Overview's notice (`noticeDismissed` once you dismiss it) |
| `~/.local/state/slated/status.json` | Extension | What's running, read by the settings window (format below) |
| `~/.local/state/slated/slated.log` | Extension and settings | The event log: JSON Lines with the same events as on the Mac (`app.start`, `action.done`, `config.saved`, `ui.*`…) |
| `~/.local/state/slated/snapshots.json` | Extension | Saved window snapshots |
| `~/.local/state/slated/key-repeat.json` | Extension | This computer's key repeat was copied into `config.json` once ([Key repeat](#key-repeat)). Delete it to copy it again on the next start (with no `keyRepeat` in `config.json`) |
| `~/.local/state/slated/settings-window.json` | Settings | The settings window's own state: `{"setupFinished": true}` once Get Started is done (the Mac keeps this in its user defaults). Until then the extension opens the window on Get Started after login. Delete it to see Get Started again |
| `~/.local/share/applications/io.github.shobhitg.Slated.desktop`, `~/.local/share/icons/hicolor/scalable/apps/io.github.shobhitg.Slated.svg` | `linux/install.sh` | Slated in your apps: opens the settings window (`gnome-extensions prefs`) |
| `~/.local/state/slated/clipboard.json` | Extension | Clipboard history, readable only by you (mode 0600), in the Mac app's format. Not written when `clipboard.persist` is off |
| `~/.local/state/slated/clipboard-images/` | Extension | Copied images, one PNG per image named by its SHA-256, readable only by you (folder 0700, files 0600). A file goes when its item does; with `clipboard.persist` off, they're all removed when Slated stops. Copied files aren't copied here: the history keeps their paths |
| `~/.config/espanso/match/slated.yml` | Extension | Your hotstrings, for espanso |
| `~/.local/share/gnome-shell/extensions/<uuid>/build-info.json` | `linux/install.sh` | `{"version", "commit", "builtAt", "build"}` of the installed build |

These locations follow `$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` if you set them. As on the Mac,
`SLATED_HOME` replaces the home folder and `SLATED_CONFIG` replaces the path of `config.json`
(`settings.json` and `config.v1.json` go beside it). Tests use these to point everything at a
throwaway home.

`status.json`:

```json
{"session": "abcd1234", "version": "0.1.0", "running": true, "paused": false, "updatedAt": "2026-10-22T18:00:00.000Z",
 "hyper": {"wanted": true, "mode": "xkb", "active": true, "keyd": "none"},
 "keyRepeat": {"state": "applied", "delay": 200, "interval": 17},
 "hotstrings": {"engine": "espanso", "espansoInstalled": true, "matchFile": "~/.config/espanso/match/slated.yml", "count": 3},
 "hotkeys": {"hyper+a": "active", "hyper+q": "failed: <reason>", "hyper+w": "duplicate", "hyper+z": "disabled"},
 "screens": [{"displayID": 1, "name": "Built-in display", "isMain": true, "scale": 1,
              "frame": {"x": 0, "y": 0, "width": 1920, "height": 1080},
              "visibleFrame": {"x": 0, "y": 32, "width": 1920, "height": 1048}}],
 "automation": {"running": ["Repeat click left every 100 ms"], "shortcuts": ["f6"], "stopShortcut": "hyper+esc", "whileHeld": "key-repeat"},
 "clipboard": {"enabled": true, "items": 12},
 "recentApps": [{"id": "steam_app_1086940", "name": "steam_app_1086940"}, {"id": "firefox", "name": "Firefox"}],
 "lastAction": "Left half · firefox", "lastError": null}
```

- `paused` is Pause Slated, from the top bar's menu. `hyper.keyd` says whether keyd has Caps Lock
  (`running`), is set up for it but doesn't run (`stopped`), isn't set up for it (`none`), or is
  still being asked (`checking`).
- `keyRepeat` is `config.json`'s `keyboard.keyRepeat` as GNOME got it: `applied`, `failed`, or `off`
  (none set: GNOME's own setting stays, and `delay` and `interval` are null).
- The keys in `hotkeys` are config key strings. For modal bindings, the modal key and a space come
  first: `"ctrl+alt+f4 1"`.
- `screens` is optional, in top-left global coordinates. When it's there, previews use your real
  displays. Otherwise they use two sample displays.
- While the extension is running, the settings window logs under its `session`, so
  `scripts/logs.py --session last` shows events from both.
- `automation.running` lists what runs now, as the indicator shows it, and `shortcuts` the keys (as in
  `hotkeys`) of the shortcuts that started it. `whileHeld` is `key-repeat` when `while-held` repeats
  stop as you let go, or `toggle` when keyboard repeat is off in GNOME Settings and they need a
  second press.
- `recentApps` are the apps you used lately, newest first: the ids `onlyInApps` takes.

## Feature parity with macOS

| Feature | macOS | GNOME |
|---|---|---|
| Window operations: move, resize, push, nudge, throw, corner, chain, sequence, by-orientation | Accessibility API | Inside GNOME Shell (Mutter) |
| Layouts, applied automatically when your displays change | ✓ | ✓ |
| Directional focus, window hints, grid, snapshots, undo | ✓ | ✓ (overlays drawn by GNOME Shell) |
| Global shortcuts | Carbon hot keys | GNOME Shell key bindings. Shortcuts GNOME already uses can't be taken and show as failed |
| Hyper key (Caps Lock → ⌃⌥⇧⌘) | Built in (key remapping and an event tap) | GNOME's `caps:hyper` option, or keyd for the full Ctrl+Alt+Shift+Super |
| Caps Lock tapped alone → Escape | ✓ | With keyd |
| Caps Lock's lock turned off when Hyper comes on | ✓ (IOKit) | ✓ (a tap on the virtual keyboard, before GNOME's option takes the key) |
| Key repeat (`keyboard.keyRepeat`) | Global defaults in 1/60 s ticks, live through `hidutil` when macOS allows it (else after logging out and in) | GNOME's keyboard settings, live at once |
| Hotstrings | Built in, with per-app filters | Through espanso, which Slated keeps in sync. No per-app filters |
| `insert-text`, `keystroke`, `open-url`, `shell` actions | ✓ | ✓ |
| `~/.slate.js`, `~/.slate` | Imported once into `config.json` (JavaScriptCore runs the script on pretend Macs) | The same, with the settings window's importer (run on pretend desktops) |
| Config files | `config.json` and `settings.json` | The same files; a version 1 `config.json` migrates on either |
| Settings | SwiftUI window | libadwaita window |
| Status at a glance | Overview in Slated's window | Settings → Overview |
| Opening Slated | Dock icon, Spotlight, menu bar icon; the window opens on Get Started until setup is done | App grid and Activities search, the top-bar icon; the window opens on Get Started after login until setup is done |
| Status icon and its menu (Open Slated, Caps Lock → Hyper Key, Pause Slated, Reload, Open Config and Settings File, Show Log) | Menu bar (`general.showStatusIcon` hides it) | Top bar (the same setting) |
| First-run setup (Get Started) | Accessibility permission, Hyper key, Slate config (imported) | No permission. Hyper key (keyd recommended), espanso for hotstrings, Slate config (imported) |
| Start at login | Login item | Runs with your session while the extension is enabled |
| Permissions | Accessibility, granted once | None needed |
| Installing an update | `./install.sh` relaunches the app | Log out and back in (Wayland) or Alt+F2 `r` (Xorg). A nested shell lets you try it first |
| Logs | `~/Library/Logs/Slated`, Console.app | `~/.local/state/slated`, `journalctl` |
| Game automation: `click`, `press`, `hold`, `repeat` (`times`, `jitter`), `wait` in macros, `stop-automations` | Synthesized events | ✓ Through a virtual pointer and keyboard, like GNOME's on-screen keyboard |
| `repeat … while-held` | Stops on key-up | Stops about 0.1 s after you let go, noticed through key repeat. Works like `toggle` with key repeat off or for repeats that type keys |
| Mouse buttons 3–5 as shortcuts | ✓ | Not possible in GNOME. Map them to F13–F20 with keyd |
| Shortcuts only in some apps (`onlyInApps`) | Bundle ids | Desktop ids or WM_CLASS. Grabbed only while the app has focus |
| Automation safety: stop shortcut, stop on app switch, time limit, the "running" indicator | ✓ | ✓ The overview counts as leaving the app, and while it's open, shortcuts that would start an automation are ignored (stopping one still works). A macro waiting on a `wait` counts as running even when it holds nothing. Disabling, locking the screen, going to sleep (logind's PrepareForSleep) and config reloads release everything |
| Clipboard history and its picker | ✓ Text, images, screenshots saved as files and files copied in Finder, in a small picker at the text caret | ✓ Text, PNG images (screenshots included: GNOME copies them) and files copied in Files, in the same picker (Ctrl for ⌘: Ctrl+1–9 · esc), below the text cursor when the app reports it to the input method (Wayland text-input or IBus), else at the pointer. File rows show GNOME's thumbnail or the file's icon, not a QuickLook thumbnail. Ctrl+P, Ctrl+Backspace and Ctrl+Shift+Backspace pin, delete and clear there. Rows show plain text: the Mac's color swatches, link hosts and monospaced code aren't drawn yet |
| Settings → Clipboard | Every item, searchable, with pin, copy and delete | Settings only, and how many items are saved. Pin, delete and clear in the picker |
| Settings → Automation | Running Now with Stop All | Lists what runs. Stop it with the stop shortcut |
| Notch island (automation status, Hyper cheat sheet, feedback) | ✓ | ✓ At the top center, hanging from the top bar. The cheat sheet comes from the same engine code, pinned to the Mac's by golden vectors. Caps Lock's hold is read from the modifier state ([The island](#the-island)) |

## Limitations

- **GNOME only, within Wayland's rules.** Other desktops would need their own extension or a
  different approach. The installer stops on them before changing anything.
- **GNOME 46–51.** The extension declares those versions; newer ones mark it as unsupported until
  it's tested and added. GNOME 50 and 51 are declared but not yet tested.
- **Updates load at your next login.** GNOME Shell can't reload an extension's code while it's
  running. In an Xorg session (GNOME 48 and earlier), Alt+F2 `r` restarts GNOME Shell instead. Use
  the nested shell while developing (see below). The settings window runs as a separate process, so
  closing and reopening it picks up a new build right away.
- **Hotstrings need espanso**, which the installer sets up except where espanso has no package
  (Wayland outside Debian and Ubuntu). App filters and action hotstrings only work on the Mac.
- **The full Hyper key needs keyd**, a system service installed with sudo. GNOME's own option can't
  do the tap-for-Escape or Meh, and in many layouts it shares a modifier with Super.
- **Shortcuts GNOME already uses** (Super+A, Super+Tab…) stay GNOME's, and Slated reports them as
  failed. Pick other keys, or change GNOME's in GNOME Settings → Keyboard → Keyboard Shortcuts.
- **A `~/.slate.js` imported by the extension runs inside GNOME Shell**, once, when it migrates an
  older `config.json` or on a first run. An endless loop in it would freeze the desktop then. To
  avoid that, open Slated's settings before logging in with the new build: the settings window,
  a separate process, migrates first.
- **GNOME reports only key presses, not releases.** `repeat … while-held` notices that you let go
  when the key's auto-repeat stops: about 0.1 s later, or as soon as you press or release another
  key, since GNOME repeats only the last key pressed. With key repeat turned off in GNOME Settings, or
  for repeats that type keys themselves, a second press stops it instead.
- **An auto-repeat that types keys skips its runs while you hold a modifier** (Alt for Alt+Tab, Ctrl,
  Shift…), and never types them later: with Alt held, they would reach GNOME's app switcher, where Q
  quits an app. A shortcut's own keys still wait until you let go of its modifiers. Keys a macro
  types after a `wait` wait too, but are dropped if you still hold a modifier after 1.5 s or another
  app has focus by then.
- **Mouse buttons can't be shortcuts in GNOME.** Bindings on `mouse3`–`mouse5` show as failed. Map
  the side buttons to keys with keyd, then bind those keys (`f13`…`f20`). In keyd the side buttons
  are usually `mouse1` and `mouse2`, and keyd only reads a mouse that its `[ids]` section lists.
  Check `man keyd` for your version's syntax; for example:

  ```ini
  [ids]
  m:046d:c52b        # your mouse's vendor:product (`keyd monitor` shows it)

  [main]
  mouse1 = f13       # back
  mouse2 = f14       # forward
  ```
- **Synthesized input in games.** Most games take it, like input from an on-screen keyboard, but
  online games with anti-cheat may ignore it or forbid it in their terms.
- **Clipboard history keeps text, PNG images and copied files** (GNOME apps offer copied images as
  PNG; up to 20 MB each). Only copies made while Slated runs are recorded. A copy with text and a
  picture (spreadsheet cells) is kept as text, as on the Mac.
- **Screenshots** reach the history because GNOME's screenshot tool copies each one to the
  clipboard; Slated tells them apart as copies GNOME Shell makes itself, and leaves them out with
  `clipboard.screenshots` off. Screenshots saved without that copy (from another tool) aren't
  picked up: unlike the Mac, Slated doesn't watch a screenshot folder.
- **Copied files** come from file managers' `x-special/gnome-copied-files` (Files, Nemo, Caja,
  Thunar) or `text/uri-list` (Dolphin), local files only: a copy from a network share (`smb://`,
  `sftp://`) stays text. The history keeps their paths, never their contents. They paste back as
  `x-special/gnome-copied-files` only, because GNOME Shell can put just one type on the clipboard:
  Files and the other GNOME-style file managers paste them, but apps that read only
  `text/uri-list` or text (browsers' upload fields, Qt apps, text editors) get nothing. Files moved
  or deleted since are left out; when none is left, the row says "Moved or deleted" and nothing is
  pasted.
- **The clipboard picker opens at the text cursor only where the app tells the input method** where
  it is: GTK and Qt apps, Firefox and terminals built on VTE through Wayland's text-input, and X11
  apps through IBus. GNOME Shell can't ask an app on demand, so elsewhere (Chromium and Electron
  without Wayland IME, games) it opens at the pointer.

## Development

```sh
linux/install.sh --nested    # install, then start a nested GNOME Shell running the new build
```

The nested shell is a GNOME Shell in a window. On GNOME 49 it starts with
`dbus-run-session gnome-shell --devkit`, which needs Mutter's devkit viewer (Fedora packages it as
`mutter-devkit`). On GNOME 48 and earlier it starts with
`dbus-run-session -- gnome-shell --nested --wayland`. It loads the extension fresh, so you can see a
change without logging out. It shares your settings, `config.json` and log with your real session.
`--nested` waits for the new build's `app.start` in the log and reports it.

| What you changed | How to see it |
|---|---|
| Settings window (`prefs.js`, `lib/prefs/`) | Run `linux/install.sh`, then close and reopen the settings window. `lib/prefs/migration.js` and `importer.js` also run in the extension: see below for that |
| Extension or engine | Run `linux/install.sh --nested`, or run `linux/install.sh` and log out and back in |

Tests (CI runs all of them on Ubuntu 24.04, which has GNOME 46):

| Command | What it covers |
|---|---|
| `make linux-test` | The engine under Node, held to the Swift behavior by golden vectors. `gjs -m linux/tests/run.mjs` runs the same tests under GJS |
| `make linux-test-prefs` | The settings logic (model, validation, presets, automation recipes, import, the two files and the migration, status and the Overview's status rows), plus the whole settings UI driven on mock GTK and libadwaita |
| `make linux-test-prefs-gjs` | The settings logic tests under GJS |
| `make linux-test-gtk` | The settings window on real GTK 4 and libadwaita (needs `gjs gir1.2-adw-1 xvfb dbus`) |
| `make linux-test-extension` | The extension's runtime against a simulated GNOME Shell: both config files, first runs and the migration, shortcuts, per-app grabs, automation timing and safety stops, the island and its cheat sheet, clipboard history, the top-bar icon and its menu, Pause Slated, Get Started at login, status and log (Node 22.15+) |
| `make linux-test-installer` | `linux/install.sh` on a pretend system: stand-ins for GNOME's tools, sudo, apt, dnf, pacman, systemctl, git, make, curl, setcap and espanso, with only basic tools on `PATH` (Ubuntu, Pop!_OS on Xorg, Fedora, Arch, COSMIC, GNOME 42, re-runs, failures), the app entry, GNOME's Extensions switch, and what `gnome-extensions info` says (`--verify`'s order: the switch, enabled, ACTIVE, ERROR, OUT OF DATE, INITIALIZED, then the build). Plus `scripts/logs.py`'s log locations |
| `linux/tests/gnome/run.sh` | The extension in a real GNOME Shell |
| `node linux/tests/prefs/coverage.mjs` | Which settings code no test runs |

The UI test's mocks are built from GObject introspection data. `linux/tests/prefs/gi/api.json` lists
every class, method, property and signal in GTK 4.14 and libadwaita 1.5 (GNOME 46). It also lists
what GTK 4.20 and libadwaita 1.8 (GNOME 49) added or deprecated. Code may use newer API only behind
an `'name' in object` check. The test runs twice: once with only GNOME 46's API, and once with
GNOME 49's. `gi/build-api.py` regenerates `api.json` from the `.gir` files in the distributions'
`-dev` packages (its header explains how). `gi/adwaita-icons.txt` lists the symbolic icons that both
Adwaita versions have, and the test checks every icon name against it.

## Troubleshooting

Start with the logs:

```sh
journalctl -f -o cat /usr/bin/gnome-shell    # GNOME Shell's log: extension errors and stack traces
scripts/logs.py --session last               # Slated's events since GNOME Shell last started it
scripts/logs.py --errors --since 1h          # problems in the last hour
make logs                                    # follow Slated's log live
journalctl --user -f -o cat                  # everything in your session, including the settings window
```

| Problem | What to do |
|---|---|
| The installer stops: Slated needs GNOME 46 or newer | It names the GNOME version or the desktop (`XDG_CURRENT_DESKTOP`) it found, and changed nothing. If GNOME 46 or later is installed next to another desktop (Pop!_OS 24.04 starts COSMIC by default), log in to the GNOME session and run `linux/install.sh` there. GNOME comes with your distribution's release: Ubuntu 24.04, Fedora 40 and Debian 13 or later have a new enough one. |
| keyd didn't install | The message says which part failed: the package, the build tools, the download from github.com, or the build (its log is `build/linux/keyd-build.log`). Fix that and run `linux/install.sh` again. Without systemd, have your init system start keyd as root. |
| espanso didn't install or start | The message says why: no package for your system (install it yourself, then run `linux/install.sh` again to start it), a failed download (check your connection), or a checksum that doesn't match (run it again; report it if it repeats). `espanso log` says why it won't start. |
| sudo didn't take the password | The steps that need it fail and say so; the rest still installs. Run `linux/install.sh` again. |
| I don't see Slated anywhere | Run `linux/install.sh --verify`: it says what's wrong and how to fix it. Usually GNOME's Extensions switch is off, or Slated is turned off; `linux/install.sh` turns both on. Then find Slated in your apps or click its icon in the top bar (unless General → Show Slated in the top bar is off). |
| Settings says "Log out and back in to start Slated" | GNOME Shell hasn't loaded the extension yet (a new install or an update on Wayland). Log out and back in, then run `linux/install.sh --verify`. |
| The Extensions app shows Slated with an error | The error is in `journalctl -o cat /usr/bin/gnome-shell`. **Settings → Overview** also shows GNOME Shell's message. |
| Settings says "A newer build is installed" | GNOME Shell is still running the previous build. Log out and back in. |
| Settings says "This GNOME version isn't supported yet" | You're on GNOME 50 or later (see [Limitations](#limitations)). |
| A shortcut says "Couldn't register" | GNOME or another extension already uses those keys. Pick other keys, or free them in GNOME Settings → Keyboard → Keyboard Shortcuts. |
| Caps Lock isn't Hyper | Settings → Keyboard shows which method is active and whether it works. With keyd, check `sudo systemctl status keyd`, and that a config in `/etc/keyd` maps `capslock` in its `[main]` section. |
| Hotstrings don't expand | Settings → Hotstrings shows espanso's status. Check `espanso status` and `espanso log`. |
| Editing `config.json` or `settings.json` by hand changes nothing | The file must be valid JSON (comments and trailing commas are fine), and each setting in its own file (`island` in `settings.json`, `bindings` in `config.json`). Settings → Overview shows what's wrong, and `scripts/logs.py --errors` shows what the extension saw. |
| Settings says it can't read `config.json` or `settings.json` | The message names the file and the spot, such as `bindings[2].id`. Ids must be UUIDs: delete a bad `"id"` line and Slated makes a new one. Settings won't save until the file reads, so nothing in either file is lost. Operations from a newer Slated for Mac than the engine knows also stop it here. |
| My `~/.slate.js` changes don't do anything | Slated doesn't read Slate files any more. Edit the shortcuts in Settings → Windows (or `config.json`), or run **Import Slate Config into Slated…** to bring over new ones. `scripts/logs.py --grep config.migrated` shows what the migration imported; `config.v1.json` is the old file. |
| A `while-held` repeat keeps going after I let go | Check that Repeat Keys is on in GNOME Settings → Keyboard (`status.json` says `"whileHeld": "toggle"` otherwise). A repeat that types keys always needs a second press. `scripts/logs.py --grep automation.while_held` says which bindings work like toggles and why. |
| An automation stops by itself | `scripts/logs.py --grep automation.stopped` gives the reason: switching apps or opening the overview (`automation.stopOnAppSwitch`), the time limit (`automation.maxRunMinutes`), the stop shortcut, going to sleep, or a config change. |
| An automation shortcut does nothing in the overview | By design: an auto-clicker started there would click into it. Close the overview first. `scripts/logs.py --grep automation.start_ignored` lists the presses Slated ignored. |
| The stop or clipboard shortcut says "Couldn't register" | GNOME or another extension uses those keys (`cmd` is Super, so the clipboard's `cmd+shift+v` is Super+Shift+V). With Caps Lock as Hyper through GNOME's own option, `hyper+esc` can collide with GNOME's Super+Esc. Set `automation.stopShortcut` or `clipboard.shortcut` to other keys, such as `ctrl+alt+esc` or `ctrl+alt+v`. |
| An `onlyInApps` shortcut never works | It's grabbed only while that app has focus. Use the id from `recentApps` in `status.json` (desktop id, or WM_CLASS for games without a desktop file). |
| Clipboard history stays empty | `clipboard.enabled` must be on. Copies from `excludedApps` and secrets marked by password managers are skipped by design, of images only PNGs up to 20 MB are kept, and screenshots only with `clipboard.screenshots` on. `scripts/logs.py --grep clipboard` shows what was skipped and why. |
| Pasting copied files does nothing | The app reads only `text/uri-list` or text, not the `x-special/gnome-copied-files` Slated puts back (see [Limitations](#limitations)); paste into Files, or drag the files. The log says `clipboard.paste_skipped` with `"files missing"` when they were all moved or deleted. |
| The clipboard picker opens at the pointer, not the text cursor | The app didn't report its cursor: `scripts/logs.py --grep switcher_opened` says `"anchor":"pointer"`. Chrome and Electron apps report it with `--enable-wayland-ime` (or under XWayland with IBus); apps that handle typing themselves (games, some terminals) never do. |
| GNOME's Extensions switch is off (`gnome-extensions info` says `Enabled: No`) | No extension runs, Slated included. Run `linux/install.sh` (it asks to turn the switch on), use **Turn On Extensions** in Settings, or turn it on in the Extensions app. Turning it on also starts the other extensions you had turned on. |
