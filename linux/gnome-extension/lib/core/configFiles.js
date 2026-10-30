// The two files Slated keeps its configuration in, shared with the Mac app (port of
// Sources/SlatedCore/Model/ConfigFiles.swift; docs/CONFIG.md):
//
//   config.json    what your keys do: keyboard (the Hyper key), bindings, hotstrings, layouts, defaults
//   settings.json  how Slated behaves: general, windows (Slate's window settings), clipboard,
//                  automation, island
//
// In memory they're one configuration (config.js); this module splits it for writing and reads the
// two files into one. Version 1 kept everything in config.json, with `windows` called `settings`
// and the Slate files' loading options in `general`. Such a file is `legacy`: its settings sections
// count until settings.json exists (then settings.json wins and they're dropped), and the stores
// migrate it (lib/prefs/migration.js).
//
// Keys a file has that this version doesn't know stay in that file: config.json's on the
// configuration itself (as config.js keeps them), except one named like a settings section
// (`windows`), and settings.json's, in `extras`. Pure: texts in, texts out.

import {CURRENT_VERSION, decodeConfiguration} from './config.js';
import {SlatedError} from './errors.js';
import {asInt, formatJSON, isNumberValue, JSONNumber, parseJSON5} from './json.js';

export const CONFIG_FILE = 'config.json';
export const SETTINGS_FILE = 'settings.json';
/** Where a migration keeps version 1's config.json, beside it. Never overwritten. */
export const BACKUP_FILE = 'config.v1.json';

/** config.json's sections (besides `version`): what your keys do. */
export const CONFIG_SECTIONS = Object.freeze(['keyboard', 'bindings', 'hotstrings', 'layouts', 'defaults']);
/** settings.json's sections (besides `version`): how Slated behaves. */
export const SETTINGS_SECTIONS = Object.freeze(['general', 'windows', 'clipboard', 'automation', 'island']);
/** The sections a version 1 config.json had that are settings.json's now (`settings` is `windows`). */
export const LEGACY_SETTINGS_SECTIONS = Object.freeze(['general', 'settings', 'clipboard', 'automation', 'island']);

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
    const found = Array.isArray(value) ? 'an array' : value === null ? 'null value' : typeof value === 'string' ? 'a string' : 'a value';
    throw inFile(new SlatedError('invalidConfiguration', `Expected to decode Dictionary<String, Any> but found ${found} instead.`, {codingPath: []}), file);
  }
  return value;
}

/** config.json's `version` as written (an Int), or null when there's none or it isn't one. */
function versionOf(object) {
  const raw = isObject(object) ? object.version : undefined;
  return isNumberValue(raw) ? asInt(raw) : null;
}

/**
 * Whether a parsed config.json is version 1's layout: no version or version 1, or one of version 1's
 * settings sections in it (general, settings, clipboard, automation, island).
 */
export function isLegacyLayout(object) {
  const version = versionOf(object);
  return version === null || version < CURRENT_VERSION || LEGACY_SETTINGS_SECTIONS.some((key) => has(object, key));
}

/** `[String]` as Swift decodes it: every element a string, else nothing. */
const stringArray = (v) => (Array.isArray(v) && v.every((x) => typeof x === 'string') ? [...v] : null);

/**
 * What a version 1 config.json said that version 2 moved or dropped (Swift's LegacyConfig), read only
 * to migrate it: whether Slate files loaded (`loadSlateConfigs`, on unless false), which
 * (`slateConfigPaths`, null when not written), the shortcuts imported from them earlier
 * (`importedSlateShortcuts`), whether it had settings sections, and whether they became
 * settings.json's (`settingsMoved`: there was no settings.json). A field of the wrong type is ignored.
 */
export function legacyConfig(object, {settingsFileExists = false} = {}) {
  const general = isObject(object?.general) ? object.general : {};
  const hadSettings = LEGACY_SETTINGS_SECTIONS.some((key) => has(object ?? {}, key));
  return {
    loadSlateConfigs: typeof general.loadSlateConfigs === 'boolean' ? general.loadSlateConfigs : true,
    slateConfigPaths: has(general, 'slateConfigPaths') ? stringArray(general.slateConfigPaths) : null,
    importedSlateShortcuts: stringArray(general.importedSlateShortcuts) ?? [],
    settingsMoved: hadSettings && !settingsFileExists,
    hadSettings,
  };
}

/** Version 1's Slate options in the migration's terms: {load, paths, imported}. */
export function legacySlateOptions(object) {
  const legacy = legacyConfig(object);
  return {load: legacy.loadSlateConfigs, paths: legacy.slateConfigPaths, imported: legacy.importedSlateShortcuts};
}

/** Decodes `object` with config.js, naming `file` in errors (and `renames` coding path heads). */
function decodeIn(object, file, renames = {}) {
  try {
    return decodeConfiguration(object);
  } catch (e) {
    const error = inFile(e, file);
    if (Array.isArray(error.codingPath) && renames[error.codingPath[0]]) error.codingPath = [renames[error.codingPath[0]], ...error.codingPath.slice(1)];
    throw error;
  }
}

/** Keys kept as written (Swift's JSONValue: whole numbers stay exact), through config.js's decoder. */
function jsonValues(object, keys, file) {
  const out = {};
  if (!keys.length) return out;
  const decoded = decodeIn(Object.fromEntries(keys.map((key) => [`x${key}`, object[key]])), file);
  for (const key of keys) put(out, key, decoded[`x${key}`]);
  return out;
}

/**
 * Reads the two files into one configuration. `configText` null: config.json doesn't exist (all
 * defaults); `settingsText` null: settings.json doesn't exist (a legacy config.json's settings
 * sections count then, else every setting is at its default). The result is version 2, or later
 * when a newer Slated wrote either file.
 *
 * Throws SlatedError("invalidConfiguration") with `file` ("config.json" or "settings.json") and
 * `codingPath`.
 * @returns {{configuration: object, extras: {config: object, settings: object}, legacy: object|null,
 *   configObject: object|null, settingsObject: object|null}} `legacy` (legacyConfig) when config.json
 *   needs migrating; `extras` are the unknown keys encodeConfigurationFiles writes back to each file
 *   (config.json's other unknown keys ride on the configuration)
 */
export function decodeConfigurationFiles(configText, settingsText = null) {
  const configObject = configText === null || configText === undefined ? null : parseConfigText(configText, CONFIG_FILE);
  const settingsObject = settingsText === null || settingsText === undefined ? null : parseConfigText(settingsText, SETTINGS_FILE);
  const source = configObject ?? {};

  // config.json: its sections and keys this version doesn't know; version 1's settings sections are
  // read below. An unknown key named like a settings section (`windows`) waits in `extras`.
  const configPart = {};
  const configExtraKeys = [];
  for (const key of Object.keys(source)) {
    if (LEGACY_SETTINGS_SECTIONS.includes(key)) continue;
    if (SETTINGS_SECTIONS.includes(key)) configExtraKeys.push(key);
    else put(configPart, key, source[key]);
  }
  const fromConfig = decodeIn(configPart, CONFIG_FILE);
  const extras = {config: jsonValues(source, configExtraKeys, CONFIG_FILE), settings: {}};
  const legacy = configObject !== null && isLegacyLayout(configObject)
    ? legacyConfig(configObject, {settingsFileExists: settingsObject !== null})
    : null;

  // settings.json, or else a legacy config.json's settings sections (`settings` as `windows`).
  let fromSettings = null;
  if (settingsObject) {
    const settingsPart = {};
    const settingsExtraKeys = [];
    for (const key of Object.keys(settingsObject)) {
      if (SETTINGS_SECTIONS.includes(key) || key === 'version') put(settingsPart, key, settingsObject[key]);
      else settingsExtraKeys.push(key);
    }
    fromSettings = decodeIn(settingsPart, SETTINGS_FILE);
    extras.settings = jsonValues(settingsObject, settingsExtraKeys, SETTINGS_FILE);
  } else if (legacy?.hadSettings) {
    const settingsPart = {};
    for (const key of ['general', 'clipboard', 'automation', 'island']) if (has(source, key)) put(settingsPart, key, source[key]);
    if (has(source, 'settings')) put(settingsPart, 'windows', source.settings);
    fromSettings = decodeIn(settingsPart, CONFIG_FILE, {windows: 'settings'});
  }

  const configuration = fromConfig;
  if (fromSettings) {
    for (const key of SETTINGS_SECTIONS) configuration[key] = fromSettings[key];
    // A newer version in settings.json is kept (decoding already made both at least the current one).
    if (settingsObject && fromSettings.version > configuration.version) configuration.version = fromSettings.version;
  }
  return {configuration, extras, legacy, configObject, settingsObject};
}

/**
 * The configuration as the two files' texts, each pretty-printed with sorted keys as Swift writes
 * them, with `version` in both. config.json gets the configuration's unknown keys and
 * `extras.config`, settings.json `extras.settings`; neither gets a key the other file owns. Throws
 * SlatedError("invalidConfiguration") for values JSON can't hold.
 * @returns {{config: string, settings: string}}
 */
export function encodeConfigurationFiles(configuration, extras = {}) {
  const c = decodeConfiguration(configuration);
  const config = {};
  const settings = {};
  for (const key of Object.keys(c)) {
    if (SETTINGS_SECTIONS.includes(key)) put(settings, key, c[key]);
    else if (!LEGACY_SETTINGS_SECTIONS.includes(key)) put(config, key, c[key]);
  }
  for (const [key, value] of Object.entries(extras?.config ?? {})) {
    // Never a settings section of version 1's: the file would read as version 1 again.
    if (!has(config, key) && !LEGACY_SETTINGS_SECTIONS.includes(key)) put(config, key, value);
  }
  for (const [key, value] of Object.entries(extras?.settings ?? {})) {
    if (!has(settings, key) && key !== 'version') put(settings, key, value);
  }
  settings.version = c.version;
  return {config: formatJSON(config), settings: formatJSON(settings)};
}
