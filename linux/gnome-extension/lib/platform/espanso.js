// Hotstrings on GNOME, through espanso (https://espanso.org).
//
// A GNOME Shell extension can't watch what you type in other apps on Wayland, so Slated doesn't
// match hotstrings itself here. When espanso is installed, Slated writes its hotstrings to
// `~/.config/espanso/match/slated.yml` (espanso reloads it on its own) and removes the file when
// hotstrings are turned off.
//
// Mapping from config.json:
//   trigger / replacement      → trigger / replace
//   wordBoundary               → word: true (also used for fire: afterDelimiter, which espanso
//                                 can only express as a word match)
//   caseSensitive: false       → propagate_case: true
//   method: type / paste       → force_mode: keys / clipboard
//   {date} {time} {datetime}   → date variables (chrono formats)
//   {date:FMT}                 → a date variable with FMT converted from Unicode to chrono syntax
//   {clipboard}                → a clipboard variable
//   {{ / }}                    → literal braces
// Not mappable, logged once: onlyInApps (skipped: espanso can't tell apps apart on GNOME Wayland),
// exceptInApps (expands everywhere), action (espanso can't run Slated actions).
//
// Sensitive hotstrings (`replacement: {secret: name}`) get their text from secrets.json, as written: no
// placeholders, `force_mode: keys` (always typed, never pasted, so the text doesn't go through the
// clipboard), and text with `{{` in it passed through an `echo` variable that espanso doesn't
// interpret. One whose text isn't on this computer is left out. espanso has to have the text to expand
// it, so the match file holds it: it's written readable only by you (0600).
//
// Replacement text is never logged.

import Gio from 'gi://Gio';

import {hotstringSecret} from '../core/index.js';

import {exists, findProgram, makePrivate, readText, remove, writePrivateTextAtomic} from './files.js';

export const MATCH_FILE_NAME = 'slated.yml';

const MEDIUM_DATE = '%b %-d, %Y';
const SHORT_TIME = '%-I:%M %p';

const ICU_FIELDS = {
  y: (n) => (n === 2 ? '%y' : '%Y'),
  u: () => '%Y',
  Y: (n) => (n === 2 ? '%g' : '%G'),
  M: (n) => ['%-m', '%m', '%b', '%B', '%b'][Math.min(n, 5) - 1],
  L: (n) => ['%-m', '%m', '%b', '%B', '%b'][Math.min(n, 5) - 1],
  d: (n) => (n === 1 ? '%-d' : '%d'),
  D: (n) => (n === 1 ? '%-j' : '%j'),
  E: (n) => (n === 4 ? '%A' : '%a'),
  e: (n) => (n <= 2 ? '%u' : n === 4 ? '%A' : '%a'),
  c: (n) => (n <= 2 ? '%u' : n === 4 ? '%A' : '%a'),
  a: () => '%p',
  h: (n) => (n === 1 ? '%-I' : '%I'),
  K: (n) => (n === 1 ? '%-I' : '%I'),
  H: (n) => (n === 1 ? '%-H' : '%H'),
  k: (n) => (n === 1 ? '%-H' : '%H'),
  m: (n) => (n === 1 ? '%-M' : '%M'),
  s: (n) => (n === 1 ? '%-S' : '%S'),
  S: (n) => (n <= 3 ? '%3f' : n <= 6 ? '%6f' : '%9f'),
  w: () => '%V',
  z: () => '%Z',
  Z: (n) => (n >= 5 ? '%:z' : '%z'),
  x: (n) => (n >= 3 ? '%:z' : '%z'),
  X: (n) => (n >= 3 ? '%:z' : '%z'),
};

/**
 * Converts a Unicode (ICU / macOS DateFormatter) date pattern like `yyyy-MM-dd` into the chrono
 * strftime syntax espanso uses (`%Y-%m-%d`). Text in single quotes is literal; `''` is a quote.
 */
export function convertDateFormat(pattern) {
  let out = '';
  let i = 0;
  const literal = (text) => text.replace(/%/g, '%%');
  while (i < pattern.length) {
    const ch = pattern[i];
    if (ch === "'") {
      if (pattern[i + 1] === "'") {
        out += "'";
        i += 2;
        continue;
      }
      // Quoted text runs to the next single quote; `''` inside it is a literal quote.
      let text = '';
      let j = i + 1;
      while (j < pattern.length) {
        if (pattern[j] === "'") {
          if (pattern[j + 1] === "'") {
            text += "'";
            j += 2;
            continue;
          }
          break;
        }
        text += pattern[j];
        j += 1;
      }
      out += literal(text);
      i = j + 1;
      continue;
    }
    if (/[A-Za-z]/.test(ch)) {
      let n = 1;
      while (pattern[i + n] === ch) n += 1;
      const field = ICU_FIELDS[ch];
      out += field ? field(n) : literal(ch.repeat(n));
      i += n;
      continue;
    }
    out += literal(ch);
    i += 1;
  }
  return out;
}

/**
 * Converts a Slated replacement template into espanso's `replace` text and variables. Unknown
 * placeholders stay as written, like Slated's own template expansion.
 */
export function templateToEspanso(template) {
  const text = String(template ?? '');
  const vars = [];
  const names = new Map();
  let dateFormats = 0;
  const variable = (key, make) => {
    if (!names.has(key)) {
      const v = make();
      names.set(key, v.name);
      vars.push(v);
    }
    return `{{${names.get(key)}}}`;
  };
  const placeholder = (token) => {
    const lower = token.toLowerCase();
    if (lower === 'date') return variable('date', () => dateVar('slated_date', MEDIUM_DATE));
    if (lower === 'time') return variable('time', () => dateVar('slated_time', SHORT_TIME));
    if (lower === 'datetime') return variable('datetime', () => dateVar('slated_datetime', `${MEDIUM_DATE}, ${SHORT_TIME}`));
    if (lower === 'clipboard') return variable('clipboard', () => ({name: 'slated_clipboard', type: 'clipboard'}));
    if (lower.startsWith('date:')) {
      const format = convertDateFormat(token.slice('date:'.length));
      return variable(`date:${format}`, () => dateVar(`slated_date_${++dateFormats}`, format));
    }
    return null;
  };

  let replace = '';
  let i = 0;
  while (i < text.length) {
    if (text.startsWith('{{', i)) {
      replace += '{';
      i += 2;
      continue;
    }
    if (text.startsWith('}}', i)) {
      replace += '}';
      i += 2;
      continue;
    }
    if (text[i] === '{') {
      const close = text.indexOf('}', i);
      if (close > i) {
        const value = placeholder(text.slice(i + 1, close));
        if (value !== null) {
          replace += value;
          i = close + 1;
          continue;
        }
      }
    }
    replace += text[i];
    i += 1;
  }
  return {replace, vars};
}

function dateVar(name, format) {
  return {name, type: 'date', params: {format}};
}

/**
 * A sensitive hotstring's text as espanso's `replace`, typed as written: text espanso would read as a
 * variable (`{{`) goes through an `echo` variable whose text it doesn't interpret.
 */
export function literalToEspanso(text) {
  const value = String(text ?? '');
  if (!value.includes('{{')) return {replace: value, vars: []};
  return {replace: '{{slated_text}}', vars: [{name: 'slated_text', type: 'echo', params: {echo: value}, inject_vars: false}]};
}

/**
 * espanso matches for the hotstrings in `config.json`, with sensitive hotstrings' text from `secrets`
 * (secrets.json, {name: text}). Returns `{matches, skipped: [{trigger, reason}], approximations: [{trigger,
 * option, note}]}`; a sensitive match has `sensitive: true` (not written to the file).
 */
export function buildEspansoMatches(hotstrings, {enabled = true, secrets = {}} = {}) {
  const matches = [];
  const skipped = [];
  const approximations = [];
  if (!enabled) return {matches, skipped, approximations};
  for (const h of hotstrings ?? []) {
    if (!h || h.enabled === false || !h.trigger) continue;
    const trigger = String(h.trigger);
    if (Array.isArray(h.onlyInApps) && h.onlyInApps.length > 0) {
      skipped.push({trigger, reason: "onlyInApps: espanso can't tell apps apart on GNOME Wayland"});
      continue;
    }
    const secret = hotstringSecret(h);
    if (secret !== null && !Object.prototype.hasOwnProperty.call(secrets ?? {}, secret)) {
      skipped.push({trigger, reason: "sensitive, and its text isn't on this computer yet (secrets.json)"});
      continue;
    }
    const {replace, vars} = secret !== null ? literalToEspanso(secrets[secret]) : templateToEspanso(h.replacement ?? '');
    const match = {trigger, replace};
    if (vars.length) match.vars = vars;
    if (h.wordBoundary || h.fire === 'afterDelimiter') match.word = true;
    if (h.caseSensitive === false) match.propagate_case = true;
    // A sensitive hotstring is always typed, whatever its method: its text never goes through the clipboard.
    if (secret !== null || h.method === 'type') match.force_mode = 'keys';
    else if (h.method === 'paste') match.force_mode = 'clipboard';
    if (secret !== null) match.sensitive = true;
    matches.push(match);

    if (h.fire === 'afterDelimiter' && !h.wordBoundary) {
      approximations.push({trigger, option: 'fire', note: 'espanso word matches also need a word boundary before the trigger'});
    }
    if (Array.isArray(h.exceptInApps) && h.exceptInApps.length > 0) {
      approximations.push({trigger, option: 'exceptInApps', note: "espanso can't tell apps apart on GNOME Wayland; expands everywhere"});
    }
    if (h.action) approximations.push({trigger, option: 'action', note: "espanso can't run Slated actions; only the text is inserted"});
  }
  return {matches, skipped, approximations};
}

/** A YAML double-quoted scalar. */
export function yamlQuote(value) {
  let out = '"';
  for (const ch of String(value)) {
    const code = ch.codePointAt(0);
    if (ch === '\\') out += '\\\\';
    else if (ch === '"') out += '\\"';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (code < 0x20 || code === 0x7f || (code >= 0x80 && code < 0xa0)) out += `\\x${code.toString(16).padStart(2, '0')}`;
    else if (code === 0x2028 || code === 0x2029 || code === 0xfeff) out += `\\u${code.toString(16).padStart(4, '0')}`;
    else out += ch;
  }
  return `${out}"`;
}

/** The match file's text. */
export function espansoYaml(matches) {
  const lines = [
    '# Generated by Slated from ~/.config/slated/config.json (hotstrings).',
    '# Slated rewrites this file when the configuration changes: edit hotstrings in Slated instead.',
  ];
  if (matches.length === 0) {
    lines.push('matches: []');
    return `${lines.join('\n')}\n`;
  }
  lines.push('matches:');
  for (const m of matches) {
    lines.push(`  - trigger: ${yamlQuote(m.trigger)}`);
    lines.push(`    replace: ${yamlQuote(m.replace)}`);
    if (m.word) lines.push('    word: true');
    if (m.propagate_case) lines.push('    propagate_case: true');
    if (m.force_mode) lines.push(`    force_mode: ${m.force_mode}`);
    if (m.vars?.length) {
      lines.push('    vars:');
      for (const v of m.vars) {
        lines.push(`      - name: ${v.name}`);
        lines.push(`        type: ${v.type}`);
        if (v.params?.format !== undefined) {
          lines.push('        params:');
          lines.push(`          format: ${yamlQuote(v.params.format)}`);
        }
        if (v.params?.echo !== undefined) {
          lines.push('        params:');
          lines.push(`          echo: ${yamlQuote(v.params.echo)}`);
        }
        if (v.inject_vars === false) lines.push('        inject_vars: false');
      }
    }
  }
  return `${lines.join('\n')}\n`;
}

const ESPANSO_DIRS = ['/usr/local/bin', '/usr/bin', '/snap/bin', '/var/lib/flatpak/exports/bin'];

/** Keeps espanso's match file in sync with Slated's hotstrings. */
export class EspansoSync {
  /**
   * @param {object} options
   * @param {object} options.log
   * @param {string} options.configDir  espanso's config directory (normally ~/.config/espanso).
   * @param {string} options.home
   * @param {() => void} [options.onConfigDirChanged]  espanso reported a different config directory.
   */
  constructor({log, configDir, home, onConfigDirChanged = null}) {
    this._log = log;
    this._configDir = configDir;
    this._home = home;
    this._onConfigDirChanged = onConfigDirChanged;
    this._binary = null;
    this._cancellable = new Gio.Cancellable();
    this._reported = new Set();
    this._warnedUnavailable = false;
    this._wrote = false;
  }

  get matchFile() {
    return `${this._configDir}/match/${MATCH_FILE_NAME}`;
  }

  get installed() {
    return !!this._binary || exists(this._configDir);
  }

  /** Looks for espanso and asks it where its config lives (`espanso path config`). */
  start() {
    this._binary = findProgram('espanso', [`${this._home}/.local/bin`, ...ESPANSO_DIRS]);
    if (!this._binary) return;
    try {
      const proc = Gio.Subprocess.new([this._binary, 'path', 'config'], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
      proc.communicate_utf8_async(null, this._cancellable, (p, result) => {
        let stdout = '';
        try {
          [, stdout] = p.communicate_utf8_finish(result);
        } catch {
          return; // Cancelled, or espanso isn't usable; keep the default directory.
        }
        const dir = (stdout ?? '').trim().split('\n').pop()?.trim();
        if (p.get_successful() && dir && dir.startsWith('/') && dir !== this._configDir) {
          this._configDir = dir;
          this._onConfigDirChanged?.();
        }
      });
    } catch {
      // Keep the default directory.
    }
  }

  /**
   * Writes or removes the match file for `config`, with sensitive hotstrings' text from `secrets`
   * (secrets.json). Returns the hotstrings part of status.json.
   */
  apply(config, {secrets = {}} = {}) {
    const enabled = config?.general?.hotstringsEnabled !== false;
    const result = buildEspansoMatches(config?.hotstrings ?? [], {enabled, secrets});
    const installed = this.installed;
    if (!installed) {
      if (enabled && result.matches.length > 0 && !this._warnedUnavailable) {
        this._warnedUnavailable = true;
        this._log?.record(
          'hotstrings.unavailable',
          {count: result.matches.length, advice: 'Install espanso (https://espanso.org) to use hotstrings on GNOME'},
          'notice',
        );
      }
      return {engine: 'none', espansoInstalled: false, matchFile: null, count: 0};
    }

    this._reportUnsupported(result);
    const path = this.matchFile;
    try {
      if (!enabled || result.matches.length === 0) {
        if (exists(path)) {
          remove(path);
          this._log?.record('espanso.removed', {path, reason: enabled ? 'no hotstrings' : 'hotstrings are off'});
        }
        this._wrote = false;
        return {engine: 'espanso', espansoInstalled: true, matchFile: path, count: 0};
      }
      const text = espansoYaml(result.matches);
      const sensitive = result.matches.filter((m) => m.sensitive).length;
      // Readable only by you: it holds sensitive hotstrings' text, which espanso needs to expand them.
      if (readText(path) !== text) {
        writePrivateTextAtomic(path, text);
        this._log?.record('espanso.written', {path, count: result.matches.length, skipped: result.skipped.length, sensitive});
      } else {
        makePrivate(path);
      }
      this._wrote = true;
      return {engine: 'espanso', espansoInstalled: true, matchFile: path, count: result.matches.length};
    } catch (e) {
      this._log?.error('espanso.write_failed', e.message ?? String(e), {path});
      return {engine: 'espanso', espansoInstalled: true, matchFile: path, count: 0};
    }
  }

  /** Stops syncing. Removes the match file unless `keepFile` (the screen is only locking). */
  destroy({keepFile = false} = {}) {
    this._cancellable.cancel();
    if (!keepFile && this._wrote && exists(this.matchFile)) {
      remove(this.matchFile);
      this._log?.record('espanso.removed', {path: this.matchFile, reason: 'Slated stopped'});
    }
    this._wrote = false;
    this._onConfigDirChanged = null;
  }

  _reportUnsupported(result) {
    const fresh = [];
    for (const item of result.skipped) {
      const key = `skip|${item.trigger}|${item.reason}`;
      if (!this._reported.has(key)) {
        this._reported.add(key);
        fresh.push({trigger: item.trigger, skipped: item.reason});
      }
    }
    for (const item of result.approximations) {
      const key = `approx|${item.trigger}|${item.option}`;
      if (!this._reported.has(key)) {
        this._reported.add(key);
        fresh.push({trigger: item.trigger, option: item.option, note: item.note});
      }
    }
    if (fresh.length) this._log?.record('hotstrings.unsupported', {items: fresh}, 'notice');
  }
}
