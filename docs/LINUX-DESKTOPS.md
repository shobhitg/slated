# Slated on more Linux desktops

**Status: not planned.** On 2026-10-31 the author decided Slated on Linux stays GNOME-only
(GNOME 46–51). This research is kept for reference in case that changes; nothing here is built.

> "We want to support all sorts of Linuxes." After GNOME 46–51, add window management, the clipboard
> picker and the island on: 1. KDE Plasma 6; 2. Xorg desktops (XFCE, Cinnamon, MATE, i3 and other
> Xorg sessions); 3. sway and Hyprland; 4. older GNOME, 42–45.

The facts below were checked against the sources at the end, in October 2026. **(unconfirmed)**
marks what I couldn't confirm. Each one is a question for the first spike on that desktop.

## The recommendation in short

- **GNOME stays an extension.** On GNOME Wayland only GNOME Shell can manage windows. 45 joins the
  current extension; 42–44 get a legacy-format build of the same source.
- **Every other desktop gets one standalone app, `slated`, written in GJS.** It has two processes:
  - a background daemon: the engine, shortcuts, the overlays, clipboard history and automation;
  - the settings window: the existing libadwaita settings code, `lib/prefs`, in its own process, as
    on GNOME.
- **A thin backend per desktop** talks to the compositor through the compositor's own public API:
  - KDE: a KWin script over D-Bus;
  - Xorg: EWMH through Wnck, and XGrabKey through Keybinder;
  - sway: sway's IPC;
  - Hyprland: Hyprland's IPC.
- **What's shared:** the engine (`lib/core`, still pinned to Swift by the golden vectors), a
  desktop-neutral runtime split out of `lib/platform`, and `lib/prefs`.
- **The same everywhere outside GNOME:**
  - overlays are drawn in GTK 3: layer-shell surfaces on Wayland, override-redirect popups on X11;
  - synthesized input goes through uinput;
  - clipboard history comes from `wl-paste --watch` on Wayland;
  - the Hyper key comes from keyd, and espanso handles hotstrings.
- **Shortcuts use each desktop's native mechanism, not the XDG GlobalShortcuts portal.** The portal
  binds a session's shortcuts once, through a dialog [5]. That doesn't suit a config that changes
  all the time.

## 1. Process model and language

| Option | For | Against |
|---|---|---|
| **A. Standalone GJS app + a backend per desktop (recommended)** | Reuses `lib/core`, most of `lib/platform` and all of `lib/prefs`. One engine on Linux. An update is a daemon restart, with no logout. Overlays, clipboard and input are written once | Needs an IPC channel to each compositor. Two processes to supervise. Typelib dependencies vary by distro |
| B. A plugin per desktop, like the GNOME extension | Runs inside the compositor, with no IPC | Only KWin has a JS plugin host. A KWin script can't read files, read clipboard history or synthesize input. sway has no plugins. Hyprland plugins are C++ against an unstable ABI. X11 has no plugin host. Doesn't work |
| C. A native daemon that reuses `SlatedCore` through Swift on Linux | No JS port to maintain | GNOME still needs the JS engine, so Linux would have two engines. The settings window would be rewritten. Swift's GTK bindings are immature |

### How A works

- **Daemon.** `slated` is a `Gio.Application` with the id `io.github.shobhitg.Slated`, unique on the
  session bus.
  - **What it does:** loads `config.json` and `settings.json`, grabs shortcuts, runs actions, draws
    the overlays, records clipboard history, runs automations, and writes `status.json` and the log.
    These are the same files and events as the extension.
  - **How it starts:** at login through XDG autostart, or through an `exec` line on
    sway/Hyprland/i3, which don't run XDG autostart.
  - **Activating it again** (the app launcher, the taskbar or `slated`) opens Settings. This is the
    Mac's shape: one app, and closing the window keeps it running.
- **Settings.** `slated settings` is a separate GTK 4/libadwaita process running `lib/prefs`, the
  way GNOME runs extension prefs. It reads `status.json` and watches the config files, as it does
  today.
- **Toolkits.**
  - **The daemon uses GTK 3:**
    - `gtk-layer-shell` hooks GTK 3 directly. `gtk4-layer-shell` has to be linked before
      `libwayland-client`, which in GJS means `LD_PRELOAD` [8].
    - GTK 4 can't place a window on X11, and its X11 backend is deprecated [9].
    - A GTK 3 daemon covers Wayland and X11 with one set of overlay views.
  - **Settings stays GTK 4.**
  - Each process uses one toolkit.
- **Helpers, only where GJS can't reach:**
  - `wl-paste --watch` and `wl-copy`, for Wayland's data-control protocols;
  - a ~150-line Python standard-library uinput helper (it needs `ioctl`). The installer already
    requires Python 3.
- **Reads come from a mirror; writes are asynchronous.**
  - The action runner calls the platform synchronously: `actions.js` has no `await`, and its tests
    rely on that.
  - Each backend therefore keeps a mirror of windows and screens, updated by the compositor's events.
  - `setFrame` writes through to the mirror and is confirmed by `afterSettle`, as on GNOME Wayland
    today.
  - So `actions.js` and its tests don't change.

**Trade-offs we accept:**

- GTK 3 is a maintenance-mode toolkit. It's fine until GTK 5 drops X11 anyway. Revisit then.
- There's a third set of overlay views: St on GNOME, GTK 3 elsewhere.
- Outside GNOME, Slated runs as an ordinary user process. Anything the compositor offers only to
  plugins is out of reach.

## 2. Per desktop

### Common to every desktop except GNOME

| Area | Design |
|---|---|
| **Overlays** | **Wayland:** wlr-layer-shell surfaces on the overlay layer, which KWin [7], sway and Hyprland implement and Mutter doesn't [7b]. **The island** is anchored to the top, centered on the active output. Its keyboard interactivity is none, and its input region covers only the running automations, so clicks pass through. **The picker, hints and grid** take the keyboard (exclusive interactivity). **X11:** GTK 3 popups (override-redirect) and `Gdk.Seat.grab`. Without a compositor (i3 without picom), the island is a shaped window with hard edges |
| **Modal keys** | When a modal key fires, the island takes the keyboard until the next key or Esc. That gives the same behavior on every backend without using each compositor's modes |
| **Caret for the picker** | AT-SPI (the `Atspi` typelib): the focused text's caret offset, then that character's extents. Slated reads only the offset and the extents, never text. On Wayland an app knows only coordinates relative to its window [15], so Slated adds the backend's window frame. On X11 it uses screen coordinates. IBus's and Wayland text-input's cursor reports reach only the compositor or the input-method panel, never an app. Qt and Chromium expose AT-SPI only while the accessibility bus is on, which costs some performance, so make it opt-in. **Falls back to the pointer** for games, terminals that draw their own text, apps without accessibility, and accessibility off |
| **Clipboard history (Wayland)** | An app can't read the clipboard without focus. So Slated runs `wl-paste --watch` (data-control) and pastes back with `wl-copy --type`, one type per write (the same limit as GNOME). **Plasma 6.5+** offers only `ext-data-control-v1` [10]. That needs **wl-clipboard 2.3** (2026), the first release with it [10b]. Distributions may still ship 2.2. sway and Hyprland also offer `wlr-data-control` |
| **Automation input** | uinput through Slated's helper: a real virtual keyboard and mouse at the kernel level, which every compositor and X11 accept. See the comparison below |
| **Hyper key and cheat sheet** | keyd on every desktop. **The cheat sheet** needs "Caps Lock is held". Slated's keyd config already puts Caps Lock on a `[hyper:…]` layer, and `keyd listen` prints layer changes [13]. So the daemon sees the hold without seeing a single keystroke. That needs access to keyd's socket, which keyd calls privileged [13] (which group gets access is **unconfirmed**). **Without keyd:** no cheat sheet. The xkb `caps:hyper` fallback is cheap on sway (`input * xkb_options`) and X11 (`setxkbmap`), and comes later for KDE and Hyprland |
| **Hotstrings** | espanso, as now. On X11, espanso can filter by app (`filter_class`), so `onlyInApps` could work on Xorg desktops (**unconfirmed**) |
| **"Works in" (per-app shortcuts)** | Every backend reports the focused app in `focus.js`'s shape: desktop id, `WM_CLASS` or `app_id`, Flatpak id. Plain-key per-app shortcuts are grabbed only while that app has focus, as on GNOME |
| **Settings and Get Started** | `lib/prefs` unchanged except for two things. **`shell.js`** becomes a host adapter: GNOME Shell's Extensions D-Bus on GNOME, the daemon's own D-Bus elsewhere (running? restart, quit). **`GNOME_NOTES`** becomes a per-desktop notes table. **Get Started** adds "Allow Slated to press keys and click" (the uinput rule): the counterpart of the Mac's Accessibility step. On sway, Hyprland and i3 it also adds "Start Slated with your session", which shows the line to add |

**Automation input options:**

| Route | Where it works | Setup and prompts | Held keys and buttons | Verdict |
|---|---|---|---|---|
| **uinput, Slated's own helper** | Everywhere: kernel level | A udev rule granting `/dev/uinput` to the logged-in user. One sudo, together with `--hyper-keyd`. Steam ships the same rule [14] | Yes, as a real device | **Recommended** |
| ydotool | Everywhere | Needs the same uinput access, plus the `ydotoold` daemon. Distribution versions differ | Yes | No: the same permission plus an extra daemon |
| keyd `do` / `input` | Where keyd runs | keyd calls its socket privileged [13] | Macro-oriented. Holds and mouse buttons aren't documented | No |
| RemoteDesktop portal (`Notify*` over D-Bus, or libei) | GNOME 46+, KDE 6.1+ [12]. Not xdg-desktop-portal-wlr. Not upstream Hyprland [12b] | A consent dialog per session. Whether KDE keeps a restore token is **unconfirmed** | Yes | Later, as a fallback without sudo on KDE |
| virtual-keyboard + wlr-virtual-pointer (wtype, wlrctl) | sway, Hyprland. Not KWin [11] | None | Awkward: one device per process | No, because KDE lacks it |
| XTEST (`Atspi.generate_*`) | X11 | None | Yes | Fallback on X11 without the rule |

### KDE Plasma 6 (Wayland; also its X11 session through Plasma 6.7)

| Area | Design |
|---|---|
| **Windows** | **The KWin script.** The daemon loads a KWin script at start through `org.kde.KWin /Scripting loadScript` (kdotool does the same [4]) and unloads it on exit, so nothing is installed into KWin. **What it mirrors to the daemon** with `callDBus` [1]: windows (`workspace.stackingOrder`, `windowAdded`/`windowRemoved`/`windowActivated`, `frameGeometry` (writable), `resourceClass`, `desktopFileName`, `internalId`) and screens (`workspace.screens`, `clientArea(MaximizeArea, output, desktop)`, `screensChanged`). **Commands back:** the script keeps one `callDBus` to the daemon outstanding, and its reply carries the next commands. The daemon replies empty about every 20 s so the call never times out. That makes a two-way channel from public scripting API only. **(unconfirmed** until the spike) |
| **Global shortcuts** | `registerShortcut` or the QML `ShortcutHandler` [1][2], both through KGlobalAccel. All four modifiers work (`Meta+Ctrl+Alt+Shift+A`). **The catches:** there's no `unregisterShortcut`, a handler's key is fixed once it's created, and entries stay in `kglobalshortcutsrc` after use [2][3]. **Plan:** name each action after its combo ("Slated: Meta+Ctrl+Alt+Shift+A") and dispatch by combo in the daemon. When the set of combos changes, reload the script, which should release dropped combos (**unconfirmed**). **Per-app plain keys** mean grabbing only while the app has focus: either a reload on focus change, or a QML `Instantiator` of `ShortcutHandler`s. The spike decides. **Key-up for `while-held`:** kglobalaccel's `globalShortcutReleased` D-Bus signal (**unconfirmed**). Without it, `while-held` works as a toggle. **The portal** is supported on KDE, but rejected (see above) |
| **Overlays** | Layer-shell. The island goes on `workspace.activeScreen`. The X11 session uses the X11 popups |
| **Clipboard** | `wl-paste --watch` with wl-clipboard ≥ 2.3. Klipper's D-Bus (`org.kde.klipper`) could be a text-only fallback (**unconfirmed**) |
| **Input** | uinput. KWin has no virtual-keyboard protocol [11]. The RemoteDesktop portal comes later as the fallback without sudo |
| **Testing** | `dbus-run-session kwin_wayland --virtual --xwayland` in a Fedora KDE container in CI (kwin-mcp runs KWin this way for CI [19]). Shortcuts are triggered through kglobalaccel's `invokeShortcut` D-Bus method. Physical key presses are skipped, because containers have no `/dev/uinput` |
| **Effort** | **M**, on top of the shared foundation (**L**, built in phase 1). The X11 session adds **S**, at low priority: Plasma 6.8 (October 2026) is Wayland-only [18] |
| **Risks** | Shortcut lifecycle (above). The script must be reloaded when KWin restarts (watch the `org.kde.KWin` name owner). Scripting API changes between Plasma releases |

### Xorg desktops (XFCE, Cinnamon, MATE, i3, Openbox…)

| Area | Design |
|---|---|
| **Windows** | Wnck 3 (GI, GTK 3, inside the daemon): the window list, frame and client geometry (`_NET_FRAME_EXTENTS`), `set_geometry`, `activate`, and window opened, closed and active-changed signals. Screens and per-monitor work areas come from `Gdk.Monitor`. Where a desktop sets only `_NET_WORKAREA` (one rectangle for all monitors), compute work areas from the docks' struts. **i3 tiles:** a placement floats the window first, through i3's IPC (sway's protocol) |
| **Global shortcuts** | Keybinder 3 (`XGrabKey`, GI). Any modifiers work. **Per-app plain keys** are grabbed on focus change, as on GNOME. **Conflicts:** a key the window manager already grabbed fails with `BadAccess` and shows as failed, as on GNOME. **`while-held`:** Keybinder doesn't report key-up, so it reuses the extension's key-repeat heuristic, which is already in the shared runtime. **Modal keys:** the island takes the keyboard. The desktops' own shortcut settings (xfconf, dconf) aren't used: they start a process on every press |
| **Overlays** | GTK 3 popups. XFCE, Cinnamon and MATE run a compositor, so the island is translucent. Under i3 it's a shaped window |
| **Clipboard** | GTK 3: `Gtk.Clipboard` `owner-change` (XFixes) plus reading its contents. Pastes back one type (the same limit as GNOME) |
| **Input** | uinput, or XTEST without the udev rule |
| **Testing** | The most complete of any desktop: Xvfb with xfwm4, marco or i3 directly on the CI runner, no Docker. `xdotool` presses real Hyper combos through XTEST |
| **Effort** | **M** |
| **Risks** | Multi-monitor work areas. Focus-stealing prevention when activating a window. i3's tiling |

### sway

| Area | Design |
|---|---|
| **Windows** | IPC over `$SWAYSOCK` (a Gio socket) [16]. **Reads:** `get_tree` (con id, `app_id` or `window_properties.class`, `rect`, floating) and `get_outputs`. The work area is the workspace `rect`, which appears to exclude bars (**unconfirmed**). **Commands:** `[con_id=N] floating enable, move absolute position X Y, resize set W H`, and `focus`. **Events:** subscribe to `window` (new, close, focus, move, floating) and `output` |
| **Global shortcuts** | `bindsym` works at runtime [16]: `bindsym --no-warn Mod4+Ctrl+Mod1+Shift+a nop slated:<id>`. sway's `binding` event carries the command [16], so the daemon dispatches without starting a process. **`--release`** gives key-up for `while-held`. **Per-app plain keys** are bound and unbound on focus events. **Modal keys:** the island, or sway's own `mode`. **A config reload drops runtime binds**, so they're re-applied on the reload event (**unconfirmed** which event) |
| **Overlays** | Layer-shell. kitty rates sway's implementation as partially working [7b] |
| **Clipboard** | `wl-paste --watch` |
| **Input** | uinput |
| **Testing** | `WLR_BACKENDS=headless WLR_RENDERER=pixman sway` directly on the CI runner. Keys through `wtype`, checks through `swaymsg`. Complete |
| **Effort** | **M** |
| **Risks** | Tiling: a placement floats the window (the author decides, below). Conflicts with binds in the user's own config |

### Hyprland

| Area | Design |
|---|---|
| **Windows** | `hyprctl` requests over `.socket.sock` [17c]. **Reads:** `-j clients` (address, class, position, size, floating, monitor) and `-j monitors` (`reserved` gives the work area). **Commands:** move, resize and focus dispatchers. **Since 0.55** dispatchers are Lua calls (`hl.dsp.…`) when the config is Lua [17c]. **Events** on `.socket2.sock`: window opened, closed and activated, and monitor changes |
| **Global shortcuts** | Runtime binds. **Under a Lua config:** `hyprctl eval 'hl.bind(…)'`; `hyprctl keyword` does nothing there [17c]. **Dispatch:** the `event` dispatcher emits `custom>>slated:<id>` on socket2 [17d], so no process starts per press. Its Lua form is **unconfirmed**. **Release binds** give key-up for `while-held`. **Per-app plain keys** are bound and unbound on `activewindow` events. **Modal keys:** the island, or submaps. **The portal** (xdph implements GlobalShortcuts) needs the user to add a config line per shortcut, so it's rejected |
| **Overlays** | Layer-shell. kitty rates Hyprland's implementation as fully working [7b] |
| **Clipboard** | `wl-paste --watch` (`wlr-data-control`) |
| **Input** | uinput. Upstream Hyprland has no RemoteDesktop portal [12b] |
| **Testing** | Headless is unproven: aquamarine needs a GPU device, according to a third party [17e]. **In CI:** Node tests against recorded `hyprctl -j` output and socket2 transcripts. **On the author's machine:** a manual checklist |
| **Effort** | **M** |
| **Risks** | **High churn.** Hyprland 0.55 (May 2026) switched configs to Lua, and the old syntax goes away "1–2 releases" later [17][17b]. Target Lua configs (0.55+) only |

### GNOME 45

What blocks it today:

1. `metadata.json` doesn't list 45.
2. Settings uses libadwaita 1.5 widgets, and GNOME 45 has 1.4:
   - `Adw.AlertDialog`, in `ui/slateimport.js` and `ui/bindingeditor.js`;
   - `Adw.AboutDialog`, in `ui/about.js`.
3. The GI API test's baseline is GTK 4.14 and libadwaita 1.5. It needs a GTK 4.12 / libadwaita 1.4
   baseline.

**The extension itself:**

- The 45→46 changes [20] don't touch our code:
  - `add_child` is used, never `add_actor`;
  - there's no `GioUnix`, no `setSourceColor`, no `Shell.BlurEffect`;
  - `lib/prefs/status.js` already handles the `ExtensionState` rename.
- To be confirmed in a container.

**Testing:** no supported distribution ships 45 (Fedora 39 and Ubuntu 23.10 are end-of-life), so
45 is tested only in CI: the existing harness with `FEDORA_VERSION=39 FEDORA_ARCHIVE=1`.

**Effort: S.**

### GNOME 42–44

**Extension: GNOME before 45 has no ES modules.**

- A pack-time transform builds a legacy-format zip from the same source:
  - `gi://X` → `imports.gi.X`;
  - `resource:///…/ui/main.js` → `imports.ui.main`;
  - the `Extension` class → `init()`.
- extensions.gnome.org takes it as a separate upload for 42–44.
- **GJS on 42–44** is 1.72–1.76 (SpiderMonkey 91–102). The code uses none of the newer built-ins
  today (checked: no `Object.hasOwn`, `findLast`, `toSorted`, `structuredClone`). A lint keeps it
  that way.
- **The GNOME Shell APIs we use exist in 42:** `grab_accelerator`, `Main.pushModal` returning a
  `Clutter.Grab`, `Meta.Selection`, Clutter virtual devices. Per version, that's to be confirmed in
  containers.

**Settings: the bigger cost.**

- Ubuntu 22.04 has libadwaita 1.1, and Debian 12 has 1.2 [21]. Settings uses widgets they lack:
  - from 1.4: `NavigationSplitView`, `NavigationView`, `ToolbarView`, `Breakpoint`, `SwitchRow`,
    `SpinRow`;
  - from 1.5: `AlertDialog`, `AboutDialog`;
  - from 1.2: `EntryRow`, which 1.1 lacks.
- **Options:**
  - a compatibility layer of about ten widget fallbacks, enforced by API baselines for 42 and 43
    (**M**);
  - a Flatpak of the settings app (needs flatpak, plus sandbox access to `~/.config/slated`);
  - no settings window, so users edit JSON.

**Who runs them:**

- GNOME 42: Ubuntu 22.04, in standard support until 2027.
- GNOME 43: Debian 12, in LTS until mid-2028.
- GNOME 44: no supported distribution.
- RHEL 9 runs GNOME 40, which is out of range.

**Testing:** the existing harness with `FEDORA_VERSION=36/37/38` from the archive, plus Ubuntu 22.04
and Debian 12 images. Whether older GNOME Shells accept the harness's headless flags is
**unconfirmed**.

**Effort: M.**

### Summary

| Desktop | Verdict | Effort | Main risk |
|---|---|---|---|
| Shared foundation (runtime split, app shell, GTK 3 overlays, uinput, clipboard, settings host) | Needed by all of these | **L** | Size. It's built during phase 1 |
| KDE Plasma 6, Wayland | Yes: KWin script + daemon | **M** | KGlobalAccel lifecycle |
| KDE Plasma, X11 session | Same backend with X11 overlays. Optional | **S** | Plasma 6.8 dropped the X11 session |
| Xorg (XFCE, Cinnamon, MATE, i3…) | Yes: Wnck + Keybinder + GTK 3 | **M** | Work areas, WM quirks |
| sway | Yes: sway IPC | **M** | Tiling semantics |
| Hyprland | Yes: Hyprland IPC, Lua configs only | **M** | API churn, no headless CI |
| GNOME 45 | Yes: the same extension | **S** | None: nobody runs it |
| GNOME 42–44 | Yes: a legacy build | **M** | Settings on old libadwaita |

Not planned, but nearly free later: other Wayland compositors (COSMIC, niri…). Layer-shell,
data-control and uinput carry over, so each needs only a window-and-shortcut backend.

## 3. What's shared, and the refactor

**Layout:**

```
linux/
  core/             the engine (today gnome-extension/lib/core); golden vectors unchanged
  runtime/          the desktop-neutral half of lib/platform (GLib/Gio only)
  prefs/            the settings window (today gnome-extension/lib/prefs) plus a host adapter
  gnome-extension/  extension.js, prefs.js, lib/gnome/: the GNOME backend and its St views
  app/              `slated`: main.js, settings.js, backends/{kde,x11,sway,hyprland}/,
                    views/gtk3/, helpers/uinput.py
  kwin/             the KWin script the KDE backend loads
```

The extension's packer copies `core/`, `runtime/` and `prefs/` into the zip, because extensions must
be self-contained.

**What moves:**

- **To `runtime/`:**
  - `actions`, `automation`, `combos`, `configStore`, `espanso`, `files`, `log`, `paths`;
  - `snapshots`, `status`, `system`, `timers`, `util`;
  - `KeybindingManager` (without `MutterGrabber`);
  - the island presenter (`island.js`) and the clipboard history service;
  - `PickerModel`, and the `runtime.js` orchestration with GNOME's imports factored out.
- **Stays GNOME-only:**
  - `windows`, `screens`, `focus`, `gnomePlatform`, `MutterGrabber`;
  - `caret` (`Main.inputMethod`), `input` and `synth` (Clutter virtual devices);
  - xkb mode in `hyper`, `hyperHold` (Clutter modifier state), `sleep` (GNOME's login manager);
  - `debug`, and the St views (`islandView`, the picker's view, `overlays`, `hud`, `indicator`).

**The interface a backend implements.** `gnomePlatform.js` and `tests/extension/fake-platform.mjs`
already define most of it:

```js
/** One desktop session. Reads are synchronous, from a mirror the backend keeps current from the
 *  compositor's events. Writes are asynchronous; afterSettle confirms them, as on GNOME Wayland. */
class DesktopBackend {
  static detect(env)                   // → score; the app picks the best match for the session
  async start(events)                  // connect and fill the mirror. events: windowOpened, windowClosed,
                                       //   focusChanged, screensChanged, shortcut, shortcutReleased
  stop()
  // Windows and apps: gnomePlatform.js's methods, so ActionRunner doesn't change
  focusedWindow() windowsOnWorkspace() frame(w) setFrame(w, rect) afterSettle(w, cb) focus(w)
  isAlive(w) sameWindow(a, b) isMaximizedOrFullscreen(w) isMainWindow(w) windowTitle(w)
  appOfWindow(w) appIdentity(app) focusedApp() runningApps() appWindows(app)
  hideApp(app) showApp(app) isAppHidden(app) activateApp(app)
  screens()                            // ScreenInfo[]: frame + visibleFrame, top-left logical coordinates
  activeScreen()                       // where the island goes
  // Shortcuts: KeybindingManager's grabber
  grab(combo, {onlyWhileFocused}) → {ok: true} | {ok: false, reason}
  ungrab(combo)
  capabilities                         // {keyRelease, nativeModes, layerShell, tiling}
}
// Services, composed per session. Each has a GNOME implementation, a Wayland one and an X11 one.
OverlayHost     // island, HUD, picker, grid, hints: show(view, monitor, {keyboard: 'none' | 'exclusive'})
ClipboardSource // watch(onCopy), read(types), write(item)
InputSink       // key(code, down), button(n, down), click(n, count), paste(text)
CaretLocator    // caretRect() → rect | null; the caller falls back to the pointer
```

**Tests:**

- **One contract suite** runs the runtime against every backend's fake, as the extension tests do
  against `fake-gnome.mjs` today.
- **Each backend's real-compositor test** in CI runs the scenario `linux/tests/gnome/scenario.py`
  runs: move a test window to an exact frame, fire a shortcut, show the island, record a copy, click
  with an automation, and check that no window titles reach the log.

**Views:**

- The presenters are already separate from their St views (`island.js` from `islandView.js`,
  `PickerModel` from `ClipboardPicker`).
- The GTK 3 views implement the same view methods.
- `stylesheet.css` mostly carries over as GTK CSS.

## 4. Installer impact

`linux/install.sh` is becoming one distro-agnostic command (keyd and espanso everywhere, the
extension on GNOME 46–51). It picks the session from `XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`,
`SWAYSOCK`, `HYPRLAND_INSTANCE_SIGNATURE` and `gnome-shell --version`. On top of that:

| Session | What it adds |
|---|---|
| **Every non-GNOME desktop** | **Installs the app:** to `~/.local/share/slated/`, with `~/.local/bin/slated`, a desktop file, and an XDG autostart entry. **Checks for:** gjs; the GTK 3 and Atspi typelibs; GTK ≥ 4.14 with libadwaita ≥ 1.5 for Settings; gtk-layer-shell on Wayland. **After an update:** restarts the daemon instead of asking you to log out. `--verify` reads `app.start` from the same log. **Asks for sudo once** (with `--hyper-keyd`, or a new `--input`) to install a udev rule for `/dev/uinput`. **`--uninstall`** also removes the autostart entry and the rule |
| KDE Plasma 6 | Checks for wl-clipboard ≥ 2.3 (Plasma 6.5+ offers only ext-data-control). Installs nothing into KWin: the daemon loads its script at runtime |
| Xorg desktops | The Wnck 3 and Keybinder 3 typelibs. Under i3: a note that the island needs a compositor (picom) to be translucent |
| sway, Hyprland, i3 | wl-clipboard (sway, Hyprland). **Autostart:** prints the line to add (`exec slated`, or Hyprland's Lua `exec-once` equivalent), because these sessions don't run XDG autostart. **Hyprland:** says so when the version is older than 0.55 or the config isn't Lua |
| GNOME 45 | Nothing new: the same ESM zip, with 45 declared |
| GNOME 42–44 | Installs the legacy-format zip instead. Restarting is the same: log out, or Alt+F2 `r` on Xorg |

## 5. Phased plan

Each phase ends with something the author can use daily.

**Phase 1: KDE Plasma 6.**

1. **Spike** (below). Its answers settle the KWin channel and the shortcut design.
2. **Refactor and app skeleton.** Split `runtime/` out with the GNOME tests still green. Build
   `slated` and its settings process, plus the KDE backend for windows and shortcuts.
   *Usable:* every window shortcut, layouts, snapshots and undo on Plasma.
3. **Overlays.** The island, with the cheat sheet through `keyd listen`, plus the HUD, modal keys,
   hints and grid. *Usable:* the island on Plasma.
4. **The rest.** The clipboard picker (at the pointer), automation through uinput, and Settings with
   Get Started's new steps. *Usable:* parity with GNOME, except the caret.
5. **The caret.** The picker opens at the caret through AT-SPI, behind an opt-in setting.

**Phase 2: Xorg.**

1. XFCE, the most common Xorg desktop.
2. Cinnamon and MATE, which are mostly testing.
3. i3, with floating through its IPC.

Each desktop is usable as it lands. Most of phase 1's overlays and services carry over unchanged.

**Phase 3: sway, then Hyprland.**

- sway first: it has the best headless CI.
- Then Hyprland, Lua configs only.
- Both reuse phase 1's Wayland pieces: layer-shell, `wl-paste`, uinput.

**Phase 4: older GNOME.**

1. GNOME 45 (**S**). Small enough to do earlier as filler if the author wants.
2. Then the 42–44 legacy build and settings fallbacks.

### First concrete step for KDE

Write `linux/kwin/probe.js` and `linux/tests/kde/run.sh`.

**How it runs:**

1. A Fedora KDE container in CI starts `dbus-run-session kwin_wayland --virtual --xwayland`.
2. It loads the probe through `org.kde.KWin /Scripting loadScript`.
3. It opens the GTK test window from `linux/tests/gnome/`.
4. It runs a GJS D-Bus test service in the daemon's place.

**What it checks:**

1. The window list, frames, app ids and work areas reach the service through `callDBus`.
2. A command returned in a pending `callDBus` reply moves the test window to an exact frame. That
   proves the two-way channel.
3. `registerShortcut("Slated: Meta+Ctrl+Alt+Shift+D")` fires when kglobalaccel's `invokeShortcut` is
   called over D-Bus.
4. After the script is unloaded, the same key can be registered under another name. This decides
   between reloading the script and an `Instantiator` of `ShortcutHandler`s.
5. Whether kglobalaccel emits a released signal for the shortcut.

**Where it lives:** the probe stays as the KDE contract test (CLAUDE.md: probes become tests). It
runs in CI only, because there's no Docker on the Mac.

## 6. Top risks

1. **KDE shortcuts.** No unregister call, keys that can't change once registered, stale entries [2][3].
   Changing or per-app shortcuts depend on script reloads releasing keys. The spike checks that
   first.
2. **Input needs a system change.** Outside GNOME, clicks and held keys need `/dev/uinput`.
   - The udev rule lets any process of the logged-in user create input devices (Steam ships the same
     rule [14]).
   - KWin offers no virtual keyboard [11].
   - The portal asks for consent per session.
3. **Clipboard on Plasma 6.5+** needs wl-clipboard 2.3 [10][10b], which distributions may not ship
   yet. The only fallback is Klipper's D-Bus (text only, **unconfirmed**).
4. **Hyprland churn.** Configs moved to Lua in May 2026, `hyprctl keyword` stopped working there, and
   dispatch syntax changed [17c]. There's no proven headless CI [17e].
5. **The caret** depends on apps' accessibility support and an opt-in accessibility switch. Many apps
   will open the picker at the pointer.
6. **Maintenance load.** Five backends, two extension builds and three sets of overlay views for one
   author. Mitigations: the shared contract suite, and real-compositor CI for KDE, Xorg, sway and
   GNOME.

## 7. Decisions for the author

These are also in [QUESTIONS.md](QUESTIONS.md#more-linux-desktops-2026-10-31-please-answer).

1. **Approve option A:** one standalone GJS app with a backend per desktop, GTK 3 for overlays and
   GTK 4 for Settings.
2. **The uinput udev rule** (`uaccess`: the logged-in user may create input devices), installed with
   sudo. Or only portal consent, which works on KDE and GNOME only.
3. **Tiling compositors** (sway, i3, Hyprland). Should a placement float the window? Or should
   push/throw become native tiling moves?
4. **The caret through AT-SPI.** It turns on accessibility for every app (a cost in Chromium and
   Electron). Opt-in, with the pointer as the default?
5. **GNOME 42–44:**
   - Are they still wanted? Phase 4 lands around 2027, when Ubuntu 22.04 leaves standard support.
   - If so, how does Settings work: compatibility layer, Flatpak, or no settings window?
6. **Hyprland:** Lua configs (0.55+) only?
7. **KDE's X11 session:** support it, or skip it now that Plasma 6.8 is Wayland-only?
8. **The Hyper key outside GNOME:** keyd only? Or also an xkb `caps:hyper` fallback per desktop?

## Proposed CLAUDE.md row

Replace the Linux row of the Decisions table with:

```
| Linux | GNOME 46–51 (45 next; 42–44 from a legacy-imports build): the GNOME Shell extension in `linux/gnome-extension`. Other desktops (decided 2026-10-31, in this order: KDE Plasma 6, Xorg, sway and Hyprland): one standalone GJS app, `slated` — a daemon (engine, shortcuts, GTK 3 overlays on layer-shell or X11, clipboard, automation) plus the libadwaita settings window in its own process — with a thin backend per desktop (KWin script over D-Bus, Wnck + Keybinder, sway IPC, Hyprland IPC). All share the engine in `linux/core` pinned to Swift by golden vectors (`fixtures/`, `make fixtures`), the desktop-neutral `linux/runtime` and `linux/prefs`. Hotstrings via espanso and Hyper via keyd everywhere (xkb `caps:hyper` fallback on GNOME); synthesized input via uinput outside GNOME. See docs/LINUX-DESKTOPS.md | On GNOME Wayland only the compositor can manage windows, grab shortcuts or overlay UI. Every other desktop offers public IPC or scripting, so one app with thin backends beats a plugin per desktop. Same `config.json` and `settings.json` everywhere. |
```

## Sources

1. KWin scripting API (`registerShortcut`, `callDBus` with callback, `workspace`, `clientArea`,
   `frameGeometry`): https://develop.kde.org/docs/plasma/kwin/api/
2. KWin `ShortcutHandler` (name and sequence fixed after construction):
   https://api.kde.org/qml-org-kde-kwin-shortcuthandler.html and
   https://lxr.kde.org/source/plasma/kwin/src/scripting/shortcuthandler.cpp
3. KDE bugs on script shortcuts (no unregister; re-registering; stale entries):
   https://bugs.kde.org/show_bug.cgi?id=318422 and https://bugs.kde.org/show_bug.cgi?id=483573
4. kdotool (loads generated KWin scripts over D-Bus, Plasma 6): https://github.com/jinliu/kdotool
5. XDG GlobalShortcuts portal, version 2 ("can only attempt to bind shortcuts of a session once"; a
   dialog "typically"):
   https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
6. Who implements it: wlr won't (https://github.com/emersion/xdg-desktop-portal-wlr/issues/240);
   KDE and Hyprland do (https://github.com/pop-os/xdg-desktop-portal-cosmic/issues/4); GNOME 48 added
   it (https://release.gnome.org/48/developers/)
7. KWin's layer-shell, version 5: https://lxr.kde.org/source/plasma/kwin/src/wayland/layershell_v1.cpp.
   7b: layer-shell support and quality per compositor, from kitty's compatibility notes as summarized
   by search (secondary; not read directly): https://sw.kovidgoyal.net/kitty/kittens/panel/
8. gtk4-layer-shell must load before libwayland-client (`LD_PRELOAD`):
   https://sources.debian.org/src/gtk4-layer-shell/1.3.0-1/linking.md
9. GTK's X11 backend deprecated, removal planned for GTK 5:
   https://blog.gtk.org/2025/02/01/whats-new-in-gtk-winter-2025-edition/
10. Plasma 6.5 offers only ext-data-control; wl-clipboard lagged:
    https://bugs.kde.org/show_bug.cgi?id=510176 and https://bugs.kde.org/show_bug.cgi?id=511173.
    10b: wl-clipboard 2.3 adds ext-data-control-v1: https://github.com/bugaevc/wl-clipboard/releases
11. KWin lacks `zwp_virtual_keyboard_v1`: https://bugs.kde.org/show_bug.cgi?id=497774
12. RemoteDesktop portal: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html;
    libei on GNOME 46+ / KDE 6.1+ (Deskflow): https://github.com/deskflow/deskflow/discussions/7499.
    12b: no RemoteDesktop in xdg-desktop-portal-hyprland (2024 report, may be dated):
    https://bbs.archlinux.org/viewtopic.php?id=299925
13. keyd's commands (`do`, `input`, `listen`; the socket is privileged):
    https://github.com/rvaiya/keyd/blob/master/docs/keyd.scdoc
14. Steam's udev rule giving `/dev/uinput` to the seat user:
    https://github.com/ValveSoftware/steam-devices/blob/master/60-steam-input.rules
15. Wayland clients know only window-relative positions (AT-SPI): https://bugzilla.gnome.org/show_bug.cgi?id=784509
16. sway(5) (`bindsym` at runtime, flags) and sway-ipc(7) (`get_tree`, events, the binding event's
    command): https://man.archlinux.org/man/sway.5.en, https://man.archlinux.org/man/sway-ipc.7.en
17. Hyprland 0.55 moves configs to Lua: https://hypr.land/news/update55/. 17b: hyprlang kept "1–2
    more releases": https://metadata.ftp-master.debian.org/changelogs/main/h/hyprland/testing_NEWS.
    17c: hyprctl(1) (`keyword` "will not work if your config provider is lua", `eval`):
    https://man.archlinux.org/man/hyprctl.1.txt. 17d: the `event` dispatcher:
    https://code.hyprland.org/hyprwm/hyprland-wiki/blame/branch/main/pages/Configuring/Dispatchers.md.
    17e: no standalone headless backend (third party):
    https://docs.rs/crate/vvland/0.1.1/source/src/linux/compositor/hyprland.rs and
    https://forum.hypr.land/t/headless-hyprland-in-github-actions/1361
18. Plasma 6.8 is Wayland-only: https://blogs.kde.org/2025/11/26/going-all-in-on-a-wayland-future/
19. `kwin_wayland --virtual` for headless CI (kwin-mcp): https://pypi.org/project/kwin-mcp/0.9.1/
20. GNOME 46 changes for extensions: https://gjs.guide/extensions/upgrading/gnome-shell-46.html
21. Distribution versions: GNOME Shell per Ubuntu release,
    https://packages.ubuntu.com/search?keywords=gnome-shell&searchon=names&exact=1&suite=all&section=all;
    libadwaita per Debian release,
    https://packages.debian.org/search?keywords=libadwaita-1-0&searchon=names&suite=all&section=all
