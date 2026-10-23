// Reads Slate config files without running Slated, so the preferences can list their bindings and
// import them into config.json (the macOS app's SlateImporter, Sources/SlatedScript/SlateImporter.swift,
// and Engine.importSlateConfigs, ported to plain JavaScript).
//
// ~/.slate.js runs against a fake `slate` API that records what the script registers instead of
// doing anything. Static operations convert directly. A bound function is run against a pretend
// desktop twice: once with the focused window on a landscape screen and once on a portrait screen.
// If each run performs exactly one operation and nothing else, the binding becomes that operation,
// or a `by-orientation` pair when the two differ. Anything else genuinely needs JavaScript and is
// skipped, with the reason. Classic ~/.slate files go through the engine's parseSlateConfig.
//
// Pure ES module: no gi:// imports. File access is injected (`readFile`).

import {isObject, deepEqual, expandHome} from './util.js';
import {newId} from './ids.js';
import {keysString, canonicalKey, isValidKey, modifierToken, statusKey} from './keys.js';
import {coerceParameter} from './canonical.js';
import {actionDetail} from './actions.js';
import {
  canonicalAction, parseOperation, parseKeystroke, parseSlateConfig, isNotImplemented, describeError,
} from './engine.js';

/** Slate's operations plus Slated's own, with the parameters each understands (ScriptOperations.swift). */
export const OPERATION_PARAMETERS = {
  move: ['x', 'y', 'width', 'height', 'screen'],
  resize: ['width', 'height', 'anchor'],
  push: ['direction', 'style', 'screen'],
  nudge: ['x', 'y'],
  throw: ['screen', 'width', 'height'],
  corner: ['direction', 'width', 'height', 'screen'],
  chain: ['operations'],
  sequence: ['operations'],
  layout: ['name'],
  focus: ['direction', 'app'],
  snapshot: ['name', 'save', 'stack'],
  'delete-snapshot': ['name', 'all'],
  'activate-snapshot': ['name', 'delete'],
  hint: ['characters'],
  grid: ['padding', 'grids'],
  hide: ['app'],
  show: ['app'],
  toggle: ['app'],
  shell: ['command', 'wait', 'path'],
  undo: [],
  relaunch: [],
  switch: ['back', 'quit', 'force-quit', 'hide'],
  'insert-text': ['text', 'method'],
  'open-url': ['url'],
  keystroke: ['keys'],
};

/** The pretend desktop the probes run on (the same as the macOS importer's). */
export const PROBE_SCREENS = Object.freeze([
  {displayID: 1, name: 'Landscape', isMain: true, scale: 1,
    frame: {x: 0, y: 0, width: 1920, height: 1080}, visibleFrame: {x: 0, y: 25, width: 1920, height: 1055}},
  {displayID: 2, name: 'Portrait', isMain: false, scale: 1,
    frame: {x: 1920, y: 0, width: 1080, height: 1920}, visibleFrame: {x: 1920, y: 0, width: 1080, height: 1920}},
]);

const PROBE_WINDOWS = {
  1: {frame: {x: 200, y: 200, width: 800, height: 600}, screen: 0},
  2: {frame: {x: 2100, y: 300, width: 700, height: 900}, screen: 1},
};

class ProbeError extends Error {}

// --- Keystrokes ----------------------------------------------------------------------------------------

function orderedModifiers(list) {
  const set = new Set(list);
  return ['fn', 'ctrl', 'alt', 'shift', 'cmd'].filter(m => set.has(m));
}

/**
 * Local parser for Slate keystrokes ("a:ctrl,shift,alt,cmd", "1:f4,ctrl,alt" with modal key f4,
 * "1:ctrl,f4:toggle"), following SlateSyntax.parseKeystroke. Used while the engine is a stub.
 */
export function parseKeystrokeLocal(string) {
  let rest = String(string ?? '').trim();
  let toggle = false;
  if (rest.toLowerCase().endsWith(':toggle')) {
    toggle = true;
    rest = rest.slice(0, -':toggle'.length);
  }
  // The key comes first and is never ":" itself, so the first colon after it starts the modifiers.
  const colon = rest.indexOf(':', 1);
  const key = colon >= 0 ? rest.slice(0, colon) : rest;
  const list = colon >= 0 ? rest.slice(colon + 1) : '';
  if (!isValidKey(key)) throw new Error(`Unknown key "${key}" in "${string}"`);
  const modifiers = [];
  let modalKey = null;
  for (const token of list.split(/[,;]/)) {
    const t = token.trim();
    if (!t) continue;
    const m = modifierToken(t);
    if (m) modifiers.push(...m);
    else if (isValidKey(t) && modalKey === null) modalKey = t;
    else throw new Error(`Unknown modifier "${t}" in "${string}"`);
  }
  if (modalKey !== null) {
    return {
      keys: {key: canonicalKey(key), modifiers: []},
      modal: {keys: {key: canonicalKey(modalKey), modifiers: orderedModifiers(modifiers)}, toggle},
    };
  }
  if (toggle) throw new Error(`:toggle needs a modal key in "${string}"`);
  return {keys: {key: canonicalKey(key), modifiers: orderedModifiers(modifiers)}, modal: null};
}

/** A Slate keystroke as config strings: {keys: "hyper+a", modal: {keys, toggle} | null}. */
export function keystrokeToConfig(string) {
  let parsed;
  try {
    parsed = parseKeystroke(string);
  } catch (error) {
    if (!isNotImplemented(error)) throw error;
    parsed = parseKeystrokeLocal(string);
  }
  const modal = parsed.modal ? {keys: keysString(parsed.modal.keys), toggle: parsed.modal.toggle === true} : null;
  return {keys: keysString(parsed.keys), modal};
}

// --- Fake API objects ----------------------------------------------------------------------------------

const HIDDEN = Symbol('slated');

function defineAliases(target, aliases) {
  for (const [short, long] of Object.entries(aliases)) target[short] = target[long];
}

function isOperation(value) {
  return Boolean(value && value[HIDDEN]?.type === 'operation');
}

/** A minimal, independent subset of underscore.js, which Slate preloaded for configs. */
function makeUnderscore() {
  const _ = {};
  const isArrayLike = obj => obj !== null && obj !== undefined && typeof obj !== 'function' && typeof obj.length === 'number';
  const pairs = obj => {
    if (obj === null || obj === undefined) return [];
    if (isArrayLike(obj)) return Array.prototype.map.call(obj, (value, index) => [value, index]);
    return Object.keys(obj).map(key => [obj[key], key]);
  };
  const iteratee = f => {
    if (typeof f === 'function') return f;
    if (f === null || f === undefined) return value => value;
    return value => (value === null || value === undefined ? undefined : value[f]);
  };
  const slice = (list, start, end) => Array.prototype.slice.call(list ?? [], start, end);
  _.each = _.forEach = (obj, f, context) => {
    for (const [value, key] of pairs(obj)) f.call(context, value, key, obj);
    return obj;
  };
  _.map = _.collect = (obj, f, context) => pairs(obj).map(([value, key]) => iteratee(f).call(context, value, key, obj));
  _.filter = _.select = (obj, f, context) => pairs(obj).filter(([v, k]) => iteratee(f).call(context, v, k, obj)).map(([v]) => v);
  _.reject = (obj, f, context) => _.filter(obj, (v, k, l) => !iteratee(f).call(context, v, k, l));
  _.find = _.detect = (obj, f, context) => pairs(obj).find(([v, k]) => iteratee(f).call(context, v, k, obj))?.[0];
  _.some = _.any = (obj, f, context) => pairs(obj).some(([v, k]) => iteratee(f).call(context, v, k, obj));
  _.every = _.all = (obj, f, context) => pairs(obj).every(([v, k]) => iteratee(f).call(context, v, k, obj));
  _.reduce = _.inject = _.foldl = function (obj, f, memo, context) {
    const list = pairs(obj);
    let start = 0;
    if (arguments.length < 3) {
      memo = list.length ? list[0][0] : undefined;
      start = 1;
    }
    for (let i = start; i < list.length; i++) memo = f.call(context, memo, list[i][0], list[i][1], obj);
    return memo;
  };
  _.values = obj => pairs(obj).map(([v]) => v);
  _.keys = obj => (obj === null || obj === undefined ? [] : Object.keys(obj));
  _.size = obj => pairs(obj).length;
  _.contains = _.include = (obj, target) => _.values(obj).includes(target);
  _.pluck = (obj, key) => _.map(obj, key);
  _.sortBy = (obj, f, context) => pairs(obj).map(([value, key]) => ({value, rank: iteratee(f).call(context, value, key, obj)}))
    .sort((a, b) => (a.rank < b.rank ? -1 : a.rank > b.rank ? 1 : 0)).map(e => e.value);
  _.first = _.head = (list, n) => (n === undefined ? slice(list)[0] : slice(list, 0, n));
  _.last = (list, n) => {
    const items = slice(list);
    return n === undefined ? items[items.length - 1] : items.slice(Math.max(items.length - n, 0));
  };
  _.rest = _.tail = (list, n) => slice(list, n === undefined ? 1 : n);
  _.without = (list, ...values) => slice(list).filter(v => !values.includes(v));
  _.uniq = _.unique = list => slice(list).filter((v, i, items) => items.indexOf(v) === i);
  _.flatten = (list, shallow) => slice(list).reduce((out, v) => out.concat(Array.isArray(v) && !shallow ? _.flatten(v) : v), []);
  _.range = function (start, stop, step) {
    if (arguments.length <= 1) {
      stop = start || 0;
      start = 0;
    }
    step = step || 1;
    const out = [];
    for (let x = start; step > 0 ? x < stop : x > stop; x += step) out.push(x);
    return out;
  };
  _.indexOf = (list, value) => slice(list).indexOf(value);
  _.times = (n, f, context) => _.range(n).map(i => f.call(context, i));
  _.extend = (obj, ...sources) => Object.assign(obj, ...sources);
  _.defaults = (obj, ...sources) => {
    for (const source of sources) for (const key in source) if (obj[key] === undefined) obj[key] = source[key];
    return obj;
  };
  _.clone = obj => (obj === null || typeof obj !== 'object' ? obj : Array.isArray(obj) ? obj.slice() : {...obj});
  _.has = (obj, key) => obj !== null && obj !== undefined && Object.prototype.hasOwnProperty.call(obj, key);
  _.identity = v => v;
  _.bind = (f, context, ...args) => f.bind(context, ...args);
  _.isString = x => typeof x === 'string' || x instanceof String;
  _.isNumber = x => typeof x === 'number' || x instanceof Number;
  _.isBoolean = x => x === true || x === false || x instanceof Boolean;
  _.isFunction = x => typeof x === 'function';
  _.isArray = Array.isArray;
  _.isObject = x => typeof x === 'function' || (typeof x === 'object' && x !== null);
  _.isUndefined = x => x === undefined;
  _.isNull = x => x === null;
  _.isEmpty = x => x === null || x === undefined || (isArrayLike(x) ? x.length === 0 : Object.keys(x).length === 0);
  return _;
}

/** Finds the script line an error or call came from, given the line offset of `new Function`. */
function scriptLine(stack, offset) {
  if (typeof stack !== 'string') return null;
  // V8: "<anonymous>:12:5"; SpiderMonkey: "line 3 > Function:12:5".
  const match = /(?:<anonymous>|> Function):(\d+):\d+/.exec(stack);
  if (!match) return null;
  const line = parseInt(match[1], 10) - offset;
  return line > 0 ? line : null;
}

// Host globals a config has no business with; the script sees them as undefined. (This is not a
// sandbox: it's the user's own config, which the extension runs too. It only keeps a stray `print`
// or `log` from reaching the preferences process.)
const SHADOWED = ['imports', 'require', 'process', 'globalThis', 'global', 'print', 'printerr', 'log', 'logError'];
const PARAMETERS = [...SHADOWED, 'slate', 'S', '_', 'window'];

/**
 * The script runs inside a block, so its own top-level `let log` or `const S` shadows the injected
 * names instead of being a redeclaration error.
 */
const wrap = text => `{\n${text}\n}`;

function functionLineOffset() {
  try {
    // eslint-disable-next-line no-new-func
    new Function(...PARAMETERS, wrap('throw new Error("probe");'))();
  } catch (error) {
    const match = /(?:<anonymous>|> Function):(\d+):\d+/.exec(error.stack ?? '');
    if (match) return parseInt(match[1], 10) - 1;
  }
  return 0;
}

// --- Loading a script ----------------------------------------------------------------------------------

/**
 * Runs a Slate JavaScript config against the fake API.
 *
 * @param {string} source the script
 * @param {object} [options]
 * @param {string} [options.path] for diagnostics and relative `slate.source` paths
 * @param {string} [options.home] the home folder, for `~` and `slate.source`
 * @param {(path: string) => string|null} [options.readFile] reads files for `slate.source`
 * @returns {{bindings: Array, layouts: Array, settings: object, defaults: Array, diagnostics: Array,
 *   probe: (binding) => {action}|{reason}}}
 */
export function loadSlateScript(source, {path = '~/.slate.js', home = '/home/user', readFile = () => null} = {}) {
  const offset = functionLineOffset();
  const diagnostics = [];
  const bindings = [];
  const layouts = [];
  const defaults = [];
  const settings = {};
  const configFunctions = {};
  const sourced = new Set();
  let loading = true;

  // Probe state: what the current run did.
  const probe = {active: false, focused: 1, recorded: [], sideEffects: [], chainPositions: new Map()};

  const report = (severity, message, line = null) => diagnostics.push({severity, message, line, file: path});
  const callerLine = () => scriptLine(new Error().stack, offset);

  // --- Operations ---

  const makeOperation = (name, kind, extra = {}) => {
    const op = {
      name,
      run() {
        return runOperation(op, probe.focused);
      },
      dup(params) {
        return dupOperation(op, params);
      },
      toString() {
        return `[SlateOperation ${name}]`;
      },
    };
    Object.defineProperty(op, HIDDEN, {value: {type: 'operation', kind, ...extra}});
    return op;
  };

  /** A JSON-compatible parameter value (screens by id, apps by name, operations as actions). */
  const jsonValue = (value, key, depth = 0) => {
    if (depth > 32) throw new Error(`"${key}" is nested too deeply`);
    if (value === undefined || value === null) return undefined;
    if (typeof value === 'boolean' || typeof value === 'string') return value;
    if (typeof value === 'number') {
      if (!Number.isFinite(value) || Math.abs(value) >= 1e15) throw new Error(`"${key}" is out of range`);
      return value;
    }
    if (isOperation(value)) {
      const info = value[HIDDEN];
      if (info.kind !== 'action') throw new Error(`"${key}" can't hold an operation that runs JavaScript`);
      return info.action;
    }
    if (typeof value === 'function') throw new Error(`"${key}" can't be a function here`);
    if (value[HIDDEN]?.type === 'screen') return value[HIDDEN].id;
    if (value[HIDDEN]?.type === 'app') return value[HIDDEN].name;
    if (value[HIDDEN]?.type === 'window') throw new Error(`"${key}" can't be a window`);
    if (Array.isArray(value)) return value.map(v => jsonValue(v, key, depth + 1)).filter(v => v !== undefined);
    const out = {};
    for (const k of Object.keys(value)) {
      const v = jsonValue(value[k], k, depth + 1);
      if (v !== undefined) out[k] = v;
    }
    return out;
  };

  const decodeAction = (name, entries) => {
    const object = {op: name};
    for (const [key, value] of entries) {
      const json = jsonValue(value, key);
      if (json !== undefined) object[key] = coerceParameter(key, json);
    }
    return canonicalAction(object);
  };

  /** Anything Slated treats as an operation: operation, function, Slate syntax string, {op: ...}. */
  const operationObject = (value, caller) => {
    if (isOperation(value)) return value;
    if (typeof value === 'function') return makeOperation('js', 'function', {fn: value});
    if (typeof value === 'string') return operationFromString(value);
    if (isObject(value) && typeof value.op === 'string') return makeOperationFromParams(value.op, value, ['op']);
    if (value === null || value === undefined) {
      // Usually slate.operation(...) failed on the same line and already said why.
      const line = callerLine();
      if (!diagnostics.some(d => d.severity === 'error' && d.line === line && line !== null)) {
        report('error', `${caller} needs an operation or a function, got ${value === null ? 'null' : 'undefined'}.`, line);
      }
      return null;
    }
    report('error', `${caller} needs an operation or a function, got ${typeof value}.`, callerLine());
    return null;
  };

  const operationFromString = text => {
    try {
      const action = parseOperation(text);
      return makeOperation(action.op, 'action', {action: canonicalAction(action)});
    } catch (error) {
      if (isNotImplemented(error)) return makeOperation('syntax', 'syntax', {text});
      report('error', `Can't parse the operation "${text}": ${describeError(error)}`, callerLine());
      return null;
    }
  };

  const makeChain = params => {
    const list = params.operations;
    if (!Array.isArray(list) || !list.length) {
      report('error', '"chain" needs "operations": an array of operations.', callerLine());
      return null;
    }
    const items = [];
    for (const [i, value] of list.entries()) {
      const item = operationObject(value, `Chain operation ${i + 1}`);
      if (!item) return null;
      items.push(item);
    }
    if (items.every(item => item[HIDDEN].kind === 'action')) {
      return makeOperation('chain', 'action', {action: {op: 'chain', operations: items.map(item => item[HIDDEN].action)}, params});
    }
    return makeOperation('chain', 'chain', {items, params});
  };

  const makeSequence = params => {
    const list = params.operations;
    if (!Array.isArray(list) || !list.length) {
      report('error', '"sequence" needs "operations": an array of operations.', callerLine());
      return null;
    }
    const groups = [];
    for (const [i, value] of list.entries()) {
      const group = [];
      for (const member of Array.isArray(value) ? value : [value]) {
        const item = operationObject(member, `Sequence step ${i + 1}`);
        if (!item) return null;
        group.push(item);
      }
      if (group.length) groups.push(group);
    }
    if (groups.flat().every(item => item[HIDDEN].kind === 'action')) {
      const steps = groups.flatMap(group => group.map((item, index) => ({action: item[HIDDEN].action, keepWindow: index > 0})));
      const action = steps.every(s => !s.keepWindow)
        ? {op: 'sequence', operations: steps.map(s => s.action)} : {op: 'sequence', steps};
      return makeOperation('sequence', 'action', {action, params});
    }
    return makeOperation('sequence', 'sequence', {groups, params});
  };

  const makeOperationFromParams = (name, rawParams, ignored = []) => {
    const known = OPERATION_PARAMETERS[name];
    if (!known) {
      report('error', `Unknown operation "${name}".`, callerLine());
      return null;
    }
    let params = rawParams;
    if (params === undefined || params === null) params = {};
    if (!isObject(params)) {
      report('error', `The parameters of "${name}" must be an object like {"direction": "left"}.`, callerLine());
      return null;
    }
    const entries = Object.keys(params).filter(k => !ignored.includes(k)).map(k => [k, params[k]]);
    for (const [key] of entries) {
      if (!known.includes(key)) report('warning', `"${name}" has no parameter "${key}", so it was ignored.`, callerLine());
    }
    if (name === 'chain') return makeChain(params);
    if (name === 'sequence') return makeSequence(params);
    const relevant = entries.filter(([key]) => known.includes(key));
    if (relevant.some(([, value]) => typeof value === 'function')) {
      return makeOperation(name, 'dynamic', {params: Object.fromEntries(relevant)});
    }
    try {
      return makeOperation(name, 'action', {action: decodeAction(name, relevant), params: Object.fromEntries(relevant)});
    } catch (error) {
      report('error', `Invalid "${name}" operation: ${describeError(error)}.`, callerLine());
      return null;
    }
  };

  const dupOperation = (op, changes) => {
    const info = op[HIDDEN];
    if (!isObject(changes)) {
      report('error', 'operation.dup needs an object with the parameters to change, like {"width": "screenSizeX/3"}.', callerLine());
      return null;
    }
    let base = info.params;
    if (!base && info.kind === 'action') base = {...info.action};
    if (!base) {
      report('error', "This operation is a JavaScript function, so it can't be duplicated.", callerLine());
      return null;
    }
    return makeOperationFromParams(op.name, {...base, ...changes}, ['op']);
  };

  // --- Running (probes) ---

  const resolveDynamic = (op, windowHandle) => {
    const entries = [];
    for (const [key, value] of Object.entries(op[HIDDEN].params)) {
      entries.push([key, typeof value === 'function' ? withWindow(windowHandle, () => value()) : value]);
    }
    return decodeAction(op.name, entries);
  };

  const runOperation = (op, windowHandle) => {
    const info = op?.[HIDDEN];
    if (!info) throw new ProbeError('Expected an operation.');
    if (!probe.active) {
      report('warning', 'Operations only run when a shortcut is pressed, so this one did nothing while loading.', callerLine());
      return false;
    }
    switch (info.kind) {
    case 'action':
      probe.recorded.push(info.action);
      return true;
    case 'syntax':
      throw new ProbeError(`uses Slate syntax that needs a newer Slated engine to read: "${info.text}"`);
    case 'function':
      withWindow(windowHandle, () => info.fn(windowObject(windowHandle)));
      return true;
    case 'dynamic':
      probe.recorded.push(resolveDynamic(op, windowHandle));
      return true;
    case 'chain':
    case 'sequence':
      throw new ProbeError(`has a ${info.kind} with JavaScript steps, which needs the script`);
    default:
      return false;
    }
  };

  const windowStack = [];
  const withWindow = (handle, body) => {
    windowStack.push(handle);
    try {
      return body();
    } finally {
      windowStack.pop();
    }
  };
  const currentWindow = () => (windowStack.length ? windowStack[windowStack.length - 1] : probe.focused);

  const sideEffect = what => {
    if (probe.active) probe.sideEffects.push(what);
    else report('warning', `${what} doesn't run while Slated reads your config.`, callerLine());
    return false;
  };

  // --- Screens, windows, apps ---

  const orderedScreens = () => {
    const ordered = settings.orderScreensLeftToRight === false ? [...PROBE_SCREENS]
      : [...PROBE_SCREENS].sort((a, b) => a.frame.x - b.frame.x || b.frame.y - a.frame.y);
    return ordered;
  };

  const screenObject = index => {
    const screens = orderedScreens();
    const screen = screens[index];
    if (!screen) return undefined;
    const object = {
      id: () => index,
      rect: () => ({...screen.frame}),
      visibleRect: () => ({...screen.visibleFrame}),
      isMain: () => screen.isMain,
      toString: () => String(index),
    };
    defineAliases(object, {vrect: 'visibleRect', main: 'isMain'});
    Object.defineProperty(object, HIDDEN, {value: {type: 'screen', id: index}});
    return object;
  };

  const screenIndexForWindow = handle => {
    const screen = PROBE_SCREENS[PROBE_WINDOWS[handle]?.screen ?? 0];
    return orderedScreens().indexOf(screen);
  };

  const app = {
    pid: () => 1,
    name: () => 'App',
    eachWindow: () => sideEffect('app.eachWindow'),
    mainWindow: () => windowObject(currentWindow()),
    toString: () => 'App',
  };
  defineAliases(app, {ewindow: 'eachWindow', mwindow: 'mainWindow'});
  Object.defineProperty(app, HIDDEN, {value: {type: 'app', name: 'App'}});

  const windowObject = handle => {
    const info = PROBE_WINDOWS[handle];
    if (!info) return undefined;
    const frame = info.frame;
    const object = {
      title: () => 'Window',
      topLeft: () => ({x: frame.x, y: frame.y}),
      size: () => ({width: frame.width, height: frame.height}),
      rect: () => ({...frame}),
      pid: () => 1,
      focus: () => sideEffect('win.focus'),
      isMinimizedOrHidden: () => false,
      isMain: () => true,
      isMovable: () => true,
      isResizable: () => true,
      move: () => sideEffect('win.move'),
      resize: () => sideEffect('win.resize'),
      screen: () => screenObject(screenIndexForWindow(handle)),
      app: () => app,
      doOperation: (operation, params) => {
        const op = operationArgument(operation, params, 'win.doOperation');
        return op ? withWindow(handle, () => runOperation(op, handle)) : false;
      },
    };
    defineAliases(object, {
      tl: 'topLeft', hidden: 'isMinimizedOrHidden', main: 'isMain', movable: 'isMovable', resizable: 'isResizable',
      doop: 'doOperation',
    });
    Object.defineProperty(object, HIDDEN, {value: {type: 'window', handle}});
    return object;
  };

  /** doOperation(op), doOperation("push", {...}), or doOperation("push left"). */
  const operationArgument = (value, params, caller) => {
    if (typeof value === 'string') {
      if ((params !== undefined && params !== null) || OPERATION_PARAMETERS[value]) return makeOperationFromParams(value, params);
      return operationFromString(value);
    }
    return operationObject(value, caller);
  };

  const pointOnScreen = point => PROBE_SCREENS.some(s => point.x >= s.frame.x && point.x <= s.frame.x + s.frame.width &&
    point.y >= s.frame.y && point.y <= s.frame.y + s.frame.height);

  const info = {
    window: () => windowObject(currentWindow()),
    app: () => app,
    screen: () => screenObject(screenIndexForWindow(currentWindow())),
    eachApp: callback => {
      if (typeof callback === 'function') callback(app);
    },
    windowUnderPoint: point => {
      for (const [handle, w] of Object.entries(PROBE_WINDOWS)) {
        const f = w.frame;
        if (point?.x >= f.x && point.x < f.x + f.width && point.y >= f.y && point.y < f.y + f.height) return windowObject(Number(handle));
      }
      return undefined;
    },
    screenUnderPoint: point => {
      const index = orderedScreens().findIndex(s => point?.x >= s.frame.x && point.x <= s.frame.x + s.frame.width &&
        point.y >= s.frame.y && point.y <= s.frame.y + s.frame.height);
      return index >= 0 ? screenObject(index) : undefined;
    },
    isRectOffScreen: r => [[r.x, r.y], [r.x + r.width, r.y], [r.x, r.y + r.height], [r.x + r.width, r.y + r.height]]
      .some(([x, y]) => !pointOnScreen({x, y})),
    isPointOffScreen: p => !pointOnScreen(p),
    screenForRef: ref => {
      const text = String(ref ?? '').trim().toLowerCase();
      const screens = orderedScreens();
      const current = screenIndexForWindow(currentWindow());
      if (/^\d+$/.test(text)) return screenObject(parseInt(text, 10));
      if (text === 'next' || text === 'right') return screenObject((current + 1) % screens.length);
      if (text === 'previous' || text === 'prev' || text === 'left') return screenObject((current - 1 + screens.length) % screens.length);
      return undefined;
    },
    screenCount: () => PROBE_SCREENS.length,
    eachScreen: callback => {
      if (typeof callback !== 'function') return;
      orderedScreens().forEach((_, index) => callback(screenObject(index)));
    },
  };
  defineAliases(info, {
    eapp: 'eachApp', wup: 'windowUnderPoint', sup: 'screenUnderPoint', rectoff: 'isRectOffScreen',
    pntoff: 'isPointOffScreen', screenr: 'screenForRef', screenc: 'screenCount', escreen: 'eachScreen',
  });

  // --- Registration API ---

  const settingValue = value => {
    if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') return value;
    if (Array.isArray(value)) return value.map(String).join(';');
    return undefined;
  };

  const setConfig = (name, value) => {
    if (typeof value === 'function') {
      configFunctions[name] = value;
      return;
    }
    const setting = settingValue(value);
    if (setting === undefined) {
      report('error', `slate.config("${name}", …) needs a string, number, boolean, array or function.`, callerLine());
      return;
    }
    delete configFunctions[name];
    settings[name] = setting;
  };

  const bind = (keystroke, target, repeat) => {
    if (!loading) {
      report('warning', 'slate.bind only works while the config loads, so this binding was ignored.', callerLine());
      return;
    }
    const line = callerLine();
    if (typeof keystroke !== 'string') {
      report('error', `slate.bind needs a keystroke like "a:ctrl,shift", got ${typeof keystroke}.`, line);
      return;
    }
    let parsed;
    try {
      parsed = keystrokeToConfig(keystroke);
    } catch (error) {
      report('error', `Can't bind "${keystroke}": ${describeError(error)}`, line);
      return;
    }
    const op = operationObject(target, `slate.bind("${keystroke}", …)`);
    if (!op) return;
    const key = statusKey(parsed.keys, parsed.modal);
    const earlier = bindings.find(b => b.statusKey === key);
    if (earlier) report('warning', `"${keystroke}" is bound more than once${earlier.line ? ` (first on line ${earlier.line})` : ''}.`, line);
    const opInfo = op[HIDDEN];
    const action = opInfo.kind === 'action' ? opInfo.action : null;
    bindings.push({
      keystroke,
      keys: parsed.keys,
      modal: parsed.modal,
      statusKey: key,
      action,
      operation: op,
      summary: action ? actionDetail(action) : opInfo.kind === 'function' ? 'JavaScript function'
        : opInfo.kind === 'syntax' ? opInfo.text : `${op.name} (with JavaScript)`,
      repeats: repeat === undefined || repeat === null ? null : Boolean(repeat),
      line,
    });
  };

  const slate = {
    log: () => undefined,
    config: (name, value) => {
      if (typeof name !== 'string') {
        report('error', 'slate.config needs a setting name (a string).', callerLine());
        return;
      }
      setConfig(name, value);
    },
    configAll: values => {
      if (!isObject(values)) {
        report('error', 'slate.configAll needs an object like {"defaultToCurrentScreen": true}.', callerLine());
        return;
      }
      for (const name of Object.keys(values)) setConfig(name, values[name]);
    },
    bind,
    bindAll: all => {
      if (!isObject(all)) {
        report('error', 'slate.bindAll needs an object mapping keystrokes to operations.', callerLine());
        return;
      }
      for (const keystroke of Object.keys(all)) {
        const value = all[keystroke];
        if (Array.isArray(value)) bind(keystroke, value[0], value[1]);
        else bind(keystroke, value, undefined);
      }
    },
    operation: (name, params) => {
      if (typeof name !== 'string') {
        report('error', 'slate.operation needs an operation name like "move".', callerLine());
        return null;
      }
      return makeOperationFromParams(name, params);
    },
    operationFromString: text => {
      if (typeof text !== 'string') {
        report('error', 'slate.operationFromString needs a string like "push left bar".', callerLine());
        return null;
      }
      return operationFromString(text);
    },
    doOperation: (operation, params) => {
      const op = operationArgument(operation, params, 'slate.doOperation');
      return op ? runOperation(op, currentWindow()) : false;
    },
    source: raw => {
      if (typeof raw !== 'string') {
        report('error', 'slate.source needs a file path (a string).', callerLine());
        return false;
      }
      const file = expandHome(raw.startsWith('/') || raw.startsWith('~') ? raw : `~/${raw}`, home);
      if (sourced.has(file)) {
        report('error', `${raw} is already loading, so slate.source skipped it to avoid a loop.`, callerLine());
        return false;
      }
      const text = readFile(file);
      if (text === null || text === undefined) {
        report('warning', `Couldn't read ${raw}, so slate.source skipped it.`, callerLine());
        return false;
      }
      sourced.add(file);
      if (file.endsWith('.js')) return evaluate(text);
      report('warning', `${raw} is a classic Slate file; its bindings are listed separately.`, callerLine());
      return false;
    },
    layout: (name, apps) => {
      if (typeof name !== 'string') {
        report('error', 'slate.layout needs a layout name (a string).', callerLine());
        return null;
      }
      if (!isObject(apps)) {
        report('error', `slate.layout("${name}", …) needs an object mapping app names to {"operations": …}.`, callerLine());
        return null;
      }
      const layout = {name, apps: [], before: [], after: [], javascript: false};
      for (const appName of Object.keys(apps)) {
        const entry = apps[appName];
        const operations = isObject(entry) ? entry.operations : undefined;
        if (operations === undefined || operations === null) {
          report('warning', `Layout "${name}": "${appName}" has no "operations", so it was skipped.`, callerLine());
          continue;
        }
        const ops = (Array.isArray(operations) ? operations : [operations])
          .map((value, index) => operationObject(value, `Layout "${name}", "${appName}" operation ${index + 1}`))
          .filter(Boolean);
        if (ops.some(op => op[HIDDEN].kind !== 'action')) layout.javascript = true;
        const actions = ops.filter(op => op[HIDDEN].kind === 'action').map(op => op[HIDDEN].action);
        if (appName === '_before_') layout.before = actions;
        else if (appName === '_after_') layout.after = actions;
        else layout.apps.push({app: appName, operations: actions, options: layoutOptions(entry)});
      }
      const existing = layouts.findIndex(l => l.name === name);
      if (existing >= 0) layouts[existing] = layout;
      else layouts.push(layout);
      return name;
    },
    default: (screens, target) => {
      let condition = null;
      if (typeof screens === 'number') condition = {count: {_0: Math.trunc(screens)}};
      else if (typeof screens === 'string' && screens.trim()) {
        condition = /^\d+$/.test(screens.trim()) ? {count: {_0: parseInt(screens, 10)}}
          : {resolutions: {_0: screens.split(/[;,]/).map(s => s.trim()).filter(Boolean).sort()}};
      } else if (Array.isArray(screens)) condition = {resolutions: {_0: screens.filter(s => typeof s === 'string').sort()}};
      if (!condition) {
        report('error', 'slate.default needs a screen count or an array of resolutions like ["1920x1080"].', callerLine());
        return;
      }
      if (typeof target === 'string') defaults.push({target, condition});
      else if (isOperation(target) && target[HIDDEN].action?.op === 'layout') defaults.push({target: target[HIDDEN].action.name, condition});
      else report('warning', 'Only slate.default with a layout name can be imported.', callerLine());
    },
    shell: () => {
      sideEffect('slate.shell');
      return null;
    },
    on: () => undefined,
    info,
    ...info,
  };
  defineAliases(slate, {
    cfg: 'config', cfga: 'configAll', bnd: 'bind', bnda: 'bindAll', op: 'operation', opstr: 'operationFromString',
    doop: 'doOperation', src: 'source', lay: 'layout', def: 'default', sh: 'shell',
  });

  function layoutOptions(entry) {
    const flag = key => entry[key] !== undefined && entry[key] !== null && entry[key] !== false && entry[key] !== 0 &&
      !['', '0', 'false', 'no', 'off'].includes(String(entry[key]).trim().toLowerCase());
    const strings = key => {
      const v = entry[key];
      if (Array.isArray(v)) return v.filter(s => typeof s === 'string');
      if (typeof v === 'string') return v.split(';');
      return undefined;
    };
    const options = {
      ignoreFail: flag('ignore-fail'), repeat: flag('repeat'), repeatLast: flag('repeat-last'),
      mainFirst: flag('main-first'), mainLast: flag('main-last'), sortTitle: flag('sort-title'),
    };
    const order = strings('title-order');
    const regex = strings('title-order-regex');
    if (order) options.titleOrder = order;
    if (regex) options.titleOrderRegex = regex;
    return options;
  }

  const fakeWindowGlobal = {};
  const underscore = makeUnderscore();

  function evaluate(text) {
    let fn;
    try {
      // eslint-disable-next-line no-new-func
      fn = new Function(...PARAMETERS, wrap(text));
    } catch (error) {
      report('error', `${error.name === 'SyntaxError' ? 'Syntax error' : 'Error'}: ${error.message}`, scriptLine(error.stack, offset));
      return false;
    }
    try {
      fn.call(fakeWindowGlobal, ...SHADOWED.map(() => undefined), slate, slate, underscore, fakeWindowGlobal);
      return true;
    } catch (error) {
      report('error', describeError(error), scriptLine(error?.stack, offset));
      return false;
    }
  }

  evaluate(source);
  loading = false;
  for (const name of Object.keys(configFunctions).sort()) {
    try {
      const value = settingValue(configFunctions[name]());
      if (value === undefined) report('error', `The function for config "${name}" returned something that isn't a string, number or boolean.`);
      else settings[name] = value;
    } catch (error) {
      report('error', `The function for config "${name}" threw: ${describeError(error)}`);
    }
  }

  /** Runs a binding on the pretend desktop: {action} when it converts, else {reason}. */
  const probeBinding = binding => {
    if (binding.action) return {action: binding.action};
    const kind = binding.operation[HIDDEN].kind;
    if (kind === 'syntax') return {reason: `uses Slate syntax that needs a newer Slated engine to read: "${binding.operation[HIDDEN].text}"`};
    if (kind === 'chain' || kind === 'sequence') return {reason: `has a ${kind} with JavaScript steps, which needs the script`};
    const runs = [];
    for (const handle of [1, 2]) {
      probe.active = true;
      probe.focused = handle;
      probe.recorded = [];
      probe.sideEffects = [];
      try {
        runOperation(binding.operation, handle);
      } catch (error) {
        probe.active = false;
        if (error instanceof ProbeError) return {reason: error.message};
        return {reason: `throws an error when it runs: ${describeError(error)}`};
      }
      probe.active = false;
      if (probe.sideEffects.length) {
        return {reason: `uses ${[...new Set(probe.sideEffects)].join(', ')}, which needs the script`};
      }
      runs.push(probe.recorded);
    }
    const [landscape, portrait] = runs;
    if (!landscape.length || !portrait.length) return {reason: "doesn't run an operation on a test window"};
    if (landscape.length > 1 || portrait.length > 1) return {reason: 'runs several operations at once, which needs the script'};
    if (deepEqual(landscape[0], portrait[0])) return {action: landscape[0]};
    return {action: {op: 'by-orientation', landscape: landscape[0], portrait: portrait[0]}};
  };

  return {bindings, layouts, defaults, settings, diagnostics, probe: probeBinding};
}

/**
 * Converts a Slate JavaScript config into Slated bindings.
 *
 * @returns {{bindings: Array, skipped: Array<{keystroke, reason}>, layouts: Array, settings: object,
 *   diagnostics: Array}}
 */
export function importSlateScript(source, options = {}) {
  const makeId = options.makeId ?? newId;
  const loaded = loadSlateScript(source, options);
  const bindings = [];
  const skipped = [];
  for (const binding of loaded.bindings) {
    const result = loaded.probe(binding);
    if (!result.action) {
      skipped.push({keystroke: binding.keystroke, reason: result.reason});
      continue;
    }
    const out = {id: makeId(), keys: binding.keys, action: result.action, enabled: true};
    if (binding.modal) out.modal = binding.modal;
    bindings.push(out);
  }
  for (const layout of loaded.layouts) {
    if (layout.javascript) skipped.push({keystroke: `layout "${layout.name}"`, reason: 'has operations that run JavaScript'});
  }
  const layouts = loaded.layouts.filter(l => !l.javascript).map(({javascript, ...rest}) => rest);
  // Like the macOS importer, display defaults (`slate.default`) stay in the script: only classic
  // .slate files contribute them.
  return {bindings, skipped, layouts, settings: loaded.settings, defaults: [], diagnostics: loaded.diagnostics};
}

/** A classic ~/.slate file through the engine: {bindings, layouts, settings, defaults, diagnostics}. */
export function importClassic(text, {path, home = '/home/user', readFile = () => null, makeId = newId} = {}) {
  const parsed = parseSlateConfig(text, {path, readFile: p => readFile(expandHome(p, home))});
  const bindings = (parsed.bindings ?? []).filter(b => b.enabled !== false).map(b => {
    const out = {id: makeId(), keys: keysString(b.keys), action: canonicalAction(b.action), enabled: true};
    if (b.modal) out.modal = {keys: keysString(b.modal.keys), toggle: b.modal.toggle === true};
    if (typeof b.repeats === 'boolean') out.repeats = b.repeats;
    return out;
  });
  return {
    bindings,
    skipped: [],
    layouts: parsed.layouts ?? [],
    settings: parsed.settings ?? {},
    defaults: parsed.defaults ?? [],
    diagnostics: parsed.diagnostics ?? [],
  };
}

/**
 * The configuration after importing the given sources (port of Engine.importSlateConfigs):
 * bindings whose keys Slated already uses are left out, the scripts' settings fill in what
 * config.json doesn't set, layouts are added by name, and when everything converted, Slate files
 * stop loading (they would only duplicate the imported bindings).
 *
 * @param {object} config the current configuration
 * @param {Array<{path: string, result: object}>} results importSlateScript/importClassic results
 */
export function planImport(config, results) {
  const next = JSON.parse(JSON.stringify(config));
  const bound = new Set(next.bindings.map(b => statusKey(b.keys, b.modal)));
  const added = [];
  const skipped = [];
  const duplicates = [];
  for (const {path, result} of results) {
    for (const binding of result.bindings) {
      const key = statusKey(binding.keys, binding.modal);
      if (bound.has(key)) {
        duplicates.push(key);
        continue;
      }
      bound.add(key);
      next.bindings.push(binding);
      added.push(binding);
    }
    skipped.push(...result.skipped.map(s => ({path, keystroke: s.keystroke, reason: s.reason})));
    next.settings = {...(result.settings ?? {}), ...next.settings};
    for (const layout of result.layouts ?? []) {
      if (!next.layouts.some(l => l.name === layout.name)) next.layouts.push(layout);
    }
    next.defaults = [...(next.defaults ?? []), ...(result.defaults ?? [])];
  }
  if (!skipped.length) next.general = {...next.general, loadSlateConfigs: false};
  return {config: next, added, skipped, duplicates, stopsLoading: !skipped.length};
}
