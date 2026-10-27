# GNOME end-to-end tests

`run.sh` runs the Slated extension in a real, headless GNOME Shell and checks what it does. It
complements `linux/tests/extension/run.sh` (syntax, unit tests, and the runtime against a simulated
GNOME), which needs only Node.

## What it checks

`scenario.py` drives the extension through its debug D-Bus interface, which exists only when GNOME
Shell runs with `SLATED_DEBUG=1`:

- the extension enables without errors; `status.json` and `app.start` are written;
- config bindings register as GNOME accelerators;
- actions move a GTK 4 test window to the expected frame of the work area: JSON actions, Slate
  syntax, undo, unknown operations failing cleanly;
- a chain binding cycles;
- pressing Ctrl+Alt+Shift+Super+D through the virtual keyboard fires the grabbed accelerator;
- window hints and the grid open with a modal grab and close on Escape;
- game automation reaches the window: a right double-click, an auto-repeat that clicks five times and
  stops, `hold key:w` shown in `status.json` and released by `stop-automations`, and disabling the
  extension releasing a held key (the test window records what it receives);
- clipboard history records the test window's copy, saves it with mode 0600, keeps the text out of
  the log, and the switcher opens;
- `~/.slate.js` loads, reloads on change, and its function binding runs `win.doOperation` with an
  orientation check;
- Caps Lock → Hyper in xkb mode adds `caps:hyper` while keeping other options;
- disabling the extension writes `running: false`, logs `app.quit` and removes the xkb option;
- every log line is valid JSON with the shared schema, with no `runtime.error` events and no window
  titles.

## Running it

With Docker:

```sh
linux/tests/gnome/run.sh                                   # Fedora 43, GNOME 49
FEDORA_VERSION=42 FEDORA_ARCHIVE=1 linux/tests/gnome/run.sh  # GNOME 48 (41 → 47, 40 → 46)
SLATED_SKIP_INPUT=1 linux/tests/gnome/run.sh               # skip the key-press checks
```

It exits 0 when everything passed, 1 when a check failed, and 2 when it couldn't run (no Docker, or
GNOME Shell didn't start). On failure it prints the end of `slated.log` and GNOME Shell's JS errors.

In CI, run the same command on a Linux runner with Docker, for example GitHub's `ubuntu-latest`.
Running it once per supported GNOME release covers 46–49.

Without Docker, use a disposable Linux machine or VM that has `gnome-shell`, `gjs`, `gtk4`,
`dbus-daemon` and `python3-gobject`:

```sh
SLATED_IN_CONTAINER=1 linux/tests/gnome/run.sh
```

It uses a throwaway `HOME` and its own D-Bus session, so it never touches a logged-in session.

If GNOME Shell doesn't start in a container, check its output. Some hosts need `--device /dev/dri`,
or `--security-opt seccomp=unconfined` for mutter. Both go on the `docker run` line in `run.sh`.

## On a real GNOME machine

These are the things a headless shell can't show. Use GNOME 46–49 on Wayland.

1. Install: copy `linux/gnome-extension` to
   `~/.local/share/gnome-shell/extensions/slated@shobhit-aida.github.io`. Log out and back in, since
   Wayland only loads new extensions at login. Then run
   `gnome-extensions enable slated@shobhit-aida.github.io`.
2. Watch the log with `tail -f ~/.local/state/slated/slated.log` (same events as macOS;
   `scripts/logs.py` only knows the macOS path so far). `journalctl --user -f -g Slated` shows
   errors.
3. `cat ~/.local/state/slated/status.json`: every binding should be `active`. A binding marked
   `failed: …` names the GNOME shortcut that owns those keys.
4. Window management: try halves, quarters, thirds and maximize on a GTK app, Firefox, and a
   terminal. Try them on a maximized window and on a half-tiled one (Super+Left). Windows should land
   flush with the work area, below the top bar.
5. Throw to other monitors, and the grid (drag across cells; Escape and clicking outside cancel).
   Then window hints (type a letter).
6. Caps Lock as Hyper:
   - With `"capsLock": "hyper"`, check `gsettings get org.gnome.desktop.input-sources xkb-options`
     shows `caps:hyper`.
   - Disabling the extension removes it again.
   - With keyd running, Slated logs `keyboard.state` with mode `keyd` and leaves xkb alone.
7. Hotstrings: with espanso installed, `~/.config/espanso/match/slated.yml` follows the config. It
   disappears when hotstrings are turned off.
8. Lock the screen and unlock: shortcuts work again afterwards, and Caps Lock is a plain Caps Lock on
   the lock screen.
9. `~/.slate.js`: edit and save it. The bindings reload within a second (`slate.loaded` in the log).
10. Game automation, with a game or any app that counts clicks:
    - `repeat 0.1 'click left'` on a shortcut clicks until you press it again. The red "running" pill
      shows at the top with the stop shortcut, and the stop shortcut ends it.
    - `hold key:w` keeps walking in a game until pressed again; `hold key:shift` sprints.
    - `repeat 0.05 while-held 'click left'` stops about 0.1 s after you let go of the shortcut.
    - An `onlyInApps` binding on a plain key (F) works only in that app: F types normally elsewhere,
      and in the overview's search.
    - Switching apps, opening the overview, locking the screen and `maxRunMinutes` stop everything;
      nothing stays pressed afterwards.
11. Clipboard history: copy a few texts, press Super+Shift+V, search, pick one with ↩ or Ctrl+2: it
    pastes into the window you were in (Ctrl+Shift+V in a terminal). A KeePassXC copy isn't recorded.
    `~/.local/state/slated/clipboard.json` is `-rw-------`.
