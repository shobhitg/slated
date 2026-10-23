// A small stand-in for lib/core/index.js, implementing just enough of its contract for the runtime's
// unit tests while the real engine is being written. Tests that want the real core use `realCore()`,
// which returns null while the core is still the stub that throws "Not implemented yet".
//
// Shapes follow the core's documented contract: actions are config.json JSON objects, KeyCombo is
// {key, modifiers}, rects are {x, y, width, height} in top-left global coordinates.

import * as RealCore from '../../gnome-extension/lib/core/index.js';

export class SlatedError extends Error {
  constructor(kind, message) {
    super(message);
    this.kind = kind;
  }
}

const HYPER = ['ctrl', 'alt', 'shift', 'cmd'];
const MOD_TOKENS = {ctrl: ['ctrl'], control: ['ctrl'], alt: ['alt'], opt: ['alt'], option: ['alt'], shift: ['shift'], cmd: ['cmd'], command: ['cmd'], fn: ['fn'], hyper: HYPER, meh: ['ctrl', 'alt', 'shift']};
const NAMED_KEYS = new Set(['left', 'right', 'up', 'down', 'return', 'tab', 'space', 'delete', 'esc', 'home', 'end', 'pageup', 'pagedown', 'padenter']);

function canonicalKey(key) {
  const lower = key.toLowerCase();
  if (lower === 'escape') return 'esc';
  if (lower === 'enter') return 'return';
  if (lower === 'pageup') return 'pageUp';
  if (lower === 'pagedown') return 'pageDown';
  if (/^f\d+$/.test(lower)) return lower;
  return key.length === 1 ? lower : lower;
}

function isValidKey(key) {
  return key.length === 1 || NAMED_KEYS.has(key.toLowerCase()) || /^f\d+$/i.test(key) || /^pad/.test(key) || key.toLowerCase() === 'escape';
}

function sortMods(mods) {
  return ['ctrl', 'alt', 'shift', 'cmd', 'fn'].filter((m) => mods.includes(m));
}

export function parseKeyCombo(text) {
  if (typeof text !== 'string' || !text.trim()) return null;
  let parts = text.trim().split('+');
  let key;
  if (text.endsWith('+')) {
    parts = parts.slice(0, -2);
    key = '+';
  } else {
    key = parts.pop();
  }
  const mods = [];
  for (const part of parts) {
    if (!part) continue;
    const m = MOD_TOKENS[part.toLowerCase()];
    if (!m) return null;
    for (const x of m) if (!mods.includes(x)) mods.push(x);
  }
  if (!key) return null;
  return {key: canonicalKey(key), modifiers: sortMods(mods)};
}

export function formatKeyCombo(combo) {
  const mods = combo.modifiers ?? [];
  const tokens = HYPER.every((m) => mods.includes(m)) ? ['hyper'] : sortMods(mods);
  return [...tokens, combo.key].join('+');
}

export function parseKeystroke(text) {
  let rest = text.trim();
  let toggle = false;
  if (rest.toLowerCase().endsWith(':toggle')) {
    toggle = true;
    rest = rest.slice(0, -':toggle'.length);
  }
  const colon = rest.indexOf(':', 1);
  const key = colon > 0 ? rest.slice(0, colon) : rest;
  const list = colon > 0 ? rest.slice(colon + 1) : '';
  if (!isValidKey(key)) throw new SlatedError('invalidSyntax', `Unknown key "${key}" in "${text}"`);
  const mods = [];
  let modal = null;
  for (const token of list.split(/[,;]/).map((t) => t.trim()).filter(Boolean)) {
    const m = MOD_TOKENS[token.toLowerCase()];
    if (m) mods.push(...m.filter((x) => !mods.includes(x)));
    else if (isValidKey(token) && !modal) modal = token;
    else throw new SlatedError('invalidSyntax', `Unknown modifier "${token}" in "${text}"`);
  }
  if (modal) return {keys: {key: canonicalKey(key), modifiers: []}, modal: {keys: {key: canonicalKey(modal), modifiers: sortMods(mods)}, toggle}};
  return {keys: {key: canonicalKey(key), modifiers: sortMods(mods)}, modal: null};
}

// --- Expressions ---------------------------------------------------------------------------------

export function evaluateExpression(expression, variables) {
  const tokens = String(expression).match(/\s*(\*\*|\d+\.?\d*|[A-Za-z_]\w*|[-+*/()])\s*/g)?.map((t) => t.trim()) ?? [];
  if (tokens.join('') !== String(expression).replace(/\s+/g, '')) throw new SlatedError('invalidExpression', `Invalid expression "${expression}"`);
  let i = 0;
  const peek = () => tokens[i];
  const next = () => tokens[i++];
  const primary = () => {
    const t = next();
    if (t === undefined) throw new SlatedError('invalidExpression', `Unexpected end of "${expression}"`);
    if (t === '(') {
      const v = sum();
      if (next() !== ')') throw new SlatedError('invalidExpression', `Missing ) in "${expression}"`);
      return v;
    }
    if (t === '-') return -unary();
    if (t === '+') return unary();
    if (/^\d/.test(t)) return Number(t);
    if (t in variables) return variables[t];
    throw new SlatedError('invalidExpression', `Unknown variable "${t}"`);
  };
  const unary = () => primary();
  const power = () => {
    const base = unary();
    if (peek() === '**') {
      next();
      return base ** power();
    }
    return base;
  };
  const product = () => {
    let v = power();
    while (peek() === '*' || peek() === '/') v = next() === '*' ? v * power() : v / power();
    return v;
  };
  const sum = () => {
    let v = product();
    while (peek() === '+' || peek() === '-') v = next() === '+' ? v + product() : v - product();
    return v;
  };
  const value = sum();
  if (i !== tokens.length) throw new SlatedError('invalidExpression', `Unexpected "${peek()}" in "${expression}"`);
  return value;
}

// --- Operations ----------------------------------------------------------------------------------

const DIRECTIONS = {left: 'left', right: 'right', up: 'up', top: 'up', above: 'up', down: 'down', bottom: 'down', below: 'down'};

function canonicalAction(action) {
  if (typeof action === 'string') return parseOperation(action);
  if (!action || typeof action !== 'object' || typeof action.op !== 'string') throw new SlatedError('invalidSyntax', 'missing "op"');
  const a = {...action};
  const expr = (v) => (typeof v === 'number' ? String(v) : v);
  switch (a.op) {
    case 'move':
      for (const k of ['x', 'y', 'width', 'height']) {
        if (a[k] === undefined) throw new SlatedError('invalidSyntax', `"move" needs "${k}"`);
        a[k] = expr(a[k]);
      }
      if (typeof a.screen === 'number') a.screen = String(a.screen);
      return a;
    case 'push':
      if (!DIRECTIONS[String(a.direction).toLowerCase()]) throw new SlatedError('invalidSyntax', `Invalid direction "${a.direction}"`);
      a.direction = DIRECTIONS[String(a.direction).toLowerCase()];
      if (a.style === 'none') delete a.style;
      return a;
    case 'corner':
      if (!['top-left', 'top-right', 'bottom-left', 'bottom-right'].includes(a.direction)) throw new SlatedError('invalidSyntax', `Invalid corner "${a.direction}"`);
      return a;
    case 'throw':
      if (a.screen === undefined) throw new SlatedError('invalidSyntax', '"throw" needs "screen"');
      a.screen = String(a.screen);
      return a;
    case 'chain':
      return {op: 'chain', operations: a.operations.map(canonicalAction)};
    case 'sequence':
      return a.steps ? {op: 'sequence', steps: a.steps.map((s) => ({action: canonicalAction(s.action), keepWindow: !!s.keepWindow}))} : {op: 'sequence', operations: a.operations.map(canonicalAction)};
    case 'by-orientation':
      return {op: 'by-orientation', landscape: canonicalAction(a.landscape), portrait: canonicalAction(a.portrait)};
    case 'focus':
      if (a.app === undefined) a.direction = DIRECTIONS[String(a.direction).toLowerCase()] ?? String(a.direction).toLowerCase();
      return a;
    case 'resize':
    case 'nudge':
    case 'layout':
    case 'snapshot':
    case 'activate-snapshot':
    case 'delete-snapshot':
    case 'hint':
    case 'grid':
    case 'hide':
    case 'show':
    case 'toggle':
    case 'shell':
    case 'undo':
    case 'relaunch':
    case 'switch':
    case 'insert-text':
    case 'open-url':
    case 'keystroke':
      return a;
    default:
      throw new SlatedError('unknownOperation', `Unknown operation "${a.op}"`);
  }
}

export function parseOperation(text) {
  const words = String(text).trim().split(/\s+/);
  const op = words.shift();
  switch (op) {
    case 'push': {
      const action = {op: 'push', direction: DIRECTIONS[words[0]]};
      if (!action.direction) throw new SlatedError('invalidSyntax', `Invalid direction "${words[0]}"`);
      if (words[1] && words[1] !== 'none') action.style = words[1];
      return action;
    }
    case 'move': {
      const [x, y] = words[0].split(';');
      const [width, height] = words[1].split(';');
      const action = {op: 'move', x, y, width, height};
      if (words[2]) action.screen = words[2];
      return action;
    }
    case 'throw': {
      const action = {op: 'throw', screen: words[0]};
      if (words[1] === 'resize') Object.assign(action, {width: 'screenSizeX', height: 'screenSizeY'});
      return action;
    }
    case 'corner':
      return {op: 'corner', direction: words[0]};
    case 'grid': {
      const action = {op: 'grid', grids: {}};
      for (const w of words) {
        if (w.startsWith('padding:')) action.padding = Number(w.slice(8));
        else {
          const [screen, size] = w.split(':');
          const [width, height] = size.split(',').map(Number);
          action.grids[screen] = {width, height};
        }
      }
      return action;
    }
    case 'focus':
      return {op: 'focus', direction: DIRECTIONS[words[0]] ?? words[0]};
    case 'layout':
      return {op: 'layout', name: words.join(' ')};
    case 'hint':
      return words[0] ? {op: 'hint', characters: words[0]} : {op: 'hint'};
    case 'undo':
    case 'relaunch':
      return {op};
    default:
      throw new SlatedError('unknownOperation', `Unknown operation "${op}"`);
  }
}

export function formatOperation(action) {
  switch (action.op) {
    case 'move':
      return `move ${action.x};${action.y} ${action.width};${action.height}${action.screen ? ` ${action.screen}` : ''}`;
    case 'push':
      return `push ${action.direction}${action.style ? ` ${action.style}` : ''}`;
    case 'corner':
      return `corner ${action.direction}`;
    case 'throw':
      return `throw ${action.screen}`;
    case 'chain':
      return `chain ${action.operations.map(formatOperation).join(' | ')}`;
    case 'layout':
      return `layout ${action.name}`;
    default:
      return action.op;
  }
}

// --- Configuration -------------------------------------------------------------------------------

export function decodeConfiguration(text) {
  const raw = JSON.parse(String(text).replace(/^\s*\/\/.*$/gm, ''));
  const general = {launchAtLogin: false, loadSlateConfigs: true, slateConfigPaths: ['~/.slate.js', '~/.slate'], showActionHUD: false, hotstringsEnabled: true, ...(raw.general ?? {})};
  const keyboard = {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: [...HYPER], ...(raw.keyboard ?? {})};
  const bindings = (raw.bindings ?? []).map((b, i) => {
    let action;
    try {
      action = canonicalAction(b.action);
    } catch (e) {
      throw new SlatedError(e.kind ?? 'invalidSyntax', `${e.message} (at bindings[${i}].action)`);
    }
    const keys = parseKeyCombo(b.keys);
    if (!keys) throw new SlatedError('invalidSyntax', `Invalid key combo "${b.keys}" (at bindings[${i}].keys)`);
    return {id: b.id ?? `binding-${i}`, name: b.name, keys, modal: b.modal ? {keys: parseKeyCombo(b.modal.keys), toggle: !!b.modal.toggle} : undefined, action, repeats: b.repeats, enabled: b.enabled ?? true};
  });
  const hotstrings = (raw.hotstrings ?? []).map((h) => ({enabled: true, caseSensitive: true, fire: 'immediately', wordBoundary: false, method: 'auto', onlyInApps: [], exceptInApps: [], replacement: '', ...h}));
  return {version: 1, general, settings: raw.settings ?? {}, keyboard, bindings, layouts: raw.layouts ?? [], defaults: raw.defaults ?? [], hotstrings};
}

export function encodeConfiguration(config) {
  const sort = (v) => (Array.isArray(v) ? v.map(sort) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sort(v[k])])) : v);
  return JSON.stringify(sort(config), null, 2);
}

export function starterConfiguration() {
  return decodeConfiguration(JSON.stringify({keyboard: {capsLock: 'hyper'}, bindings: [{name: 'Left half', keys: 'hyper+a', action: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'}}]}));
}

export function toGnomeAccelerator(combo, {hyperMode} = {}) {
  const mods = combo.modifiers ?? [];
  const names = {ctrl: '<Control>', alt: '<Alt>', shift: '<Shift>', cmd: '<Super>'};
  const prefix = hyperMode === 'xkb' && HYPER.every((m) => mods.includes(m)) ? '<Hyper>' : sortMods(mods).filter((m) => m !== 'fn').map((m) => names[m]).join('');
  const keyNames = {left: 'Left', right: 'Right', up: 'Up', down: 'Down', return: 'Return', tab: 'Tab', space: 'space', esc: 'Escape', "'": 'apostrophe'};
  return prefix + (keyNames[combo.key] ?? combo.key);
}

// --- Screens and frames --------------------------------------------------------------------------

function screenOf(screens, rect) {
  let best = null;
  let area = 0;
  for (const s of screens) {
    const w = Math.min(s.frame.x + s.frame.width, rect.x + rect.width) - Math.max(s.frame.x, rect.x);
    const h = Math.min(s.frame.y + s.frame.height, rect.y + rect.height) - Math.max(s.frame.y, rect.y);
    if (w > 0 && h > 0 && w * h > area) {
      best = s;
      area = w * h;
    }
  }
  return best ?? screens.find((s) => s.isMain) ?? screens[0];
}

export function resolveScreen(ref, context) {
  const current = screenOf(context.screens, context.frame);
  if (ref === null || ref === undefined) return current;
  const text = String(ref).toLowerCase();
  const ordered = [...context.screens].sort((a, b) => a.frame.x - b.frame.x || b.frame.y - a.frame.y);
  if (/^-?\d+$/.test(text)) return ordered[Number(text)] ?? (text === '-1' ? current : null);
  const direction = DIRECTIONS[text];
  if (direction) {
    const c = current.frame;
    const candidates = context.screens.filter((s) => s !== current).filter((s) => {
      const f = s.frame;
      if (direction === 'right') return f.x >= c.x + c.width;
      if (direction === 'left') return f.x + f.width <= c.x;
      if (direction === 'up') return f.y + f.height <= c.y;
      return f.y >= c.y + c.height;
    });
    return candidates[0] ?? null;
  }
  const m = /^(\d+)x(\d+)$/.exec(text);
  if (m) return context.screens.find((s) => s.frame.width === Number(m[1]) && s.frame.height === Number(m[2])) ?? null;
  throw new SlatedError('invalidSyntax', `Invalid screen reference "${ref}"`);
}

function variables(screen, frame, size) {
  const v = screen.visibleFrame;
  return {
    screenOriginX: Math.trunc(v.x),
    screenOriginY: Math.trunc(v.y),
    screenSizeX: Math.trunc(v.width),
    screenSizeY: Math.trunc(v.height),
    windowTopLeftX: Math.trunc(frame.x),
    windowTopLeftY: Math.trunc(frame.y),
    windowSizeX: Math.trunc(frame.width),
    windowSizeY: Math.trunc(frame.height),
    newWindowSizeX: Math.trunc(size.width),
    newWindowSizeY: Math.trunc(size.height),
  };
}

function plan(action, context) {
  const {frame, screens} = context;
  if (action.op === 'by-orientation') {
    const s = screenOf(screens, frame);
    return plan(s.frame.height > s.frame.width ? action.portrait : action.landscape, context);
  }
  const screen = resolveScreen(action.screen ?? null, context);
  if (!screen) throw new SlatedError('screenNotFound', `No screen matches "${action.screen}"`);
  const before = variables(screen, frame, frame);
  const ev = (e, vars) => evaluateExpression(e, vars);
  switch (action.op) {
    case 'move':
      return {size: {width: ev(action.width, before), height: ev(action.height, before)}, origin: (size) => ({x: ev(action.x, variables(screen, frame, size)), y: ev(action.y, variables(screen, frame, size))})};
    case 'throw':
      return {
        size: {width: action.width ? ev(action.width, before) : frame.width, height: action.height ? ev(action.height, before) : frame.height},
        origin: () => ({x: before.screenOriginX, y: before.screenOriginY}),
      };
    case 'corner': {
      const width = action.width ? ev(action.width, before) : frame.width;
      const height = action.height ? ev(action.height, before) : frame.height;
      return {
        size: {width, height},
        origin: (size) => ({
          x: action.direction.endsWith('left') ? before.screenOriginX : before.screenOriginX + before.screenSizeX - size.width,
          y: action.direction.startsWith('top') ? before.screenOriginY : before.screenOriginY + before.screenSizeY - size.height,
        }),
      };
    }
    case 'push': {
      const style = action.style ?? 'none';
      const bar = style.startsWith('bar');
      const amount = style.startsWith('bar-resize:') ? ev(style.slice(11), before) : null;
      const horizontal = action.direction === 'left' || action.direction === 'right';
      const width = horizontal ? (amount ?? frame.width) : bar ? before.screenSizeX : frame.width;
      const height = horizontal ? (bar ? before.screenSizeY : frame.height) : (amount ?? frame.height);
      return {
        size: {width, height},
        origin: (size) => {
          switch (action.direction) {
            case 'left':
              return {x: before.screenOriginX, y: bar ? before.screenOriginY : frame.y};
            case 'right':
              return {x: before.screenOriginX + before.screenSizeX - size.width, y: bar ? before.screenOriginY : frame.y};
            case 'up':
              return {x: bar ? before.screenOriginX : frame.x, y: before.screenOriginY};
            default:
              return {x: bar ? before.screenOriginX : frame.x, y: before.screenOriginY + before.screenSizeY - size.height};
          }
        },
      };
    }
    default:
      throw new SlatedError('invalidSyntax', `"${action.op}" doesn't move or resize a window`);
  }
}

export function targetFrame(action, context) {
  const p = plan(action, context);
  return {...p.origin(p.size), ...p.size};
}

export function targetOrigin(action, context, actualSize) {
  return plan(action, context).origin(actualSize);
}

export function parseSlateConfig(text, {path} = {}) {
  const result = {settings: {}, bindings: [], layouts: [], defaults: [], diagnostics: []};
  String(text)
    .split('\n')
    .forEach((line, index) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return;
      const [directive, ...rest] = trimmed.split(/\s+/);
      if (directive === 'config') result.settings[rest[0]] = rest.slice(1).join(' ') === 'true' ? true : rest.slice(1).join(' ');
      else if (directive === 'bind') {
        const parsed = parseKeystroke(rest[0]);
        result.bindings.push({id: `${path}#${index}`, keys: parsed.keys, modal: parsed.modal ?? undefined, action: parseOperation(rest.slice(1).join(' ')), enabled: true});
      } else result.diagnostics.push({severity: 'error', message: `Unknown directive "${directive}"`, file: path, line: index + 1});
    });
  return result;
}

export const fakeCore = {
  SlatedError,
  parseKeyCombo,
  formatKeyCombo,
  parseKeystroke,
  evaluateExpression,
  parseOperation,
  formatOperation,
  decodeConfiguration,
  encodeConfiguration,
  starterConfiguration,
  toGnomeAccelerator,
  resolveScreen,
  targetFrame,
  targetOrigin,
  parseSlateConfig,
};

/** The real core once it is implemented; null while lib/core/index.js is still the stub. */
export function realCore() {
  try {
    RealCore.parseKeyCombo('hyper+a');
    return RealCore;
  } catch (e) {
    if (e?.kind === 'notImplemented') return null;
    throw e;
  }
}
