// What actions are called and where they put a window, as the macOS app shows them: a port of SlatedUI's
// WindowPresets (named placements), ActionDescriber.title, ActionKind.symbol and CheatSheet.region.
// The island's cheat sheet lists shortcuts by these names, so both platforms read the same.
// Pinned to Swift by fixtures/cheatsheet.json.

import {decodeAction, sequenceSteps} from './config.js';
import {targetFrame} from './frame.js';
import {displayKeyCombo} from './keys.js';
import {parseSyntheticInput} from './automation.js';
import {screenRefFromSlate} from './model.js';
import {graphemes, uppercased} from './text.js';

// --- Window presets ----------------------------------------------------------------------------------

const move = (x, y, width, height) => ({op: 'move', x, y, width, height});
const rect = (x, y, width, height) => ({x, y, width, height});

function preset(id, title, region, symbol, action, aliases = []) {
  return Object.freeze({id, title, region, symbol, action, aliases});
}

/** WindowPresets.all: the placements the binding editor offers, with the region its glyph shows. */
const PRESETS = [
  // Halves
  preset('left-half', 'Left Half', rect(0, 0, 0.5, 1), null, move('screenOriginX', 'screenOriginY', 'screenSizeX/2', 'screenSizeY'), [
    {op: 'push', direction: 'left', style: 'bar-resize:screenSizeX/2'},
  ]),
  preset('right-half', 'Right Half', rect(0.5, 0, 0.5, 1), null, move('screenOriginX+screenSizeX/2', 'screenOriginY', 'screenSizeX/2', 'screenSizeY'), [
    {op: 'push', direction: 'right', style: 'bar-resize:screenSizeX/2'},
  ]),
  preset('top-half', 'Top Half', rect(0, 0, 1, 0.5), null, move('screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY/2'), [
    {op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/2'},
  ]),
  preset('bottom-half', 'Bottom Half', rect(0, 0.5, 1, 0.5), null, move('screenOriginX', 'screenOriginY+screenSizeY/2', 'screenSizeX', 'screenSizeY/2'), [
    {op: 'push', direction: 'down', style: 'bar-resize:screenSizeY/2'},
  ]),
  // Quarters
  preset('top-left', 'Top Left', rect(0, 0, 0.5, 0.5), null, move('screenOriginX', 'screenOriginY', 'screenSizeX/2', 'screenSizeY/2'), [
    {op: 'corner', direction: 'top-left', width: 'screenSizeX/2', height: 'screenSizeY/2'},
  ]),
  preset('top-right', 'Top Right', rect(0.5, 0, 0.5, 0.5), null, move('screenOriginX+screenSizeX/2', 'screenOriginY', 'screenSizeX/2', 'screenSizeY/2'), [
    {op: 'corner', direction: 'top-right', width: 'screenSizeX/2', height: 'screenSizeY/2'},
  ]),
  preset('bottom-left', 'Bottom Left', rect(0, 0.5, 0.5, 0.5), null, move('screenOriginX', 'screenOriginY+screenSizeY/2', 'screenSizeX/2', 'screenSizeY/2'), [
    {op: 'corner', direction: 'bottom-left', width: 'screenSizeX/2', height: 'screenSizeY/2'},
  ]),
  preset('bottom-right', 'Bottom Right', rect(0.5, 0.5, 0.5, 0.5), null, move('screenOriginX+screenSizeX/2', 'screenOriginY+screenSizeY/2', 'screenSizeX/2', 'screenSizeY/2'), [
    {op: 'corner', direction: 'bottom-right', width: 'screenSizeX/2', height: 'screenSizeY/2'},
  ]),
  // Thirds
  preset('left-third', 'Left Third', rect(0, 0, 1 / 3, 1), null, move('screenOriginX', 'screenOriginY', 'screenSizeX/3', 'screenSizeY')),
  preset('center-third', 'Center Third', rect(1 / 3, 0, 1 / 3, 1), null, move('screenOriginX+screenSizeX/3', 'screenOriginY', 'screenSizeX/3', 'screenSizeY')),
  preset('right-third', 'Right Third', rect(2 / 3, 0, 1 / 3, 1), null, move('screenOriginX+screenSizeX*2/3', 'screenOriginY', 'screenSizeX/3', 'screenSizeY')),
  preset('left-two-thirds', 'Left Two Thirds', rect(0, 0, 2 / 3, 1), null, move('screenOriginX', 'screenOriginY', 'screenSizeX*2/3', 'screenSizeY')),
  // Slate configs commonly write the offset of a two-thirds span as "*1/3".
  preset('right-two-thirds', 'Right Two Thirds', rect(1 / 3, 0, 2 / 3, 1), null, move('screenOriginX+screenSizeX/3', 'screenOriginY', 'screenSizeX*2/3', 'screenSizeY'), [
    move('screenOriginX+screenSizeX*1/3', 'screenOriginY', 'screenSizeX*2/3', 'screenSizeY'),
  ]),
  // Center & fill
  preset('center', 'Center', rect(0.25, 0.22, 0.5, 0.56), null,
    move('screenOriginX+(screenSizeX-windowSizeX)/2', 'screenOriginY+(screenSizeY-windowSizeY)/2', 'windowSizeX', 'windowSizeY')),
  preset('center-large', 'Center Large', rect(1 / 6, 1 / 6, 2 / 3, 2 / 3), null,
    move('screenOriginX+screenSizeX/6', 'screenOriginY+screenSizeY/6', 'screenSizeX*2/3', 'screenSizeY*2/3')),
  preset('almost-maximize', 'Almost Maximize', rect(0.06, 0.06, 0.88, 0.88), null,
    move('screenOriginX+screenSizeX/20', 'screenOriginY+screenSizeY/20', 'screenSizeX*0.9', 'screenSizeY*0.9')),
  preset('maximize', 'Maximize', rect(0, 0, 1, 1), null, move('screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY'), [
    {op: 'corner', direction: 'top-left', width: 'screenSizeX', height: 'screenSizeY'},
  ]),
  // Displays
  preset('throw-next', 'Next Display', null, 'arrow.right.to.line.compact', {op: 'throw', screen: 'next'}),
  preset('throw-previous', 'Previous Display', null, 'arrow.left.to.line.compact', {op: 'throw', screen: 'previous'}),
  preset('throw-next-max', 'Next Display, Maximized', null, 'arrow.up.left.and.arrow.down.right',
    {op: 'throw', screen: 'next', width: 'screenSizeX', height: 'screenSizeY'}),
];

/**
 * Thirds that turn with the display (`by-orientation`): side by side on a landscape one, stacked on a
 * portrait one, named by position. The portrait half trades x for y and width for height.
 */
function turning(id, title) {
  const landscape = PRESETS.find((p) => p.id === id);
  const turn = (expression) => expression.replace(/[XY]/g, (c) => (c === 'X' ? 'Y' : 'X'));
  const pairs = [landscape.action, ...landscape.aliases]
    .filter((a) => a.op === 'move')
    .map((a) => ({op: 'by-orientation', landscape: a, portrait: move(turn(a.y), turn(a.x), turn(a.height), turn(a.width))}));
  return preset(id, title, landscape.region, landscape.symbol, pairs[0], pairs.slice(1));
}

const ORIENTATION = [
  turning('left-third', 'First Third'),
  turning('center-third', 'Middle Third'),
  turning('right-third', 'Last Third'),
  turning('left-two-thirds', 'First Two Thirds'),
  turning('right-two-thirds', 'Last Two Thirds'),
];

/** JSON with sorted keys: value equality of canonical actions, like Swift's `==`. */
function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${stable(value[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

const MATCHABLE = [...PRESETS, ...ORIENTATION].map((p) => ({preset: p, keys: [p.action, ...p.aliases].map(stable)}));

/** The canonical form of an action (any form config.json takes), or null if it isn't one. */
function canonical(action) {
  if (action === null || action === undefined) return null;
  try {
    return decodeAction(action);
  } catch {
    return null;
  }
}

/** WindowPresets.matching: the named placement an action is, if any ({id, title, region, symbol}). */
export function matchingPreset(action) {
  const a = canonical(action);
  if (!a) return null;
  const key = stable(a);
  return MATCHABLE.find((m) => m.keys.includes(key))?.preset ?? null;
}

// --- Symbols (SF Symbols; the GNOME island maps them to icon names) ----------------------------------

const KIND_SYMBOLS = {
  move: 'arrow.up.and.down.and.arrow.left.and.right',
  resize: 'arrow.up.left.and.arrow.down.right',
  push: 'arrow.left.to.line',
  nudge: 'arrow.right.circle',
  throw: 'rectangle.portrait.and.arrow.right',
  corner: 'arrow.up.left.square',
  chain: 'link',
  sequence: 'list.number',
  layout: 'rectangle.3.group',
  'by-orientation': 'rectangle.portrait.rotate',
  focus: 'scope',
  'focus-app': 'app.badge.checkmark',
  hint: 'character.cursor.ibeam',
  grid: 'square.grid.3x3',
  hide: 'eye.slash',
  show: 'eye',
  toggle: 'eye.trianglebadge.exclamationmark',
  switch: 'square.stack.3d.forward.dottedline',
  snapshot: 'camera.viewfinder',
  'activate-snapshot': 'clock.arrow.circlepath',
  'delete-snapshot': 'trash',
  undo: 'arrow.uturn.backward',
  'insert-text': 'text.insert',
  keystroke: 'keyboard',
  'open-url': 'link.circle',
  shell: 'terminal',
  relaunch: 'arrow.clockwise',
  'clipboard-history': 'list.clipboard',
  click: 'cursorarrow.click',
  press: 'hand.point.up.left',
  hold: 'hand.tap',
  repeat: 'repeat',
  wait: 'hourglass',
  'stop-automations': 'stop.circle',
};

/** The settings UI's symbol for an action: its preset's, else its kind's (`focus` with an app is its own kind). */
export function actionSymbol(action) {
  const a = canonical(action);
  if (!a) return null;
  const presetSymbol = matchingPreset(a)?.symbol;
  if (presetSymbol) return presetSymbol;
  return KIND_SYMBOLS[a.op === 'focus' && a.app !== undefined ? 'focus-app' : a.op] ?? null;
}

// --- Regions ---------------------------------------------------------------------------------------

const SAMPLE = {x: 0, y: 0, width: 1600, height: 1000};
const SAMPLE_SCREEN = {displayID: 1, name: 'Sample', frame: SAMPLE, visibleFrame: SAMPLE, isMain: true, scale: 1};
const SAMPLE_WINDOW = {x: 400, y: 250, width: 800, height: 500};

/** CGRect.intersection with the unit square, or null when empty (Swift's `nilIfEmpty`). */
function clipToUnit(r) {
  const x1 = Math.max(r.x, 0);
  const x2 = Math.min(r.x + r.width, 1);
  const y1 = Math.max(r.y, 0);
  const y2 = Math.min(r.y + r.height, 1);
  if (x1 > x2 || y1 > y2) return null;
  const clipped = {x: x1, y: y1, width: x2 - x1, height: y2 - y1};
  return clipped.width === 0 || clipped.height === 0 ? null : clipped;
}

/**
 * Where a window action puts the window, as fractions of the screen ({x, y, width, height}, top-left
 * origin), for the region glyph: a preset's region, else the frame it computes for a sample window
 * on a sample screen. Null for actions that don't place the window there (throws, focus…).
 */
export function actionRegion(action) {
  const a = canonical(action);
  if (!a) return null;
  return regionOf(a);
}

function regionOf(a) {
  const presetRegion = matchingPreset(a)?.region;
  if (presetRegion) return {...presetRegion};
  switch (a.op) {
    case 'by-orientation':
      return regionOf(a.landscape);
    case 'chain':
      return a.operations.length ? regionOf(a.operations[0]) : null;
    case 'move':
    case 'resize':
    case 'push':
    case 'corner': {
      let frame;
      try {
        frame = targetFrame(a, {frame: SAMPLE_WINDOW, screens: [SAMPLE_SCREEN]});
      } catch {
        return null;
      }
      if (!(frame.width > 0 && frame.height > 0)) return null;
      return clipToUnit({x: frame.x / SAMPLE.width, y: frame.y / SAMPLE.height, width: frame.width / SAMPLE.width, height: frame.height / SAMPLE.height});
    }
    default:
      return null;
  }
}

// --- Titles ----------------------------------------------------------------------------------------

const DIRECTION_TITLES = {left: 'Left', right: 'Right', up: 'Up', down: 'Down'};
const CORNER_TITLES = {'top-left': 'Top Left', 'top-right': 'Top Right', 'bottom-left': 'Bottom Left', 'bottom-right': 'Bottom Right'};

/** Swift's `capitalized` for the one-word raw values titles use ("left" → "Left"). */
const capitalized = (word) => {
  const [first = '', ...rest] = Array.from(String(word));
  return uppercased(first) + rest.join('').toLowerCase();
};

/** At most `max` characters, the last one an ellipsis when cut. */
export function truncateText(text, max) {
  const characters = graphemes(String(text));
  return characters.length <= max ? String(text) : `${characters.slice(0, max - 1).join('')}…`;
}

const singleLine = (text) => String(text).replaceAll('\n', ' ⏎ ');

/** printf's "%.1f": like toFixed(1), except that exact ties go to the even digit. */
function oneDecimal(value) {
  if (Number.isInteger(value * 4) && !Number.isInteger(value * 2)) {
    const tenths = value * 10;
    const down = Math.floor(tenths);
    return ((down % 2 === 0 ? down : down + 1) / 10).toFixed(1);
  }
  return value.toFixed(1);
}

/** "100 ms", "0.5 s"… as ActionDescriber.seconds: under a second in milliseconds. */
export function secondsTitle(value) {
  if (value < 1) return `${Math.round(value * 1000)} ms`;
  return Number.isInteger(value) ? `${value} s` : `${oneDecimal(value)} s`;
}

function screenName(screen) {
  const ref = screenRefFromSlate(String(screen));
  if (!ref) return String(screen);
  switch (ref.kind) {
    case 'index':
      return `Display ${BigInt(ref.index) + 1n}`;
    case 'ordered':
      return `Display ${BigInt(ref.index) + 1n} (left to right)`;
    case 'resolution':
      return `the ${ref.width}×${ref.height} Display`;
    case 'relative':
      if (ref.direction === 'up') return 'Display Above';
      if (ref.direction === 'down') return 'Display Below';
      return `${DIRECTION_TITLES[ref.direction]} Display`;
    case 'next':
      return 'Next Display';
    default:
      return 'Previous Display';
  }
}

function appsPhrase(selector) {
  if (selector === 'current') return 'Current App';
  if (selector === 'all') return 'All Apps';
  if (typeof selector === 'string' && selector.startsWith('all-but:')) return `All but ${selector.slice('all-but:'.length)}`;
  const apps = Array.isArray(selector) ? selector : [String(selector)];
  if (apps.length === 0) return 'Apps';
  return apps.length <= 2 ? apps.join(' & ') : `${apps[0]} & ${apps.length - 1} more`;
}

function inputTitle(raw) {
  const input = parseSyntheticInput(raw);
  if (!input) return String(raw);
  return input.kind === 'mouse' ? `${capitalized(input.button)} Button` : displayKeyCombo(input.combo);
}

/** Foundation's `URL(string:)?.host` for the URLs `open-url` takes: the authority's host, or null. */
function urlHost(url) {
  const match = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^/?#]*)/.exec(url);
  if (!match) return null;
  let host = match[1].slice(match[1].lastIndexOf('@') + 1);
  if (host.startsWith('[')) return host.slice(1, host.indexOf(']') === -1 ? undefined : host.indexOf(']'));
  host = host.replace(/:\d*$/, '');
  return host === '' ? null : host;
}

/**
 * A short title for an action, as the settings UI and the island name it: the preset's name when it
 * is a known placement ("Left Half"), otherwise a plain description ("Focus Safari", "Throw to Next
 * Display"). Accepts any form config.json takes.
 */
export function actionTitle(action) {
  const a = canonical(action);
  if (!a) return typeof action === 'string' ? action : 'Unknown Operation';
  return titleOf(a);
}

function titleOf(a) {
  const presetTitle = matchingPreset(a)?.title;
  if (presetTitle) return presetTitle;
  switch (a.op) {
    case 'move': {
      // Name a centered placement by its size ("Center, 50%"), which says what it does.
      const r = regionOf(a);
      if (r && Math.abs(r.x + r.width / 2 - 0.5) < 0.02 && Math.abs(r.y + r.height / 2 - 0.5) < 0.02) {
        const w = Math.round(r.width * 100);
        const h = Math.round(r.height * 100);
        if (w >= 99 && h >= 99) return 'Maximize';
        return w === h ? `Center, ${w}%` : `Center, ${w}% × ${h}%`;
      }
      return 'Move & Resize';
    }
    case 'resize':
      return `Resize ${a.width} × ${a.height}`;
    case 'push': {
      const direction = DIRECTION_TITLES[a.direction];
      if (a.style === 'bar') return `Push ${direction}, Full ${a.direction === 'up' || a.direction === 'down' ? 'Width' : 'Height'}`;
      if (a.style === 'center') return `Push ${direction}, Centered`;
      return `Push ${direction}`;
    }
    case 'nudge':
      return `Nudge ${a.x}, ${a.y}`;
    case 'throw':
      return `Throw to ${screenName(a.screen)}${a.width === undefined ? '' : ', Resized'}`;
    case 'corner':
      return `${CORNER_TITLES[a.direction]} Corner`;
    case 'chain':
      return a.operations.length === 0 ? 'Empty Chain' : `Cycle ${a.operations.slice(0, 3).map(titleOf).join(' → ')}`;
    case 'sequence': {
      const count = sequenceSteps(a).length;
      return count === 0 ? 'Empty Sequence' : `Sequence of ${count}`;
    }
    case 'layout':
      return a.name === '' ? 'Apply Layout' : `Layout “${a.name}”`;
    case 'by-orientation': {
      // Thirds that turn with the display are presets ("First Third"); anything else names both.
      const landscape = titleOf(a.landscape);
      const portrait = titleOf(a.portrait);
      return landscape === portrait ? landscape : `${landscape} / ${portrait}`;
    }
    case 'focus':
      if (a.app !== undefined) return a.app === '' ? 'Focus App' : `Focus ${a.app}`;
      return a.direction === 'behind' ? 'Focus Window Behind' : `Focus ${capitalized(a.direction)}`;
    case 'snapshot':
      return `Snapshot “${a.name}”`;
    case 'delete-snapshot':
      return `Delete Snapshot “${a.name}”`;
    case 'activate-snapshot':
      return `Restore Snapshot “${a.name}”`;
    case 'hint':
      return 'Window Hints';
    case 'grid':
      return 'Grid';
    case 'hide':
      return `Hide ${appsPhrase(a.app)}`;
    case 'show':
      return `Show ${appsPhrase(a.app)}`;
    case 'toggle':
      return `Toggle ${appsPhrase(a.app)}`;
    case 'shell':
      return a.command === '' ? 'Run Command' : `Run “${truncateText(a.command, 28)}”`;
    case 'undo':
      return 'Undo';
    case 'relaunch':
      return 'Reload Configuration';
    case 'switch':
      return 'App Switcher';
    case 'insert-text':
      return a.text === '' ? 'Insert Text' : `Insert “${truncateText(singleLine(a.text), 24)}”`;
    case 'open-url':
      return `Open ${urlHost(a.url) ?? truncateText(a.url, 28)}`;
    case 'keystroke':
      return `Press ${displayKeyCombo(a.keys)}`;
    case 'clipboard-history':
      return 'Clipboard History';
    case 'click': {
      const count = a.count ?? 1;
      const button = capitalized(a.button);
      if (count === 2) return `Double-Click ${button}`;
      return count > 2 ? `${count}× Click ${button}` : `Click ${button}`;
    }
    case 'press':
      return `${a.phase === 'down' ? 'Press' : 'Release'} ${inputTitle(a.input)}`;
    case 'hold':
      return `Hold ${inputTitle(a.input)}`;
    case 'repeat':
      return (
        `Repeat ${titleOf(a.action)} every ${secondsTitle(a.interval)}` +
        (a.mode === 'while-held' ? ' while held' : '') +
        (a.times === undefined ? '' : `, ${a.times}×`)
      );
    case 'wait':
      return `Wait ${secondsTitle(a.seconds)}`;
    case 'stop-automations':
      return 'Stop Automations';
    default:
      return a.op;
  }
}
