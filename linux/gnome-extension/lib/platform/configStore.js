// Loads and watches Slated's configuration: `~/.config/slated/config.json` (what your keys do) and
// `settings.json` beside it (how Slated behaves), the same files and format as on macOS. A port of
// the macOS ConfigStore.
//
// Reading, creating and migrating the files is lib/prefs/migration.js, shared with the settings
// window (pure JavaScript, no GTK): whichever process sees a version 1 config.json first migrates it,
// and the other then finds version 2. A first run imports a Slate config (~/.slate.js, else
// ~/.slate) or starts from the starter bindings. The extension doesn't save edits; the settings
// window does, and the extension picks them up through the file monitors.

import {loadConfigFiles} from '../prefs/migration.js';

import {exists, readText, watchFile, writeTextAtomic, writeTextIfMissing} from './files.js';
import {Debouncer} from './timers.js';

/**
 * A configuration with every default and nothing bound, used only while no configuration could be
 * read. Same defaults as Swift's SlatedConfiguration.
 */
export function emptyConfiguration() {
  return {
    version: 2,
    general: {launchAtLogin: false, showActionHUD: false, hotstringsEnabled: true},
    windows: {},
    keyboard: {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: ['ctrl', 'alt', 'shift', 'cmd']},
    bindings: [],
    layouts: [],
    defaults: [],
    hotstrings: [],
    clipboard: {
      enabled: true, shortcut: 'shift+cmd+v', maxItems: 200, persist: true, retentionDays: 30, ignoreConcealed: true,
      excludedApps: [], pasteAfterSelecting: true,
    },
    automation: {stopShortcut: 'hyper+esc', stopOnAppSwitch: true, maxRunMinutes: 0, showIndicator: true},
    island: {enabled: true, cheatSheet: true, cheatSheetDelay: 0.5, showFailures: true},
  };
}

/** A file's text, null when it doesn't exist; throws when it exists but can't be read. */
function readOrThrow(path) {
  const text = readText(path);
  if (text === null && exists(path)) throw new Error('it exists but could not be read (check its permissions)');
  return text;
}

export class ConfigStore {
  /**
   * @param {object} options
   * @param {{config: string, settings: string, backup: string, record: string}} options.paths
   *   config.json, settings.json, config.v1.json and config-migration.json
   * @param {string} options.home the home folder, for Slate files
   * @param {object} [options.log] the EventLog
   * @param {object} options.timers
   */
  constructor({paths, home, log, timers}) {
    this.paths = paths;
    this.path = paths.config;
    this._home = home;
    this._log = log;
    this._timers = timers;
    /** The active configuration, or null when none could ever be read. */
    this.configuration = null;
    /** Why the files on disk couldn't be used, if they couldn't (naming the file). */
    this.loadError = null;
    this._lastTexts = {config: null, settings: null};
    this._watchers = [];
    this._changed = null;
  }

  /** The files, for migration.loadConfigFiles. */
  _io() {
    const {config, settings, backup, record} = this.paths;
    return {
      home: this._home,
      readConfig: () => readOrThrow(config),
      readSettings: () => readOrThrow(settings),
      writeConfig: (text) => writeTextAtomic(config, text),
      writeSettings: (text) => writeTextAtomic(settings, text),
      backupConfig: (text) => writeTextIfMissing(backup, text),
      readFile: (path) => readText(path),
      readRecord: () => readText(record),
      writeRecord: (text) => writeTextAtomic(record, text),
    };
  }

  /**
   * Reads both files, creating them on a first run and migrating version 1. When a file can't be
   * read, the previous configuration stays active and `loadError` explains the problem.
   */
  load() {
    const log = (event, data = {}, level = 'info') => this._log?.record(event, data, level);
    const result = loadConfigFiles(this._io(), {by: 'gnome-extension', log});
    if (result.error) {
      const file = result.error.file ?? 'config.json';
      const message = describe(result.error);
      this.loadError = message.startsWith("Couldn't read") ? message : `Couldn't read ${file}: ${message}`;
      this._lastTexts = {config: result.configText ?? null, settings: result.settingsText ?? null};
      this._log?.error('config.error', this.loadError, {path: file === 'settings.json' ? this.paths.settings : this.paths.config});
      return;
    }
    this.configuration = result.configuration;
    this._lastTexts = {config: result.configText ?? null, settings: result.settingsText ?? null};
    this.loadError = result.writeError ? `Couldn't write the configuration: ${describe(result.writeError)}` : null;
    this._log?.record('config.loaded', this.summary());
  }

  /** Calls `onExternalChange` after either file changes on disk (hand edits, the settings window). */
  startWatching(onExternalChange) {
    this.stopWatching();
    this._changed = new Debouncer(this._timers, 200, () => {
      const texts = {config: readText(this.paths.config), settings: readText(this.paths.settings)};
      if (texts.config === null) return;
      if (texts.config === this._lastTexts.config && texts.settings === this._lastTexts.settings) return;
      this._log?.record('config.changed_on_disk', {path: this.paths.config});
      this.load();
      onExternalChange();
    });
    this._watchers = [this.paths.config, this.paths.settings].map((path) => watchFile(path, () => this._changed.trigger()));
  }

  stopWatching() {
    this._changed?.cancel();
    for (const watcher of this._watchers) watcher?.cancel();
    this._changed = null;
    this._watchers = [];
  }

  summary() {
    const c = this.configuration ?? {};
    return {
      path: this.paths.config,
      bindings: c.bindings?.length ?? 0,
      hotstrings: c.hotstrings?.length ?? 0,
      layouts: c.layouts?.length ?? 0,
      capsLock: c.keyboard?.capsLock ?? 'off',
    };
  }
}

/** "bindings[2].id: …" for decoding errors, as the settings window says it. */
function describe(error) {
  const path = Array.isArray(error?.codingPath) && error.codingPath.length
    ? error.codingPath.map((key, i) => (typeof key === 'number' ? `[${key}]` : i ? `.${key}` : String(key))).join('')
    : '';
  const message = error?.message ?? String(error);
  return path ? `${path}: ${message}` : message;
}
