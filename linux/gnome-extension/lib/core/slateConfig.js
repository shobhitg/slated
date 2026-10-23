// Classic `.slate` files (port of SlateConfigParser.swift): config, alias, layout, default, bind, source.
//
// Each line is one directive; `#` starts a comment (except inside quotes). A line that fails becomes an
// error diagnostic with its file and line, and parsing carries on; questionable but usable lines
// (an unknown setting, an unknown layout option) load with a warning. Bindings get stable ids derived
// from what they are, so reloading an unchanged file gives the same ids as on macOS.

import {SlatedError} from './errors.js';
import {closestName} from './expression.js';
import {formatKeyCombo} from './keys.js';
import {dropFirst, setSetting, settingFromSlate, splitCharacters} from './model.js';
import {formatOperation, parseKeystroke, parseOperation} from './slateSyntax.js';
import {leadingTokens, split, splitAtOutsideQuotes, tokenize, unquote} from './tokenizer.js';
import {
  compareStrings,
  graphemes,
  hasPrefix,
  hasSuffix,
  isNewline,
  isWhitespace,
  lowercased,
  parseInt64,
  stringEquals,
  trimWhitespace,
  trimWhitespaceAndNewlines,
  uppercased,
} from './text.js';

/** The settings Slate understands. Others still load, with a warning (a typo is the likely cause). */
export const knownSettings = Object.freeze([
  'defaultToCurrentScreen', 'nudgePercentOf', 'resizePercentOf', 'repeatOnHoldOps', 'secondsBeforeRepeat',
  'secondsBetweenRepeat', 'checkDefaultsOnLoad', 'focusCheckWidth', 'focusCheckWidthMax', 'focusPreferSameApp',
  'orderScreensLeftToRight', 'windowHintsFontName', 'windowHintsFontSize', 'windowHintsFontColor', 'windowHintsWidth',
  'windowHintsHeight', 'windowHintsBackgroundColor', 'windowHintsDuration', 'windowHintsRoundedCornerSize',
  'windowHintsIgnoreHiddenWindows', 'windowHintsTopLeftX', 'windowHintsTopLeftY', 'windowHintsOrder',
  'windowHintsShowIcons', 'windowHintsIconAlpha', 'windowHintsSpread', 'windowHintsSpreadSearchWidth',
  'windowHintsSpreadSearchHeight', 'windowHintsSpreadPadding', 'switchIconSize', 'switchIconPadding',
  'switchBackgroundColor', 'switchSelectedBackgroundColor', 'switchSelectedBorderColor', 'switchSelectedBorderSize',
  'switchRoundedCornerSize', 'switchOrientation', 'switchSecondsBeforeRepeat', 'switchSecondsBetweenRepeat',
  'switchStopRepeatAtEdge', 'switchOnlyFocusMainWindow', 'switchFontSize', 'switchFontColor', 'switchFontName',
  'switchShowTitles', 'switchType', 'switchSelectedPadding', 'keyboardLayout', 'snapshotTitleMatch',
  'snapshotMaxStackSize', 'undoMaxStackSize', 'undoOps', 'gridBackgroundColor', 'gridRoundedCornerSize',
  'gridCellBackgroundColor', 'gridCellSelectedColor', 'gridCellRoundedCornerSize', 'layoutFocusOnActivate',
  'modalEscapeKey', 'jsReceiveMoveEvent', 'jsReceiveResizeEvent',
]);
const KNOWN = new Set(knownSettings);
const SORTED_KNOWN = [...knownSettings].sort(compareStrings);
const MAXIMUM_SOURCE_DEPTH = 16;

const isQuote = (c) => c === "'" || c === '"';

/**
 * Parses a classic .slate file and everything it `source`s.
 * @param {string} text
 * @param {{path?: string|null, homeDirectory?: string, readFile?: (path: string) => string|null}} [options]
 *   `path` names the file in diagnostics and guards against it sourcing itself; relative `source`
 *   paths resolve against `homeDirectory`, as in Slate; `readFile` loads sourced files and returns
 *   null when a file can't be read (default: nothing can be read).
 * @returns {{settings: Object, bindings: Object[], layouts: Object[], defaults: Object[], diagnostics: Object[]}}
 *   bindings, layouts and defaults in config.json's form; diagnostics are {severity, message, file?, line?}.
 */
export function parseSlateConfig(text, {path = null, homeDirectory = '~', readFile = () => null} = {}) {
  const parser = new ConfigFileParser(homeDirectory, readFile);
  if (path !== null && path !== undefined) parser.sourceStack.push(standardizedPath(parser.resolve(path)));
  parser.parse(String(text), path ?? null);
  return parser.result;
}

/** "file, line N: message" (the file's last path component), as Slated shows a diagnostic. */
export function describeDiagnostic(d) {
  const location = [d.file == null ? null : lastPathComponent(d.file), d.line == null ? null : `line ${d.line}`]
    .filter((p) => p !== null)
    .join(', ');
  return location === '' ? d.message : `${location}: ${d.message}`;
}

/** Removes a trailing `# comment`; quote tracking on `bind` lines starts after the key (it may be a quote). */
export function stripComment(line) {
  const chars = graphemes(line);
  let start = 0;
  if (hasPrefix(lowercased(line), 'bind') && chars.length > 4 && isWhitespace(chars[4])) {
    let i = 4;
    while (i < chars.length && isWhitespace(chars[i])) i++;
    while (i < chars.length && !isWhitespace(chars[i])) {
      if (chars[i] === '#') return trimWhitespace(chars.slice(0, i).join(''));
      i++;
    }
    start = i;
  }
  let quote = null;
  for (let i = start; i < chars.length; i++) {
    const c = chars[i];
    if (quote !== null) {
      if (c === quote) quote = null;
    } else if (c === '#') {
      return trimWhitespace(chars.slice(0, i).join(''));
    } else if (isQuote(c)) {
      quote = c;
    }
  }
  return line;
}

const invalid = (message) => new SlatedError('invalidSyntax', message);

class ConfigFileParser {
  constructor(home, readFile) {
    this.home = home;
    this.readFile = readFile;
    this.result = {settings: {}, bindings: [], layouts: [], defaults: [], diagnostics: []};
    this.aliases = []; // [name, value], first spelling kept like a Swift dictionary key
    this.bindingOccurrences = new Map();
    this.sourceStack = [];
  }

  parse(text, file) {
    let body = text;
    if (hasPrefix(body, '\uFEFF')) body = graphemes(body).slice(1).join('');
    // Split on any line break; "\r\n" is a single character, as in Swift.
    const lines = splitCharacters(body, isNewline, false);
    lines.forEach((rawLine, index) => {
      const line = trimWhitespaceAndNewlines(rawLine);
      if (line === '' || hasPrefix(line, '#')) return;
      const content = stripComment(line);
      if (content === '') return;
      const location = {file, line: index + 1};
      try {
        this.handle(this.substituteAliases(content), location);
      } catch (e) {
        if (!(e instanceof SlatedError)) throw e;
        this.report('error', e.message, location);
      }
    });
  }

  report(severity, message, location) {
    const diagnostic = {severity, message};
    if (location.file !== null) diagnostic.file = location.file;
    diagnostic.line = location.line;
    this.result.diagnostics.push(diagnostic);
  }

  handle(line, location) {
    const [directive, rest] = splitFirstWord(line);
    switch (lowercased(directive)) {
      case 'config': return this.config(rest, location);
      case 'alias': return this.alias(rest);
      case 'bind': return this.bind(rest, location);
      case 'layout': return this.layout(rest, location);
      case 'default': return this.defaultDirective(rest);
      case 'source': return this.source(rest, location);
      default:
        throw invalid(`Unknown directive "${directive}"; lines start with config, alias, layout, default, bind or source`);
    }
  }

  /** `config name value` */
  config(rest, location) {
    const [key, value] = splitFirstWord(rest);
    if (key === '' || value === '') throw invalid('config needs a name and a value, like config defaultToCurrentScreen true');
    if (graphemes(key).includes(':')) {
      this.report('warning', `Per-app settings like "${key}" aren't supported yet; skipped this line`, location);
      return;
    }
    if (!KNOWN.has(key)) {
      let message = `Unknown setting "${key}"`;
      const suggestion = closestName(key, SORTED_KNOWN);
      if (suggestion !== null) message += `; did you mean "${suggestion}"?`;
      this.report('warning', message, location);
    }
    setSetting(this.result.settings, key, settingFromSlate(unquote(value)));
  }

  /** `alias name value`; later lines use it as `${name}`. */
  alias(rest) {
    const [name, value] = splitFirstWord(rest);
    if (name === '' || value === '') throw invalid('alias needs a name and a value, like alias half push left bar-resize:screenSizeX/2');
    const existing = this.aliases.find(([n]) => stringEquals(n, name));
    if (existing) existing[1] = value;
    else this.aliases.push([name, value]);
  }

  /** `bind key:modifiers operation` */
  bind(rest, location) {
    const [keystroke, operation] = splitFirstWord(rest);
    if (keystroke === '' || operation === '') throw invalid('bind needs a key and an operation, like bind left:ctrl;cmd push left');
    const keys = parseKeystroke(keystroke);
    const action = parseOperation(operation);
    // The id depends only on what the binding is (and where), so reloading an unchanged file gives the
    // same bindings, and editing an unrelated line doesn't change them.
    const modal = keys.modal === null ? '' : `${formatKeyCombo(keys.modal.keys)}${keys.modal.toggle ? ':toggle' : ''}`;
    const identity = [location.file ?? '', formatKeyCombo(keys.keys), modal, formatOperation(action)].join('\n');
    const occurrence = this.bindingOccurrences.get(identity) ?? 0;
    this.bindingOccurrences.set(identity, occurrence + 1);
    const binding = {action, enabled: true, id: stableUUID(`${identity}\n${occurrence}`), keys: formatKeyCombo(keys.keys)};
    if (keys.modal !== null) binding.modal = {keys: formatKeyCombo(keys.modal.keys), toggle: keys.modal.toggle};
    this.result.bindings.push(binding);
  }

  /** `layout name 'App Name':OPTIONS operation | operation …`, or `layout name BEFORE|AFTER operation`. */
  layout(rest, location) {
    const {tokens: words, rest: operations} = leadingTokens(rest, 2);
    if (words.length !== 2 || words[0].text === '' || operations === '') {
      throw invalid("layout needs a name, an app and operations, like layout coding 'Terminal' push left");
    }
    const name = words[0].text;
    const appWord = words[1];

    if (!appWord.isQuoted && (appWord.text === 'BEFORE' || appWord.text === 'AFTER')) {
      const action = parseOperation(operations);
      const isBefore = appWord.text === 'BEFORE';
      this.updateLayout(name, (layout) => (isBefore ? layout.before : layout.after).push(action));
      return;
    }

    const raw = appWord.raw;
    const parts = splitAtOutsideQuotes(raw, ':');
    const app = unquote(parts === null ? raw : parts[0]);
    if (app === '') throw invalid(`The app name is empty in "${raw}"`);
    if (!appWord.isQuoted && (app === 'BEFORE' || app === 'AFTER')) throw invalid(`${app} doesn't take options`);
    const {options, warnings} = layoutOptions(parts === null ? '' : parts[1], app);

    const pieces = split(operations, '|');
    if (pieces.some((p) => p.text === '')) throw invalid(`Missing an operation next to "|" in "${operations}"`);
    const actions = pieces.map((p) => parseOperation(p.text));

    for (const warning of warnings) this.report('warning', warning, location);
    this.updateLayout(name, (layout) => {
      // Like Slate, a later line for the same app replaces it and moves it to the end.
      layout.apps = layout.apps.filter((a) => !stringEquals(a.app, app));
      layout.apps.push({app, operations: actions, options});
    });
  }

  updateLayout(name, update) {
    let layout = this.result.layouts.find((l) => stringEquals(l.name, name));
    if (!layout) {
      layout = {name, apps: [], before: [], after: []};
      this.result.layouts.push(layout);
    }
    update(layout);
  }

  /** `default name count:N` or `default name resolutions:1440x900;1920x1080` */
  defaultDirective(rest) {
    const words = tokenize(rest);
    const usage = 'like default coding count:2 or default coding resolutions:1440x900;1920x1080';
    if (words.length !== 2 || words[0].text === '') {
      throw invalid(`default needs a layout or snapshot name and a screen setup, ${usage}`);
    }
    const setup = words[1].text;
    const chars = graphemes(setup);
    const colon = chars.indexOf(':');
    if (colon < 0) throw invalid(`Unknown screen setup "${setup}"; ${usage}`);
    const value = chars.slice(colon + 1).join('');
    let condition;
    switch (lowercased(chars.slice(0, colon).join(''))) {
      case 'count': {
        const count = parseInt64(value);
        if (count === null || !(count > 0)) throw invalid(`count: needs a number of screens, not "${value}"`);
        condition = {count: {_0: count}};
        break;
      }
      case 'resolutions': {
        const resolutions = [];
        for (const item of splitCharacters(value, (c) => c === ';' || c === ',')) {
          const parts = splitCharacters(lowercased(item), (c) => c === 'x', false);
          const width = parts.length === 2 ? parseInt64(parts[0]) : null;
          const height = parts.length === 2 ? parseInt64(parts[1]) : null;
          if (width === null || height === null || !(width > 0) || !(height > 0)) {
            throw invalid(`Unknown resolution "${item}"; write resolutions like 1920x1080`);
          }
          resolutions.push(`${width}x${height}`);
        }
        if (resolutions.length === 0) throw invalid(`resolutions: needs at least one resolution, ${usage}`);
        condition = {resolutions: {_0: resolutions}};
        break;
      }
      default:
        throw invalid(`Unknown screen setup "${setup}"; ${usage}`);
    }
    this.result.defaults.push({target: words[0].text, condition});
  }

  /** `source path [if_exists]` */
  source(rest, location) {
    const words = tokenize(rest);
    if (words.length < 1 || words.length > 2 || words[0].text === '') {
      throw invalid('source needs a file, like source ~/.slate.local if_exists');
    }
    let ifExists = false;
    if (words.length === 2) {
      if (lowercased(words[1].text) !== 'if_exists') {
        throw invalid(`Unknown source option "${words[1].text}"; the only option is if_exists`);
      }
      ifExists = true;
    }
    const written = words[0].text;
    const path = this.resolve(written);
    if (hasSuffix(lowercased(path), '.js')) {
      this.report(
        'warning',
        `Can't source the JavaScript config "${written}" from a .slate file; add it to Slated's Slate config files instead`,
        location,
      );
      return;
    }
    const key = standardizedPath(path);
    const start = this.sourceStack.findIndex((p) => stringEquals(p, key));
    if (start >= 0) {
      const loop = [...this.sourceStack.slice(start), key].map(lastPathComponent).join(' → ');
      throw invalid(`"${written}" is already being loaded (${loop}); skipped it to avoid an endless loop`);
    }
    if (this.sourceStack.length >= MAXIMUM_SOURCE_DEPTH) {
      throw invalid(`Too many nested source directives (more than ${MAXIMUM_SOURCE_DEPTH})`);
    }
    const text = this.readFile(path);
    if (text === null || text === undefined) {
      if (ifExists) return;
      throw invalid(`Couldn't read "${written}"; check the path, or add if_exists to skip it when it's missing`);
    }
    this.sourceStack.push(key);
    this.parse(String(text), path);
    this.sourceStack.pop();
  }

  /** Replaces each `${name}` with the alias's value (values were expanded when defined). */
  substituteAliases(line) {
    let result = '';
    let rest = line;
    for (;;) {
      const start = rest.indexOf('${');
      if (start < 0) break;
      result += rest.slice(0, start);
      const end = rest.indexOf('}', start + 2);
      if (end < 0) throw invalid(`Missing } after "\${" in "${line}"`);
      const name = rest.slice(start + 2, end);
      const alias = this.aliases.find(([n]) => stringEquals(n, name));
      if (!alias) {
        let message = `Unknown alias "\${${name}}"`;
        const suggestion = closestName(name, this.aliases.map(([n]) => n).sort(compareStrings));
        message += suggestion !== null ? `; did you mean "\${${suggestion}}"?` : '; define it with an alias line above this one';
        throw invalid(message);
      }
      result += alias[1];
      rest = rest.slice(end + 1);
    }
    return result + rest;
  }

  /** Slate's rule: `~` is the home directory, and paths that aren't absolute are relative to it. */
  resolve(path) {
    if (path === '~') return this.home;
    if (hasPrefix(path, '~/')) return appendingPathComponent(this.home, dropFirst(path, 2));
    if (hasPrefix(path, '~')) return path; // another user's home: can't be looked up here
    if (hasPrefix(path, '/')) return path;
    return appendingPathComponent(this.home, path);
  }
}

/** The first whitespace-separated word of `text` and the trimmed rest. */
function splitFirstWord(text) {
  const chars = graphemes(trimWhitespaceAndNewlines(text));
  let end = chars.findIndex(isWhitespace);
  if (end < 0) end = chars.length;
  return [chars.slice(0, end).join(''), trimWhitespaceAndNewlines(chars.slice(end).join(''))];
}

function layoutOptions(text, app) {
  const options = {ignoreFail: false, mainFirst: false, mainLast: false, repeat: false, repeatLast: false, sortTitle: false};
  const warnings = [];
  if (text === '') return {options, warnings};
  for (const piece of split(text, ',')) {
    if (piece.text === '') continue;
    const item = piece.text;
    const parts = splitAtOutsideQuotes(item, '=');
    const key = uppercased(trimWhitespace(parts === null ? item : parts[0]));
    const value = parts === null ? null : unquote(parts[1]);
    switch (key) {
      case 'IGNORE_FAIL': options.ignoreFail = true; break;
      case 'REPEAT': options.repeat = true; break;
      case 'REPEAT_LAST': options.repeatLast = true; break;
      case 'MAIN_FIRST': options.mainFirst = true; break;
      case 'MAIN_LAST': options.mainLast = true; break;
      case 'SORT_TITLE': options.sortTitle = true; break;
      case 'TITLE_ORDER': options.titleOrder = titles(value, key); break;
      case 'TITLE_ORDER_REGEX': {
        const patterns = titles(value, key);
        for (const pattern of patterns) {
          if (!isValidRegex(pattern)) throw invalid(`Invalid regular expression "${pattern}" in TITLE_ORDER_REGEX`);
        }
        options.titleOrderRegex = patterns;
        break;
      }
      default:
        warnings.push(`Unknown layout option "${key}" for "${app}"; ignored it`);
    }
  }
  if (options.mainFirst && options.mainLast) warnings.push(`MAIN_FIRST and MAIN_LAST can't both apply to "${app}"`);
  return {options, warnings};
}

function titles(value, option) {
  const list = splitCharacters(value ?? '', (c) => c === ';');
  if (list.length === 0) throw invalid(`${option} needs window titles separated by ;, like ${option}=Inbox;Drafts`);
  return list;
}

/**
 * Whether a TITLE_ORDER_REGEX pattern is valid. Swift checks with NSRegularExpression (ICU), which is
 * stricter about braces than JavaScript's RegExp: `{` must start an interval like {2}, {2,} or {2,5},
 * and a `}` that doesn't end one is an error. ICU-only syntax (inline flags, possessive quantifiers)
 * counts as invalid here, since the Linux version matches titles with JavaScript regular expressions.
 */
export function isValidRegex(pattern) {
  try {
    new RegExp(pattern);
  } catch {
    return false;
  }
  let classDepth = 0;
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === '\\') {
      if (pattern[i + 1] === 'Q') {
        const end = pattern.indexOf('\\E', i + 2);
        i = end < 0 ? pattern.length : end + 1;
      } else {
        i++;
      }
    } else if (c === '[') {
      classDepth++;
    } else if (c === ']' && classDepth > 0) {
      classDepth--;
    } else if (classDepth === 0 && c === '{') {
      const interval = /^\{[0-9]+(?:,[0-9]*)?\}/.exec(pattern.slice(i));
      if (!interval) return false;
      i += interval[0].length - 1;
    } else if (classDepth === 0 && c === '}') {
      return false;
    }
  }
  return true;
}

// --- Paths (NSString's rules, without touching the file system) ------------------------------------------

/** NSString.appendingPathComponent: joins with one slash, collapsing `//` and dropping a trailing `/`. */
export function appendingPathComponent(base, component) {
  const joined = base === '' ? component : component === '' ? base : `${base}/${component}`;
  const collapsed = joined.replace(/\/{2,}/g, '/');
  return collapsed.length > 1 ? collapsed.replace(/\/$/, '') : collapsed;
}

/** NSString.lastPathComponent. */
export function lastPathComponent(path) {
  if (path === '/') return '/';
  const trimmed = path.replace(/\/+$/, '');
  if (trimmed === '') return '/';
  return trimmed.slice(trimmed.lastIndexOf('/') + 1);
}

/** NSString.standardizingPath, lexically: no `//`, `.` or trailing `/`, and `..` resolved in absolute paths. */
export function standardizedPath(path) {
  const absolute = path.startsWith('/');
  const parts = [];
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..' && absolute) {
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  const joined = parts.join('/');
  return absolute ? `/${joined}` : joined || '.';
}

// --- Stable ids ------------------------------------------------------------------------------------

function utf8Bytes(s) {
  const bytes = [];
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (cp < 0x80) bytes.push(cp);
    else if (cp < 0x800) bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
    else if (cp < 0x10000) bytes.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    else bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
  }
  return bytes;
}

const MASK64 = (1n << 64n) - 1n;
const FNV_PRIME = 0x100000001b3n;

/**
 * A UUID derived from `name` (two 64-bit FNV-1a hashes, marked as a name-based UUID), so the same name
 * always gives the same identifier. Not cryptographic; it only needs to be stable.
 */
export function stableUUID(name) {
  let first = 0xcbf29ce484222325n;
  let second = 0x6c62272e07bb0142n;
  for (const byte of utf8Bytes(name)) {
    first = ((first ^ BigInt(byte)) * FNV_PRIME) & MASK64;
    second = ((second ^ BigInt(byte)) * FNV_PRIME) & MASK64;
  }
  const bytes = [];
  for (let i = 0; i < 8; i++) bytes.push(Number((first >> BigInt(8 * i)) & 0xffn));
  for (let i = 0; i < 8; i++) bytes.push(Number((second >> BigInt(8 * i)) & 0xffn));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5: name-based
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytes.map((b) => b.toString(16).padStart(2, '0')).join('').toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
