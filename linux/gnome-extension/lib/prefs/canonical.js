// The canonical JSON form of an action, as Swift's Action Codable writes it after reading it back
// (Sources/SlatedCore/Model/Action.swift): directions spelled "up"/"down", defaults left out
// (push style "none", resize anchor "top-left", false flags, insert method "auto"), screen
// references and expressions as strings, sequences as "operations" unless a step keeps its window.
//
// This is the local fallback for the engine's decodeConfiguration (lib/core) while that is a stub,
// and the reference the tests hold the preferences to. Slate operation syntax strings ("push left")
// can't be parsed here; they are returned unchanged for the engine to handle.
//
// Pure ES module.

import {isObject} from './util.js';
import {parseKeyComboLocal, formatKeyComboLocal} from './keys.js';

export class ActionError extends Error {
  constructor(message) {
    super(message);
    this.kind = 'invalidSyntax';
  }
}

const fail = message => {
  throw new ActionError(message);
};

/** Slate direction → "left" | "right" | "up" | "down", or null. */
export function direction(raw) {
  switch (String(raw ?? '').toLowerCase()) {
  case 'left': return 'left';
  case 'right': return 'right';
  case 'up': case 'top': case 'above': return 'up';
  case 'down': case 'bottom': case 'below': return 'down';
  default: return null;
  }
}

export const CORNERS = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];

/** A screen reference as Swift's ScreenRef writes it: "0", "ordered:1", "1680x1050", "left", "next"… */
export function screenRef(raw) {
  if (typeof raw === 'number' && Number.isInteger(raw)) return String(raw);
  const s = String(raw ?? '').trim();
  if (/^[+-]?\d+$/.test(s)) return String(parseInt(s, 10));
  const ordered = /^ordered:([+-]?\d+)$/i.exec(s);
  if (ordered) return `ordered:${parseInt(ordered[1], 10)}`;
  const lower = s.toLowerCase();
  if (lower === 'next') return 'next';
  if (lower === 'previous' || lower === 'prev') return 'previous';
  const d = direction(s);
  if (d) return d;
  const res = /^(\d+)x(\d+)$/i.exec(s);
  if (res) return `${parseInt(res[1], 10)}x${parseInt(res[2], 10)}`;
  return null;
}

/** Push style as written: "none" | "center" | "bar" | "bar-resize:<expr>", or null if invalid. */
export function pushStyle(raw) {
  const s = String(raw ?? '').trim();
  switch (s.toLowerCase()) {
  case '': case 'none': return 'none';
  case 'center': return 'center';
  case 'bar': return 'bar';
  default:
    return s.toLowerCase().startsWith('bar-resize:') ? `bar-resize:${s.slice('bar-resize:'.length)}` : null;
  }
}

/** An expression parameter: strings as they are, numbers as Swift prints them; else undefined. */
function expr(value) {
  if (typeof value === 'string') return value;
  // Whole numbers print without a fraction in both languages ("4", not "4.0").
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return undefined;
}

function required(action, key) {
  const value = expr(action[key]);
  if (value === undefined) fail(`"${action.op}" needs "${key}"`);
  return value;
}

function flag(action, key) {
  const value = action[key];
  if (value === undefined || value === null) return false;
  if (typeof value !== 'boolean') fail(`"${key}" should be true or false`);
  return value;
}

function optionalScreen(action, out) {
  if (action.screen === undefined || action.screen === null) return;
  const ref = screenRef(action.screen);
  if (ref === null) fail(`Invalid screen reference "${action.screen}"`);
  out.screen = ref;
}

function appSelector(raw) {
  if (Array.isArray(raw)) return raw.map(String);
  if (typeof raw !== 'string') fail('"app" should be a string or a list of app names');
  const lower = raw.toLowerCase();
  if (lower === 'current') return 'current';
  if (lower === 'all') return 'all';
  if (lower.startsWith('all-but:')) return `all-but:${raw.slice('all-but:'.length)}`;
  return [raw];
}

/**
 * Canonical form of an action object (recursively). Strings (Slate syntax) are returned as they
 * are. Throws ActionError for an invalid action, with the same wording as Swift's decoder where it
 * matters.
 */
export function canonicalActionLocal(action) {
  if (typeof action === 'string') return action;
  if (!isObject(action)) fail('An action must be an object with "op", or Slate operation syntax');
  const op = action.op;
  if (typeof op !== 'string') fail('The action has no "op"');
  const out = {op};
  switch (op) {
  case 'move':
    out.x = required(action, 'x');
    out.y = required(action, 'y');
    out.width = required(action, 'width');
    out.height = required(action, 'height');
    optionalScreen(action, out);
    break;
  case 'resize': {
    out.width = expr(action.width) ?? '+0';
    out.height = expr(action.height) ?? '+0';
    const anchor = action.anchor ?? 'top-left';
    if (!CORNERS.includes(anchor)) fail(`Invalid corner "${anchor}"`);
    if (anchor !== 'top-left') out.anchor = anchor;
    break;
  }
  case 'push': {
    const raw = required(action, 'direction');
    const d = direction(raw);
    if (!d) fail(`Invalid direction "${raw}"`);
    out.direction = d;
    if (action.style !== undefined && action.style !== null) {
      const style = pushStyle(action.style);
      if (style === null) fail(`Invalid push style "${action.style}"`);
      if (style !== 'none') out.style = style;
    }
    optionalScreen(action, out);
    break;
  }
  case 'nudge':
    out.x = expr(action.x) ?? '+0';
    out.y = expr(action.y) ?? '+0';
    break;
  case 'throw': {
    if (action.screen === undefined || action.screen === null) fail('"throw" needs "screen"');
    optionalScreen(action, out);
    const w = expr(action.width);
    const h = expr(action.height);
    if (w !== undefined) out.width = w;
    if (h !== undefined) out.height = h;
    break;
  }
  case 'corner': {
    const raw = required(action, 'direction');
    if (!CORNERS.includes(raw.toLowerCase())) fail(`Invalid corner "${raw}"`);
    out.direction = raw.toLowerCase();
    const w = expr(action.width);
    const h = expr(action.height);
    if (w !== undefined) out.width = w;
    if (h !== undefined) out.height = h;
    optionalScreen(action, out);
    break;
  }
  case 'chain':
    if (!Array.isArray(action.operations)) fail('"chain" needs "operations"');
    out.operations = action.operations.map(canonicalActionLocal);
    break;
  case 'sequence': {
    let steps;
    if (Array.isArray(action.steps)) {
      steps = action.steps.map(step => {
        if (!isObject(step)) fail('Each sequence step needs an "action"');
        return {action: canonicalActionLocal(step.action), keepWindow: step.keepWindow === true};
      });
    } else if (Array.isArray(action.operations)) {
      steps = action.operations.map(a => ({action: canonicalActionLocal(a), keepWindow: false}));
    } else {
      fail('"sequence" needs "operations"');
    }
    if (steps.every(step => !step.keepWindow)) out.operations = steps.map(step => step.action);
    else out.steps = steps;
    break;
  }
  case 'layout':
    out.name = required(action, 'name');
    break;
  case 'focus':
    if (typeof action.app === 'string') {
      out.app = action.app;
    } else {
      const raw = required(action, 'direction');
      const d = String(raw).toLowerCase() === 'behind' ? 'behind' : direction(raw);
      if (!d) fail(`Invalid focus direction "${raw}"`);
      out.direction = d;
    }
    break;
  case 'snapshot':
    out.name = required(action, 'name');
    if (flag(action, 'save')) out.save = true;
    if (flag(action, 'stack')) out.stack = true;
    break;
  case 'delete-snapshot':
    out.name = required(action, 'name');
    if (flag(action, 'all')) out.all = true;
    break;
  case 'activate-snapshot':
    out.name = required(action, 'name');
    if (flag(action, 'delete')) out.delete = true;
    break;
  case 'hint':
    if (typeof action.characters === 'string') out.characters = action.characters;
    break;
  case 'grid': {
    if (action.padding !== undefined && action.padding !== null) {
      if (!Number.isInteger(action.padding)) fail('"padding" should be a whole number');
      out.padding = action.padding;
    }
    if (isObject(action.grids)) {
      const grids = {};
      for (const key of Object.keys(action.grids).sort()) {
        const size = action.grids[key];
        if (!isObject(size) || !Number.isInteger(size.width) || !Number.isInteger(size.height)) {
          fail(`Grid "${key}" needs a whole-number width and height`);
        }
        grids[key] = {width: size.width, height: size.height};
      }
      if (Object.keys(grids).length) out.grids = grids;
    }
    break;
  }
  case 'hide': case 'show': case 'toggle':
    if (action.app === undefined || action.app === null) fail(`"${op}" needs "app"`);
    out.app = appSelector(action.app);
    break;
  case 'shell':
    out.command = required(action, 'command');
    if (flag(action, 'wait')) out.wait = true;
    if (typeof action.path === 'string') out.path = action.path;
    break;
  case 'undo': case 'relaunch': case 'switch':
    break;
  case 'by-orientation':
    if (action.landscape === undefined || action.portrait === undefined) {
      fail('"by-orientation" needs "landscape" and "portrait"');
    }
    out.landscape = canonicalActionLocal(action.landscape);
    out.portrait = canonicalActionLocal(action.portrait);
    break;
  case 'insert-text': {
    out.text = required(action, 'text');
    const method = action.method ?? 'auto';
    if (!['auto', 'type', 'paste'].includes(method)) fail(`Invalid insert method "${method}"`);
    if (method !== 'auto') out.method = method;
    break;
  }
  case 'open-url':
    out.url = required(action, 'url');
    break;
  case 'keystroke': {
    const combo = typeof action.keys === 'string' ? parseKeyComboLocal(action.keys)
      : isObject(action.keys) ? action.keys : null;
    if (!combo || !combo.key) fail(`Invalid key combo "${action.keys}"`);
    out.keys = formatKeyComboLocal(combo);
    break;
  }
  default:
    fail(`Unknown operation "${op}"`);
  }
  return out;
}

/**
 * Slate accepted strings and numbers where a flag or count was expected (`"wait": "true"`,
 * `"padding": "4"`), so the importer coerces them like Swift's ScriptOperations.coerce.
 */
export function coerceParameter(key, value) {
  const truthy = v => !['', '0', 'false', 'no', 'off'].includes(String(v).trim().toLowerCase());
  switch (key) {
  case 'wait': case 'save': case 'stack': case 'all': case 'delete':
    if (typeof value === 'string') return truthy(value);
    if (typeof value === 'number') return value !== 0;
    return value;
  case 'padding':
    if (typeof value === 'string' && /^\s*-?\d+\s*$/.test(value)) return parseInt(value, 10);
    return value;
  case 'grids':
    if (!isObject(value)) return value;
    return Object.fromEntries(Object.entries(value).map(([screen, size]) => {
      if (!isObject(size)) return [screen, size];
      const fixed = {...size};
      for (const dim of ['width', 'height']) {
        if (typeof fixed[dim] === 'string' && /^\d+$/.test(fixed[dim])) fixed[dim] = parseInt(fixed[dim], 10);
      }
      return [screen, fixed];
    }));
  default:
    return value;
  }
}
