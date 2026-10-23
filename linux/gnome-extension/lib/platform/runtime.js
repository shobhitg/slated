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
import {bindingKey, comboOf, modalOf} from './combos.js';
import {ConfigStore, DEFAULT_SLATE_PATHS, emptyConfiguration} from './configStore.js';
import {DebugService} from './debug.js';
import {EspansoSync} from './espanso.js';
import {readText} from './files.js';
import {GnomePlatform} from './gnomePlatform.js';
import {ActionHUD} from './hud.js';
import {HyperManager, acceleratorOptions} from './hyper.js';
import {InputInjector} from './input.js';
import {KeybindingManager, MutterGrabber} from './keybindings.js';
import {EventLog, LogFile, journalMirror} from './log.js';
import {OverlayController} from './overlays.js';
import * as Paths from './paths.js';
import {GnomeScriptHost, ScriptEvents} from './scriptHost.js';
import {MonitorWatcher, currentScreens} from './screens.js';
import {SlateSources} from './slateSources.js';
import {SnapshotStore} from './snapshots.js';
import {StatusFile, buildStatus} from './status.js';
import {Debouncer, Timers} from './timers.js';
import {conditionMatches, defaultEntry, diagnosticText, resolutionOf, truthyText} from './util.js';
import * as Windows from './windows.js';

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
      this._platform = new GnomePlatform({timers: this._timers, input: this._input, home: this._home});
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
    this._step('shortcuts', () => {
      this._keybindings = new KeybindingManager({
        grabber: new MutterGrabber({timers: this._timers, hyperIsSuper: () => this._hyper.hyperIsSuper}),
        log: this._log,
      });
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
    this._step('debug interface', () => this._debugService?.destroy());
    this._step('displays', () => {
      this._monitors?.destroy();
      this._screensChanged?.cancel();
    });
    this._step('config', () => this._store?.stopWatching());
    this._step('slate sources', () => this._sources?.destroy());
    this._step('shortcuts', () => this._keybindings?.destroy());
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
      // Slated's own bindings come first so they win over Slate-file duplicates.
      this._keybindings.apply([...this._configEntries(config, settings), ...(this._sources?.entries(settings) ?? [])], {
        disabled,
        escapeKeys,
        acceleratorFor: (combo) => this.core.toGnomeAccelerator(combo, options),
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
      entries.push({
        id,
        keys,
        modal,
        repeats: typeof binding.repeats === 'boolean' ? binding.repeats : repeatOps.includes(binding.action?.op),
        source: 'Slated',
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
    return {
      session: this._log?.session,
      version: this._build?.version,
      running,
      hyper: this._hyper,
      hotstrings: this._hotstrings,
      hotkeys: this._keybindings?.statuses ?? {},
      sources: this._sources?.sources ?? [],
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
}
