// The running extension's brain: loads the configuration (config.json and settings.json), registers
// shortcuts, sets up the Hyper key and hotstrings, runs actions, and publishes status. A port of the
// macOS Engine (Sources/Slated/Engine/Engine.swift). Slate files aren't read here: they're imported
// into the configuration (lib/prefs/migration.js).
//
// `start()` never throws: each part starts on its own, and a part that fails is logged
// (`runtime.error`) while the rest keeps working. `stop()` undoes everything `start()` did.
//
// As on the Mac, Slated's icon sits in the top bar (statusIcon.js): a click opens the settings window,
// and its menu can pause Slated. Until Get Started is finished, the settings window opens on it a few
// seconds after login, once per GNOME Shell session.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import * as Config from 'resource:///org/gnome/shell/misc/config.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import * as Core from '../core/index.js';
import {ActionRunner, errorMessage} from './actions.js';
import {AutomationEngine, OWN_APPS, automationShortcuts, sendsKeys, whileHeldRepeat} from './automation.js';
import {ClipboardService} from './clipboard.js';
import {CAPS_LOCK_KEYSYM, CapsLockGuard} from './capsLock.js';
import {bindingKey, comboOf, modalOf} from './combos.js';
import {ConfigStore, emptyConfiguration} from './configStore.js';
import {DebugService} from './debug.js';
import {EspansoSync} from './espanso.js';
import {exists, readText} from './files.js';
import {FocusTracker} from './focus.js';
import {GnomePlatform} from './gnomePlatform.js';
import {ActionHUD} from './hud.js';
import {HyperManager, acceleratorOptions} from './hyper.js';
import {HyperHoldWatcher, hyperMasks} from './hyperHold.js';
import {AutomationIndicator} from './indicator.js';
import {IslandPresenter, islandSettings} from './island.js';
import {InputInjector} from './input.js';
import {KeyRepeatManager} from './keyRepeat.js';
import {KeybindingManager, MutterGrabber, readKeyboardRepeat, releaseTiming} from './keybindings.js';
import {EventLog, LogFile, journalMirror} from './log.js';
import {OverlayController} from './overlays.js';
import * as Paths from './paths.js';
import {MonitorWatcher, currentScreens} from './screens.js';
import {findSettingsWindow, setupFinished, shouldOfferGetStarted} from './settingsWindow.js';
import {SleepWatcher} from './sleep.js';
import {SnapshotStore} from './snapshots.js';
import {StatusFile, buildStatus} from './status.js';
import {StatusIcon, statusWarnings} from './statusIcon.js';
import {InputSynthesizer, seatKeymap} from './synth.js';
import {openURL} from './system.js';
import {Debouncer, Timers} from './timers.js';
import {appMatchesAny, conditionMatches, defaultEntry, resolutionOf, shortcutLabel, truthyText} from './util.js';
import * as Windows from './windows.js';

/** How many recently focused apps status.json lists (for the settings window's app picker). */
const RECENT_APPS = 12;

/** How long after login the settings window opens on Get Started (until setup is finished). */
export const GET_STARTED_DELAY_MS = 3000;

/** "0.1.0", "0.1.0+3f2a9c1" or "0.1.0 (3f2a9c1-dirty)" → {version, commit}. */
export function parseVersionName(versionName) {
  const text = String(versionName ?? '').trim();
  const match = /^(.+?)(?:\s*\+\s*|\s+\(\s*)([0-9a-f]{7,40}(?:-dirty)?)\)?$/i.exec(text);
  if (match) return {version: match[1], commit: match[2]};
  return {version: text || 'dev', commit: 'unknown'};
}

/**
 * Version facts for `app.start` and status.json: metadata.json's `version-name`, overridden by a
 * `build-info.json` next to it when the installer generated one ({version, commit, builtAt, build}).
 */
export function buildInfo(metadata, buildInfoText = null) {
  const info = parseVersionName(metadata?.['version-name'] ?? metadata?.version);
  if (buildInfoText) {
    try {
      const parsed = JSON.parse(buildInfoText);
      for (const key of ['version', 'commit', 'builtAt', 'build']) {
        if (typeof parsed[key] === 'string' || typeof parsed[key] === 'number') info[key] = String(parsed[key]);
      }
    } catch {
      // A broken build-info.json only loses the extra facts.
    }
  }
  return info;
}

function repeatOnHoldOps(settings) {
  return String(settings.repeatOnHoldOps ?? 'resize,nudge')
    .split(',')
    .map((s) => s.trim());
}

function settingBool(settings, key, fallback) {
  const value = settings[key];
  if (value === undefined || value === null) return fallback;
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  return truthyText(value);
}

/** Window placements show where the window went in the island; focusing and app actions show their symbol. */
function showsRegion(action) {
  if (!action) return true; // a grid placement
  switch (action.op) {
    case 'focus': case 'switch': case 'hint': case 'show': case 'hide': case 'toggle':
      return false;
    default:
      return true;
  }
}

/** Where `frame` sits in `area`, as fractions (0…1), or null when it's outside. */
function regionIn(frame, area) {
  if (!(area?.width > 0 && area?.height > 0)) return null;
  const x1 = Math.max((frame.x - area.x) / area.width, 0);
  const y1 = Math.max((frame.y - area.y) / area.height, 0);
  const x2 = Math.min((frame.x + frame.width - area.x) / area.width, 1);
  const y2 = Math.min((frame.y + frame.height - area.y) / area.height, 1);
  return x2 > x1 && y2 > y1 ? {x: x1, y: y1, width: x2 - x1, height: y2 - y1} : null;
}

export class SlatedRuntime {
  /**
   * @param {object} extension
   * @param {string} extension.path      The extension's directory.
   * @param {object} extension.metadata  metadata.json.
   * @param {string} extension.uuid
   * @param {object} [extension.core]  The engine API; tests pass a fake.
   * @param {object} [extension.session]  What outlives a disable, kept by extension.js for the GNOME
   *   Shell session (GNOME disables extensions while the screen is locked): {paused, getStartedOpened}.
   * @param {() => void} [extension.openPreferences]  Asks GNOME Shell to open the settings window.
   */
  constructor({path, metadata, uuid, core = Core, session = null, openPreferences = null}) {
    this._extensionPath = path;
    this._metadata = metadata ?? {};
    this._uuid = uuid;
    this.core = core;
    this._session = session ?? {paused: false, getStartedOpened: false};
    this._openPreferences = openPreferences;
    this._statusIcon = null;
    this._startupSignal = 0;
    this._lastAction = null;
    this._lastError = null;
    this._hyper = {wanted: false, mode: 'off', active: false, hyperIsSuper: false};
    /** keyboard.keyRepeat as applied: status.json's keyRepeat. */
    this._keyRepeat = {state: 'off', delay: null, interval: null};
    this._hotstrings = {engine: 'none', espansoInstalled: false, matchFile: null, count: 0};
    this._statusIdle = 0;
    this._applyIdle = 0;
    this._started = false;
    /** The focused app (util.appIdentity), for per-app bindings and stopping automations. */
    this._focusedApp = null;
    this._recentApps = [];
    /** "key-repeat": while-held repeats stop when the key is let go; "toggle": keyboard repeat is off. */
    this._whileHeldMode = 'key-repeat';
    this._loggedWhileHeld = '';
    /** The hotkey entries last registered, in priority order: what the island's cheat sheet lists. */
    this._shortcutEntries = [];
  }

  // --- Lifecycle ---------------------------------------------------------------------------------

  start() {
    this._timers = new Timers();
    this._home = Paths.homeDir();
    this._debugMode = GLib.getenv('SLATED_DEBUG') === '1';
    this._log = new EventLog({sink: new LogFile(Paths.logPath()), mirror: journalMirror({verbose: this._debugMode})});
    this._build = buildInfo(this._metadata, readText(`${this._extensionPath}/build-info.json`));
    this._log.record(
      'app.start',
      {
        version: this._build.version,
        commit: this._build.commit,
        build: this._build.build,
        builtAt: this._build.builtAt,
        gnome: Config.PACKAGE_VERSION,
        sessionType: GLib.getenv('XDG_SESSION_TYPE') || (Meta.is_wayland_compositor?.() ? 'wayland' : 'x11'),
        mode: 'gnome-extension',
        uuid: this._uuid,
        debug: this._debugMode,
        paused: this.paused,
      },
      'notice',
    );
    this._statusFile = new StatusFile(Paths.statusPath());

    this._step('config', () => {
      this._store = new ConfigStore({
        paths: {config: Paths.configPath(), settings: Paths.settingsPath(), backup: Paths.backupPath(), record: Paths.migrationRecordPath()},
        home: this._home,
        log: this._log,
        timers: this._timers,
      });
      this._store.load();
      this._store.startWatching(() => this.scheduleApply('config changed'));
    });
    this._step('actions', () => {
      this._input = new InputInjector({
        timers: this._timers,
        log: this._log,
        focusedAppId: () => this._platform?.appInfo(this._platform.focusedApp())?.id ?? null,
        ownModifiers: () => this._synth?.heldModifierMask() ?? 0,
      });
      this._synth = new InputSynthesizer({log: this._log});
      this._platform = new GnomePlatform({timers: this._timers, input: this._input, synth: this._synth, home: this._home});
      this._snapshots = new SnapshotStore({path: Paths.snapshotsPath(), platform: this._platform, log: this._log});
      this._runner = new ActionRunner({platform: this._platform, core: this.core, log: this._log, snapshots: this._snapshots});
      this._overlays = new OverlayController({log: this._log, place: (window, frame) => this._runner.place(window, frame, 'Grid')});
      this._runner.overlays = this._overlays;
      this._hud = new ActionHUD();
      this._runner.onPerformed = (message, report) => {
        this._lastAction = message;
        if (this._configuration().general?.showActionHUD) {
          try {
            this._showFeedback(message, report);
          } catch (e) {
            this._error('hud', e);
          }
        }
        this._publishStatus();
      };
      this._runner.onError = (message) => {
        this._lastError = message;
        this._publishStatus();
      };
      // Why a shortcut couldn't run, in the island (showFailures).
      this._runner.onFailed = (message) => this._island?.flashFailure(message);
      // Reloading re-grabs shortcuts; never do that from inside Mutter's key handling.
      this._runner.onRelaunch = () => this.scheduleReload('relaunch');
      // An auto-clicker started from the overview would click into it.
      this._runner.automationBlocked = () => (Main.overview?.visible ? 'the overview is open' : null);
    });
    this._step('automation', () => {
      this._automation = new AutomationEngine({
        timers: this._timers,
        synth: this._synth,
        log: this._log,
        focusedApp: () => this._focusedApp,
      });
      this._automation.perform = (action) => this._runner?.performStep(action) ?? false;
      this._automation.onChange = () => this._automationChanged();
      // A stop (shortcut, app switch, time limit) also ends what's still pending: the rest of a macro
      // and keys waiting for modifiers, which would otherwise land in the app you switched to.
      this._automation.onStopAll = () => {
        this._runner?.cancelPendingSteps();
        this._input?.cancelPending();
      };
      this._indicator = new AutomationIndicator();
      if (this._runner) this._runner.automation = this._automation;
    });
    this._step('island', () => {
      this._island = new IslandPresenter({timers: this._timers, log: this._log});
      this._island.hyperSheet = () => this._hyperCheatSheet();
      this._island.currentAutomations = () => this._indicatedAutomations();
      this._island.comboOf = (keys) => {
        try {
          return comboOf(keys, this.core);
        } catch {
          return null;
        }
      };
      this._island.onStop = () => this._automation?.stopAll('stopped from the island');
      // GNOME reports no modifier presses, so the Hyper key's hold is read from the modifier state.
      this._hyperHold = new HyperHoldWatcher({
        timers: this._timers,
        onChange: (held) => (held ? this._island?.hyperPressed() : this._island?.hyperReleased()),
      });
    });
    // Without the lock on suspend, nothing else would stop automations across a sleep.
    this._step('sleep', () => (this._sleepWatcher = new SleepWatcher(() => this._automation?.stopAll('sleep'))));
    this._step('clipboard', () => {
      this._clipboard = new ClipboardService({
        timers: this._timers,
        log: this._log,
        path: Paths.clipboardPath(),
        input: this._input,
        focus: {
          window: () => Windows.focusedWindow(),
          app: () => this._focusedApp,
          activate: (window) => Windows.activate(window),
          isAlive: (window) => Windows.isAlive(window),
        },
      });
      this._clipboard.onChange = () => this._publishStatus();
      if (this._input) this._input.onClipboardWrite = (text) => this._clipboard?.markOwnWrite(text);
      if (this._runner) this._runner.clipboard = this._clipboard;
    });
    this._step('shortcuts', () => {
      this._keybindings = new KeybindingManager({
        grabber: new MutterGrabber({timers: this._timers, hyperIsSuper: () => this._hyper.hyperIsSuper}),
        log: this._log,
        onRelease: (entry) => this._automation?.released(`hotkey ${entry.id}`),
        onModalChange: (_id, keys) => this._modalChanged(keys ?? null),
        onFire: (entry) => {
          // A shortcut while Hyper is held: a quick combo, no cheat sheet.
          this._island?.hyperUsed();
          this._island?.shortcutFired(entry.id);
        },
      });
    });
    this._step('focus', () => {
      this._focusTracker = new FocusTracker((app) => this._focusChanged(app));
      this._focusedApp = this._focusTracker.current();
      this._rememberApp(this._focusedApp);
      this._keybindings?.setFocusedApp(this._focusedApp);
    });
    this._step('caps lock', () => {
      this._capsLock = new CapsLockGuard({
        keymap: seatKeymap(),
        tap: () => this._synth?.tap(CAPS_LOCK_KEYSYM) ?? {ok: false, error: 'no virtual keyboard'},
        timers: this._timers,
        log: this._log,
        hyperActive: () => this._hyper.active,
      }).start();
    });
    this._step('key repeat', () => {
      this._keyRepeatManager = new KeyRepeatManager({log: this._log, markerPath: Paths.keyRepeatStatePath()});
      this._captureKeyRepeat();
    });
    this._step('hyper key', () => {
      this._hyperManager = new HyperManager({
        log: this._log,
        statePath: Paths.hyperStatePath(),
        keydConfigPath: Paths.keydConfigPath(),
        onDetected: () => this.scheduleApply('keyd detected'),
      });
      this._hyperManager.detect();
    });
    this._step('hotstrings', () => {
      this._espanso = new EspansoSync({
        log: this._log,
        configDir: Paths.espansoConfigDir(),
        home: this._home,
        onConfigDirChanged: () => this.scheduleApply('espanso config moved'),
      });
      this._espanso.start();
    });
    this._step('displays', () => {
      this._screensChanged = new Debouncer(this._timers, 750, () => this._applyDisplayDefaults('display change'));
      this._monitors = new MonitorWatcher(() => this._screensChanged.trigger());
    });
    if (this._debugMode) this._step('debug interface', () => (this._debugService = new DebugService(this)));

    this._started = true;
    this.apply();
    if (settingBool(this._settings ?? {}, 'checkDefaultsOnLoad', false)) this._applyDisplayDefaults('config loaded');
    this._step('get started', () => this._scheduleGetStarted());
  }

  stop() {
    if (!this._timers) return;
    // GNOME disables extensions while the screen is locked; keep espanso's file then, so hotstrings
    // don't churn on every lock.
    const locked = !!Main.sessionMode?.isLocked;
    this._started = false;
    // Safety first: nothing Slated pressed stays down, and no auto-repeat or macro keeps running.
    this._step('automation', () => {
      this._automation?.destroy(locked ? 'screen locked' : 'disabled');
      this._runner?.cancelPendingSteps();
      this._synth?.destroy();
      this._indicator?.destroy();
    });
    this._step('island', () => {
      this._hyperHold?.destroy();
      this._island?.destroy();
    });
    this._step('sleep', () => this._sleepWatcher?.destroy());
    // Key repeat stays as set: it's your preference, not a temporary mapping.
    this._step('caps lock', () => this._capsLock?.destroy());
    this._step('top bar', () => {
      this._statusIcon?.destroy();
      if (this._startupSignal) Main.layoutManager.disconnect(this._startupSignal);
    });
    this._statusIcon = null;
    this._startupSignal = 0;
    this._step('debug interface', () => this._debugService?.destroy());
    this._step('displays', () => {
      this._monitors?.destroy();
      this._screensChanged?.cancel();
    });
    this._step('focus', () => this._focusTracker?.destroy());
    this._step('config', () => this._store?.stopWatching());
    this._step('shortcuts', () => this._keybindings?.destroy());
    this._step('clipboard', () => this._clipboard?.stop());
    this._step('overlays', () => this._overlays?.destroy());
    this._step('hud', () => this._hud?.destroy());
    this._step('text input', () => this._input?.destroy());
    this._step('actions', () => this._runner?.destroy());
    let capsHyperLeft = false;
    this._step('hyper key', () => (capsHyperLeft = this._hyperManager?.destroy() === true));
    this._step('hotstrings', () => this._espanso?.destroy({keepFile: locked}));
    this._timers.clearAll();
    // The last status says what's left: GNOME's caps:hyper option went with Slated, unless you had set
    // it yourself (keyd keeps working without Slated), and espanso's match file too, unless the
    // screen is only locked.
    const hyperRestored = this._hyper.mode === 'xkb' && !capsHyperLeft;
    if (hyperRestored) this._hyper = {...this._hyper, mode: 'off', active: false, hyperIsSuper: false};
    if (!locked) this._hotstrings = {...this._hotstrings, count: 0};
    this._step('status', () => this._writeStatus(false));
    this._log?.record('app.quit', {reason: locked ? 'screen locked' : 'disabled', hyperRestored}, 'notice');
    this._log?.close();

    this._debugService = this._monitors = this._screensChanged = this._store = null;
    this._keybindings = this._overlays = this._hud = null;
    this._input = this._platform = this._snapshots = this._runner = this._hyperManager = this._espanso = null;
    this._capsLock = this._keyRepeatManager = null;
    this._automation = this._synth = this._indicator = this._clipboard = this._focusTracker = this._sleepWatcher = null;
    this._island = this._hyperHold = null;
    this._shortcutEntries = [];
    this._statusFile = null;
    this._timers = null;
  }

  // --- Applying configuration --------------------------------------------------------------------

  _configuration() {
    return this._store?.configuration ?? emptyConfiguration();
  }

  /** Re-registers everything from the current configuration. */
  apply() {
    if (!this._started) return;
    const config = this._configuration();

    // Safety: a reload re-grabs every trigger, so nothing keeps running or stays held across it.
    this._step('automation', () => {
      if (this._automation?.isBusy) this._automation.stopAll('config reloaded');
      this._runner?.cancelPendingSteps();
      if (this._automation) this._automation.settings = {...this._automation.settings, ...(config.automation ?? {})};
    });
    this._step('clipboard', () => this._clipboard?.apply(config.clipboard));
    const island = islandSettings(config.island);
    this._step('island', () => this._island?.apply(island));

    // Slate's window settings (settings.json's `windows`).
    const settings = {...(config.windows ?? {})};
    this._settings = settings;
    if (this._runner) {
      this._runner.settings = settings;
      this._runner.setLayouts(config.layouts ?? []);
    }

    // Before the shortcuts: GNOME's keyboard repeat timing goes into their hold timing.
    this._step('key repeat', () => {
      if (this._keyRepeatManager) this._keyRepeat = this._keyRepeatManager.apply(config.keyboard?.keyRepeat ?? null);
    });

    const wantsHyper = config.keyboard?.capsLock === 'hyper' && !this.paused;
    // A Caps Lock that's on stays on once it's the Hyper key: turn it off first, while the keymap still
    // has a Caps_Lock key to tap (GNOME's caps:hyper option takes it away). With the option already
    // set, the step after the Hyper key tries again once the mode has changed (to keyd, say).
    this._step('caps lock', () => {
      if (wantsHyper && !this._hyperManager?.capsHyperSet()) this._capsLock?.clear(this._hyper.active ? 'caps lock on' : 'hyper turned on');
    });
    const modeBefore = this._hyper.mode;

    this._step('hyper key', () => {
      if (this._hyperManager) {
        this._hyper = this._hyperManager.apply({
          // Paused: Caps Lock is a plain Caps Lock again (keyd, a system service, keeps its mapping).
          wanted: wantsHyper,
          capsLockAlone: config.keyboard?.capsLockAlone,
        });
      }
    });
    this._step('caps lock', () => {
      if (wantsHyper && this._hyper.mode !== modeBefore) this._capsLock?.clearSoon('hyper mode changed');
    });

    this._step('shortcuts', () => {
      if (!this._keybindings) return;
      const options = acceleratorOptions(this._hyper.mode);
      const disabled = [];
      for (const binding of this.paused ? [] : (config.bindings ?? [])) {
        if (binding.enabled !== false) continue;
        try {
          disabled.push(bindingKey(comboOf(binding.keys, this.core), modalOf(binding.modal, this.core), this.core));
        } catch {
          // An unreadable binding has no status to show.
        }
      }
      let escapeKeys = null;
      try {
        escapeKeys = comboOf(String(settings.modalEscapeKey ?? 'esc'), this.core);
      } catch {
        escapeKeys = null;
      }
      // While-held repeats notice the key being let go through GNOME's key repeat; with it off, a
      // second press stops them instead.
      const repeat = readKeyboardRepeat();
      this._whileHeldMode = repeat.enabled ? 'key-repeat' : 'toggle';
      // The built-in clipboard and stop shortcuts come last, so a binding on the same keys wins (as on macOS).
      // Paused: nothing is grabbed, so the keys reach the apps.
      const entries = this.paused ? [] : [...this._configEntries(config, settings), ...this._builtInEntries(config)];
      this._shortcutEntries = entries;
      this._logWhileHeld(entries);
      this._keybindings.apply(entries, {
        disabled,
        escapeKeys,
        acceleratorFor: (combo) => this.core.toGnomeAccelerator(combo, options),
        holdTiming: repeat.enabled ? releaseTiming(repeat) : null,
      });
    });

    this._step('hotstrings', () => {
      // Paused: espanso's match file goes, so nothing expands.
      const live = this.paused ? {...config, general: {...config.general, hotstringsEnabled: false}} : config;
      if (this._espanso) this._hotstrings = this._espanso.apply(live);
    });

    this._step('island', () => this._watchHyper(config, island));
    // The island turned on or off: running automations move between it and the pill.
    this._automationChanged();

    this._lastError = this._store?.loadError ?? null;
    this._step('top bar', () => this._syncStatusIcon(config));
    this._publishStatus();
  }

  // --- Pause, the top bar and the settings window --------------------------------------------------

  /**
   * The first run of this version: copies GNOME's key repeat into config.json when it has none, once
   * per computer (keyRepeat.js), so the setting travels with config.json. Never while config.json
   * can't be read: Slated mustn't write over a file it couldn't read.
   */
  _captureKeyRepeat() {
    const manager = this._keyRepeatManager;
    const store = this._store;
    if (!manager || !store?.configuration || store.loadError || manager.captured) return;
    if (store.configuration.keyboard?.keyRepeat) {
      // Copied from another computer: it's applied here, and turning it off later sticks.
      manager.markCaptured();
      return;
    }
    const raw = manager.read();
    if (!raw) return; // GNOME's setting can't be read; try again next time
    if (!raw.enabled) {
      // Applying a keyRepeat turns repeating on; that's for you to choose in Settings.
      manager.markCaptured();
      this._log?.record('keyboard.key_repeat_not_captured', {reason: 'key repeat is off in GNOME'});
      return;
    }
    const current = Core.clampKeyRepeat(raw);
    if (store.update((config) => ({...config, keyboard: {...config.keyboard, keyRepeat: current}}))) store.load();
    manager.markCaptured(current);
    this._log?.record('keyboard.key_repeat_captured', {delay: current.delay, interval: current.interval});
  }

  /** "Pause Slated": no shortcuts, Hyper key or hotstrings until resumed (Engine.setPaused on the Mac). */
  get paused() {
    return this._session.paused === true;
  }

  /** Pauses or resumes. Kept across screen locks (the session object), not across logins, as on the Mac. */
  setPaused(value) {
    const paused = value === true;
    if (paused === this.paused) return;
    this._session.paused = paused;
    if (paused) this._automation?.stopAll('paused');
    this._log?.record(paused ? 'app.paused' : 'app.resumed', {}, 'notice');
    this.apply();
  }

  /** Shows or hides the top-bar icon (`general.showStatusIcon`, on by default). */
  _syncStatusIcon(config) {
    if (config.general?.showStatusIcon === false) {
      this._statusIcon?.destroy();
      this._statusIcon = null;
      return;
    }
    if (!this._statusIcon) {
      this._statusIcon = new StatusIcon({iconDir: `${this._extensionPath}/icons`, role: this._uuid ?? 'slated', commands: this._menuCommands()});
    }
    this._refreshStatusIcon();
  }

  _refreshStatusIcon() {
    if (!this._statusIcon) return;
    const warnings = statusWarnings({loadError: this._store?.loadError ?? null, hotkeys: this._keybindings?.statuses ?? {}});
    this._statusIcon.update({paused: this.paused, hyperOn: this._configuration().keyboard?.capsLock === 'hyper', warnings});
  }

  /** What the top bar's menu does, logged under the Mac's event names. */
  _menuCommands() {
    return {
      open: (reason) => this.openSettings(reason),
      toggleHyper: (on) => this._setHyperKey(on),
      togglePause: (on) => {
        this._log?.record('menu.toggle_pause', {pause: on});
        this.setPaused(on);
      },
      reload: () => {
        this._log?.record('menu.reload');
        this.reload('menu');
      },
      openConfig: () => this._openPath('menu.open_config', Paths.configPath()),
      // settings.json; when it isn't there (every setting at its default), the folder it would be in.
      openSettings: () => {
        const path = Paths.settingsPath();
        this._openPath('menu.open_settings', exists(path) ? path : path.slice(0, path.lastIndexOf('/')));
      },
      showLog: () => this._openPath('menu.show_log', Paths.stateDir()),
      menuOpened: () => this._log?.record('menu.opened'),
    };
  }

  /** Caps Lock → Hyper Key: config.json's keyboard.capsLock, saved as the settings window saves it. */
  _setHyperKey(on) {
    this._log?.record('menu.toggle_hyper', {enable: on});
    try {
      this._store?.update((config) => ({...config, keyboard: {...config.keyboard, capsLock: on ? 'hyper' : 'off'}}));
    } catch (e) {
      this._log?.error('config.save_failed', errorMessage(e));
      this._refreshStatusIcon(); // the switch goes back
      return;
    }
    this.reload('menu');
  }

  _openPath(event, path) {
    this._log?.record(event);
    const result = openURL(GLib.filename_to_uri(path, null));
    if (!result.ok) this._log?.error('menu.open_failed', result.error, {event});
  }

  /**
   * Opens Slated's settings window, or brings it forward when it's open. `reason`: "status_icon",
   * "menu" or "first_login". Returns "focused", "opened" or "unavailable".
   */
  openSettings(reason) {
    const event = {status_icon: 'menu.status_item_clicked', menu: 'menu.settings', first_login: 'ui.get_started_opened'}[reason] ?? 'ui.settings_requested';
    let result = 'unavailable';
    try {
      const window = findSettingsWindow(this._metadata.name ?? 'Slated', Windows.allWindows());
      if (window) {
        Windows.activate(window);
        result = 'focused';
      } else if (this._openPreferences) {
        this._openPreferences();
        result = 'opened';
      }
    } catch (e) {
      this._error('settings window', e);
    }
    this._log?.record(event, {result});
    return result;
  }

  /** Until Get Started is finished: the settings window opens on it shortly after login, once per session. */
  _scheduleGetStarted() {
    if (this._session.getStartedOpened || !this._openPreferences) return;
    if (setupFinished(readText(Paths.settingsWindowStatePath()))) return;
    const wait = () => this._timers?.timeout(GET_STARTED_DELAY_MS, () => this._offerGetStarted());
    // At login, extensions start before GNOME Shell has finished starting up.
    if (Main.layoutManager?._startingUp) {
      this._startupSignal = Main.layoutManager.connect('startup-complete', () => {
        Main.layoutManager.disconnect(this._startupSignal);
        this._startupSignal = 0;
        wait();
      });
    } else {
      wait();
    }
  }

  _offerGetStarted() {
    const offer = shouldOfferGetStarted({
      stateText: readText(Paths.settingsWindowStatePath()),
      alreadyOpened: this._session.getStartedOpened,
      locked: !!Main.sessionMode?.isLocked,
    });
    if (!offer) return;
    this._session.getStartedOpened = true;
    this.openSettings('first_login');
  }

  _configEntries(config, settings) {
    const repeatOps = repeatOnHoldOps(settings);
    const entries = [];
    (config.bindings ?? []).forEach((binding, index) => {
      if (binding.enabled === false) return;
      let keys;
      let modal;
      try {
        keys = comboOf(binding.keys, this.core);
        modal = modalOf(binding.modal, this.core);
      } catch (e) {
        this._log.error('binding.invalid', errorMessage(e), {index});
        return;
      }
      if (!keys) return;
      const id = bindingKey(keys, modal, this.core);
      const whileHeld = whileHeldRepeat(binding.action);
      entries.push({
        id,
        keys,
        modal,
        repeats: typeof binding.repeats === 'boolean' ? binding.repeats : repeatOps.includes(binding.action?.op),
        source: 'Slated',
        apps: Array.isArray(binding.onlyInApps) ? binding.onlyInApps : [],
        // A while-held repeat needs to hear about the key being let go; one that types keys can't
        // (any key event ends GNOME's key repeat), so it works like a toggle.
        holdable: !!whileHeld && !modal && !sendsKeys(whileHeld.action),
        whileHeld: !!whileHeld,
        name: binding.name ?? null,
        action: binding.action,
        run: () =>
          this._runner?.run(binding.action, {
            label: binding.name ?? null,
            chainKey: binding.id ?? `config#${index}`,
            trigger: `hotkey ${id}`,
            source: 'Slated',
          }),
      });
    });
    return entries;
  }

  /** Slated's own shortcuts: the clipboard switcher (`clipboard.shortcut`) and the automation stop shortcut. */
  _builtInEntries(config) {
    const entries = [];
    const add = (keysText, action, source, name) => {
      let keys = null;
      try {
        keys = comboOf(keysText, this.core);
      } catch {
        keys = null;
      }
      if (!keys) return;
      const id = bindingKey(keys, null, this.core);
      entries.push({id, keys, modal: null, repeats: false, source, name, action, run: () => this._runner?.run(action, {trigger: `hotkey ${id}`, source})});
    };
    if (config.clipboard?.enabled !== false && config.clipboard?.shortcut) add(config.clipboard.shortcut, {op: 'clipboard-history'}, 'Slated clipboard', 'Clipboard history');
    if (config.automation?.stopShortcut) add(config.automation.stopShortcut, {op: 'stop-automations'}, 'Slated automation', 'Stop automations');
    return entries;
  }

  /** Says once (per change) which while-held bindings work like toggles on GNOME, and why. */
  _logWhileHeld(entries) {
    const whileHeld = entries.filter((e) => e.whileHeld);
    const toggles = whileHeld.filter((e) => this._whileHeldMode === 'toggle' || !e.holdable).map((e) => e.id);
    const signature = JSON.stringify([this._whileHeldMode, toggles]);
    if (signature === this._loggedWhileHeld) return;
    this._loggedWhileHeld = signature;
    if (whileHeld.length === 0) return;
    const data = {mode: this._whileHeldMode, bindings: whileHeld.length};
    if (toggles.length) {
      data.toggles = toggles;
      data.reason =
        this._whileHeldMode === 'toggle'
          ? 'keyboard repeat is off in GNOME Settings, so Slated can’t tell when a key is let go: press the shortcut again to stop'
          : 'these repeat keystrokes, which stop GNOME’s key repeat: press the shortcut again to stop';
    }
    this._log.record('automation.while_held', data, toggles.length ? 'notice' : 'info');
  }

  // --- Automation, focus and clipboard -----------------------------------------------------------

  _focusChanged(app) {
    this._focusedApp = app;
    this._rememberApp(app);
    this._automation?.focusChanged(app);
    if (this._keybindings?.setFocusedApp(app)) this._publishStatus();
  }

  /** Recently focused apps (id and name), newest first, for the settings window's app picker. */
  _rememberApp(app) {
    if (!app?.id || appMatchesAny(app, OWN_APPS)) return;
    this._recentApps = [{id: app.id, name: app.name ?? app.id}, ...this._recentApps.filter((a) => a.id !== app.id)].slice(0, RECENT_APPS);
  }

  /** The stop shortcut as keycaps ("✦ Esc"), when it's registered. */
  _stopLabel() {
    const text = this._configuration().automation?.stopShortcut;
    if (!text) return null;
    try {
      const combo = comboOf(text, this.core);
      if (!combo) return null;
      const status = this._keybindings?.statuses?.[bindingKey(combo, null, this.core)];
      return status === 'active' || status === 'duplicate' ? shortcutLabel(combo) : null;
    } catch {
      return null;
    }
  }

  /** What the island or the pill lists: what runs, unless `automation.showIndicator` is off. */
  _indicatedAutomations() {
    return this._configuration().automation?.showIndicator === false ? [] : (this._automation?.active ?? []);
  }

  /** Running automations: in the island, or the red pill when the island is off. */
  _automationChanged() {
    const islandOn = islandSettings(this._configuration().island).enabled;
    const stopLabel = this._stopLabel();
    try {
      this._indicator?.update(islandOn ? [] : (this._automation?.active ?? []), {
        stopLabel,
        visible: !islandOn && this._configuration().automation?.showIndicator !== false,
      });
    } catch (e) {
      this._error('indicator', e);
    }
    try {
      this._island?.automationsChanged(islandOn ? this._indicatedAutomations() : [], {stopLabel});
    } catch (e) {
      this._error('island', e);
    }
    this._publishStatus();
  }

  // --- The island ----------------------------------------------------------------------------------

  /** What a shortcut did: in the island, or the bottom pill when the island is off. */
  _showFeedback(message, report) {
    if (!islandSettings(this._configuration().island).enabled || !this._island) {
      this._hud.show(message);
      return;
    }
    const action = report?.action ?? null;
    let region = null;
    let monitor = null;
    if (report?.frame) {
      const screen = Core.screenContaining(currentScreens(), report.frame);
      if (screen) {
        monitor = screen.displayID;
        // Window placements show where the window went; focusing and app actions show their symbol.
        if (showsRegion(action)) region = regionIn(report.frame, screen.visibleFrame);
      }
    }
    let symbol = 'square.grid.3x3';
    if (action) {
      try {
        symbol = (this.core.actionSymbol ?? Core.actionSymbol)(action) ?? 'checkmark';
      } catch {
        symbol = 'checkmark';
      }
    }
    this._island.flash({title: report?.title ?? message, app: report?.app ?? null, region, symbol}, {monitor});
  }

  /** Shortcuts that work right now, as the cheat sheet takes them: live for the focused app, registered. */
  _liveShortcuts() {
    const statuses = this._keybindings?.statuses ?? {};
    return this._shortcutEntries
      .filter((entry) => !entry.apps?.length || appMatchesAny(this._focusedApp, entry.apps))
      .filter((entry) => {
        const status = statuses[entry.id] ?? '';
        return status !== 'disabled' && !status.startsWith('failed');
      })
      .map((entry) => ({keys: entry.keys, modal: entry.modal?.keys ?? null, name: entry.name ?? null, action: entry.action ?? null, summary: entry.summary ?? null}));
  }

  /** What the island lists while the Hyper key is held. */
  _hyperCheatSheet() {
    const build = this.core.hyperCheatSheet ?? Core.hyperCheatSheet;
    return build(this._liveShortcuts(), this._configuration().keyboard?.hyperModifiers ?? ['ctrl', 'alt', 'shift', 'cmd']);
  }

  /** A modal key was pressed (its KeyCombo) or modal mode ended (null): the island shows it, then its keys. */
  _modalChanged(keys) {
    let sheet = null;
    if (keys) {
      try {
        const build = this.core.modalCheatSheet ?? Core.modalCheatSheet;
        sheet = {...build(keys, this._liveShortcuts()), modalLabel: shortcutLabel(keys)};
      } catch (e) {
        this._error('island', e);
      }
    }
    this._island?.modalChanged(sheet);
  }

  /**
   * Reads the Hyper key's hold for the cheat sheet, only while it can show: the island and its cheat
   * sheet on, Caps Lock working as Hyper, and some Hyper shortcut to list.
   */
  _watchHyper(config, island) {
    if (!this._hyperHold) return;
    const hyperModifiers = config.keyboard?.hyperModifiers ?? ['ctrl', 'alt', 'shift', 'cmd'];
    const anyHyperShortcut = this._shortcutEntries.some(
      (entry) => !entry.modal && hyperModifiers.every((m) => (entry.keys?.modifiers ?? []).includes(m)),
    );
    const wanted = island.enabled && island.cheatSheet && this._hyper.active && anyHyperShortcut;
    const masks = wanted ? hyperMasks(this._hyper.mode, hyperModifiers) : null;
    this._hyperHold.watch(masks);
    if (!masks) this._island?.hyperUnavailable();
  }

  /** Re-applies on the next main-loop turn (coalesces bursts; safe from inside key handlers). */
  scheduleApply(_reason) {
    if (!this._timers || this._applyIdle) return;
    this._applyIdle = this._timers.idle(() => {
      this._applyIdle = 0;
      this.apply();
    });
  }

  scheduleReload(reason) {
    if (!this._timers) return;
    this._timers.idle(() => this.reload(reason));
  }

  reload(reason = 'reload') {
    if (!this._started) return;
    this._log.record('config.reload', {reason});
    this._store?.load();
    this.apply();
  }

  /** Slate's `default` directive: apply a layout or snapshot when the display setup matches. */
  _applyDisplayDefaults(reason) {
    if (!this._runner) return;
    const screens = currentScreens();
    this._log.record('display.changed', {screens: screens.length, resolutions: screens.map(resolutionOf).sort(), reason});
    const defaults = (this._configuration().defaults ?? []).map(defaultEntry).filter(Boolean);
    const trigger = `display change (${screens.length} screens)`;
    for (const entry of defaults) {
      if (!conditionMatches(entry.condition, screens)) continue;
      if (this._runner.layouts.has(entry.target)) {
        this._runner.run({op: 'layout', name: entry.target}, {trigger});
      } else {
        this._runner.run({op: 'activate-snapshot', name: entry.target}, {trigger});
      }
      break;
    }
    this._publishStatus();
  }

  // --- Status ------------------------------------------------------------------------------------

  _statusState(running) {
    const config = this._configuration();
    return {
      session: this._log?.session,
      version: this._build?.version,
      running,
      paused: running && this.paused,
      hyper: this._hyper,
      keyRepeat: this._keyRepeat,
      hotstrings: this._hotstrings,
      hotkeys: this._keybindings?.statuses ?? {},
      automation: {
        running: running ? (this._automation?.active ?? []).map((a) => a.title) : [],
        shortcuts: running ? automationShortcuts(this._automation?.active ?? []) : [],
        stopShortcut: config.automation?.stopShortcut ?? null,
        whileHeld: this._whileHeldMode,
      },
      clipboard: {enabled: config.clipboard?.enabled !== false, items: this._clipboard?.count ?? 0},
      recentApps: this._recentApps,
      lastAction: this._lastAction,
      lastError: this._lastError,
    };
  }

  _publishStatus() {
    if (!this._timers || this._statusIdle) return;
    this._statusIdle = this._timers.idle(() => {
      this._statusIdle = 0;
      this._step('top bar', () => this._refreshStatusIcon());
      this._writeStatus(true);
    });
  }

  _writeStatus(running) {
    try {
      this._statusFile?.write(this._statusState(running));
    } catch (e) {
      this._log?.error('status.write_failed', errorMessage(e), {path: Paths.statusPath()});
    }
  }

  // --- Errors ------------------------------------------------------------------------------------

  _step(area, body) {
    try {
      return body();
    } catch (e) {
      this._error(area, e);
      return undefined;
    }
  }

  _error(area, error) {
    const message = errorMessage(error);
    if (this._log) this._log.error('runtime.error', message, {area, stack: String(error?.stack ?? '').split('\n').slice(0, 6).join(' | ')});
    else console.error(`Slated: ${area}: ${message}`);
  }

  // --- Debug interface (debug.js; only with SLATED_DEBUG=1) ----------------------------------------

  debugRunAction(json) {
    let action = json;
    try {
      action = JSON.parse(json);
    } catch {
      // Not JSON: Slate operation syntax.
    }
    if (!this._runner) return {ok: false, error: 'The action runner did not start'};
    const ok = this._runner.run(action, {trigger: 'debug', source: 'debug'});
    return {ok, error: ok ? null : this._runner.lastFailure ?? 'failed'};
  }

  debugTriggerBinding(keys) {
    return this._keybindings?.trigger(keys) ?? false;
  }

  debugPressKeys(keys) {
    try {
      const combo = comboOf(keys, this.core);
      if (!combo) return {ok: false, error: `Unknown keys ${keys}`};
      return this._input.pressKeys(combo);
    } catch (e) {
      return {ok: false, error: errorMessage(e)};
    }
  }

  debugFocusWindow(id) {
    const window = Windows.allWindows().find((w) => w.get_id() === id);
    if (!window) return false;
    Windows.activate(window);
    return true;
  }

  _describeWindow(window) {
    return {
      id: window.get_id(),
      app: Windows.appId(Windows.appOf(window), window),
      frame: Windows.frameOf(window),
      minimized: window.minimized,
      maximized: Windows.isMaximized(window),
      focused: window === global.display.get_focus_window(),
    };
  }

  debugFocusedWindow() {
    const window = Windows.focusedWindow();
    return window ? this._describeWindow(window) : null;
  }

  debugWindows() {
    return Windows.stackedWindows({includeMinimized: true}).map((w) => this._describeWindow(w));
  }

  debugScreens() {
    return currentScreens();
  }

  debugStatus() {
    return buildStatus(this._statusState(true));
  }

  debugMovePointer(x, y) {
    try {
      return this._synth?.moveTo(x, y).ok ?? false;
    } catch {
      return false;
    }
  }
}
