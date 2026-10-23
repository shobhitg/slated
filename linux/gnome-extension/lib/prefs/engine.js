// The preferences' only door into the engine (lib/core/index.js).
//
// The engine is the JavaScript port of SlatedCore, held to the Swift behavior by golden vectors, so
// config.json reads and writes exactly as on the Mac (ids must be UUIDs; new ones come from its
// randomUUID, see ids.js). Should a function throw SlatedError("notImplemented"), the preferences
// keep working: configuration reading and writing, key combos and action normalization fall back to
// local implementations that follow the same rules (and keep sections they don't model); everything
// else (expression values, Slate syntax, window math) reports that it is unavailable, and the UI
// says "Preview unavailable" instead of failing.
//
// Pure ES module.

import * as core from '../core/index.js';
import {fillDefaults, parseLenientJSON, encodeLocal} from './config.js';
import {canonicalActionLocal} from './canonical.js';

export const SlatedError = core.SlatedError;

/** True for the engine's "not implemented yet" error. */
export function isNotImplemented(error) {
  return error?.kind === 'notImplemented';
}

/**
 * A readable message for any engine error. Configuration errors say where the problem is, e.g.
 * "bindings[2].id: Attempted to decode UUID from invalid UUID string."
 */
export function describeError(error) {
  if (!error) return 'Unknown error';
  if (typeof error === 'string') return error;
  const message = error.message || String(error);
  const path = Array.isArray(error.codingPath) ? formatCodingPath(error.codingPath) : '';
  return path ? `${path}: ${message}` : message;
}

/** ["bindings", 2, "id"] → "bindings[2].id". */
export function formatCodingPath(path) {
  return path.map((key, i) => (typeof key === 'number' ? `[${key}]` : i ? `.${key}` : String(key))).join('');
}

function withFallback(call, fallback) {
  try {
    return call();
  } catch (error) {
    if (isNotImplemented(error)) return fallback(error);
    throw error;
  }
}

/** True once the engine implements `name` (probed with a harmless call). */
export function implemented(name) {
  const probes = {
    evaluateExpression: () => core.evaluateExpression('1', {}),
    parseOperation: () => core.parseOperation('undo'),
    targetFrame: () => core.targetFrame({op: 'undo'}, {frame: {x: 0, y: 0, width: 1, height: 1}, screens: []}),
    decodeConfiguration: () => core.decodeConfiguration('{}'),
    parseSlateConfig: () => core.parseSlateConfig('', {}),
  };
  try {
    probes[name]?.();
    return true;
  } catch (error) {
    return !isNotImplemented(error);
  }
}

// --- Configuration ----------------------------------------------------------------------------------

/** config.json text → configuration with every default filled in. Throws a readable Error. */
export function decodeConfiguration(text) {
  // The engine also takes parsed objects; the preferences always pass the file's text.
  if (typeof text !== 'string') throw new TypeError(`Expected config.json text, got ${text === null ? 'null' : typeof text}`);
  return withFallback(() => core.decodeConfiguration(text), () => fillDefaults(parseLenientJSON(text)));
}

/** Configuration → the text Slated writes to config.json. */
export function encodeConfiguration(config) {
  return withFallback(() => core.encodeConfiguration(config), () => encodeLocal(config));
}

/** The author's 21-binding starter setup, or null while the engine can't provide it. */
export function starterConfiguration() {
  return withFallback(() => core.starterConfiguration(), () => null);
}

/**
 * The canonical JSON form of one action (directions normalized, defaults dropped, strings parsed
 * when the engine can parse Slate syntax). Throws for an invalid action.
 */
export function canonicalAction(action) {
  return withFallback(() => {
    if (action === undefined || action === null) throw new Error('Choose an operation.');
    // decodeAction keeps error paths relative to the action ("operations[1].x"). The JSON round trip
    // hands it plain data, as config.json would.
    if (typeof core.decodeAction === 'function') return core.decodeAction(JSON.parse(JSON.stringify(action)));
    const config = core.decodeConfiguration(JSON.stringify({bindings: [{keys: 'f1', action}]}));
    const decoded = config?.bindings?.[0]?.action;
    if (decoded === undefined) throw new Error('The engine returned no action');
    return decoded;
  }, () => canonicalActionLocal(action));
}

// --- Slate syntax -------------------------------------------------------------------------------------

/** "push left bar-resize:screenSizeX/2" → Action. Throws SlatedError (also notImplemented). */
export function parseOperation(text) {
  return core.parseOperation(text);
}

/** Action → Slate syntax, or null while the engine can't format. */
export function formatOperation(action) {
  return withFallback(() => core.formatOperation(action), () => null);
}

/** "a:ctrl,shift,alt,cmd" → {keys: KeyCombo, modal}. Throws SlatedError (also notImplemented). */
export function parseKeystroke(text) {
  return core.parseKeystroke(text);
}

/** Classic .slate text → {settings, bindings, layouts, defaults, diagnostics}. Throws notImplemented. */
export function parseSlateConfig(text, options) {
  return core.parseSlateConfig(text, options);
}

// --- Expressions and window math ----------------------------------------------------------------------

/** Evaluates a Slate expression. Throws SlatedError (also notImplemented). */
export function evaluateExpression(expression, variables) {
  return core.evaluateExpression(expression, variables);
}

/** Where `action` puts a window. Throws SlatedError (also notImplemented). */
export function targetFrame(action, context) {
  return core.targetFrame(action, context);
}
