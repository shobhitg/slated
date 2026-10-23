// config.json defaults and a lenient reader, used by the preferences while the engine's
// decodeConfiguration/encodeConfiguration (lib/core) are still stubs. Defaults match Swift's
// SlatedConfiguration (Sources/SlatedCore/Model/Configuration.swift).
//
// Pure ES module.

import {isObject, stableStringify} from './util.js';
import {newId} from './ids.js';

export const DEFAULT_SLATE_PATHS = ['~/.slate.js', '~/.slate'];

export function defaultGeneral() {
  return {
    launchAtLogin: false,
    loadSlateConfigs: true,
    slateConfigPaths: [...DEFAULT_SLATE_PATHS],
    showActionHUD: false,
    hotstringsEnabled: true,
  };
}

export function defaultKeyboard() {
  return {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: ['ctrl', 'alt', 'shift', 'cmd']};
}

export function defaultLayoutAppOptions() {
  return {ignoreFail: false, repeat: false, repeatLast: false, mainFirst: false, mainLast: false, sortTitle: false};
}

/** A new hotstring with Swift's defaults. */
export function newHotstring(fields = {}, makeId = newId) {
  return {
    id: makeId(),
    trigger: '',
    replacement: '',
    enabled: true,
    caseSensitive: true,
    fire: 'immediately',
    wordBoundary: false,
    method: 'auto',
    onlyInApps: [],
    exceptInApps: [],
    ...fields,
  };
}

/** A new binding. `keys` is the config string ("hyper+a"; "" while it waits to be recorded). */
export function newBinding(fields = {}, makeId = newId) {
  return {id: makeId(), keys: '', action: {op: 'undo'}, enabled: true, ...fields};
}

/** Strips the JSON5 conveniences hand-edited files use: comments, trailing commas, single quotes,
 * unquoted keys. Returns plain JSON text. */
export function json5ToJSON(text) {
  let out = '';
  let i = 0;
  const n = text.length;
  const isIdentStart = c => /[A-Za-z_$]/.test(c);
  const isIdent = c => /[A-Za-z0-9_$]/.test(c);
  while (i < n) {
    const c = text[i];
    if (c === '"' || c === "'") {
      const quote = c;
      let s = '';
      i++;
      while (i < n && text[i] !== quote) {
        if (text[i] === '\\' && i + 1 < n) {
          const next = text[i + 1];
          // \' is valid JSON5 but not JSON.
          s += next === "'" ? "'" : `\\${next}`;
          i += 2;
          continue;
        }
        if (text[i] === '"' && quote === "'") s += '\\"';
        else if (text[i] === '\n') s += '\\n';
        else s += text[i];
        i++;
      }
      i++;
      out += `"${s}"`;
      continue;
    }
    if (c === '/' && text[i + 1] === '/') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    if (c === ',') {
      // Drop a comma that only whitespace and comments separate from } or ].
      let j = i + 1;
      for (;;) {
        while (j < n && /\s/.test(text[j])) j++;
        if (text[j] === '/' && text[j + 1] === '/') {
          while (j < n && text[j] !== '\n') j++;
        } else if (text[j] === '/' && text[j + 1] === '*') {
          j += 2;
          while (j < n && !(text[j] === '*' && text[j + 1] === '/')) j++;
          j += 2;
        } else {
          break;
        }
      }
      if (text[j] === '}' || text[j] === ']') {
        i++;
        continue;
      }
      out += c;
      i++;
      continue;
    }
    if (isIdentStart(c)) {
      let j = i;
      while (j < n && isIdent(text[j])) j++;
      const word = text.slice(i, j);
      let k = j;
      while (k < n && /\s/.test(text[k])) k++;
      if (text[k] === ':' && !['true', 'false', 'null'].includes(word)) out += `"${word}"`;
      else out += word;
      i = j;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** Parses config.json text allowing JSON5 conveniences. Throws with a readable message. */
export function parseLenientJSON(text) {
  try {
    return JSON.parse(json5ToJSON(text));
  } catch (error) {
    throw new Error(`config.json isn't valid JSON: ${error.message}`);
  }
}

function fillBinding(raw, makeId) {
  const b = isObject(raw) ? raw : {};
  const out = {id: typeof b.id === 'string' ? b.id : makeId(), keys: b.keys ?? '', action: b.action ?? {op: 'undo'}};
  if (typeof b.name === 'string') out.name = b.name;
  if (isObject(b.modal)) out.modal = {keys: b.modal.keys ?? '', toggle: b.modal.toggle === true};
  if (typeof b.repeats === 'boolean') out.repeats = b.repeats;
  out.enabled = b.enabled !== false;
  return out;
}

function fillHotstring(raw, makeId) {
  const h = isObject(raw) ? raw : {};
  const out = newHotstring({}, makeId);
  if (typeof h.id === 'string') out.id = h.id;
  for (const key of ['trigger', 'replacement']) if (typeof h[key] === 'string') out[key] = h[key];
  for (const key of ['enabled', 'caseSensitive', 'wordBoundary']) if (typeof h[key] === 'boolean') out[key] = h[key];
  if (['immediately', 'afterDelimiter'].includes(h.fire)) out.fire = h.fire;
  if (['auto', 'type', 'paste'].includes(h.method)) out.method = h.method;
  for (const key of ['onlyInApps', 'exceptInApps']) if (Array.isArray(h[key])) out[key] = h[key].map(String);
  if (h.action !== undefined) out.action = h.action;
  if (typeof h.notes === 'string') out.notes = h.notes;
  return out;
}

function fillLayout(raw) {
  const l = isObject(raw) ? raw : {};
  return {
    name: typeof l.name === 'string' ? l.name : '',
    apps: (Array.isArray(l.apps) ? l.apps : []).map(app => ({
      app: typeof app?.app === 'string' ? app.app : '',
      operations: Array.isArray(app?.operations) ? app.operations : [],
      options: {...defaultLayoutAppOptions(), ...(isObject(app?.options) ? app.options : {})},
    })),
    before: Array.isArray(l.before) ? l.before : [],
    after: Array.isArray(l.after) ? l.after : [],
  };
}

/**
 * A configuration object with every default filled in (the shape decodeConfiguration returns).
 * Sections this stand-in doesn't model (clipboard, automation, anything newer) pass through as they
 * are, so saving never drops them.
 */
export function fillDefaults(raw, makeId = newId) {
  const c = isObject(raw) ? raw : {};
  if (raw !== undefined && !isObject(raw)) throw new Error('config.json must contain a JSON object');
  return {
    ...c,
    version: Number.isInteger(c.version) ? c.version : 1,
    general: {...defaultGeneral(), ...(isObject(c.general) ? c.general : {})},
    settings: isObject(c.settings) ? {...c.settings} : {},
    keyboard: {...defaultKeyboard(), ...(isObject(c.keyboard) ? c.keyboard : {})},
    bindings: (Array.isArray(c.bindings) ? c.bindings : []).map(b => fillBinding(b, makeId)),
    layouts: (Array.isArray(c.layouts) ? c.layouts : []).map(fillLayout),
    defaults: Array.isArray(c.defaults) ? c.defaults : [],
    hotstrings: (Array.isArray(c.hotstrings) ? c.hotstrings : []).map(h => fillHotstring(h, makeId)),
  };
}

/** Local stand-in for encodeConfiguration: stable pretty JSON with sorted keys. */
export function encodeLocal(config) {
  return `${stableStringify(config, 2)}\n`;
}
