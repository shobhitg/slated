// The running extension's brain: loads configuration from every source, registers shortcuts, sets up
// the Hyper key and hotstrings, runs actions, and publishes status. A port of the macOS Engine
// (Sources/Slated/Engine/Engine.swift).
//
// `start()` never throws: each part starts on its own, and a part that fails is logged
// (`runtime.error`) while the rest keeps working. `stop()` undoes everything `start()` did.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import * as Config from 'resource:///org/gnome/shell/misc/config.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import * as Core from '../core/index.js';
import {ActionRunner, errorMessage} from './actions.js';
import {AutomationEngine, OWN_APPS, automationShortcuts, sendsKeys, whileHeldRepeat} from './automation.js';
import {ClipboardService} from './clipboard.js';
import {bindingKey, comboOf, modalOf} from './combos.js';
import {ConfigStore, DEFAULT_SLATE_PATHS, emptyConfiguration} from './configStore.js';
import {DebugService} from './debug.js';
import {EspansoSync} from './espanso.js';
import {readText} from './files.js';
import {FocusTracker} from './focus.js';
import {GnomePlatform} from './gnomePlatform.js';
import {ActionHUD} from './hud.js';
import {HyperManager, acceleratorOptions} from './hyper.js';
import {AutomationIndicator} from './indicator.js';
import {InputInjector} from './input.js';
import {KeybindingManager, MutterGrabber, readKeyboardRepeat, releaseTiming} from './keybindings.js';
import {EventLog, LogFile, journalMirror} from './log.js';
import {OverlayController} from './overlays.js';
import * as Paths from './paths.js';
import {GnomeScriptHost, ScriptEvents} from './scriptHost.js';
import {MonitorWatcher, currentScreens} from './screens.js';
import {SlateSources} from './slateSources.js';
import {SnapshotStore} from './snapshots.js';
import {StatusFile, buildStatus} from './status.js';
import {InputSynthesizer} from './synth.js';
import {Debouncer, Timers} from './timers.js';
import {appMatchesAny, conditionMatches, defaultEntry, diagnosticText, resolutionOf, shortcutLabel, truthyText} from './util.js';
import * as Windows from './windows.js';

/** How many recently focused apps status.json lists (for the settings window's app picker). */
const RECENT_APPS = 12;

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

export class SlatedRuntime {
  /**
   * @param {object} extension
   * @param {string} extension.path      The extension's directory.
   * @param {object} extension.metadata  metadata.json.
   * @param {string} extension.uuid
   * @param {object} [extension.core]  The engine API; tests pass a fake.
   */
  constructor({path, metadata, uuid, core = Core}) {
    this._extensionPath = path;
    this._metadata = metadata ?? {};
    this._uuid = uuid;
    this.core = core;
    this._lastAction = null;
    this._lastError = null;
    this._hyper = {wanted: false, mode: 'off', active: false, hyperIsSuper: false};
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
      },
      'notice',
    );
    this._statusFile = new StatusFile(Paths.statusPath());

    this._step('config', () => {
      this._store = new ConfigStore({
        path: Paths.configPath(),
        home: this._home,
        log: this._log,
        timers: this._timers,
        core: this.core,
      });
      this._store.load();
      this._store.startWatching(() => this.scheduleApply('config changed'));
    });
    this._step('actions', () => {
      this._input = new InputInjector({
        timers: this._timers,
        log: this._log,
        focusedAppId: () => this._platform?.appInfo(this._platform.focusedApp())?.id ?? null,
      });
      this._synth = new InputSynthesizer({log: this._log});
      this._platform = new GnomePlatform({timers: this._timers, input: this._input, synth: this._synth, home: this._home});
      this._snapshots = new SnapshotStore({path: Paths.snapshotsPath(), platform: this._platform, log: this._log});
      this._runner = new ActionRunner({platform: this._platform, core: this.core, log: this._log, snapshots: this._snapshots});
      this._overlays = new OverlayController({log: this._log, place: (window, frame) => this._runner.place(window, frame, 'Grid')});
      this._runner.overlays = this._overlays;
      this._hud = new ActionHUD();
      this._runner.onPerformed = (message) => {
        this._lastAction = message;
        if (this._configuration().general?.showActionHUD) {
          try {
            this._hud.show(message);
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
      // Reloading re-grabs shortcuts; never do that from inside Mutter's key handling.
      this._runner.onRelaunch = () => this.scheduleReload('relaunch');
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
      this._indicator = new AutomationIndicator();
      if (this._runner) this._runner.automation = this._automation;
    });
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
      });
    });
    this._step('focus', () => {
      this._focusTracker = new FocusTracker((app) => this._focusChanged(app));
      this._focusedApp = this._focusTracker.current();
      this._rememberApp(this._focusedApp);
      this._keybindings?.setFocusedApp(this._focusedApp);
    });
    this._step('slate sources', () => {
      this._scriptHost = new GnomeScriptHost({runner: this._runner, log: this._log, home: this._home});
      this._scriptEvents = new ScriptEvents({host: this._scriptHost, timers: this._timers, dispatch: (event) => this._sources?.dispatch(event)});
      this._sources = new SlateSources({
        core: this.core,
        log: this._log,
        runner: this._runner,
        host: this._scriptHost,
        events: this._scriptEvents,
        platform: this._platform,
        timers: this._timers,
        home: this._home,
        onChange: () => this.scheduleApply('Slate file changed'),
        onDiagnostics: (diagnostics) => {
          this._lastError = diagnostics.map(diagnosticText).join('\n');
          this._publishStatus();
        },
      });
      this._runner.externalLayout = (name) => this._sources.runLayout(name);
    });
    this._step('hyper key', () => {
      this._hyperManager = new HyperManager({
        log: this._log,
        statePath: Paths.hyperStatePath(),
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
    this._step('debug interface', () => this._debugService?.destroy());
    this._step('displays', () => {
      this._monitors?.destroy();
      this._screensChanged?.cancel();
    });
    this._step('focus', () => this._focusTracker?.destroy());
    this._step('config', () => this._store?.stopWatching());
    this._step('slate sources', () => this._sources?.destroy());
    this._step('shortcuts', () => this._keybindings?.destroy());
    this._step('clipboard', () => this._clipboard?.stop());
    this._step('overlays', () => this._overlays?.destroy());
    this._step('hud', () => this._hud?.destroy());
    this._step('text input', () => this._input?.destroy());
    this._step('actions', () => this._runner?.destroy());
    this._step('hyper key', () => this._hyperManager?.destroy());
    this._step('hotstrings', () => this._espanso?.destroy({keepFile: locked}));
    this._timers.clearAll();
    this._step('status', () => this._writeStatus(false));
    this._log?.record('app.quit', {reason: locked ? 'screen locked' : 'disabled', hyperRestored: this._hyper.mode === 'xkb'}, 'notice');
    this._log?.close();

    this._debugService = this._monitors = this._screensChanged = this._store = this._sources = null;
    this._scriptEvents = this._scriptHost = this._keybindings = this._overlays = this._hud = null;
    this._input = this._platform = this._snapshots = this._runner = this._hyperManager = this._espanso = null;
    this._automation = this._synth = this._indicator = this._clipboard = this._focusTracker = null;
    this._statusFile = null;
    this._timers = null;
  }

  // --- Applying configuration --------------------------------------------------------------------

  _configuration() {
    return this._store?.configuration ?? emptyConfiguration();
  }

  /** Re-registers everything from the current configuration and Slate sources. */
  apply() {
    if (!this._started) return;
    const config = this._configuration();
    const general = config.general ?? {};

    // Safety: a reload re-grabs every trigger, so nothing keeps running or stays held across it.
    this._step('automation', () => {
      if (this._automation?.isRunning) this._automation.stopAll('config reloaded');
      this._runner?.cancelPendingSteps();
      if (this._automation) this._automation.settings = {...this._automation.settings, ...(config.automation ?? {})};
    });
    this._step('clipboard', () => this._clipboard?.apply(config.clipboard));

    this._step('slate sources', () => {
      const paths = general.loadSlateConfigs === false ? [] : (general.slateConfigPaths ?? DEFAULT_SLATE_PATHS);
      this._sources?.load(paths);
    });
    const settings = {...(this._sources?.settings ?? {}), ...(config.settings ?? {})};
    this._settings = settings;
    if (this._runner) {
      this._runner.settings = settings;
      this._runner.setLayouts([...(this._sources?.layouts ?? []), ...(config.layouts ?? [])]);
    }

    this._step('hyper key', () => {
      if (this._hyperManager) {
        this._hyper = this._hyperManager.apply({
          wanted: config.keyboard?.capsLock === 'hyper',
          capsLockAlone: config.keyboard?.capsLockAlone,
        });
      }
    });

    this._step('shortcuts', () => {
      if (!this._keybindings) return;
      const options = acceleratorOptions(this._hyper.mode);
      const disabled = [];
      for (const binding of config.bindings ?? []) {
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
      // Slated's own bindings come first so they win over Slate-file duplicates; the built-in
      // clipboard and stop shortcuts come last, so a binding on the same keys wins (as on macOS).
      const entries = [...this._configEntries(config, settings), ...(this._sources?.entries(settings) ?? []), ...this._builtInEntries(config)];
      this._logWhileHeld(entries);
      this._keybindings.apply(entries, {
        disabled,
        escapeKeys,
        acceleratorFor: (combo) => this.core.toGnomeAccelerator(combo, options),
        holdTiming: repeat.enabled ? releaseTiming(repeat) : null,
      });
    });

    this._step('hotstrings', () => {
      if (this._espanso) this._hotstrings = this._espanso.apply(config);
    });

    this._lastError = this._store?.loadError ?? null;
    this._publishStatus();
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
    const add = (keysText, action, source) => {
      let keys = null;
      try {
        keys = comboOf(keysText, this.core);
      } catch {
        keys = null;
      }
      if (!keys) return;
      const id = bindingKey(keys, null, this.core);
      entries.push({id, keys, modal: null, repeats: false, source, run: () => this._runner?.run(action, {trigger: `hotkey ${id}`, source})});
    };
    if (config.clipboard?.enabled !== false && config.clipboard?.shortcut) add(config.clipboard.shortcut, {op: 'clipboard-history'}, 'Slated clipboard');
    if (config.automation?.stopShortcut) add(config.automation.stopShortcut, {op: 'stop-automations'}, 'Slated automation');
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

  _automationChanged() {
    try {
      this._indicator?.update(this._automation?.active ?? [], {
        stopLabel: this._stopLabel(),
        visible: this._configuration().automation?.showIndicator !== false,
      });
    } catch (e) {
      this._error('indicator', e);
    }
    this._publishStatus();
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
    const defaults = [...(this._sources?.defaults ?? []), ...(this._configuration().defaults ?? []).map(defaultEntry).filter(Boolean)];
    const trigger = `display change (${screens.length} screens)`;
    for (const entry of defaults) {
      if (!conditionMatches(entry.condition, screens)) continue;
      if (this._runner.layouts.has(entry.target)) {
        this._runner.run({op: 'layout', name: entry.target}, {trigger});
      } else if (this._sources?.runLayout(entry.target)) {
        this._log.record('action.done', {trigger, action: `layout ${entry.target}`, source: 'JavaScript'});
      } else {
        this._runner.run({op: 'activate-snapshot', name: entry.target}, {trigger});
      }
      break;
    }
    this._sources?.runCallbackDefaults(screens);
    this._publishStatus();
  }

  // --- Status ------------------------------------------------------------------------------------

  _statusState(running) {
    const config = this._configuration();
    return {
      session: this._log?.session,
      version: this._build?.version,
      running,
      hyper: this._hyper,
      hotstrings: this._hotstrings,
      hotkeys: this._keybindings?.statuses ?? {},
      sources: this._sources?.sources ?? [],
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
