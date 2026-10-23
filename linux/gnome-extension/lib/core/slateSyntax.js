// Slate's operation and keystroke syntax (port of SlateSyntax.swift, SlateOperationParser.swift and
// SlateOperationFormatter.swift).
//
// `parseOperation("push left bar-resize:screenSizeX/2")` returns the canonical Action JSON
// ({op: "push", direction: "left", style: "bar-resize:screenSizeX/2"}); `formatOperation` turns an
// action back into canonical Slate syntax. Differences from Slate, as in Swift: any amount of
// whitespace between parameters, `|`/`>` need no surrounding spaces, expressions are checked when
// parsing, unknown options are errors, operation names are case-insensitive.

import {formatSyntheticInput, MOUSE_BUTTONS, parseSyntheticInput, PRESS_PHASES, REPEAT_MODES} from './automation.js';
import {decodeAction, sequenceAction, sequenceSteps, sortedGridKeys} from './config.js';
import {invalidExpression, invalidSyntax, SlatedError, unknownOperation} from './errors.js';
import {validateExpression} from './expression.js';
import {formatKeyCombo, isValidKey, modifierMask, modifiersFromMask, parseKeyCombo, canonicalKey} from './keys.js';
import {
  CORNERS,
  directionFromSlate,
  dropFirst,
  dropLast,
  focusDirectionFromSlate,
  GRID_ORDER,
  INSERT_METHODS,
  pushStyleFromSlate,
  screenRefFromSlate,
  screenRefToSlate,
  splitCharacters,
} from './model.js';
import {quote, quoteIfNeeded, split, tokenize, unquote} from './tokenizer.js';
import {
  graphemes,
  hasPrefix,
  hasSuffix,
  isWhitespace,
  lowercased,
  parseDouble,
  parseInt64,
  shortNumber,
  stringEquals,
  trimWhitespace,
  trimWhitespaceAndNewlines,
} from './text.js';

const USAGE = {
  move: 'move x;y width;height [screen]',
  resize: 'resize width height [anchor]',
  push: 'push direction [none|center|bar|bar-resize:expression] [screen]',
  nudge: 'nudge x y',
  throw: 'throw screen [resize|resize:width;height]',
  corner: 'corner top-left|top-right|bottom-left|bottom-right [resize:width;height] [screen]',
  chain: 'chain operation | operation …',
  sequence: 'sequence operation | operation > operation …',
  layout: 'layout name',
  focus: "focus left|right|up|down|behind|'App Name'",
  snapshot: 'snapshot name [save-to-disk;stack]',
  'delete-snapshot': 'delete-snapshot name [all]',
  'activate-snapshot': 'activate-snapshot name [delete]',
  grid: 'grid [padding:n] [screen:width,height …]',
  hide: "hide 'App','Other App' | current | all | all-but:'App'",
  show: "show 'App','Other App' | current | all | all-but:'App'",
  toggle: "toggle 'App','Other App' | current | all | all-but:'App'",
  shell: "shell [wait] [path:~/dir] 'command'",
  'insert-text': "insert-text [type|paste] 'text'",
  'open-url': "open-url 'https://…'",
  keystroke: 'keystroke cmd+shift+4',
};

/**
 * Parses one operation string, e.g. "push left bar-resize:screenSizeX/2",
 * "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 1", "chain push up | push down".
 * @returns {Object} the canonical Action
 * @throws {SlatedError} invalidSyntax, invalidExpression or unknownOperation
 */
export function parseOperation(string) {
  const trimmed = trimWhitespaceAndNewlines(String(string));
  if (trimmed === '') throw invalidSyntax('The operation is empty');
  const chars = graphemes(trimmed);
  let end = chars.findIndex(isWhitespace);
  if (end < 0) end = chars.length;
  return new OperationParser(trimmed, chars.slice(0, end).join(''), trimWhitespaceAndNewlines(chars.slice(end).join(''))).parse();
}

class OperationParser {
  constructor(operation, name, args) {
    this.operation = operation;
    this.name = name;
    this.args = args;
    this.kind = lowercased(name);
  }

  parse() {
    switch (this.kind) {
      case 'move': return this.move();
      case 'resize': return this.resize();
      case 'push': return this.push();
      case 'nudge': return this.nudge();
      case 'throw': return this.throwWindow();
      case 'corner': return this.corner();
      case 'chain': return {op: 'chain', operations: this.pieces('|').map((p) => parseOperation(p.text))};
      case 'sequence':
        return sequenceAction(this.pieces('|>').map((p) => ({action: parseOperation(p.text), keepWindow: p.separator === '>'})));
      case 'layout': return this.layout();
      case 'focus': return this.focus();
      case 'snapshot': case 'delete-snapshot': case 'activate-snapshot': return this.snapshot();
      case 'hint': return this.args === '' ? {op: 'hint'} : {op: 'hint', characters: unquote(this.args)};
      case 'grid': return this.grid();
      case 'hide': case 'show': case 'toggle': return this.visibility();
      case 'shell': return this.shell();
      case 'undo': return this.bare('undo');
      case 'relaunch': return this.bare('relaunch');
      // Slate's switcher took key options (back:, quit:, …); they are accepted and dropped.
      case 'switch': return {op: 'switch'};
      case 'by-orientation': return this.byOrientation();
      case 'insert-text': return this.insertText();
      case 'open-url': return this.openURL();
      case 'keystroke': return this.keystroke();
      case 'click': return this.click();
      case 'press': return this.press();
      case 'hold': return this.hold();
      case 'repeat': return this.repeat();
      case 'wait': return this.wait();
      case 'stop-automations': return this.bare('stop-automations');
      case 'clipboard-history': return this.bare('clipboard-history');
      default: throw unknownOperation(this.name);
    }
  }

  // --- Window geometry -------------------------------------------------------------------------------

  move() {
    const words = this.tokens();
    this.expect(words, 2, 3);
    const [x, y] = this.pair(words[0].text, 'position');
    const [width, height] = this.pair(words[1].text, 'size');
    const screen = words.length === 3 ? this.screenRef(words[2]) : undefined;
    for (const e of [x, y, width, height]) validateExpression(e);
    const action = {op: 'move', x, y, width, height};
    if (screen !== undefined) action.screen = screen;
    return action;
  }

  resize() {
    const words = this.tokens();
    this.expect(words, 2, 3);
    let anchor = 'top-left';
    if (words.length === 3) {
      anchor = lowercased(words[2].text);
      if (!CORNERS.includes(anchor)) {
        throw this.fail(`Unknown anchor "${words[2].text}"`, 'use top-left, top-right, bottom-left or bottom-right');
      }
    }
    validateResizeAmount(words[0].text);
    validateResizeAmount(words[1].text);
    const action = {op: 'resize', width: words[0].text, height: words[1].text};
    if (anchor !== 'top-left') action.anchor = anchor;
    return action;
  }

  push() {
    const words = this.tokens();
    this.expect(words, 1, 3);
    const direction = directionFromSlate(words[0].text);
    if (direction === null) throw this.fail(`Unknown direction "${words[0].text}"`, 'use up, down, left or right');
    let style = 'none';
    let screen;
    if (words.length >= 2) {
      const parsed = pushStyleFromSlate(words[1].text);
      if (parsed !== null) {
        style = parsed;
      } else if (words.length === 2 && screenRefFromSlate(words[1].text) !== null) {
        screen = screenRefToSlate(screenRefFromSlate(words[1].text)); // `push up 1`
      } else {
        throw this.fail(`Unknown push style "${words[1].text}"`, 'use none, center, bar or bar-resize:expression');
      }
    }
    if (words.length === 3) screen = this.screenRef(words[2]);
    if (style.startsWith('bar-resize:')) {
      const expression = style.slice('bar-resize:'.length);
      if (trimWhitespace(expression) === '') throw this.fail('bar-resize needs an expression', 'like bar-resize:screenSizeX/2');
      validateExpression(expression);
    }
    const action = {op: 'push', direction};
    if (style !== 'none') action.style = style;
    if (screen !== undefined) action.screen = screen;
    return action;
  }

  nudge() {
    const words = this.tokens();
    this.expect(words, 2, 2);
    validateNudgeAmount(words[0].text);
    validateNudgeAmount(words[1].text);
    return {op: 'nudge', x: words[0].text, y: words[1].text};
  }

  throwWindow() {
    const words = this.tokens();
    this.expect(words, 1, 2);
    const screen = this.screenRef(words[0]);
    let width;
    let height;
    if (words.length === 2) {
      const style = words[1].text;
      const lower = lowercased(style);
      if (lower === 'resize') {
        [width, height] = ['screenSizeX', 'screenSizeY'];
      } else if (lower !== 'noresize') {
        if (!hasPrefix(lower, 'resize:')) {
          throw this.fail(`Unknown throw style "${style}"`, 'use resize, resize:width;height or noresize');
        }
        [width, height] = this.pair(dropFirst(style, 'resize:'.length), 'size');
      }
    }
    for (const e of [width, height]) if (e !== undefined) validateExpression(e);
    const action = {op: 'throw', screen};
    if (width !== undefined) action.width = width;
    if (height !== undefined) action.height = height;
    return action;
  }

  corner() {
    const words = this.tokens();
    this.expect(words, 1, 3);
    const corner = lowercased(words[0].text);
    if (!CORNERS.includes(corner)) {
      throw this.fail(`Unknown corner "${words[0].text}"`, 'use top-left, top-right, bottom-left or bottom-right');
    }
    let width;
    let height;
    let screen;
    if (words.length >= 2) {
      const style = words[1].text;
      const lower = lowercased(style);
      if (hasPrefix(lower, 'resize:')) {
        [width, height] = this.pair(dropFirst(style, 'resize:'.length), 'size');
      } else if (lower === 'noresize' || lower === 'resize') {
        // Slate ignores anything but resize:… here; `noresize` keeps a screen in the fourth position.
      } else if (words.length === 2 && screenRefFromSlate(style) !== null) {
        screen = screenRefToSlate(screenRefFromSlate(style)); // `corner top-left 1`
      } else {
        throw this.fail(`Unknown corner style "${style}"`, 'use resize:width;height');
      }
    }
    if (words.length === 3) screen = this.screenRef(words[2]);
    for (const e of [width, height]) if (e !== undefined) validateExpression(e);
    const action = {op: 'corner', direction: corner};
    if (width !== undefined) action.width = width;
    if (height !== undefined) action.height = height;
    if (screen !== undefined) action.screen = screen;
    return action;
  }

  // --- Composition ---------------------------------------------------------------------------------

  pieces(separators) {
    if (this.args === '') throw this.fail('Missing operations');
    const pieces = split(this.args, separators);
    pieces.forEach((piece, index) => {
      if (piece.text !== '') return;
      const separator = index === 0 ? pieces[1].separator : piece.separator;
      throw this.fail(`Missing an operation ${index === 0 ? 'before' : 'after'} "${separator}"`);
    });
    return pieces;
  }

  layout() {
    const name = unquote(this.args);
    if (name === '') throw this.fail('Missing the layout name');
    return {op: 'layout', name};
  }

  // --- Focus, snapshots, overlays ------------------------------------------------------------------

  focus() {
    const words = this.tokens();
    if (words.length !== 1) {
      if (words.length === 0) throw this.fail('Missing a direction or app');
      throw this.fail('App names need quotes', `write focus '${this.args}'`);
    }
    if (words[0].isQuoted) {
      if (words[0].text === '') throw this.fail('The app name is empty');
      return {op: 'focus', app: words[0].text};
    }
    const direction = focusDirectionFromSlate(words[0].text);
    if (direction === null) {
      throw this.fail(
        `Unknown focus direction "${words[0].text}"`,
        "use left, right, up, down, behind or a quoted app name like 'Safari'",
      );
    }
    return {op: 'focus', direction};
  }

  snapshot() {
    const words = this.tokens();
    if (words.length === 0 || words[0].text === '') throw this.fail('Missing the snapshot name');
    const options = words
      .slice(1)
      .flatMap((w) => splitCharacters(w.text, (c) => c === ';' || c === ',').map(trimWhitespace))
      .filter((o) => o !== '');
    const kind = this.kind;
    const allowed = kind === 'snapshot' ? ['save-to-disk', 'stack'] : kind === 'delete-snapshot' ? ['all'] : ['delete'];
    for (const option of options) {
      if (!allowed.includes(lowercased(option))) {
        throw this.fail(`Unknown ${kind} option "${option}"`, `use ${allowed.join(' or ')}`);
      }
    }
    const set = new Set(options.map(lowercased));
    const action = {op: kind, name: words[0].text};
    if (kind === 'snapshot') {
      if (set.has('save-to-disk')) action.save = true;
      if (set.has('stack')) action.stack = true;
    } else if (kind === 'delete-snapshot') {
      if (set.has('all')) action.all = true;
    } else if (set.has('delete')) {
      action.delete = true;
    }
    return action;
  }

  grid() {
    let padding;
    const grids = [];
    for (const word of this.tokens()) {
      const chars = graphemes(word.text);
      const colon = chars.indexOf(':');
      if (colon < 0) throw this.fail(`Unknown grid option "${word.text}"`, 'use padding:n or screen:width,height');
      const key = chars.slice(0, colon).join('');
      const value = chars.slice(colon + 1).join('');
      if (lowercased(key) === 'padding') {
        const n = parseInt64(value);
        if (n === null || n < 0) throw this.fail(`Grid padding must be a whole number, not "${value}"`);
        padding = n;
        continue;
      }
      if (parseInt64(key) === null && !isResolution(key)) {
        throw this.fail(`Unknown grid screen "${key}"`, 'use a screen index like 0 or a resolution like 1920x1080');
      }
      const size = splitCharacters(value, (c) => c === ',', false);
      const width = size.length === 2 ? parseInt64(size[0]) : null;
      const height = size.length === 2 ? parseInt64(size[1]) : null;
      if (width === null || height === null || !(width > 0) || !(height > 0)) {
        throw this.fail(`Grid size for screen ${key} must be width,height in cells`, `like ${key}:12,12`);
      }
      const grid = {screen: key, width: Number(width), height: Number(height)};
      const existing = grids.findIndex((g) => stringEquals(g.screen, key));
      if (existing >= 0) grids[existing] = grid; // like Slate, a later size for the same screen wins
      else grids.push(grid);
    }
    return gridAction(padding === undefined ? undefined : Number(padding), grids);
  }

  visibility() {
    if (this.args === '') throw this.fail('Missing the apps');
    const selectors = [];
    const apps = [];
    for (const piece of split(this.args, ',')) {
      const item = piece.text;
      if (item === '') throw this.fail('Empty app name in the list');
      const lower = lowercased(item);
      if (lower === 'current') {
        selectors.push('current');
      } else if (lower === 'all') {
        selectors.push('all');
      } else if (hasPrefix(lower, 'all-but:')) {
        const app = unquote(dropFirst(item, 'all-but:'.length));
        if (app === '') throw this.fail('all-but: needs an app name', "like all-but:'Finder'");
        selectors.push(`all-but:${app}`);
      } else {
        // Quoted names lose their quotes; unquoted names (even with spaces) are taken as written, like Slate.
        apps.push(unquote(item));
      }
    }
    if (selectors.length > 0 && (selectors.length > 1 || apps.length > 0)) {
      throw this.fail("current, all and all-but: can't be combined with other apps");
    }
    return {op: this.kind, app: selectors[0] ?? apps};
  }

  // --- Shell and Slated's own actions --------------------------------------------------------------

  shell() {
    const words = this.tokens();
    const commandWord = words[words.length - 1];
    if (commandWord === undefined) throw this.fail('Missing the command');
    const lowerCommand = lowercased(commandWord.text);
    if (!commandWord.isQuoted && (lowerCommand === 'wait' || hasPrefix(lowerCommand, 'path:'))) {
      throw this.fail('Missing the command', "quote it, like shell wait '/usr/bin/say hello'");
    }
    let wait = false;
    let path;
    for (const option of words.slice(0, -1)) {
      const lower = lowercased(option.text);
      if (lower === 'wait') {
        wait = true;
      } else if (hasPrefix(lower, 'path:')) {
        path = dropFirst(option.text, 'path:'.length);
        if (path === '') throw this.fail('path: needs a directory', 'like path:~/code');
      } else {
        throw this.fail(`Unknown shell option "${option.text}"`, "quote the whole command, like shell 'open -a Safari'");
      }
    }
    if (trimWhitespace(commandWord.text) === '') throw this.fail('The command is empty');
    const action = {op: 'shell', command: commandWord.text};
    if (wait) action.wait = true;
    if (path !== undefined) action.path = path;
    return action;
  }

  byOrientation() {
    const words = this.tokens();
    if (words.length !== 2) {
      throw this.fail(
        'by-orientation needs two quoted operations',
        "like by-orientation 'move screenOriginX;screenOriginY screenSizeX/3;screenSizeY' 'push up'",
      );
    }
    return {op: 'by-orientation', landscape: parseOperation(words[0].text), portrait: parseOperation(words[1].text)};
  }

  insertText() {
    const words = this.tokens();
    if (words.length === 0) throw this.fail('Missing the text', "quote it, like insert-text 'Hello!'");
    if (words.length > 2) throw this.fail('Text with spaces needs quotes', `write insert-text '${this.args}'`);
    let method = 'auto';
    if (words.length === 2) {
      const parsed = lowercased(words[0].text);
      if (words[0].isQuoted || !INSERT_METHODS.includes(parsed)) {
        throw this.fail(`Unknown insert-text option "${words[0].text}"`, 'use type or paste, and quote the text');
      }
      method = parsed;
    }
    const action = {op: 'insert-text', text: unescapeText(words[words.length - 1].text)};
    if (method !== 'auto') action.method = method;
    return action;
  }

  openURL() {
    const words = this.tokens();
    if (words.length !== 1 || words[0].text === '') {
      if (words.length === 0 || (words.length === 1 && words[0].text === '')) throw this.fail('Missing the URL');
      throw this.fail('URLs with spaces need quotes', "like open-url 'https://example.com/a b'");
    }
    return {op: 'open-url', url: words[0].text};
  }

  keystroke() {
    const words = this.tokens();
    if (words.length !== 1) throw this.fail(words.length === 0 ? 'Missing the keys' : 'Too many parameters', 'like keystroke cmd+shift+4');
    const text = words[0].text;
    const combo = parseKeyCombo(text);
    if (combo !== null && isValidKey(combo.key)) return {op: 'keystroke', keys: formatKeyCombo(combo)};
    if (graphemes(text).includes(':')) {
      let parsed = null;
      try {
        parsed = parseKeystroke(text);
      } catch (e) {
        if (!(e instanceof SlatedError)) throw e;
      }
      if (parsed !== null && parsed.modal === null) return {op: 'keystroke', keys: formatKeyCombo(parsed.keys)};
    }
    throw this.fail(`Unknown keystroke "${text}"`, 'write it like cmd+shift+4');
  }

  bare(op) {
    if (this.args !== '') throw this.fail(`${op} takes no parameters`);
    return {op};
  }

  // --- Automation ----------------------------------------------------------------------------------

  /** `click [left|right|middle] [count]` */
  click() {
    const words = this.tokens();
    if (words.length > 2) throw this.fail('Too many parameters', 'like click right 2');
    let button = 'left';
    let count = 1;
    for (const word of words) {
      const lower = lowercased(word.text);
      const n = parseInt64(word.text);
      if (MOUSE_BUTTONS.includes(lower)) {
        button = lower;
      } else if (n !== null && n >= 1 && n <= 10) {
        count = n;
      } else {
        throw this.fail(`Unknown click option "${word.text}"`, 'use left, right or middle and a count from 1 to 10');
      }
    }
    const action = {op: 'click', button};
    if (count !== 1) action.count = count;
    return action;
  }

  /** `press <mouse:button|key:combo> <down|up>` */
  press() {
    const words = this.tokens();
    if (words.length !== 2) throw this.fail('press needs an input and down or up', 'like press key:w down');
    const input = parseSyntheticInput(words[0].text);
    if (input === null) throw this.invalidInput(words[0].text);
    const phase = lowercased(words[1].text);
    if (!PRESS_PHASES.includes(phase)) throw this.fail(`Unknown press phase "${words[1].text}"`, 'use down or up');
    return {op: 'press', input: formatSyntheticInput(input), phase};
  }

  /** `hold <mouse:button|key:combo>` */
  hold() {
    const words = this.tokens();
    if (words.length !== 1) throw this.fail('hold needs one input', 'like hold mouse:right or hold key:w');
    const input = parseSyntheticInput(words[0].text);
    if (input === null) throw this.invalidInput(words[0].text);
    return {op: 'hold', input: formatSyntheticInput(input)};
  }

  /** `repeat <seconds> [toggle|while-held] [times:N] [jitter:F] '<operation>'` */
  repeat() {
    const words = this.tokens();
    if (words.length < 2 || words.length > 5) {
      throw this.fail('repeat needs an interval and a quoted operation', "like repeat 0.1 'click left'");
    }
    const interval = parseDouble(words[0].text);
    if (interval === null || !Number.isFinite(interval) || !(interval > 0)) {
      throw this.fail('The interval must be a number of seconds above 0', "like repeat 0.1 'click left'");
    }
    let mode = 'toggle';
    let times;
    let jitter = 0;
    for (const word of words.slice(1, -1)) {
      const lower = lowercased(word.text);
      const n = hasPrefix(lower, 'times:') ? parseInt64(dropFirst(lower, 'times:'.length)) : null;
      const j = hasPrefix(lower, 'jitter:') ? parseDouble(dropFirst(lower, 'jitter:'.length)) : null;
      if (REPEAT_MODES.includes(lower)) {
        mode = lower;
      } else if (n !== null && n >= 1) {
        times = n;
      } else if (j !== null && Number.isFinite(j) && j >= 0 && j <= 0.5) {
        jitter = j;
      } else {
        throw this.fail(`Unknown repeat option "${word.text}"`, 'use toggle or while-held, times:N (1 or more) and jitter:F (0 to 0.5)');
      }
    }
    const action = {op: 'repeat', action: parseOperation(words[words.length - 1].text), interval};
    if (mode !== 'toggle') action.mode = mode;
    if (times !== undefined) action.times = times;
    if (jitter !== 0) action.jitter = jitter;
    return action;
  }

  /** `wait <seconds>` */
  wait() {
    const words = this.tokens();
    const seconds = words.length === 1 ? parseDouble(words[0].text) : null;
    if (seconds === null || !Number.isFinite(seconds) || !(seconds >= 0)) {
      throw this.fail('wait needs a number of seconds', 'like wait 0.5');
    }
    return {op: 'wait', seconds};
  }

  invalidInput(text) {
    return this.fail(`Unknown input "${text}"`, 'use mouse:left, mouse:right, mouse:middle or key:<key>, like key:w');
  }

  // --- Helpers -------------------------------------------------------------------------------------

  tokens() {
    return tokenize(this.args);
  }

  expect(words, min, max) {
    if (words.length < min) throw this.fail('Missing parameters');
    if (words.length > max) throw this.fail('Too many parameters');
  }

  screenRef(word) {
    const ref = screenRefFromSlate(word.text);
    if (ref === null) {
      throw this.fail(
        `Unknown screen "${word.text}"`,
        'use an index like 1, a resolution like 1920x1080, left, right, up, down, next or previous',
      );
    }
    return screenRefToSlate(ref);
  }

  /** Splits `x;y` (or Slate's older `x,y`, with commas inside parentheses or braces ignored). */
  pair(text, what) {
    let parts = splitCharacters(text, (c) => c === ';', false);
    if (parts.length !== 2) parts = splitTopLevelCommas(text);
    if (parts.length !== 2 || trimWhitespace(parts[0]) === '' || trimWhitespace(parts[1]) === '') {
      throw this.fail(`Expected the ${what} as ${what === 'size' ? 'width;height' : 'x;y'}, found "${text}"`);
    }
    return parts;
  }

  /** An error like `Unknown direction "sideways" in "push sideways"; use up, down, left or right`. */
  fail(problem, hint) {
    let message = `${problem} in "${this.operation}"`;
    if (hint !== undefined) message += `; ${hint}`;
    else if (Object.prototype.hasOwnProperty.call(USAGE, this.kind)) message += `. Usage: ${USAGE[this.kind]}`;
    return invalidSyntax(message);
  }
}

function splitTopLevelCommas(text) {
  const parts = [];
  let current = '';
  let depth = 0;
  for (const c of graphemes(text)) {
    if (c === '(' || c === '{') depth++;
    else if (c === ')' || c === '}') depth--;
    if (c === ',' && depth === 0) {
      parts.push(current);
      current = '';
    } else {
      current += c;
    }
  }
  parts.push(current);
  return parts;
}

function isResolution(text) {
  const parts = splitCharacters(lowercased(text), (c) => c === 'x', false);
  return parts.length === 2 && parseInt64(parts[0]) !== null && parseInt64(parts[1]) !== null;
}

/** A canonical grid action from screens in written order (kept for formatting, see GRID_ORDER). */
function gridAction(padding, grids) {
  const action = {op: 'grid'};
  if (padding !== undefined) action.padding = padding;
  if (grids.length > 0) {
    action.grids = {};
    for (const g of grids) {
      Object.defineProperty(action.grids, g.screen, {value: {width: g.width, height: g.height}, enumerable: true, writable: true, configurable: true});
    }
    Object.defineProperty(action, GRID_ORDER, {value: grids.map((g) => g.screen)});
  }
  return action;
}

// --- Amounts (shared with the frame math) ------------------------------------------------------------

/** A `resize` width or height: a sign for a relative change, a magnitude, and whether it is a percentage. */
export function resizeAmount(value) {
  let text = trimWhitespace(value);
  let sign = null;
  if (hasPrefix(text, '+') || hasPrefix(text, '-')) {
    sign = hasPrefix(text, '-') ? -1 : 1;
    text = trimWhitespace(dropFirst(text, 1));
  }
  const isPercent = hasSuffix(text, '%');
  if (isPercent) text = trimWhitespace(dropLast(text, 1));
  return {sign, magnitude: text, isPercent};
}

/** Checks a `resize` amount: `+10%`, `-100`, `+screenSizeX/10`, or an absolute size like `screenSizeX/2` or `50%`. */
export function validateResizeAmount(value) {
  const amount = resizeAmount(value);
  try {
    if (amount.magnitude === '') throw invalidExpression('the amount is empty');
    if (amount.sign !== null && parseInt64(amount.magnitude) !== null) return;
    validateExpression(amount.magnitude);
  } catch (e) {
    if (e instanceof SlatedError) throw invalidExpression(`Invalid resize amount "${value}": ${e.message}`);
    throw e;
  }
}

/** Checks a `nudge` amount: `+10%`, `-100`, or a signed expression like `+screenSizeX/10`. */
export function validateNudgeAmount(value) {
  try {
    if (trimWhitespace(value) === '') throw invalidExpression('the amount is empty');
    validateExpression(nudgeExpression(value, 'X', 'screenSize'));
  } catch (e) {
    if (e instanceof SlatedError) throw invalidExpression(`Invalid nudge amount "${value}": ${e.message}`);
    throw e;
  }
}

/**
 * Slate builds a nudge as text: `windowTopLeftX` followed by the amount, with `%` replaced by
 * `*screenSizeX/100` (or windowSizeX, per nudgePercentOf). This is the amount part; an unsigned amount
 * counts as positive.
 */
export function nudgeExpression(value, axis, percentOf) {
  let amount = trimWhitespace(value);
  if (!hasPrefix(amount, '+') && !hasPrefix(amount, '-')) amount = `+${amount}`;
  return amount.split('%').join(`*${percentOf}${axis}/100`);
}

// --- Formatting ----------------------------------------------------------------------------------------

const word = (text) => quoteIfNeeded(text);
const join = (...parts) => parts.filter((p) => p !== null && p !== undefined).join(' ');

/** `resize` (throw only, when the size is the whole screen), `resize:width;height`, or null for no resize. */
function resizeStyle(width, height, plainResizeAllowed) {
  if (width === undefined && height === undefined) return null;
  if (plainResizeAllowed && width === 'screenSizeX' && height === 'screenSizeY') return 'resize';
  return word(`resize:${width ?? 'windowSizeX'};${height ?? 'windowSizeY'}`);
}

function appList(app) {
  if (Array.isArray(app)) return app.map(quote).join(',');
  if (app === 'current' || app === 'all') return app;
  return `all-but:${quote(app.slice('all-but:'.length))}`;
}

/**
 * Formats an action as canonical Slate syntax that `parseOperation` reads back as the same action
 * (except a throw/corner with only one of width and height, and a chain or sequence nested in
 * another, which come back equivalent). Accepts any form `decodeAction` accepts.
 */
export function formatOperation(action) {
  return format(decodeAction(action));
}

function format(a) {
  switch (a.op) {
    case 'move':
      return join('move', word(`${a.x};${a.y}`), word(`${a.width};${a.height}`), a.screen === undefined ? null : word(a.screen));
    case 'resize':
      return join('resize', word(a.width), word(a.height), a.anchor === undefined || a.anchor === 'top-left' ? null : a.anchor);
    case 'push': {
      const style = a.style ?? 'none';
      const styleWord = style === 'none' && a.screen === undefined ? null : word(style);
      return join('push', a.direction, styleWord, a.screen === undefined ? null : word(a.screen));
    }
    case 'nudge':
      return join('nudge', word(a.x), word(a.y));
    case 'throw':
      return join('throw', word(a.screen), resizeStyle(a.width, a.height, true));
    case 'corner': {
      // `noresize` keeps the screen in the fourth position, which Slate also reads that way.
      const style = resizeStyle(a.width, a.height, false) ?? (a.screen === undefined ? null : 'noresize');
      return join('corner', a.direction, style, a.screen === undefined ? null : word(a.screen));
    }
    case 'chain':
      return `chain ${a.operations.map(format).join(' | ')}`;
    case 'sequence': {
      let text = 'sequence';
      sequenceSteps(a).forEach((step, index) => {
        if (index > 0) text += step.keepWindow ? ' >' : ' |';
        text += ` ${format(step.action)}`;
      });
      return text;
    }
    case 'layout':
      return join('layout', word(a.name));
    case 'focus':
      return a.app !== undefined ? join('focus', quote(a.app)) : join('focus', a.direction);
    case 'snapshot': {
      const options = [a.save ? 'save-to-disk' : null, a.stack ? 'stack' : null].filter((o) => o !== null);
      return join('snapshot', word(a.name), options.length === 0 ? null : options.join(';'));
    }
    case 'delete-snapshot':
      return join('delete-snapshot', word(a.name), a.all ? 'all' : null);
    case 'activate-snapshot':
      return join('activate-snapshot', word(a.name), a.delete ? 'delete' : null);
    case 'hint':
      return join('hint', a.characters === undefined ? null : word(a.characters));
    case 'grid': {
      const order = Array.isArray(a[GRID_ORDER]) ? a[GRID_ORDER] : sortedGridKeys(a.grids);
      const sizes = order.map((k) => `${k}:${a.grids[k].width},${a.grids[k].height}`);
      return ['grid', a.padding === undefined ? null : `padding:${a.padding}`, ...sizes].filter((p) => p !== null).join(' ');
    }
    case 'hide':
    case 'show':
    case 'toggle':
      return join(a.op, appList(a.app));
    case 'shell':
      return join('shell', a.wait ? 'wait' : null, a.path === undefined ? null : `path:${word(a.path)}`, quote(a.command));
    case 'by-orientation':
      return join('by-orientation', quote(format(a.landscape)), quote(format(a.portrait)));
    case 'insert-text':
      return join('insert-text', a.method === undefined || a.method === 'auto' ? null : a.method, quote(escapeText(a.text)));
    case 'open-url':
      return join('open-url', quote(a.url));
    case 'keystroke':
      return join('keystroke', word(a.keys));
    case 'click':
      return join('click', a.button ?? 'left', a.count === undefined || a.count === 1 ? null : String(a.count));
    case 'press':
      return join('press', word(a.input), a.phase);
    case 'hold':
      return join('hold', word(a.input));
    case 'repeat':
      return join(
        'repeat',
        shortNumber(a.interval),
        a.mode === undefined || a.mode === 'toggle' ? null : a.mode,
        a.times === undefined ? null : `times:${a.times}`,
        a.jitter === undefined || a.jitter === 0 ? null : `jitter:${shortNumber(a.jitter)}`,
        quote(format(a.action)),
      );
    case 'wait':
      return join('wait', shortNumber(a.seconds));
    default:
      return a.op; // undo, relaunch, switch, stop-automations, clipboard-history
  }
}

// --- Keystrokes, shell arguments, text escapes -------------------------------------------------------------

/**
 * Parses a Slate keystroke: `a:ctrl,shift,alt,cmd`, `left:ctrl;cmd`, `1:f4,ctrl,alt` (modal key f4
 * with ⌃⌥), or `1:ctrl,f4:toggle`.
 * @returns {{keys: {key: string, modifiers: string[]}, modal: {keys: {key: string, modifiers: string[]}, toggle: boolean} | null}}
 */
export function parseKeystroke(string) {
  let rest = trimWhitespace(String(string));
  let toggle = false;
  if (hasSuffix(lowercased(rest), ':toggle')) {
    toggle = true;
    rest = dropLast(rest, ':toggle'.length);
  }
  // The key comes first and is never ":" itself, so the first colon after it separates the modifiers.
  const chars = graphemes(rest);
  const colon = chars.indexOf(':', 1);
  const key = colon < 0 ? rest : chars.slice(0, colon).join('');
  const modifierList = colon < 0 ? '' : chars.slice(colon + 1).join('');
  if (!isValidKey(key)) throw invalidSyntax(`Unknown key "${key}" in "${string}"`);

  let mask = 0;
  let modalKey = null;
  for (const token of splitCharacters(modifierList, (c) => c === ',' || c === ';')) {
    const t = trimWhitespace(token);
    const m = modifierMask(t);
    if (m !== null) mask |= m;
    else if (isValidKey(t) && modalKey === null) modalKey = t;
    else throw invalidSyntax(`Unknown modifier "${t}" in "${string}"`);
  }
  const combo = (k, bits) => ({key: canonicalKey(k), modifiers: modifiersFromMask(bits)});
  if (modalKey !== null) {
    // Slate applies the listed modifiers to the modal key; the binding's own key is pressed bare.
    return {keys: combo(key, 0), modal: {keys: combo(modalKey, mask), toggle}};
  }
  if (toggle) throw invalidSyntax(`:toggle needs a modal key in "${string}"`);
  return {keys: combo(key, mask), modal: null};
}

/**
 * Splits a `shell` command into the program and its arguments the way Slate ran it: no shell,
 * whitespace-separated words, '…'/"…" group words. `/usr/bin/say "hello world"` → ["/usr/bin/say", "hello world"].
 */
export function shellArguments(command) {
  return tokenize(command).map((t) => t.text);
}

/** Reverses `escapeText`: \n, \t, \r and \\ become a newline, tab, return and backslash; other backslashes stay. */
export function unescapeText(text) {
  const chars = graphemes(text);
  let result = '';
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i];
    if (c !== '\\') {
      result += c;
      continue;
    }
    const next = chars[++i];
    if (next === undefined) result += '\\';
    else if (next === 'n') result += '\n';
    else if (next === 't') result += '\t';
    else if (next === 'r') result += '\r';
    else if (next === '\\') result += '\\';
    else result += `\\${next}`;
  }
  return result;
}

/** Escapes text for `insert-text` so it fits on one line. */
export function escapeText(text) {
  let result = '';
  for (const c of graphemes(text)) {
    if (c === '\\') result += '\\\\';
    else if (c === '\n') result += '\\n';
    else if (c === '\t') result += '\\t';
    else if (c === '\r') result += '\\r';
    else result += c;
  }
  return result;
}
