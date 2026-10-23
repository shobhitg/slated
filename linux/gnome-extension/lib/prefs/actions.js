// Actions as the editor sees them: one picker entry per kind (focus is split into a direction and an
// app, as on macOS), conversion between kinds that keeps compatible parameters (port of
// Sources/SlatedUI/Model/ActionForm.swift) and human-readable titles (ActionDescriber.swift).
//
// Actions are plain JSON objects exactly as in config.json ({"op": "push", "direction": "left"}).
// A bare string is Slate operation syntax; the editor shows it as text until the engine parses it.
//
// Pure ES module.

import {truncate, singleLine, isObject} from './util.js';
import {comboLabel} from './keys.js';
import {matchingPreset, defaultChain, defaultSequence} from './presets.js';
import {formatOperation, parseOperation, isNotImplemented} from './engine.js';

export const CATEGORIES = [
  {id: 'window', title: 'Window'},
  {id: 'combine', title: 'Combine'},
  {id: 'focus', title: 'Focus'},
  {id: 'apps', title: 'Apps'},
  {id: 'snapshots', title: 'Snapshots'},
  {id: 'automation', title: 'Automation'},
];

const kind = (id, category, title, icon, explanation) => Object.freeze({id, category, title, icon, explanation});

/** Every operation the editor offers, in picker order. Icon names are Adwaita symbolic icons. */
export const KINDS = Object.freeze([
  kind('move', 'window', 'Move & Resize', 'view-fullscreen-symbolic',
    'Place the window at an exact position and size. Expressions can use the screen and window size.'),
  kind('resize', 'window', 'Resize', 'zoom-fit-best-symbolic', 'Grow or shrink the window, keeping one corner fixed.'),
  kind('push', 'window', 'Push to Edge', 'go-first-symbolic',
    'Slide the window against a screen edge, optionally stretching it along that edge.'),
  kind('nudge', 'window', 'Nudge', 'go-next-symbolic', 'Move the window by a small amount without resizing it.'),
  kind('throw', 'window', 'Throw to Screen', 'send-to-symbolic', 'Send the window to another display.'),
  kind('corner', 'window', 'Corner', 'view-restore-symbolic', 'Snap the window into a corner, optionally resizing it.'),
  kind('chain', 'combine', 'Chain', 'insert-link-symbolic',
    'Each press runs the next operation, then wraps around — great for cycling sizes.'),
  kind('sequence', 'combine', 'Sequence', 'view-list-ordered-symbolic', 'Run several operations in order with one shortcut.'),
  kind('layout', 'combine', 'Apply Layout', 'view-dual-symbolic', "Arrange several apps' windows at once."),
  kind('by-orientation', 'combine', 'By Screen Orientation', 'object-rotate-right-symbolic',
    'Do one thing on landscape displays and another on portrait ones — thirds side by side or stacked, say.'),
  kind('focus', 'focus', 'Focus Direction', 'find-location-symbolic', 'Focus the nearest window in a direction.'),
  kind('focus-app', 'focus', 'Focus App', 'view-app-grid-symbolic', 'Bring an app to the front.'),
  kind('hint', 'focus', 'Window Hints', 'edit-find-symbolic', 'Show a letter over every window; type it to focus that window.'),
  kind('grid', 'focus', 'Grid', 'view-grid-symbolic', "Show a grid over each screen and drag out the window's new frame."),
  kind('hide', 'apps', 'Hide Apps', 'view-conceal-symbolic', 'Hide the current app, all apps, or a list of apps.'),
  kind('show', 'apps', 'Show Apps', 'view-reveal-symbolic', 'Unhide apps.'),
  kind('toggle', 'apps', 'Toggle Apps', 'object-flip-horizontal-symbolic',
    'Hide apps that are visible and show apps that are hidden.'),
  kind('switch', 'apps', 'App Switcher', 'application-x-executable-symbolic',
    "Slate's app switcher. Slated recognizes it but doesn't run it yet."),
  kind('snapshot', 'snapshots', 'Take Snapshot', 'camera-photo-symbolic', 'Remember where every window is, to restore later.'),
  kind('activate-snapshot', 'snapshots', 'Restore Snapshot', 'document-revert-symbolic',
    'Put windows back where a snapshot saw them.'),
  kind('delete-snapshot', 'snapshots', 'Delete Snapshot', 'user-trash-symbolic', 'Forget a snapshot.'),
  kind('undo', 'snapshots', 'Undo', 'edit-undo-symbolic', 'Put the last moved window back where it was.'),
  kind('insert-text', 'automation', 'Insert Text', 'insert-text-symbolic', 'Type or paste text into the focused app.'),
  kind('keystroke', 'automation', 'Press Keys', 'input-keyboard-symbolic', 'Send a keyboard shortcut to the focused app.'),
  kind('open-url', 'automation', 'Open URL', 'web-browser-symbolic', 'Open a link or app URL scheme.'),
  kind('shell', 'automation', 'Run Shell Command', 'utilities-terminal-symbolic', 'Run a command in the background.'),
  kind('relaunch', 'automation', 'Reload Configuration', 'view-refresh-symbolic', 'Reload config.json and your Slate files.'),
]);

/** Pseudo-kind for Slate operation syntax the engine can't parse yet; edited as text. */
export const SYNTAX_KIND = kind('syntax', 'automation', 'Slate Operation', 'text-x-generic-symbolic',
  'An operation in Slate syntax, for example "push left bar-resize:screenSizeX/2".');

export function kindById(id) {
  if (id === 'syntax') return SYNTAX_KIND;
  if (id === 'unknown') return UNKNOWN_KIND;
  return KINDS.find(k => k.id === id) ?? null;
}

export function kindsInCategory(categoryId) {
  return KINDS.filter(k => k.category === categoryId);
}

/** Pseudo-kind for an object whose "op" Slated doesn't know (kept unchanged until replaced). */
export const UNKNOWN_KIND = kind('unknown', 'automation', 'Unknown Operation', 'dialog-question-symbolic',
  "Slated doesn't know this operation. Pick another one to replace it.");

/** The picker kind of an action. */
export function kindOf(action) {
  if (typeof action === 'string') return 'syntax';
  if (!isObject(action)) return 'unknown';
  if (action.op === 'focus' && typeof action.app === 'string') return 'focus-app';
  return KINDS.some(k => k.id === action.op) ? action.op : 'unknown';
}

/** The action itself when it's an object, else the engine's parse of the Slate string (or null). */
export function resolveAction(action) {
  if (isObject(action)) return action;
  if (typeof action !== 'string') return null;
  try {
    return parseOperation(action);
  } catch {
    return null;
  }
}

const GEOMETRY = new Set(['move', 'resize', 'push', 'nudge', 'throw', 'corner']);

/** True for actions that move or resize the focused window. */
export function isWindowGeometry(action) {
  const a = resolveAction(action);
  if (!a) return false;
  if (a.op === 'by-orientation') return isWindowGeometry(a.landscape) && isWindowGeometry(a.portrait);
  return GEOMETRY.has(a.op);
}

export function isGeometryKind(kindId) {
  return GEOMETRY.has(kindId);
}

// --- Forms: switching kinds while keeping compatible parameters ----------------------------------------

const move = (x, y, width, height) => ({op: 'move', x, y, width, height});

/** A flat view of every parameter any operation can have, with the editor's defaults. */
export function defaultForm() {
  return {
    kind: 'move',
    x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY',
    resizes: false, screen: null,
    resizeWidth: '+10%', resizeHeight: '+0', anchor: 'top-left',
    direction: 'left', pushStyle: 'bar-resize:screenSizeX/2',
    nudgeX: '+10%', nudgeY: '+0',
    throwScreen: 'next',
    corner: 'top-left',
    operations: defaultChain(),
    steps: defaultSequence().map(action => ({action, keepWindow: false})),
    landscape: move('screenOriginX', 'screenOriginY', 'screenSizeX/3', 'screenSizeY'),
    portrait: move('screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY/3'),
    name: '',
    snapshotName: 'main', save: false, stack: false, all: false, delete: false,
    focusDirection: 'left', app: '',
    hintCharacters: '', gridPadding: 0, grids: [],
    appSelector: 'current',
    command: '', wait: false, workingDirectory: '',
    text: '', method: 'auto', url: 'https://', keys: 'cmd+shift+4',
    syntax: '',
  };
}

/** The form for an action. */
export function formFromAction(action) {
  const form = defaultForm();
  form.kind = kindOf(action);
  if (form.kind === 'syntax') {
    form.syntax = action;
    return form;
  }
  if (form.kind === 'unknown') {
    form.raw = action;
    return form;
  }
  const a = action;
  switch (a.op) {
  case 'move':
    Object.assign(form, {x: a.x, y: a.y, width: a.width, height: a.height, screen: a.screen ?? null});
    break;
  case 'resize':
    Object.assign(form, {resizeWidth: a.width ?? '+0', resizeHeight: a.height ?? '+0', anchor: a.anchor ?? 'top-left'});
    break;
  case 'push':
    Object.assign(form, {direction: a.direction, pushStyle: a.style ?? 'none', screen: a.screen ?? null});
    break;
  case 'nudge':
    Object.assign(form, {nudgeX: a.x ?? '+0', nudgeY: a.y ?? '+0'});
    break;
  case 'throw':
    form.throwScreen = a.screen ?? 'next';
    if (a.width !== undefined && a.height !== undefined) Object.assign(form, {width: a.width, height: a.height, resizes: true});
    break;
  case 'corner':
    Object.assign(form, {corner: a.direction, screen: a.screen ?? null});
    if (a.width !== undefined && a.height !== undefined) Object.assign(form, {width: a.width, height: a.height, resizes: true});
    break;
  case 'chain':
    form.operations = a.operations ?? [];
    break;
  case 'sequence':
    form.steps = a.steps ?? (a.operations ?? []).map(op => ({action: op, keepWindow: false}));
    break;
  case 'layout':
    form.name = a.name ?? '';
    break;
  case 'by-orientation':
    Object.assign(form, {landscape: a.landscape, portrait: a.portrait});
    break;
  case 'focus':
    if (typeof a.app === 'string') form.app = a.app;
    else form.focusDirection = a.direction ?? 'left';
    break;
  case 'snapshot':
    Object.assign(form, {snapshotName: a.name ?? '', save: !!a.save, stack: !!a.stack});
    break;
  case 'delete-snapshot':
    Object.assign(form, {snapshotName: a.name ?? '', all: !!a.all});
    break;
  case 'activate-snapshot':
    Object.assign(form, {snapshotName: a.name ?? '', delete: !!a.delete});
    break;
  case 'hint':
    form.hintCharacters = a.characters ?? '';
    break;
  case 'grid':
    form.gridPadding = a.padding ?? 0;
    form.grids = Object.keys(a.grids ?? {}).sort().map(screen => ({screen, ...a.grids[screen]}));
    break;
  case 'hide': case 'show': case 'toggle':
    form.appSelector = a.app ?? 'current';
    break;
  case 'shell':
    Object.assign(form, {command: a.command ?? '', wait: !!a.wait, workingDirectory: a.path ?? ''});
    break;
  case 'insert-text':
    Object.assign(form, {text: a.text ?? '', method: a.method ?? 'auto'});
    break;
  case 'open-url':
    form.url = a.url ?? '';
    break;
  case 'keystroke':
    form.keys = typeof a.keys === 'string' ? a.keys : form.keys;
    break;
  default:
    break;
  }
  return form;
}

/** The action a form describes, in canonical shape (defaults left out). */
export function actionFromForm(form) {
  const withScreen = (action, screen) => (screen ? {...action, screen} : action);
  switch (form.kind) {
  case 'move': return withScreen(move(form.x, form.y, form.width, form.height), form.screen);
  case 'resize': {
    const action = {op: 'resize', width: form.resizeWidth, height: form.resizeHeight};
    if (form.anchor && form.anchor !== 'top-left') action.anchor = form.anchor;
    return action;
  }
  case 'push': {
    const action = {op: 'push', direction: form.direction};
    if (form.pushStyle && form.pushStyle !== 'none') action.style = form.pushStyle;
    return withScreen(action, form.screen);
  }
  case 'nudge': return {op: 'nudge', x: form.nudgeX, y: form.nudgeY};
  case 'throw': {
    const action = {op: 'throw', screen: form.throwScreen || 'next'};
    if (form.resizes) Object.assign(action, {width: form.width, height: form.height});
    return action;
  }
  case 'corner': {
    const action = {op: 'corner', direction: form.corner};
    if (form.resizes) Object.assign(action, {width: form.width, height: form.height});
    return withScreen(action, form.screen);
  }
  case 'chain': return {op: 'chain', operations: form.operations};
  case 'sequence':
    return form.steps.every(step => !step.keepWindow)
      ? {op: 'sequence', operations: form.steps.map(step => step.action)}
      : {op: 'sequence', steps: form.steps};
  case 'layout': return {op: 'layout', name: form.name};
  case 'by-orientation': return {op: 'by-orientation', landscape: form.landscape, portrait: form.portrait};
  case 'focus': return {op: 'focus', direction: form.focusDirection};
  case 'focus-app': return {op: 'focus', app: form.app};
  case 'hint': return form.hintCharacters ? {op: 'hint', characters: form.hintCharacters} : {op: 'hint'};
  case 'grid': {
    const action = {op: 'grid'};
    if (form.gridPadding) action.padding = form.gridPadding;
    if (form.grids.length) {
      action.grids = Object.fromEntries(form.grids.map(g => [g.screen, {width: g.width, height: g.height}]));
    }
    return action;
  }
  case 'hide': case 'show': case 'toggle': return {op: form.kind, app: form.appSelector};
  case 'switch': return {op: 'switch'};
  case 'snapshot': {
    const action = {op: 'snapshot', name: form.snapshotName};
    if (form.save) action.save = true;
    if (form.stack) action.stack = true;
    return action;
  }
  case 'activate-snapshot': {
    const action = {op: 'activate-snapshot', name: form.snapshotName};
    if (form.delete) action.delete = true;
    return action;
  }
  case 'delete-snapshot': {
    const action = {op: 'delete-snapshot', name: form.snapshotName};
    if (form.all) action.all = true;
    return action;
  }
  case 'undo': return {op: 'undo'};
  case 'insert-text': {
    const action = {op: 'insert-text', text: form.text};
    if (form.method && form.method !== 'auto') action.method = form.method;
    return action;
  }
  case 'keystroke': return {op: 'keystroke', keys: form.keys};
  case 'open-url': return {op: 'open-url', url: form.url};
  case 'shell': {
    const action = {op: 'shell', command: form.command};
    if (form.wait) action.wait = true;
    if (form.workingDirectory) action.path = form.workingDirectory;
    return action;
  }
  case 'relaunch': return {op: 'relaunch'};
  case 'syntax': return form.syntax;
  case 'unknown': return form.raw;
  default: throw new Error(`Unknown kind "${form.kind}"`);
  }
}

/** Returns a copy of `action` with one form field changed. */
export function updateAction(action, field, value) {
  const form = formFromAction(action);
  form[field] = value;
  return actionFromForm(form);
}

/**
 * `action` converted to another kind, keeping whatever parameters carry over (port of
 * ActionForm.convert and ActionEditor.converted).
 */
export function convertAction(action, kindId, {knownLayouts = []} = {}) {
  const form = formFromAction(action);
  const wasGeometry = isWindowGeometry(action);
  const previousKind = form.kind;
  form.kind = kindId;
  // A Move always has a size; keep it when it becomes a Corner (a Throw stays a plain throw).
  if (kindId === 'corner' && previousKind === 'move') form.resizes = true;
  // A placement becomes both branches, ready to adjust one of them.
  if (kindId === 'by-orientation' && wasGeometry && previousKind !== 'by-orientation') {
    form.landscape = action;
    form.portrait = action;
  }
  if (kindId === 'layout' && !form.name && knownLayouts.length) form.name = [...knownLayouts].sort()[0];
  if (kindId === 'syntax') form.syntax = describeSyntax(action);
  return actionFromForm(form);
}

function describeSyntax(action) {
  if (typeof action === 'string') return action;
  return formatOperation(action) ?? localDetail(action);
}

// --- Titles and details ---------------------------------------------------------------------------------

const DIRECTION_TITLES = {left: 'Left', right: 'Right', up: 'Up', down: 'Down'};
const CORNER_TITLES = {'top-left': 'Top Left', 'top-right': 'Top Right', 'bottom-left': 'Bottom Left', 'bottom-right': 'Bottom Right'};

/** "Display 1", "Next Display", "Display on the Left"… for a screen reference string. */
export function screenName(ref) {
  const s = String(ref ?? '');
  if (/^-?\d+$/.test(s)) return `Display ${parseInt(s, 10) + 1}`;
  const ordered = /^ordered:(-?\d+)$/.exec(s);
  if (ordered) return `Display ${parseInt(ordered[1], 10) + 1} (left to right)`;
  const res = /^(\d+)x(\d+)$/.exec(s);
  if (res) return `the ${res[1]}×${res[2]} Display`;
  switch (s) {
  case 'left': return 'Display on the Left';
  case 'right': return 'Display on the Right';
  case 'up': return 'Display Above';
  case 'down': return 'Display Below';
  case 'next': return 'Next Display';
  case 'previous': return 'Previous Display';
  default: return s || "the Window's Display";
  }
}

/** "Current App", "All Apps", "All but Firefox", "Firefox & Files", "Firefox & 2 more". */
export function appsPhrase(selector) {
  if (selector === 'current') return 'Current App';
  if (selector === 'all') return 'All Apps';
  if (typeof selector === 'string' && selector.startsWith('all-but:')) return `All but ${selector.slice(8)}`;
  const apps = Array.isArray(selector) ? selector : [];
  if (!apps.length) return 'Apps';
  return apps.length <= 2 ? apps.join(' & ') : `${apps[0]} & ${apps.length - 1} more`;
}

function urlHost(url) {
  const m = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i.exec(String(url ?? ''));
  return m ? m[1] : null;
}

/** A short title: the preset name for known placements, else a plain description. */
export function actionTitle(action) {
  if (typeof action === 'string') {
    const parsed = resolveAction(action);
    return parsed ? actionTitle(parsed) : `Slate: ${truncate(action, 28)}`;
  }
  if (!isObject(action)) return 'Unknown Action';
  const preset = matchingPreset(action);
  if (preset) return preset.title;
  const a = action;
  switch (a.op) {
  case 'move': return 'Move & Resize';
  case 'resize': return `Resize ${a.width ?? '+0'} × ${a.height ?? '+0'}`;
  case 'push': {
    const d = DIRECTION_TITLES[a.direction] ?? a.direction;
    if (a.style === 'bar') return `Push ${d}, Full ${a.direction === 'up' || a.direction === 'down' ? 'Width' : 'Height'}`;
    if (a.style === 'center') return `Push ${d}, Centered`;
    return `Push ${d}`;
  }
  case 'nudge': return `Nudge ${a.x ?? '+0'}, ${a.y ?? '+0'}`;
  case 'throw': return `Throw to ${screenName(a.screen)}${a.width === undefined ? '' : ', Resized'}`;
  case 'corner': return `${CORNER_TITLES[a.direction] ?? a.direction} Corner`;
  case 'chain': {
    const ops = a.operations ?? [];
    return ops.length ? `Cycle ${ops.slice(0, 3).map(actionTitle).join(' → ')}` : 'Empty Chain';
  }
  case 'sequence': {
    const n = (a.steps ?? a.operations ?? []).length;
    return n ? `Sequence of ${n}` : 'Empty Sequence';
  }
  case 'layout': return a.name ? `Layout “${a.name}”` : 'Apply Layout';
  case 'by-orientation': return `${actionTitle(a.landscape)} / ${actionTitle(a.portrait)}`;
  case 'focus':
    if (typeof a.app === 'string') return a.app ? `Focus ${a.app}` : 'Focus App';
    return a.direction === 'behind' ? 'Focus Window Behind' : `Focus ${DIRECTION_TITLES[a.direction] ?? a.direction}`;
  case 'snapshot': return `Snapshot “${a.name}”`;
  case 'delete-snapshot': return `Delete Snapshot “${a.name}”`;
  case 'activate-snapshot': return `Restore Snapshot “${a.name}”`;
  case 'hint': return 'Window Hints';
  case 'grid': return 'Grid';
  case 'hide': return `Hide ${appsPhrase(a.app)}`;
  case 'show': return `Show ${appsPhrase(a.app)}`;
  case 'toggle': return `Toggle ${appsPhrase(a.app)}`;
  case 'shell': return a.command ? `Run “${truncate(a.command, 28)}”` : 'Run Command';
  case 'undo': return 'Undo';
  case 'relaunch': return 'Reload Configuration';
  case 'switch': return 'App Switcher';
  case 'insert-text': return a.text ? `Insert “${truncate(singleLine(a.text), 24)}”` : 'Insert Text';
  case 'open-url': return `Open ${urlHost(a.url) ?? truncate(a.url ?? '', 28)}`;
  case 'keystroke': return `Press ${comboLabel(a.keys)}`;
  default: return `Unknown “${a.op}”`;
  }
}

/** Slate syntax for secondary text: the engine's formatting, else a local approximation. */
export function actionDetail(action) {
  if (typeof action === 'string') return action;
  if (!isObject(action)) return '';
  try {
    const formatted = formatOperation(action);
    if (formatted && formatted !== action.op) return formatted;
  } catch (error) {
    if (!isNotImplemented(error)) return localDetail(action);
  }
  return localDetail(action);
}

function selectorSyntax(selector) {
  if (selector === 'current' || selector === 'all') return selector;
  if (typeof selector === 'string' && selector.startsWith('all-but:')) return `all-but:'${selector.slice(8)}'`;
  return (Array.isArray(selector) ? selector : []).map(app => `'${app}'`).join(' ');
}

/** Port of ActionDescriber.localDetail: Slate-like syntax without the engine. */
export function localDetail(a) {
  if (typeof a === 'string') return a;
  if (!isObject(a)) return '';
  const screen = s => (s === undefined || s === null ? '' : ` ${s}`);
  switch (a.op) {
  case 'move': return `move ${a.x};${a.y} ${a.width};${a.height}${screen(a.screen)}`;
  case 'resize': return `resize ${a.width ?? '+0'} ${a.height ?? '+0'}${a.anchor && a.anchor !== 'top-left' ? ` ${a.anchor}` : ''}`;
  case 'push': return `push ${a.direction}${a.style && a.style !== 'none' ? ` ${a.style}` : ''}${screen(a.screen)}`;
  case 'nudge': return `nudge ${a.x ?? '+0'} ${a.y ?? '+0'}`;
  case 'throw': return `throw ${a.screen}${a.width !== undefined ? ` ${a.width};${a.height ?? ''}` : ''}`;
  case 'corner':
    return `corner ${a.direction}${a.width !== undefined ? ` resize:${a.width};${a.height ?? ''}` : ''}${screen(a.screen)}`;
  case 'chain': return (a.operations ?? []).map(op => (isObject(op) ? op.op : op)).join(' | ');
  case 'sequence': {
    const steps = a.steps ?? (a.operations ?? []).map(action => ({action, keepWindow: false}));
    return steps.map((step, i) => `${i === 0 ? '' : step.keepWindow ? '> ' : '| '}${isObject(step.action) ? step.action.op : step.action}`).join(' ');
  }
  case 'layout': return `layout ${a.name}`;
  case 'by-orientation': return `landscape: ${localDetail(a.landscape)} · portrait: ${localDetail(a.portrait)}`;
  case 'focus': return typeof a.app === 'string' ? `focus '${a.app}'` : `focus ${a.direction}`;
  case 'snapshot': return `snapshot ${a.name}${a.save ? ' save-to-disk' : ''}${a.stack ? ' stack' : ''}`;
  case 'delete-snapshot': return `delete ${a.name}${a.all ? ' all' : ''}`;
  case 'activate-snapshot': return `activate-snapshot ${a.name}${a.delete ? ' delete' : ''}`;
  case 'hint': return `hint${a.characters ? ` ${a.characters}` : ''}`;
  case 'grid': {
    const grids = Object.keys(a.grids ?? {}).sort().map(k => ` ${k}:${a.grids[k].width},${a.grids[k].height}`).join('');
    return `grid${a.padding !== undefined ? ` padding:${a.padding}` : ''}${grids}`;
  }
  case 'hide': case 'show': case 'toggle': return `${a.op} ${selectorSyntax(a.app)}`;
  case 'shell': return `shell${a.wait ? ' wait' : ''} '${a.command}'`;
  case 'insert-text': return `insert-text${a.method && a.method !== 'auto' ? ` (${a.method})` : ''} “${truncate(singleLine(a.text ?? ''), 40)}”`;
  case 'open-url': return a.url ?? '';
  case 'keystroke': return `keystroke ${a.keys}`;
  default: return a.op ?? '';
  }
}

/** The display title of a binding: its name, else the action's title. */
export function bindingTitle(binding) {
  const name = typeof binding?.name === 'string' ? binding.name.trim() : '';
  return name || actionTitle(binding?.action);
}

/** Secondary text for list rows: what the action is, without repeating the title. */
export function bindingSubtitle(binding) {
  const title = bindingTitle(binding);
  const action = actionTitle(binding?.action);
  if (action !== title) return action;
  const k = kindById(kindOf(binding?.action));
  if (!k) return '';
  if (k.title !== title) return k.title;
  return CATEGORIES.find(c => c.id === k.category)?.title ?? '';
}

/** Extra items for the "Add step" menu of chains and sequences, after the presets. */
export const EXTRA_STEPS = [
  {title: 'Focus Window to the Left', action: {op: 'focus', direction: 'left'}},
  {title: 'Focus App…', action: {op: 'focus', app: ''}},
  {title: 'Undo', action: {op: 'undo'}},
];
