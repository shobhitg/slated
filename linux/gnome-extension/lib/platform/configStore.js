// Loads, saves and watches `~/.config/slated/config.json` (the same file and format as on macOS),
// decoding and encoding it with the core. A port of the macOS ConfigStore.
//
// First run behaves as on macOS: if `~/.slate.js` or `~/.slate` exists, Slated starts with an empty
// configuration so the Slate file is the default; otherwise with the built-in starter bindings.

import * as Core from '../core/index.js';

import {exists, readText, watchFile, writeTextAtomic} from './files.js';
import {Debouncer} from './timers.js';
import {expandHome} from './util.js';

export const DEFAULT_SLATE_PATHS = Object.freeze(['~/.slate.js', '~/.slate']);

/**
 * A configuration with every default and nothing bound, used only while the core can't decode one
 * (e.g. a development build without the engine). Same defaults as Swift's SlatedConfiguration.
 */
export function emptyConfiguration() {
  return {
    version: 1,
    general: {
      launchAtLogin: false,
      loadSlateConfigs: true,
      slateConfigPaths: [...DEFAULT_SLATE_PATHS],
      showActionHUD: false,
      hotstringsEnabled: true,
    },
    settings: {},
    keyboard: {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: ['ctrl', 'alt', 'shift', 'cmd']},
    bindings: [],
    layouts: [],
    defaults: [],
    hotstrings: [],
  };
}

/** Whether a first run should defer to an existing Slate config. */
export function hasSlateConfig(home, fileExists = exists) {
  return DEFAULT_SLATE_PATHS.some((path) => fileExists(expandHome(path, home)));
}

export class ConfigStore {
  constructor({path, home, log, timers, core = Core}) {
    this.path = path;
    this._home = home;
    this._log = log;
    this._timers = timers;
    this._core = core;
    /** The active configuration, or null when none could ever be read. */
    this.configuration = null;
    /** Why the file on disk couldn't be used, if it couldn't. */
    this.loadError = null;
    this._lastText = null;
    this._watcher = null;
    this._changed = null;
  }

  /**
   * Reads the file, creating it on first run. On a parse error the previous configuration stays active
   * and `loadError` explains the problem.
   */
  load() {
    const text = readText(this.path);
    if (text === null && !exists(this.path)) {
      this._createFirstRun();
      return;
    }
    try {
      this.configuration = this._core.decodeConfiguration(text ?? '');
      this._lastText = text;
      this.loadError = null;
      this._log?.record('config.loaded', this.summary());
    } catch (e) {
      this.loadError = `Couldn't read ${this.path}: ${e.message ?? e}`;
      this._log?.error('config.error', this.loadError, {path: this.path});
    }
  }

  _createFirstRun() {
    const deferToSlate = hasSlateConfig(this._home);
    try {
      const configuration = deferToSlate ? this._core.decodeConfiguration('{}') : this._core.starterConfiguration();
      this.save(configuration);
      this._log?.record('config.created', {
        path: this.path,
        from: deferToSlate ? 'empty (Slate config is the default)' : 'starter bindings',
      });
    } catch (e) {
      this.loadError = `Couldn't create ${this.path}: ${e.message ?? e}`;
      this._log?.error('config.error', this.loadError, {path: this.path});
    }
  }

  save(configuration) {
    const text = this._core.encodeConfiguration(configuration);
    writeTextAtomic(this.path, text.endsWith('\n') ? text : `${text}\n`);
    this._lastText = readText(this.path);
    this.configuration = configuration;
    this.loadError = null;
  }

  /** Calls `onExternalChange` after the file changes on disk (hand edits, the preferences app). */
  startWatching(onExternalChange) {
    this.stopWatching();
    this._changed = new Debouncer(this._timers, 200, () => {
      const text = readText(this.path);
      if (text === null || text === this._lastText) return;
      this._log?.record('config.changed_on_disk', {path: this.path});
      this.load();
      onExternalChange();
    });
    this._watcher = watchFile(this.path, () => this._changed.trigger());
  }

  stopWatching() {
    this._changed?.cancel();
    this._watcher?.cancel();
    this._changed = null;
    this._watcher = null;
  }

  summary() {
    const c = this.configuration ?? {};
    return {
      path: this.path,
      bindings: c.bindings?.length ?? 0,
      hotstrings: c.hotstrings?.length ?? 0,
      layouts: c.layouts?.length ?? 0,
      capsLock: c.keyboard?.capsLock ?? 'off',
      loadSlateConfigs: c.general?.loadSlateConfigs ?? true,
    };
  }
}
