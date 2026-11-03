// Loads and watches Slated's configuration: `~/.config/slated/config.json` (what your keys do),
// `settings.json` beside it (how Slated behaves) and `secrets.json` (sensitive hotstrings' text,
// readable only by you), the same files and format as on macOS. A port of the macOS ConfigStore. The
// extension only reads secrets.json (espanso needs the text to expand them); the settings window writes it.
//
// Reading, creating and migrating the files is lib/prefs/migration.js, shared with the settings
// window (pure JavaScript, no GTK): whichever process sees a version 1 config.json first migrates it,
// and the other then finds version 2. A first run imports a Slate config (~/.slate.js, else
// ~/.slate) or starts from the starter bindings. Edits are the settings window's, which the extension
// picks up through the file monitors; the extension itself changes only what its top-bar menu offers
// (Caps Lock → Hyper Key), through `update()`, the same way the settings window saves.

import {defaultClipboard} from '../core/index.js';
import {changedFiles, loadConfigFiles, redactedError, writeConfigFiles} from '../prefs/migration.js';

import {exists, makePrivate, readText, watchFile, writePrivateTextAtomic, writeTextAtomic, writeTextIfMissing} from './files.js';
import {Debouncer} from './timers.js';

/**
 * A configuration with every default and nothing bound, used only while no configuration could be
 * read. Same defaults as Swift's SlatedConfiguration.
 */
export function emptyConfiguration() {
  return {
    version: 2,
    general: {launchAtLogin: false, showActionHUD: false, hotstringsEnabled: true, showStatusIcon: true, showConfigKeys: true},
    windows: {},
    keyboard: {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: ['ctrl', 'alt', 'shift', 'cmd']},
    bindings: [],
    layouts: [],
    defaults: [],
    hotstrings: [],
    clipboard: defaultClipboard(),
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
   * @param {{config: string, settings: string, backup: string, record: string, secrets?: string}} options.paths
   *   config.json, settings.json, config.v1.json, config-migration.json and secrets.json (beside config.json
   *   by default)
   * @param {string} options.home the home folder, for Slate files
   * @param {object} [options.log] the EventLog
   * @param {object} options.timers
   */
  constructor({paths, home, log, timers}) {
    this.paths = {...paths, secrets: paths.secrets ?? paths.config.replace(/[^/]*$/, 'secrets.json')};
    this.path = paths.config;
    /** Sensitive hotstrings' text by name (secrets.json), empty without the file. Never logged. */
    this.secrets = {};
    this._home = home;
    this._log = log;
    this._timers = timers;
    /** The active configuration, or null when none could ever be read. */
    this.configuration = null;
    /** Why the files on disk couldn't be used, if they couldn't (naming the file). */
    this.loadError = null;
    this._lastTexts = {config: null, settings: null, secrets: null};
    this._watchers = [];
    this._changed = null;
  }

  /** The files, for migration.loadConfigFiles. */
  _io() {
    const {config, settings, backup, record, secrets} = this.paths;
    return {
      home: this._home,
      readConfig: () => readOrThrow(config),
      readSettings: () => readOrThrow(settings),
      readSecrets: () => {
        // Made or copied by hand with the usual mode: only you may read it.
        if (exists(secrets) && makePrivate(secrets)) this._log?.record('config.secrets_made_private', {path: secrets}, 'notice');
        return readOrThrow(secrets);
      },
      writeSecrets: (text) => writePrivateTextAtomic(secrets, text),
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
      // secrets.json's errors quote nothing from it.
      const message = redactedError(describe(result.error), file);
      this.loadError = message.startsWith("Couldn't read") ? message : `Couldn't read ${file}: ${message}`;
      this._lastTexts = this._texts(result);
      const paths = {'settings.json': this.paths.settings, 'secrets.json': this.paths.secrets};
      this._log?.error('config.error', this.loadError, {path: paths[file] ?? this.paths.config});
      return;
    }
    this.configuration = result.configuration;
    this.secrets = result.secrets ?? {};
    this._lastTexts = this._texts(result);
    this.loadError = result.writeError ? `Couldn't write the configuration: ${describe(result.writeError)}` : null;
    this._log?.record('config.loaded', this.summary());
  }

  /**
   * Changes the configuration on disk: reads both files afresh, applies `change` to a copy, and writes
   * only the files whose content changed, as the settings window saves. Throws when the files can't
   * be read or written. Returns whether anything was written; `load()` picks it up.
   */
  update(change) {
    const io = this._io();
    const log = (event, data = {}, level = 'info') => this._log?.record(event, data, level);
    const current = loadConfigFiles(io, {by: 'gnome-extension', log});
    if (current.error) throw current.error;
    const next = change(JSON.parse(JSON.stringify(current.configuration)));
    const which = changedFiles(current.configuration, next, current.extras);
    if (!which.config && !which.settings) return false;
    writeConfigFiles(io, next, current.extras, which);
    return true;
  }

  /** What was read, to tell a real change from a file monitor's echo. */
  _texts(result) {
    return {config: result.configText ?? null, settings: result.settingsText ?? null, secrets: result.secretsText ?? null};
  }

  /** Calls `onExternalChange` after a file changes on disk (hand edits, the settings window). */
  startWatching(onExternalChange) {
    this.stopWatching();
    this._changed = new Debouncer(this._timers, 200, () => {
      const texts = {config: readText(this.paths.config), settings: readText(this.paths.settings), secrets: readText(this.paths.secrets)};
      if (texts.config === null) return;
      const last = this._lastTexts;
      if (texts.config === last.config && texts.settings === last.settings && texts.secrets === last.secrets) return;
      // Which file, by name: what changed in secrets.json is nobody's business.
      const file = texts.config !== last.config ? 'config.json' : texts.settings !== last.settings ? 'settings.json' : 'secrets.json';
      this._log?.record('config.changed_on_disk', {path: this.paths.config, file});
      this.load();
      onExternalChange();
    });
    this._watchers = [this.paths.config, this.paths.settings, this.paths.secrets].map((path) => watchFile(path, () => this._changed.trigger()));
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
      // How many: never a name or a text.
      secrets: Object.keys(this.secrets ?? {}).length,
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
