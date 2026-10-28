// The island's cheat sheet: every Hyper shortcut (or a modal key's shortcuts), grouped by what they do
// and in keyboard order. A port of SlatedUI's CheatSheet (Sources/SlatedUI/Island/CheatSheet.swift),
// pinned to Swift by fixtures/cheatsheet.json, so the Mac and GNOME islands list the same thing.
//
// A shortcut is {keys, modal?, name?, action?, summary?}: keys and modal as KeyCombos or config strings,
// the action in any form config.json takes, `summary` what to show for a script without either.
// A sheet is {title, isHyper, sections: [{title, items: [item]}]}; an item is
// {id, label, title, region, symbol, keys, extraModifiers}: `label` is the keycap as the Mac shows it
// ("⇧H" under Hyper), `keys` the combo and `extraModifiers` the modifiers beyond Hyper, so a platform
// can label keycaps its own way.

import {actionRegion, actionSymbol, actionTitle} from './actionNames.js';
import {decodeAction, isAutomation} from './config.js';
import {canonicalKey, displayKeyCombo, formatKeyCombo, keyDisplayName, modifierMask, modifiersFromMask, namedKeys, parseKeyCombo} from './keys.js';
import {characterCount, hasPrefix, hasSuffix, lowercased, trimWhitespace, uppercased} from './text.js';

/** Sections in the order the island shows them. */
export const CHEAT_SHEET_GROUPS = Object.freeze(['Windows', 'Displays', 'Apps & Focus', 'Layouts', 'Automation', 'Utilities', 'Scripts']);
const [WINDOWS, DISPLAYS, APPS, LAYOUTS, AUTOMATION, UTILITIES, SCRIPTS] = CHEAT_SHEET_GROUPS;

const SYMBOLS = ['fn', 'ctrl', 'alt', 'shift', 'cmd'];
const GLYPHS = {fn: 'fn', ctrl: '⌃', alt: '⌥', shift: '⇧', cmd: '⌘'};

function comboOf(value) {
  if (value === null || value === undefined) return null;
  try {
    if (typeof value === 'string') return parseKeyCombo(value);
    if (typeof value === 'object' && typeof value.key === 'string') return parseKeyCombo(formatKeyCombo(value));
  } catch {
    // Not a key combo: the shortcut isn't listed.
  }
  return null;
}

function maskOf(modifiers) {
  let mask = 0;
  for (const m of modifiers ?? []) mask |= modifierMask(m) ?? 0;
  return mask;
}

function canonical(action) {
  if (action === null || action === undefined) return null;
  try {
    return decodeAction(action);
  } catch {
    return null;
  }
}

/** Shortcuts as the sheet works on them: parsed combos, canonical actions and their ids. */
function normalize(shortcuts) {
  const out = [];
  for (const s of shortcuts ?? []) {
    const keys = comboOf(s?.keys);
    if (!keys) continue;
    const modal = comboOf(s.modal);
    const id = (modal ? `${formatKeyCombo(modal)} ` : '') + formatKeyCombo(keys);
    out.push({keys, modal, id, name: s.name ?? null, action: canonical(s.action), summary: s.summary ?? null});
  }
  return out;
}

/** Anything that clicks or presses is an automation, as in Settings, whatever its shape. */
function containsAutomation(action) {
  if (isAutomation(action)) return true;
  switch (action.op) {
    case 'chain':
      return action.operations.some(containsAutomation);
    case 'sequence':
      return (action.steps?.map((s) => s.action) ?? action.operations).some(containsAutomation);
    case 'by-orientation':
      return containsAutomation(action.landscape) || containsAutomation(action.portrait);
    default:
      return false;
  }
}

/** The section an action goes under (CheatSheet.group). */
export function cheatSheetGroup(action) {
  const a = canonical(action);
  return a ? groupOf(a) : SCRIPTS;
}

function groupOf(a) {
  if (containsAutomation(a)) return AUTOMATION;
  switch (a.op) {
    case 'throw':
      return DISPLAYS;
    case 'by-orientation':
      return groupOf(a.landscape);
    case 'chain':
      return a.operations.length ? groupOf(a.operations[0]) : WINDOWS;
    case 'sequence': {
      // Like a chain, a sequence goes with its first step ("Next display, then maximize" is a display shortcut).
      const first = a.steps?.[0]?.action ?? a.operations?.[0];
      return first ? groupOf(first) : UTILITIES;
    }
    case 'move': case 'resize': case 'push': case 'nudge': case 'corner': case 'grid': case 'undo':
      return WINDOWS;
    case 'focus': case 'hide': case 'show': case 'toggle': case 'switch': case 'hint':
      return APPS;
    case 'layout': case 'snapshot': case 'activate-snapshot': case 'delete-snapshot':
      return LAYOUTS;
    case 'click': case 'press': case 'hold': case 'repeat': case 'wait': case 'stop-automations':
      return AUTOMATION;
    default:
      return UTILITIES;
  }
}

function titleFor(shortcut) {
  const name = shortcut.name === null ? '' : trimWhitespace(String(shortcut.name));
  if (name !== '') return name;
  if (shortcut.action) return actionTitle(shortcut.action);
  return shortcut.summary ?? 'Script';
}

/**
 * Drops what the section title already says: under Displays, "Throw to the screen on the right" reads
 * "Screen on the right", and "Throw to Display Above, Resized" reads "Display Above".
 */
function shortened(title, group) {
  if (group !== DISPLAYS) return title;
  let text = title;
  if (hasSuffix(text, ', Resized')) text = text.slice(0, -', Resized'.length);
  for (const prefix of ['Throw to the ', 'Throw to ']) {
    if (hasPrefix(text, prefix) && characterCount(text) > characterCount(prefix)) {
      const [first, ...rest] = Array.from(text.slice(prefix.length));
      return uppercased(first) + rest.join('');
    }
  }
  return text;
}

/** Named keys in natural order, so F2 comes before F10: by name, then by the number they end with. */
const NAMED_KEY_ORDER = (() => {
  const split = (name) => {
    const digits = /[0-9]*$/.exec(name)[0];
    return {name: lowercased(name.slice(0, name.length - digits.length)), number: digits === '' ? -1 : Number(digits)};
  };
  const names = namedKeys().sort((a, b) => {
    const x = split(a);
    const y = split(b);
    if (x.name !== y.name) return x.name < y.name ? -1 : 1;
    return x.number - y.number;
  });
  return new Map(names.map((name, index) => [name, index]));
})();

const ARROWS = ['left', 'up', 'down', 'right'];

/**
 * Keyboard order: letters, digits (1 before 0, as on the keyboard), punctuation, arrows, then everything
 * else by name; fewer extra modifiers first.
 */
function rank(combo) {
  const key = lowercased(combo.key);
  const single = characterCount(key) === 1;
  // Swift looks at a character's first scalar: "é" spelled e + accent counts as an e.
  const first = key.codePointAt(0);
  let base;
  if (single && first >= 97 && first <= 122) base = first - 97;
  else if (single && /^[0-9]$/.test(key)) base = 100 + (key === '0' ? 10 : Number(key));
  else if (ARROWS.includes(key)) base = 300 + ARROWS.indexOf(key);
  else if (single) base = 200 + (first % 100);
  else base = 400 + (NAMED_KEY_ORDER.get(canonicalKey(combo.key)) ?? NAMED_KEY_ORDER.size);
  return [base, combo.modifiers.length];
}

function sections(shortcuts, label) {
  const seen = new Set();
  const groups = new Map();
  for (const shortcut of shortcuts) {
    if (seen.has(shortcut.id)) continue;
    seen.add(shortcut.id);
    const group = shortcut.action ? groupOf(shortcut.action) : SCRIPTS;
    const item = {
      id: shortcut.id,
      label: label(shortcut.keys),
      title: shortened(titleFor(shortcut), group),
      region: shortcut.action ? actionRegion(shortcut.action) : null,
      symbol: (shortcut.action && actionSymbol(shortcut.action)) || 'curlybraces',
      keys: shortcut.keys,
      extraModifiers: [],
    };
    if (!groups.has(group)) groups.set(group, []);
    groups.get(group).push({rank: rank(shortcut.keys), item});
  }
  const out = [];
  for (const title of CHEAT_SHEET_GROUPS) {
    const entries = groups.get(title);
    if (!entries?.length) continue;
    // Array#sort is stable, like Swift's sort on equal ranks.
    entries.sort((a, b) => a.rank[0] - b.rank[0] || a.rank[1] - b.rank[1]);
    out.push({title, items: entries.map((e) => e.item)});
  }
  return out;
}

/**
 * Every shortcut that holds at least the Hyper modifiers, without a modal key. The first shortcut for
 * a key wins, as when registering hotkeys.
 * @param {object[]} shortcuts  In registration order.
 * @param {string[]} [hyperModifiers]  keyboard.hyperModifiers (default Ctrl+Alt+Shift+Cmd).
 */
export function hyperCheatSheet(shortcuts, hyperModifiers = ['ctrl', 'alt', 'shift', 'cmd']) {
  const hyper = maskOf(hyperModifiers);
  const matching = normalize(shortcuts).filter((s) => !s.modal && (maskOf(s.keys.modifiers) & hyper) === hyper && s.keys.key !== '');
  const result = sections(matching, (combo) => {
    const extra = modifiersFromMask(maskOf(combo.modifiers) & ~hyper);
    return SYMBOLS.filter((m) => extra.includes(m)).map((m) => GLYPHS[m]).join('') + keyDisplayName(combo.key);
  });
  for (const section of result) {
    for (const item of section.items) item.extraModifiers = modifiersFromMask(maskOf(item.keys.modifiers) & ~hyper);
  }
  return {title: 'Hyper', isHyper: true, sections: result};
}

/** The keys available after pressing the modal key `modal`. */
export function modalCheatSheet(modal, shortcuts) {
  const modalCombo = comboOf(modal);
  if (!modalCombo) return {title: '', isHyper: false, sections: []};
  const modalId = formatKeyCombo(modalCombo);
  const matching = normalize(shortcuts).filter((s) => s.modal && formatKeyCombo(s.modal) === modalId && s.keys.key !== '');
  const result = sections(matching, (combo) => displayKeyCombo(combo));
  for (const section of result) for (const item of section.items) item.extraModifiers = [...item.keys.modifiers];
  return {title: displayKeyCombo(modalCombo), isHyper: false, sections: result};
}

/** Every item of a sheet, in order. */
export const cheatSheetItems = (sheet) => (sheet?.sections ?? []).flatMap((s) => s.items);
