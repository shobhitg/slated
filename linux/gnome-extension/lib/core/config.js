// Slated's configuration (config.json) and the Action model (port of Configuration.swift,
// Action.swift's Codable conformance, SlateSettings.swift and Starter.swift).
//
// Every value here is plain JSON-shaped data in its canonical form, exactly what Swift's encoder
// writes: an action is {op: "push", direction: "up", style: "bar-resize:screenSizeY/2"}, a binding is
// {id, keys: "hyper+a", action, enabled, name?, modal?, repeats?}. `decodeAction` and
// `decodeConfiguration` accept everything Swift's decoders accept and fill in the same defaults.

import {SlatedError} from './errors.js';
import {asDouble, asInt, formatJSON, isNumberValue, JSONNumber, parseJSON5} from './json.js';
import {formatKeyCombo, modifierMask, parseKeyCombo} from './keys.js';
import {
  appSelectorFromString,
  cornerFromRaw,
  directionFromSlate,
  focusDirectionFromSlate,
  GRID_ORDER,
  INSERT_METHODS,
  pushStyleFromSlate,
  readSettings,
  screenRefFromSlate,
  screenRefToSlate,
} from './model.js';
import {parseOperation} from './slateSyntax.js';
import {compareStrings, lowercased, shortNumber} from './text.js';

export {readSettings};

export const CURRENT_VERSION = 1;

// --- Decoding helpers (Swift's keyed containers) ---------------------------------------------------

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof JSONNumber);

function describe(v) {
  if (v === null) return 'null value';
  if (Array.isArray(v)) return 'an array';
  if (isNumberValue(v)) return 'number';
  if (typeof v === 'string') return 'a string';
  if (typeof v === 'boolean') return 'bool';
  return 'a dictionary';
}

const decodingError = (path, message) => new SlatedError('invalidConfiguration', message, {codingPath: path});

function typeMismatch(path, expected, value) {
  if (value === null) return decodingError(path, `Cannot get value of type ${expected} -- found null value instead`);
  return decodingError(path, `Expected to decode ${expected} but found ${describe(value)} instead.`);
}

/** Puts `key` on a plain object (safe for keys like "__proto__"). */
function put(object, key, value) {
  Object.defineProperty(object, key, {value, enumerable: true, writable: true, configurable: true});
}

class Keyed {
  constructor(value, path) {
    if (!isObject(value)) throw typeMismatch(path, 'Dictionary<String, Any>', value);
    this.value = value;
    this.path = path;
  }

  raw(key) {
    return Object.prototype.hasOwnProperty.call(this.value, key) ? this.value[key] : undefined;
  }

  at(key) {
    return [...this.path, key];
  }

  /** `decodeIfPresent`: nil for a missing key or null. */
  optional(key, decode) {
    const v = this.raw(key);
    return v === undefined || v === null ? undefined : decode(v, this.at(key));
  }

  /** `decode`: the key must be there; a null value fails in `decode` ("found null value instead"). */
  required(key, decode) {
    const v = this.raw(key);
    if (v === undefined) throw decodingError(this.at(key), `No value associated with key "${key}".`);
    return decode(v, this.at(key));
  }
}

const str = (v, path) => {
  if (typeof v !== 'string') throw typeMismatch(path, 'String', v);
  return v;
};
const bool = (v, path) => {
  if (typeof v !== 'boolean') throw typeMismatch(path, 'Bool', v);
  return v;
};
const int = (v, path) => {
  if (!isNumberValue(v)) throw typeMismatch(path, 'Int', v);
  const n = asInt(v);
  if (n === null) throw decodingError(path, 'The given data was not valid JSON.');
  return n;
};
const arrayOf = (decode) => (v, path) => {
  if (!Array.isArray(v)) throw typeMismatch(path, 'Array<Any>', v);
  return v.map((item, k) => decode(item, [...path, k]));
};
const enumOf = (values, type) => (v, path) => {
  const s = str(v, path);
  if (!values.includes(s)) throw decodingError(path, `Cannot initialize ${type} from invalid String value ${s}`);
  return s;
};

const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const uuid = (v, path) => {
  const s = str(v, path);
  if (!UUID_PATTERN.test(s)) throw decodingError(path, 'Attempted to decode UUID from invalid UUID string.');
  return s.toUpperCase();
};

/** A random (version 4) UUID in Swift's uppercase form. */
export function randomUUID() {
  const native = globalThis.crypto?.randomUUID?.();
  if (native) return native.toUpperCase();
  const hex = [];
  for (let i = 0; i < 16; i++) hex.push(Math.floor(Math.random() * 256));
  hex[6] = (hex[6] & 0x0f) | 0x40;
  hex[8] = (hex[8] & 0x3f) | 0x80;
  const s = hex.map((b) => b.toString(16).padStart(2, '0')).join('').toUpperCase();
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

// --- Actions -------------------------------------------------------------------------------------

/** ScreenRef's decoding: an Int index, or Slate's screen text. Returns the canonical text. */
function screenRef(v, path) {
  if (isNumberValue(v)) {
    const i = asInt(v);
    if (i !== null) return String(i);
  }
  const raw = str(v, path);
  const ref = screenRefFromSlate(raw);
  if (ref === null) throw decodingError(path, `Invalid screen reference "${raw}"`);
  return screenRefToSlate(ref);
}

function pushStyle(v, path) {
  const raw = str(v, path);
  const style = pushStyleFromSlate(raw);
  if (style === null) throw decodingError(path, `Invalid push style "${raw}"`);
  return style;
}

function keyCombo(v, path) {
  const raw = str(v, path);
  const combo = parseKeyCombo(raw);
  if (combo === null) {
    throw decodingError(path, `Invalid key combo "${raw}". Expected e.g. "hyper+a" or "ctrl+cmd+left".`);
  }
  return formatKeyCombo(combo);
}

function appSelector(v, path) {
  if (Array.isArray(v) && v.every((item) => typeof item === 'string')) return [...v];
  return appSelectorFromString(str(v, path));
}

/**
 * An action from its config.json form, in canonical form: an object with "op" and Slate's
 * JavaScript parameter names, or a string of Slate operation syntax. Throws SlatedError
 * ("invalidConfiguration", with `codingPath`) for anything Swift's decoder rejects.
 * @returns {Object} the canonical Action
 */
export function decodeAction(value, path = []) {
  if (typeof value === 'string') {
    try {
      return parseOperation(value);
    } catch (e) {
      if (e instanceof SlatedError) throw decodingError(path, `Invalid operation "${value}": ${e.message}`);
      throw e;
    }
  }
  const c = new Keyed(value, path);
  const op = c.required('op', str);

  const expr = (key) => {
    const v = c.raw(key);
    if (typeof v === 'string') return v;
    if (isNumberValue(v)) {
      const d = asDouble(v);
      if (d !== null) return shortNumber(d);
    }
    return undefined;
  };
  const required = (key) => {
    const v = expr(key);
    if (v === undefined) throw decodingError(c.at(key), `"${op}" needs "${key}"`);
    return v;
  };
  const flag = (key) => c.optional(key, bool) ?? false;
  const corner = (v, p) => enumOf(['top-left', 'top-right', 'bottom-left', 'bottom-right'], 'Corner')(v, p);

  switch (op) {
    case 'move': {
      const action = {op, x: required('x'), y: required('y'), width: required('width'), height: required('height')};
      const screen = c.optional('screen', screenRef);
      if (screen !== undefined) action.screen = screen;
      return action;
    }
    case 'resize': {
      const action = {op, width: expr('width') ?? '+0', height: expr('height') ?? '+0'};
      const anchor = c.optional('anchor', corner) ?? 'top-left';
      if (anchor !== 'top-left') action.anchor = anchor;
      return action;
    }
    case 'push': {
      const raw = required('direction');
      const direction = directionFromSlate(raw);
      if (direction === null) throw decodingError(c.at('direction'), `Invalid direction "${raw}"`);
      const style = c.optional('style', pushStyle) ?? 'none';
      const screen = c.optional('screen', screenRef);
      const action = {op, direction};
      if (style !== 'none') action.style = style;
      if (screen !== undefined) action.screen = screen;
      return action;
    }
    case 'nudge':
      return {op, x: expr('x') ?? '+0', y: expr('y') ?? '+0'};
    case 'throw': {
      const action = {op, screen: c.required('screen', screenRef)};
      const width = expr('width');
      const height = expr('height');
      if (width !== undefined) action.width = width;
      if (height !== undefined) action.height = height;
      return action;
    }
    case 'corner': {
      const raw = required('direction');
      const direction = cornerFromRaw(lowercased(raw));
      if (direction === null) throw decodingError(c.at('direction'), `Invalid corner "${raw}"`);
      const action = {op, direction};
      const width = expr('width');
      const height = expr('height');
      const screen = c.optional('screen', screenRef);
      if (width !== undefined) action.width = width;
      if (height !== undefined) action.height = height;
      if (screen !== undefined) action.screen = screen;
      return action;
    }
    case 'chain':
      return {op, operations: c.required('operations', arrayOf(decodeAction))};
    case 'sequence': {
      const step = (v, p) => {
        const s = new Keyed(v, p);
        return {action: s.required('action', decodeAction), keepWindow: s.required('keepWindow', bool)};
      };
      const steps = c.optional('steps', arrayOf(step)) ?? c.required('operations', arrayOf(decodeAction)).map((a) => ({action: a, keepWindow: false}));
      return sequenceAction(steps);
    }
    case 'layout':
      return {op, name: required('name')};
    case 'focus': {
      const app = c.optional('app', str);
      if (app !== undefined) return {op, app};
      const raw = required('direction');
      const direction = focusDirectionFromSlate(raw);
      if (direction === null) throw decodingError(c.at('direction'), `Invalid focus direction "${raw}"`);
      return {op, direction};
    }
    case 'snapshot': {
      const action = {op, name: required('name')};
      if (flag('save')) action.save = true;
      if (flag('stack')) action.stack = true;
      return action;
    }
    case 'delete-snapshot': {
      const action = {op, name: required('name')};
      if (flag('all')) action.all = true;
      return action;
    }
    case 'activate-snapshot': {
      const action = {op, name: required('name')};
      if (flag('delete')) action.delete = true;
      return action;
    }
    case 'hint': {
      const characters = c.optional('characters', str);
      return characters === undefined ? {op} : {op, characters};
    }
    case 'grid': {
      const size = (v, p) => {
        const s = new Keyed(v, p);
        return {width: s.required('width', int), height: s.required('height', int)};
      };
      const sizes = c.optional('grids', (v, p) => {
        const object = new Keyed(v, p);
        const out = {};
        for (const key of Object.keys(object.value)) put(out, key, size(object.value[key], [...p, key]));
        return out;
      });
      const padding = c.optional('padding', int);
      const action = {op};
      if (padding !== undefined) action.padding = padding;
      if (sizes && Object.keys(sizes).length > 0) {
        action.grids = sizes;
        const order = value[GRID_ORDER];
        if (Array.isArray(order) && order.length === Object.keys(sizes).length && order.every((k) => k in sizes)) {
          Object.defineProperty(action, GRID_ORDER, {value: [...order]});
        }
      }
      return action;
    }
    case 'hide':
    case 'show':
    case 'toggle':
      return {op, app: c.required('app', appSelector)};
    case 'shell': {
      const action = {op, command: required('command')};
      if (flag('wait')) action.wait = true;
      const path = c.optional('path', str);
      if (path !== undefined) action.path = path;
      return action;
    }
    case 'undo':
    case 'relaunch':
    case 'switch':
      return {op};
    case 'by-orientation':
      return {op, landscape: c.required('landscape', decodeAction), portrait: c.required('portrait', decodeAction)};
    case 'insert-text': {
      const action = {op, text: required('text')};
      const method = c.optional('method', enumOf(INSERT_METHODS, 'InsertMethod')) ?? 'auto';
      if (method !== 'auto') action.method = method;
      return action;
    }
    case 'open-url':
      return {op, url: required('url')};
    case 'keystroke':
      return {op, keys: c.required('keys', keyCombo)};
    default:
      throw decodingError(c.at('op'), `Unknown operation "${op}"`);
  }
}

/** A sequence in canonical form: plain `operations` unless a step keeps the window (Slate's `>`). */
export function sequenceAction(steps) {
  if (steps.every((s) => !s.keepWindow)) return {op: 'sequence', operations: steps.map((s) => s.action)};
  return {op: 'sequence', steps: steps.map((s) => ({action: s.action, keepWindow: s.keepWindow}))};
}

/** The steps of a canonical sequence action. */
export function sequenceSteps(action) {
  return action.steps ?? (action.operations ?? []).map((a) => ({action: a, keepWindow: false}));
}

/** True for operations that move or resize the focused window (and can be undone). */
export function isWindowGeometry(action) {
  return geometry(decodeAction(action));
}

function geometry(action) {
  switch (action.op) {
    case 'move': case 'resize': case 'push': case 'nudge': case 'throw': case 'corner': return true;
    case 'by-orientation': return geometry(action.landscape) && geometry(action.portrait);
    default: return false;
  }
}

// --- Configuration -------------------------------------------------------------------------------

function defaultGeneral() {
  return {launchAtLogin: false, loadSlateConfigs: true, slateConfigPaths: ['~/.slate.js', '~/.slate'], showActionHUD: false, hotstringsEnabled: true};
}

function defaultKeyboard() {
  return {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: ['ctrl', 'alt', 'shift', 'cmd']};
}

const defaultOptions = () => ({ignoreFail: false, mainFirst: false, mainLast: false, repeat: false, repeatLast: false, sortTitle: false});

function general(v, path) {
  const c = new Keyed(v, path);
  const d = defaultGeneral();
  return {
    launchAtLogin: c.optional('launchAtLogin', bool) ?? d.launchAtLogin,
    loadSlateConfigs: c.optional('loadSlateConfigs', bool) ?? d.loadSlateConfigs,
    slateConfigPaths: c.optional('slateConfigPaths', arrayOf(str)) ?? d.slateConfigPaths,
    showActionHUD: c.optional('showActionHUD', bool) ?? d.showActionHUD,
    hotstringsEnabled: c.optional('hotstringsEnabled', bool) ?? d.hotstringsEnabled,
  };
}

/** One Slate `config` value: a boolean, a number or text, as in SettingValue's decoding. */
function settingValue(v, path) {
  if (typeof v === 'boolean') return v;
  if (isNumberValue(v)) {
    const d = asDouble(v);
    if (d !== null) return d;
  }
  return str(v, path);
}

function settings(v, path) {
  const c = new Keyed(v, path);
  const out = {};
  for (const key of Object.keys(c.value)) put(out, key, settingValue(c.value[key], [...path, key]));
  return out;
}

function keyboard(v, path) {
  const c = new Keyed(v, path);
  let mask = 15;
  const tokens = c.optional('hyperModifiers', arrayOf(str));
  if (tokens !== undefined) mask = tokens.reduce((m, t) => m | (modifierMask(t) ?? 0), 0);
  const hyperModifiers = [['fn', 16], ['ctrl', 1], ['alt', 2], ['shift', 4], ['cmd', 8]]
    .filter(([, bit]) => mask & bit)
    .map(([n]) => n);
  return {
    capsLock: c.optional('capsLock', enumOf(['off', 'hyper'], 'CapsLockMode')) ?? 'off',
    capsLockAlone: c.optional('capsLockAlone', enumOf(['nothing', 'escape'], 'CapsLockAlone')) ?? 'nothing',
    hyperModifiers,
  };
}

function binding(v, path) {
  const c = new Keyed(v, path);
  const id = c.optional('id', uuid) ?? randomUUID();
  const name = c.optional('name', str);
  const keys = c.required('keys', keyCombo);
  const modal = c.optional('modal', (m, p) => {
    const k = new Keyed(m, p);
    return {keys: k.required('keys', keyCombo), toggle: k.required('toggle', bool)};
  });
  const action = c.required('action', decodeAction);
  const repeats = c.optional('repeats', bool);
  const enabled = c.optional('enabled', bool) ?? true;
  const out = {action, enabled, id, keys};
  if (modal !== undefined) out.modal = modal;
  if (name !== undefined) out.name = name;
  if (repeats !== undefined) out.repeats = repeats;
  return out;
}

function layoutOptions(v, path) {
  const c = new Keyed(v, path);
  const out = defaultOptions();
  for (const key of Object.keys(out)) out[key] = c.optional(key, bool) ?? false;
  const titleOrder = c.optional('titleOrder', arrayOf(str));
  const titleOrderRegex = c.optional('titleOrderRegex', arrayOf(str));
  if (titleOrder !== undefined) out.titleOrder = titleOrder;
  if (titleOrderRegex !== undefined) out.titleOrderRegex = titleOrderRegex;
  return out;
}

function layoutApp(v, path) {
  const c = new Keyed(v, path);
  return {
    app: c.required('app', str),
    operations: c.optional('operations', arrayOf(decodeAction)) ?? [],
    options: c.optional('options', layoutOptions) ?? defaultOptions(),
  };
}

function layout(v, path) {
  const c = new Keyed(v, path);
  return {
    name: c.required('name', str),
    apps: c.optional('apps', arrayOf(layoutApp)) ?? [],
    before: c.optional('before', arrayOf(decodeAction)) ?? [],
    after: c.optional('after', arrayOf(decodeAction)) ?? [],
  };
}

/** ScreenDefault.Condition as Swift synthesizes it: {"count": {"_0": 2}} or {"resolutions": {"_0": [...]}}. */
function condition(v, path) {
  const c = new Keyed(v, path);
  const keys = ['count', 'resolutions'].filter((k) => c.raw(k) !== undefined);
  if (keys.length !== 1) throw decodingError(path, 'Invalid number of keys found, expected one.');
  const inner = new Keyed(c.raw(keys[0]), c.at(keys[0]));
  if (keys[0] === 'count') return {count: {_0: inner.required('_0', int)}};
  return {resolutions: {_0: inner.required('_0', arrayOf(str))}};
}

function screenDefault(v, path) {
  const c = new Keyed(v, path);
  return {target: c.required('target', str), condition: c.required('condition', condition)};
}

function hotstring(v, path) {
  const c = new Keyed(v, path);
  const out = {
    id: c.optional('id', uuid) ?? randomUUID(),
    trigger: c.required('trigger', str),
    replacement: c.optional('replacement', str) ?? '',
  };
  const action = c.optional('action', decodeAction);
  Object.assign(out, {
    enabled: c.optional('enabled', bool) ?? true,
    caseSensitive: c.optional('caseSensitive', bool) ?? true,
    fire: c.optional('fire', enumOf(['immediately', 'afterDelimiter'], 'Fire')) ?? 'immediately',
    wordBoundary: c.optional('wordBoundary', bool) ?? false,
    method: c.optional('method', enumOf(INSERT_METHODS, 'InsertMethod')) ?? 'auto',
    onlyInApps: c.optional('onlyInApps', arrayOf(str)) ?? [],
    exceptInApps: c.optional('exceptInApps', arrayOf(str)) ?? [],
  });
  const notes = c.optional('notes', str);
  if (action !== undefined) out.action = action;
  if (notes !== undefined) out.notes = notes;
  return out;
}

function configuration(v, path) {
  const c = new Keyed(v, path);
  return {
    version: c.optional('version', int) ?? CURRENT_VERSION,
    general: c.optional('general', general) ?? defaultGeneral(),
    settings: c.optional('settings', settings) ?? {},
    keyboard: c.optional('keyboard', keyboard) ?? defaultKeyboard(),
    bindings: c.optional('bindings', arrayOf(binding)) ?? [],
    layouts: c.optional('layouts', arrayOf(layout)) ?? [],
    defaults: c.optional('defaults', arrayOf(screenDefault)) ?? [],
    hotstrings: c.optional('hotstrings', arrayOf(hotstring)) ?? [],
  };
}

/**
 * Reads config.json text (JSON5 comments, trailing commas, unquoted keys… allowed) into the
 * canonical configuration with every default filled in. Entries without an `id` get a random one,
 * as in Swift. Also accepts an already-parsed object. Throws SlatedError("invalidConfiguration").
 */
export function decodeConfiguration(text) {
  return configuration(typeof text === 'string' ? parseJSON5(text) : text, []);
}

/**
 * The configuration as Swift writes config.json: pretty-printed with sorted keys, byte for byte.
 * The input is canonicalized first (so it may be partial); throws SlatedError("invalidConfiguration")
 * for values Swift couldn't hold or JSON can't represent (NaN, infinity).
 */
export function encodeConfiguration(config) {
  return formatJSON(decodeConfiguration(config));
}

// --- Hotstrings (matcher input) --------------------------------------------------------------------

/** A hotstring with Swift's defaults filled in, without validation (for the matcher). */
export function hotstringDefaults(h) {
  return {
    trigger: String(h.trigger ?? ''),
    replacement: h.replacement ?? '',
    enabled: h.enabled ?? true,
    caseSensitive: h.caseSensitive ?? true,
    fire: h.fire ?? 'immediately',
    wordBoundary: h.wordBoundary ?? false,
    onlyInApps: h.onlyInApps ?? [],
    exceptInApps: h.exceptInApps ?? [],
  };
}

// --- The starter configuration ---------------------------------------------------------------------

const X = 'screenOriginX';
const Y = 'screenOriginY';
const W = 'screenSizeX';
const H = 'screenSizeY';
const move = (x, y, width, height) => ({op: 'move', x, y, width, height});
const quarter = (corner) => ({op: 'corner', direction: corner, width: `${W}/2`, height: `${H}/2`});

/** Thirds sit side by side on a wide screen and stack on a vertical one. */
function third(index, span = 1) {
  const offset = index === 0 ? '' : index === 1 ? '/3' : '*2/3';
  const size = span === 1 ? '/3' : '*2/3';
  // Slate configs commonly write the 1/3 offset of a two-thirds span as "*1/3".
  const twoThirdsOffset = span === 2 && index === 1 ? '*1/3' : offset;
  return {
    op: 'by-orientation',
    landscape: move(index === 0 ? X : `${X}+${W}${twoThirdsOffset}`, Y, `${W}${size}`, H),
    portrait: move(X, index === 0 ? Y : `${Y}+${H}${twoThirdsOffset}`, W, `${H}${size}`),
  };
}

const throwTo = (screen) => ({op: 'throw', screen, width: W, height: H});

const STARTER = [
  ['Center', "'", move(`${X}+${W}/4`, `${Y}+${H}/4`, `${W}/2`, `${H}/2`)],
  ['Left half', 'a', move(X, Y, `${W}/2`, H)],
  ['Right half', 'd', move(`${X}+${W}/2`, Y, `${W}/2`, H)],
  ['Top half', 'w', {op: 'push', direction: 'up', style: `bar-resize:${H}/2`}],
  ['Bottom half', 'x', {op: 'push', direction: 'down', style: `bar-resize:${H}/2`}],
  ['Top-left quarter', 'q', quarter('top-left')],
  ['Top-right quarter', 'e', quarter('top-right')],
  ['Bottom-left quarter', 'z', quarter('bottom-left')],
  ['Bottom-right quarter', 'c', quarter('bottom-right')],
  ['First third', 'f', third(0)],
  ['Middle third', 'g', third(1)],
  ['Last third', 'h', third(2)],
  ['First two-thirds', 'v', third(0, 2)],
  ['Last two-thirds', 'b', third(1, 2)],
  ['Large center', 'return', move(`${X}+${W}/8`, `${Y}+${H}/8`, `${W}/1.3`, `${H}/1.3`)],
  ['Maximize', 's', move(X, Y, W, H)],
  ['Grid', 'tab', {op: 'grid', padding: 4, grids: {0: {width: 6, height: 6}, 1: {width: 6, height: 6}, 2: {width: 6, height: 6}}}],
  ['Throw to the screen on the right', 'right', throwTo('right')],
  ['Throw to the screen on the left', 'left', throwTo('left')],
  ['Throw to the screen above', 'up', throwTo('up')],
  ['Throw to the second screen', 'down', throwTo('1')],
];

/**
 * The configuration a new install starts with when there's no Slate config: the author's Slate setup
 * with every window binding on the Hyper key (21 bindings, random ids).
 */
export function starterConfiguration() {
  return {
    version: CURRENT_VERSION,
    general: defaultGeneral(),
    settings: {},
    keyboard: {...defaultKeyboard(), capsLock: 'hyper'},
    bindings: STARTER.map(([name, key, action]) => ({
      action: JSON.parse(JSON.stringify(action)),
      enabled: true,
      id: randomUUID(),
      keys: `hyper+${key}`,
      name,
    })),
    layouts: [],
    defaults: [],
    hotstrings: [],
  };
}

/** Sorted grid screen keys, the order Swift's decoder gives them. */
export function sortedGridKeys(grids) {
  return Object.keys(grids ?? {}).sort(compareStrings);
}
