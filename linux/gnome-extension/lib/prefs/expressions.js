// Checks Slate expressions as the user types, e.g. "screenOriginX+screenSizeX/2" (port of
// Sources/SlatedUI/Model/ExpressionCheck.swift).
//
// Uses the engine's evaluateExpression when it is implemented, which also reports the value on a
// sample screen. Until then a lightweight local lint catches typos: unknown names, unbalanced
// parentheses, stray characters.
//
// Pure ES module.

import {editDistance} from './util.js';
import {evaluateExpression, isNotImplemented, describeError} from './engine.js';

export const VARIABLES = [
  'screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY', 'windowTopLeftX', 'windowTopLeftY',
  'windowSizeX', 'windowSizeY', 'newWindowSizeX', 'newWindowSizeY', 'windowHintsWidth', 'windowHintsHeight',
];

export const FUNCTIONS = [
  'sum', 'count', 'min', 'max', 'average', 'median', 'stddev', 'sqrt', 'log', 'ln', 'exp', 'floor',
  'ceiling', 'abs', 'trunc', 'random', 'randomn',
];

/** Sample values for every variable, for a window on `screen` (a visible frame rect). */
export function sampleVariables(screen, window) {
  return {
    screenOriginX: screen.x, screenOriginY: screen.y, screenSizeX: screen.width, screenSizeY: screen.height,
    windowTopLeftX: window.x, windowTopLeftY: window.y, windowSizeX: window.width, windowSizeY: window.height,
    newWindowSizeX: window.width, newWindowSizeY: window.height, windowHintsWidth: 100, windowHintsHeight: 100,
  };
}

/** A typical 1920 × 1080 GNOME screen (32 px top bar) with a centered window. */
export const DEFAULT_VARIABLES = sampleVariables(
  {x: 0, y: 32, width: 1920, height: 1048}, {x: 480, y: 270, width: 960, height: 629});

/** Slate's relative amounts for resize and nudge: "+10%", "-100". */
export function isRelativeAmount(text) {
  return /^[+-]\s*\d+(\.\d+)?%?$/.test(text);
}

/**
 * Checks an expression. Returns {status: "empty"} | {status: "valid", value: number|null} |
 * {status: "invalid", message}.
 *
 * @param {object} [options]
 * @param {boolean} [options.relative] also accept "+10%" / "-100" (resize and nudge)
 * @param {Object<string, number>} [options.variables] sample values for evaluation
 */
export function checkExpression(raw, {relative = false, variables = DEFAULT_VARIABLES} = {}) {
  const text = String(raw ?? '').trim();
  if (!text) return {status: 'empty'};
  if (relative && isRelativeAmount(text)) return {status: 'valid', value: null};
  try {
    const value = evaluateExpression(text, variables && Object.keys(variables).length ? variables : DEFAULT_VARIABLES);
    return {status: 'valid', value: typeof value === 'number' && Number.isFinite(value) ? value : null};
  } catch (error) {
    if (isNotImplemented(error)) return lint(text);
    return {status: 'invalid', message: describeError(error)};
  }
}

/** The local lint used while the engine can't evaluate expressions. */
export function lint(text) {
  let depth = 0;
  let braces = 0;
  let last = null;
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (/[A-Za-z]/.test(c)) {
      const start = i;
      while (i < text.length && /[A-Za-z0-9]/.test(text[i])) i++;
      const name = text.slice(start, i);
      if (FUNCTIONS.includes(name)) {
        const next = text.slice(i).trimStart()[0];
        if (next !== '(') return {status: 'invalid', message: `“${name}” is a function — write ${name}(…)`};
      } else if (!VARIABLES.includes(name)) {
        return {status: 'invalid', message: suggestion(name)};
      }
      last = 'a';
      continue;
    }
    if (/[0-9.]/.test(c)) {
      last = '0';
    } else if ('+-*/'.includes(c)) {
      last = c;
    } else if (c === '(') {
      depth++;
      last = c;
    } else if (c === ')') {
      depth--;
      if (depth < 0) return {status: 'invalid', message: 'There\'s a “)” without a matching “(”'};
      last = c;
    } else if (c === '{') {
      braces++;
      last = c;
    } else if (c === '}') {
      braces--;
      if (braces < 0) return {status: 'invalid', message: 'There\'s a “}” without a matching “{”'};
      last = c;
    } else if (c === ',') {
      last = c;
    } else if (c !== ' ' && c !== '\t') {
      return {status: 'invalid', message: `“${c}” can't be used in an expression`};
    }
    i++;
  }
  if (depth > 0) return {status: 'invalid', message: 'Missing “)”'};
  if (braces > 0) return {status: 'invalid', message: 'Missing “}”'};
  if (last && '+-*/('.includes(last)) return {status: 'invalid', message: 'The expression ends too early'};
  return {status: 'valid', value: null};
}

function suggestion(name) {
  const lower = name.toLowerCase();
  let best = null;
  let bestDistance = Infinity;
  for (const candidate of [...VARIABLES, ...FUNCTIONS]) {
    const d = editDistance(candidate.toLowerCase(), lower);
    if (d < bestDistance) {
      best = candidate;
      bestDistance = d;
    }
  }
  if (best && bestDistance <= Math.max(2, Math.floor(name.length / 3))) {
    return `Unknown name “${name}”. Did you mean ${best}?`;
  }
  return `Unknown name “${name}”`;
}
