// Reading, creating, migrating and writing Slated's two configuration files (config.json and
// settings.json, see lib/core/configFiles.js). The extension (lib/platform/configStore.js) and the
// settings window (model.js) both use this, so whichever process reads a version 1 config.json first
// migrates it, and the other then finds version 2.
//
// - First run (no config.json): a Slate config (~/.slate.js, else ~/.slate) imported into native
//   bindings, or else the starter bindings. Both files are written.
// - Migration (a version 1 config.json): a copy to config.v1.json (never overwritten), the settings
//   sections moved to settings.json (unless it exists: then it wins), the Slate files version 1
//   loaded imported once, then settings.json and config.json written. A file that doesn't parse
//   isn't migrated.
// - The import's counts and what couldn't be converted go into a small record in the state folder
//   (config-migration.json), from which the settings window tells you once.
//
// Slate files are never loaded live any more; importing runs ~/.slate.js on pretend desktops
// (importer.js) and keeps what converts.
//
// Pure ES module: file access comes in through `io`.

import {decodeConfigurationFiles, encodeConfigurationFiles, legacySlateOptions, starterConfiguration} from '../core/index.js';
import {importSlateScript, importClassic, planImport} from './importer.js';
import {describeError} from './engine.js';
import {newId} from './ids.js';
import {comboLabel} from './keys.js';
import {expandHome, formatList, isObject, plural, tildify} from './util.js';

/** Where Slate configs are looked for when version 1 named none: the first one that exists. */
export const DEFAULT_SLATE_PATHS = Object.freeze(['~/.slate.js', '~/.slate']);

/**
 * @typedef {object} ConfigFilesIO
 * @property {string} home the home folder (for ~ in Slate paths)
 * @property {() => string|null} readConfig config.json's text, null when it doesn't exist; throws when unreadable
 * @property {() => string|null} readSettings settings.json's, likewise
 * @property {(text: string) => void} writeConfig writes config.json atomically
 * @property {(text: string) => void} writeSettings writes settings.json atomically
 * @property {(text: string) => boolean} backupConfig writes config.v1.json unless it exists; true when written
 * @property {(path: string) => string|null} readFile a Slate file (and what it sources), null when missing
 * @property {() => string|null} [readRecord] config-migration.json in the state folder
 * @property {(text: string) => void} [writeRecord]
 */

/**
 * The Slate configs to import: every existing one of `paths` (version 1's slateConfigPaths), or without
 * them the first of ~/.slate.js and ~/.slate.
 */
export function findSlateFiles(io, paths = null) {
  const read = raw => {
    const file = expandHome(String(raw).trim(), io.home);
    let text = null;
    try {
      text = io.readFile(file);
    } catch {
      text = null;
    }
    if (text === null || text === undefined) return null;
    return {path: raw, file, displayPath: tildify(file, io.home), kind: file.endsWith('.js') ? 'javascript' : 'classic', text};
  };
  // Version 1's list, even an empty one (it loaded nothing then).
  if (Array.isArray(paths)) return paths.filter(p => typeof p === 'string' && p.trim()).map(read).filter(Boolean);
  for (const path of DEFAULT_SLATE_PATHS) {
    const found = read(path);
    if (found) return [found];
  }
  return [];
}

/**
 * Imports Slate files into `configuration` with the merge rule (importer.planImport): a binding whose
 * trigger Slated already has is skipped, as are `alreadyImported` ones.
 * @returns the plan ({config, added, duplicates, alreadyImported, skipped, neverRun}) with `errors`
 *   (files that couldn't be read) and `files` (their ~ paths)
 */
export function importSlateFiles(configuration, files, {home, readFile, makeId = newId, alreadyImported = []} = {}) {
  const results = [];
  const errors = [];
  for (const source of files) {
    const options = {path: source.file, home, readFile, makeId};
    try {
      const result = source.kind === 'javascript' ? importSlateScript(source.text, options) : importClassic(source.text, options);
      results.push({path: source.displayPath, result});
    } catch (error) {
      errors.push({path: source.displayPath, message: describeError(error)});
    }
  }
  return {...planImport(configuration, results, {alreadyImported}), errors, files: files.map(f => f.displayPath)};
}

/**
 * What an import did, for the log, the record and the notice: counts, and what couldn't be converted
 * by key combo or name, with the reason (never the script's source).
 */
export function importSummary(plan) {
  const unconvertible = [...plan.skipped, ...plan.neverRun].map(s => (s.keys
    ? {keys: s.keys, modal: s.modal ?? null, reason: s.reason}
    : {label: s.keystroke, reason: s.reason}));
  for (const e of plan.errors ?? []) unconvertible.push({label: e.path, reason: e.message});
  return {
    files: plan.files ?? [],
    imported: plan.added.length,
    skipped: plan.duplicates.length + plan.alreadyImported.length,
    unconvertible,
  };
}

/** Counts only, for `config.migrated` and `config.created`. */
function slateCounts(summary) {
  if (!summary) return null;
  return {files: summary.files.length, imported: summary.imported, skipped: summary.skipped, unconvertible: summary.unconvertible.length};
}

const withNewline = text => (text.endsWith('\n') ? text : `${text}\n`);

/**
 * Which files' content differs between two configurations (a save writes only those).
 * @returns {{config: boolean, settings: boolean, texts: {config: string, settings: string}}}
 */
export function changedFiles(before, after, settingsExtras = {}) {
  const old = before ? encodeConfigurationFiles(before, settingsExtras) : {config: null, settings: null};
  const texts = encodeConfigurationFiles(after, settingsExtras);
  return {config: texts.config !== old.config, settings: texts.settings !== old.settings, texts};
}

/**
 * Writes the configuration's files: settings.json first, then config.json, each only when `which`
 * says so. Throws what the writes throw.
 * @returns {{configText: string|null, settingsText: string|null}} what was written
 */
export function writeConfigFiles(io, configuration, settingsExtras, which = {config: true, settings: true}) {
  const texts = encodeConfigurationFiles(configuration, settingsExtras);
  const out = {configText: null, settingsText: null};
  if (which.settings) {
    out.settingsText = withNewline(texts.settings);
    io.writeSettings(out.settingsText);
  }
  if (which.config) {
    out.configText = withNewline(texts.config);
    io.writeConfig(out.configText);
  }
  return out;
}

// --- The record the settings window tells you from --------------------------------------------------

/** config-migration.json's text → the record, or null. */
export function parseRecord(text) {
  try {
    const record = typeof text === 'string' ? JSON.parse(text) : null;
    return isObject(record) ? record : null;
  } catch {
    return null;
  }
}

export function recordText(record) {
  return `${JSON.stringify(record, null, 2)}\n`;
}

function readRecord(io) {
  try {
    return parseRecord(io.readRecord?.() ?? null);
  } catch {
    return null;
  }
}

/** Keeps a record of the import, unless an earlier one said all there is to say (told once). */
function saveRecord(io, record, log) {
  if (!io.writeRecord || !record.slate) return;
  const previous = readRecord(io);
  if (previous?.slate && record.slate.imported === 0 && record.slate.unconvertible.length === 0) return;
  try {
    io.writeRecord(recordText(record));
  } catch (error) {
    log('config.record_failed', {message: describeError(error)}, 'warning');
  }
}

// --- Loading -----------------------------------------------------------------------------------------

/**
 * Reads the files, creating them on a first run and migrating version 1.
 *
 * @param {ConfigFilesIO} io
 * @param {object} [options]
 * @param {string} [options.by] who's doing it, for the log: "gnome-extension" or "settings"
 * @param {() => string} [options.makeId] ids for imported bindings
 * @param {(event: string, data?: object, level?: string) => void} [options.log]
 * @param {() => Date} [options.now]
 * @returns {{configuration?, settingsExtras?, configText: string|null, settingsText: string|null,
 *   created?: boolean, migrated?: boolean, record?: object, error?: Error, writeError?: Error}}
 *   `error` (with `file`): nothing usable was read, and nothing was written. `writeError`: the
 *   configuration is usable but creating or migrating the files failed.
 */
export function loadConfigFiles(io, {by = 'settings', makeId = newId, log = () => {}, now = () => new Date()} = {}) {
  let configText;
  let settingsText;
  try {
    configText = io.readConfig();
  } catch (error) {
    return {error: readError(error, 'config.json'), configText: null, settingsText: null};
  }
  try {
    settingsText = io.readSettings();
  } catch (error) {
    return {error: readError(error, 'settings.json'), configText, settingsText: null};
  }
  const context = {io, by, makeId, log, now};
  if (configText === null || configText === undefined) return create(context, settingsText ?? null);
  let decoded;
  try {
    decoded = decodeConfigurationFiles(configText, settingsText ?? null);
  } catch (error) {
    return {error, configText, settingsText: settingsText ?? null};
  }
  const result = {configuration: decoded.configuration, settingsExtras: decoded.settingsExtras, configText, settingsText: settingsText ?? null};
  return decoded.legacy ? migrate(context, decoded, result) : result;
}

function readError(error, file) {
  const out = new Error(`Couldn't read ${file}: ${describeError(error)}`);
  out.file = file;
  return out;
}

/** First run: the Slate config imported, or the starter bindings; settings.json's settings if it's there. */
function create({io, by, makeId, log, now}, settingsText) {
  let base;
  try {
    base = decodeConfigurationFiles(null, settingsText);
  } catch (error) {
    return {error, configText: null, settingsText};
  }
  let configuration = base.configuration;
  let slate = null;
  const files = findSlateFiles(io);
  if (files.length) {
    const plan = importSlateFiles(configuration, files, {home: io.home, readFile: p => io.readFile(p), makeId});
    configuration = plan.config;
    slate = importSummary(plan);
  } else {
    const starter = starterConfiguration();
    configuration = {...configuration, keyboard: starter.keyboard, bindings: starter.bindings};
  }
  const result = {configuration, settingsExtras: base.settingsExtras, configText: null, settingsText, created: true};
  try {
    const written = writeConfigFiles(io, configuration, base.settingsExtras, {config: true, settings: settingsText === null});
    result.configText = written.configText;
    if (written.settingsText !== null) result.settingsText = written.settingsText;
  } catch (error) {
    result.writeError = error;
    log('config.error', {message: `Couldn't create the configuration: ${describeError(error)}`, by}, 'error');
    return result;
  }
  log('config.created', {by, from: slate ? 'Slate config' : 'starter bindings', slate: slateCounts(slate)});
  if (slate) {
    result.record = {version: 1, kind: 'first-run', at: now().toISOString(), by, slate, noticeDismissed: false};
    saveRecord(io, result.record, log);
  }
  return result;
}

/** Version 1 → version 2 (see the top of this file). `result` holds what was read. */
function migrate({io, by, makeId, log, now}, decoded, result) {
  let backup = false;
  try {
    backup = io.backupConfig(result.configText) === true;
  } catch (error) {
    // Without the copy, nothing is rewritten: the configuration still reads as version 1.
    result.writeError = error;
    log('config.migration_failed', {by, message: `Couldn't copy config.json to config.v1.json: ${describeError(error)}`}, 'error');
    return result;
  }
  const options = legacySlateOptions(decoded.configObject);
  let configuration = decoded.configuration;
  let slate = null;
  if (options.load) {
    const files = findSlateFiles(io, options.paths);
    if (files.length) {
      const plan = importSlateFiles(configuration, files, {home: io.home, readFile: p => io.readFile(p), makeId, alreadyImported: options.imported});
      configuration = plan.config;
      slate = importSummary(plan);
    }
  }
  const settingsMoved = result.settingsText === null && ['general', 'settings', 'windows', 'clipboard', 'automation', 'island']
    .some(key => Object.prototype.hasOwnProperty.call(decoded.configObject, key));
  // settings.json is written when it's new, or when the import added window settings to it.
  const settingsChanged = result.settingsText === null || changedFiles(decoded.configuration, configuration, decoded.settingsExtras).settings;
  try {
    const written = writeConfigFiles(io, configuration, decoded.settingsExtras, {config: true, settings: settingsChanged});
    result.configText = written.configText;
    if (written.settingsText !== null) result.settingsText = written.settingsText;
  } catch (error) {
    result.writeError = error;
    log('config.migration_failed', {by, message: `Couldn't write the configuration: ${describeError(error)}`}, 'error');
    return {...result, configuration};
  }
  result.configuration = configuration;
  result.migrated = true;
  log('config.migrated', {by, from: 1, to: 2, settingsMoved, settingsKept: !settingsMoved && result.settingsText !== null && !settingsChanged,
    backup, slate: slateCounts(slate)}, 'notice');
  result.record = {version: 1, kind: 'migration', at: now().toISOString(), by, settingsMoved, backup, slate, noticeDismissed: false};
  saveRecord(io, result.record, log);
  return result;
}

// --- Telling you -------------------------------------------------------------------------------------

/** "✦ X", "Ctrl Alt F4 → 1", or a name like `slate.on("windowOpened")`. */
export function unconvertibleLabel(item) {
  if (item.keys) {
    try {
      return comboLabel(item.keys, item.modal ? {keys: item.modal} : null);
    } catch {
      return item.keys;
    }
  }
  return item.label ?? '';
}

/**
 * The Overview's one-time notice after a migration imported Slate files (the Mac shows the same
 * words), or null when there's nothing to say or it was dismissed.
 * @returns {{text: string, unconvertible: string|null, items: Array<{label, reason}>}|null}
 */
export function migrationNotice(record, {configPath = '~/.config/slated/config.json'} = {}) {
  if (!record || record.kind !== 'migration' || !record.slate || record.noticeDismissed === true) return null;
  const files = formatList(record.slate.files?.length ? record.slate.files : ['~/.slate.js']);
  const text = `Your ${files} shortcuts are now part of Slated's config. Slated doesn't read ${files} any more: `
    + `edit them here or in ${configPath}.`;
  const items = (record.slate.unconvertible ?? []).map(item => ({label: unconvertibleLabel(item), reason: item.reason ?? ''}));
  const unconvertible = items.length ? `${items.length} couldn't be converted: ${formatList(items.map(i => i.label))}.` : null;
  return {text, unconvertible, items};
}

/** What Get Started's Slate step says about an import the record describes, or null. */
export function importedText(record) {
  const slate = record?.slate;
  if (!slate) return null;
  const files = formatList(slate.files ?? []);
  const parts = [`Slated imported ${plural(slate.imported, 'shortcut')} from ${files}.`];
  if (slate.skipped) parts.push(`${plural(slate.skipped, 'shortcut')} Slated already had ${slate.skipped === 1 ? 'was' : 'were'} left alone.`);
  if (slate.unconvertible?.length) {
    parts.push(`${slate.unconvertible.length} couldn't be converted: ${formatList(slate.unconvertible.map(unconvertibleLabel))}.`);
  }
  return parts.join(' ');
}
