// The two files Slated keeps its configuration in, shared with the Mac app (docs/CONFIG.md):
//
//   config.json    what your keys do: keyboard (the Hyper key), bindings, hotstrings, layouts, defaults
//   settings.json  how Slated behaves: general, windows (Slate's window settings), clipboard,
//                  automation, island
//
// In memory they're one configuration (config.js); this module splits it for writing and combines
// the files for reading. Version 1 kept everything in config.json, with `windows` called `settings`
// and the Slate files' loading options in `general`. Such a file still reads (its settings sections
// count until settings.json exists); `isLegacyLayout` tells the stores to migrate it.
//
// Pure: texts in, texts out. The stores (lib/platform/configStore.js, lib/prefs/model.js, through
// lib/prefs/migration.js) read, write and watch the files.

import {CURRENT_VERSION, decodeConfiguration} from './config.js';
import {SlatedError} from './errors.js';
import {asInt, formatJSON, isNumberValue, JSONNumber, parseJSON5} from './json.js';

export const CONFIG_FILE = 'config.json';
export const SETTINGS_FILE = 'settings.json';
/** Where a migration keeps version 1's config.json, beside it. Never overwritten. */
export const BACKUP_FILE = 'config.v1.json';

/** config.json's sections: what your keys do. */
export const CONFIG_SECTIONS = Object.freeze(['keyboard', 'bindings', 'hotstrings', 'layouts', 'defaults']);
/** settings.json's sections: how Slated behaves. */
export const SETTINGS_SECTIONS = Object.freeze(['general', 'windows', 'clipboard', 'automation', 'island']);
/** Settings sections in a config.json mark version 1's layout (`settings` is version 1's `windows`). */
const LEGACY_SECTIONS = Object.freeze(['general', 'settings', 'windows', 'clipboard', 'automation', 'island']);

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof JSONNumber);
const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

function put(object, key, value) {
  Object.defineProperty(object, key, {value, enumerable: true, writable: true, configurable: true});
}

/** Names the file an error comes from (`error.file`), so messages can say which one to fix. */
export function inFile(error, file) {
  const out = error instanceof SlatedError ? error : new SlatedError('invalidConfiguration', String(error?.message ?? error), {codingPath: []});
  if (!out.file) out.file = file;
  return out;
}

/** A file's text as a JSON5 object. Throws SlatedError("invalidConfiguration") naming the file. */
export function parseConfigText(text, file) {
  let value;
  try {
    value = parseJSON5(text);
  } catch (e) {
    throw inFile(e, file);
  }
  if (!isObject(value)) {
    throw inFile(new SlatedError('invalidConfiguration', `${file} must contain a JSON object`, {codingPath: []}), file);
  }
  return value;
}

/**
 * Whether a parsed config.json is version 1's layout: no version or version 1, or a settings
 * section in it.
 */
export function isLegacyLayout(object) {
  const raw = isObject(object) ? object.version : undefined;
  const version = isNumberValue(raw) ? asInt(raw) : null;
  if (version === null || version < CURRENT_VERSION) return true;
  return LEGACY_SECTIONS.some((key) => has(object, key));
}

/**
 * Version 1's Slate options, from a legacy config.json's `general`: whether Slate files loaded
 * (`loadSlateConfigs`, on unless false), which (`slateConfigPaths`, null when not written) and the
 * shortcuts already imported from them while they kept loading (`importedSlateShortcuts`).
 */
export function legacySlateOptions(object) {
  const general = isObject(object?.general) ? object.general : {};
  const strings = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === 'string') : null);
  return {
    load: general.loadSlateConfigs !== false,
    paths: strings(general.slateConfigPaths),
    imported: strings(general.importedSlateShortcuts) ?? [],
  };
}

/** The file a decoding error's coding path points into. */
function fileOf(error, settingsFromSettingsFile) {
  const first = Array.isArray(error?.codingPath) ? error.codingPath[0] : undefined;
  const settingsSection = LEGACY_SECTIONS.includes(first);
  return settingsSection && settingsFromSettingsFile ? SETTINGS_FILE : CONFIG_FILE;
}

/**
 * Reads the two files into one configuration. `configText` null: config.json doesn't exist (all
 * defaults); `settingsText` null: settings.json doesn't exist (a version 1 config.json's settings
 * sections count then, else the defaults). settings.json wins over a version 1 config.json's.
 *
 * Unknown top-level keys are kept for the file they came from: config.json's on the configuration
 * (as before), settings.json's in `settingsExtras`, for encodeConfigurationFiles.
 *
 * Throws SlatedError("invalidConfiguration") with `file` ("config.json" or "settings.json") and
 * `codingPath`.
 * @returns {{configuration: object, settingsExtras: object, legacy: boolean, configObject: object|null,
 *   settingsObject: object|null}}
 */
export function decodeConfigurationFiles(configText, settingsText = null) {
  const configObject = configText === null || configText === undefined ? null : parseConfigText(configText, CONFIG_FILE);
  const settingsObject = settingsText === null || settingsText === undefined ? null : parseConfigText(settingsText, SETTINGS_FILE);
  const combined = {};
  const settingsExtras = {};
  if (configObject) {
    for (const key of Object.keys(configObject)) {
      // config.json's own sections and keys Slated doesn't know; version 1's settings sections below.
      if (!LEGACY_SECTIONS.includes(key)) put(combined, key, configObject[key]);
    }
  }
  const settingsSource = settingsObject ?? configObject ?? {};
  for (const key of LEGACY_SECTIONS) {
    if (has(settingsSource, key)) put(combined, key, settingsSource[key]);
  }
  if (settingsObject) {
    // Anything else in settings.json (a newer Slated's sections, a config.json section put there by
    // hand) stays there as written, read as Swift's JSONValue reads it, through the configuration's
    // own decoder.
    const extras = Object.keys(settingsObject).filter((key) => key !== 'version' && !LEGACY_SECTIONS.includes(key));
    if (extras.length) {
      let decoded;
      try {
        decoded = decodeConfiguration(Object.fromEntries(extras.map((key) => [`x${key}`, settingsObject[key]])));
      } catch (e) {
        throw inFile(e, SETTINGS_FILE);
      }
      for (const key of extras) put(settingsExtras, key, decoded[`x${key}`]);
    }
  }
  let configuration;
  try {
    configuration = decodeConfiguration(combined);
  } catch (e) {
    throw inFile(e, fileOf(e, Boolean(settingsObject)));
  }
  return {
    configuration,
    settingsExtras,
    legacy: configObject !== null && isLegacyLayout(configObject),
    configObject,
    settingsObject,
  };
}

/**
 * The configuration as the two files' texts, each pretty-printed with sorted keys as Swift writes
 * them, with `version` in both. Unknown top-level keys on the configuration go to config.json,
 * `settingsExtras` to settings.json. Throws SlatedError("invalidConfiguration") for values JSON
 * can't hold.
 * @returns {{config: string, settings: string}}
 */
export function encodeConfigurationFiles(configuration, settingsExtras = {}) {
  const c = decodeConfiguration(configuration);
  const config = {};
  const settings = {};
  for (const key of Object.keys(c)) {
    if (key === 'settings') continue;
    put(SETTINGS_SECTIONS.includes(key) ? settings : config, key, c[key]);
  }
  for (const key of Object.keys(settingsExtras ?? {})) {
    if (!has(settings, key) && key !== 'version') put(settings, key, settingsExtras[key]);
  }
  settings.version = c.version;
  return {config: formatJSON(config), settings: formatJSON(settings)};
}
