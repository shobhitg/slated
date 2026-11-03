// Wherever the preferences name one of Slated's files (config.json, settings.json, secrets.json,
// config.v1.json, ~/.config/slated, ~/.slate.js, ~/.slate), the name opens it: a port of the Mac's FileLink
// (Sources/SlatedCore/Model/FileLink.swift), with the same names, links and words. Pure: the window
// (ui/filelinks.js) turns the markup into clickable labels and opens what a link names.

/**
 * Text made safe in markup: in text (not attribute values) Pango needs only &, < and > escaped, so
 * apostrophes and quotes stay as written.
 */
const escapeText = text => String(text ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** The links' URI scheme. Never a real URI: the window opens these itself. */
export const FILE_LINK_SCHEME = 'slated-file';

/**
 * Each link: how the window writes it (`name`) and what the event log calls it (`logName`, the file's
 * name, never a path).
 */
export const FILE_LINKS = Object.freeze({
  config: Object.freeze({name: 'config.json', logName: 'config.json'}),
  settings: Object.freeze({name: 'settings.json', logName: 'settings.json'}),
  secrets: Object.freeze({name: 'secrets.json', logName: 'secrets.json'}),
  backup: Object.freeze({name: 'config.v1.json', logName: 'config.v1.json'}),
  folder: Object.freeze({name: '~/.config/slated', logName: 'folder'}),
  'slate-js': Object.freeze({name: '~/.slate.js', logName: '.slate.js'}),
  slate: Object.freeze({name: '~/.slate', logName: '.slate'}),
});

const SLATE_LINKS = new Set(['slate-js', 'slate']);

/** What the window's text calls each file, longest first (as on the Mac). */
const SPELLINGS = Object.freeze([
  ['~/.config/slated/config.v1.json', 'backup'],
  ['~/.config/slated/config.json', 'config'],
  ['~/.config/slated/settings.json', 'settings'],
  ['~/.config/slated/secrets.json', 'secrets'],
  ['~/.config/slated', 'folder'],
  ['config.v1.json', 'backup'],
  ['config.json', 'config'],
  ['settings.json', 'settings'],
  ['secrets.json', 'secrets'],
  ['~/.slate.js', 'slate-js'],
  ['~/.slate', 'slate'],
]);

/** Every spelling the window links, for tests that look for an unlinked one. */
export const FILE_LINK_SPELLINGS = Object.freeze(SPELLINGS.map(([spelling]) => spelling));

/** `slated-file://config` and the like. */
export function linkUri(link) {
  return `${FILE_LINK_SCHEME}://${link}`;
}

/** The link a URI names; null for any other URI (a web page, a file:// URI). */
export function parseLinkUri(uri) {
  const prefix = `${FILE_LINK_SCHEME}://`;
  if (typeof uri !== 'string' || !uri.startsWith(prefix)) return null;
  const link = uri.slice(prefix.length).replace(/\/$/, '');
  return Object.hasOwn(FILE_LINKS, link) ? link : null;
}

/** The link for one of the files a key is in: 'config.json' → 'config'. */
export function linkForFile(file) {
  if (file === 'settings.json') return 'settings';
  return file === 'secrets.json' ? 'secrets' : 'config';
}

const isWordChar = c => /[\p{L}\p{N}_-]/u.test(c);

/**
 * `text` split into plain runs and the file names in it, in order: [{text}, {text, link}]. Joined, the
 * runs are `text`. A name counts only on its own: `myconfig.json`, `config.jsonc` and `~/.slated`
 * aren't links. `linked(link)` says which links to make (all by default).
 */
export function fileLinkSegments(text, {linked = () => true} = {}) {
  const chars = Array.from(String(text ?? ''));
  const out = [];
  let plain = '';
  const standsAlone = (start, end) => {
    if (start > 0 && (isWordChar(chars[start - 1]) || chars[start - 1] === '.')) return false;
    if (end >= chars.length) return true;
    if (isWordChar(chars[end])) return false;
    // "config.json." ends a sentence; "config.json.bak" and "~/.config/slated/x" go on.
    return !((chars[end] === '.' || chars[end] === '/') && end + 1 < chars.length && isWordChar(chars[end + 1]));
  };
  const matches = (spelling, at) => chars.slice(at, at + spelling.length).join('') === spelling;
  let i = 0;
  while (i < chars.length) {
    const found = SPELLINGS.find(([spelling, link]) => linked(link)
      && matches(spelling, i) && standsAlone(i, i + spelling.length));
    if (found) {
      if (plain) out.push({text: plain});
      plain = '';
      out.push({text: found[0], link: found[1]});
      i += found[0].length;
    } else {
      plain += chars[i];
      i += 1;
    }
  }
  if (plain) out.push({text: plain});
  return out;
}

/** One link as Pango markup, with a tooltip ("Open config.json"). */
export function linkMarkup(text, link) {
  return `<a href="${linkUri(link)}" title="Open ${FILE_LINKS[link].name}">${escapeText(text)}</a>`;
}

/** `text` as Pango markup: escaped, its file names links. */
export function fileLinkMarkup(text, options) {
  return fileLinkSegments(text, options).map(s => (s.link ? linkMarkup(s.text, s.link) : escapeText(s.text))).join('');
}

/**
 * A key's caption as Pango markup: `settings.json › island.enabled` with the file's name a link and the
 * rest plain. A field's key, relative to its item (`trigger`), names no file and has no link.
 */
export function keyLinkMarkup(text) {
  const value = String(text ?? '');
  for (const file of ['config.json', 'settings.json', 'secrets.json']) {
    if (value.startsWith(`${file} ›`)) return linkMarkup(file, linkForFile(file)) + escapeText(value.slice(file.length));
  }
  return escapeText(value);
}

/**
 * Whether `text` (plain or markup) names one of Slated's files outside a link, for tests. `options` as
 * for fileLinkSegments: only the links the window would make count.
 */
export function hasUnlinkedFileName(text, options) {
  const outside = String(text ?? '').replace(/<a\s[^>]*>.*?<\/a>/gs, '').replace(/<[^>]+>/g, '');
  const plain = outside.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  return fileLinkSegments(plain, options).some(s => s.link);
}

/**
 * Where a link's file is: config.json and settings.json where `paths` (lib/prefs/paths.js) has them,
 * the backup and the folder beside them, the Slate files in the home folder.
 */
export function linkPath(link, paths) {
  switch (link) {
  case 'config': return paths.configFile;
  case 'settings': return paths.settingsFile;
  case 'secrets': return paths.secretsFile ?? `${paths.configDir}/secrets.json`;
  case 'backup': return paths.backupFile;
  case 'folder': return paths.configDir;
  case 'slate-js': return `${paths.home}/.slate.js`;
  case 'slate': return `${paths.home}/.slate`;
  default: return null;
  }
}

/** What the window says when the file isn't there, instead of opening nothing without a word. */
export function missingText(link) {
  switch (link) {
  case 'config':
  case 'settings':
    return `${FILE_LINKS[link].name} isn't there yet. Slated creates it the first time it saves a change.`;
  case 'secrets': return "There's no secrets.json yet. Slated creates it when you make a hotstring Sensitive.";
  case 'backup': return "There's no config.v1.json. Slated keeps one only when it updates a version 1 config.json.";
  case 'folder': return "~/.config/slated isn't there yet. Slated creates it the first time it saves a change.";
  default: return `There's no ${FILE_LINKS[link]?.name ?? 'such file'} in your home folder.`;
  }
}

/**
 * Whether the window links `link` where it's named. A Slate file is a link while Slated finds a Slate
 * config (`slateFound`), so "No ~/.slate or ~/.slate.js here" names them without offering to open
 * them; Slated's own files are always links (a missing one says so when clicked).
 */
export function isLinked(link, {slateFound = true} = {}) {
  return !SLATE_LINKS.has(link) || slateFound;
}

/**
 * Opens the file `link` names: the pending edit is saved first (for config.json, settings.json and
 * their folder, so the editor shows what the window shows), then the file opens in its default app,
 * the folder in Files. A file that isn't there opens nothing and the window says so. Logs
 * `ui.config_file_opened` with the file's name and how it opened (`default`, `files`, `missing`).
 * Returns how, or null for a link that isn't one.
 *
 * @param {string} link
 * @param {{paths, exists: (path) => boolean, launch: (path) => void, toast: (message) => void,
 *   log: (event, data) => void, saveNow?: () => void}} io
 */
export function openFileLink(link, {paths, exists, launch, toast, log, saveNow = () => {}}) {
  const info = FILE_LINKS[link];
  if (!info) return null;
  if (link === 'config' || link === 'settings' || link === 'folder') saveNow();
  const path = linkPath(link, paths);
  if (!exists(path)) {
    toast(missingText(link));
    log('ui.config_file_opened', {file: info.logName, with: 'missing'});
    return 'missing';
  }
  launch(path);
  const how = link === 'folder' ? 'files' : 'default';
  log('ui.config_file_opened', {file: info.logName, with: how});
  return how;
}
