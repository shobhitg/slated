// Where each setting lives in Slated's files (port of Sources/SlatedCore/Model/ConfigKey.swift and
// ConfigKeys.swift). The settings window shows the key under every setting
// (`settings.json › island.cheatSheetDelay`) and copies it, so keys must be exactly what the encoder
// writes. fixtures/config-keys.json pins this registry, the naming of items and the copied values to
// Swift's.
//
// A key is {file, components}: components are {key: 'island'} or {index: 2, name: ';sig'|null} for an
// item of a list (named by its natural key when that's unique, else by index).

import {decodeConfiguration} from './config.js';
import {encodeConfigurationFiles, CONFIG_FILE, SETTINGS_FILE} from './configFiles.js';
import {formatJSON, parseJSON5, quoteJSON} from './json.js';

const keys = (dotted) => dotted.split('.').filter(Boolean).map((key) => ({key}));

/** configKey('settings.json', 'island.cheatSheetDelay'). */
export function configKey(file, dotted = '') {
  return Object.freeze({file, components: Object.freeze(keys(dotted))});
}

/** `key` with more keys after it: appendKey(item, 'action.direction'). */
export function appendKey(key, dotted) {
  return Object.freeze({file: key.file, components: Object.freeze([...key.components, ...keys(dotted)])});
}

/** The item at `index` of the list `key` names, with its name (or null). */
export function itemKey(key, index, name = null) {
  return Object.freeze({file: key.file, components: Object.freeze([...key.components, {index, name: name ?? null}])});
}

/** What Copy Key copies: `island.cheatSheetDelay`, `hotstrings[2].replacement`. */
export function keyPath(key) {
  let out = '';
  for (const c of key.components) {
    if (c.key !== undefined) out += out ? `.${c.key}` : c.key;
    else out += `[${c.index}]`;
  }
  return out;
}

function describe(components) {
  let out = '';
  let afterName = false;
  for (const c of components) {
    if (c.key !== undefined) {
      out += out ? `${afterName ? ' › ' : '.'}${c.key}` : c.key;
      afterName = false;
    } else if (c.name === null || c.name === undefined) {
      out += `[${c.index}]`;
      afterName = false;
    } else {
      out += `${out ? ' › ' : ''}${quoteJSON(c.name)}`;
      afterName = true;
    }
  }
  return out;
}

/** What the window shows: `settings.json › island.cheatSheetDelay`, `config.json › hotstrings › ";sig"`. */
export function keyDisplay(key) {
  return `${key.file} › ${describe(key.components)}`;
}

/** The part after `base` (an item), as a field of its editor shows it: `replacement`, `action.direction`. */
export function relativeDisplay(key, base) {
  const n = base.components.length;
  const same = key.file === base.file && key.components.length >= n
    && base.components.every((c, i) => c.key === key.components[i].key && c.index === key.components[i].index);
  return same ? describe(key.components.slice(n)) : keyDisplay(key);
}

/** An item's name when it's not empty and unique in `names`, else null (it goes by index). */
export function itemName(names, index) {
  const name = names[index];
  if (typeof name !== 'string' || !name) return null;
  return names.filter((n) => n === name).length === 1 ? name : null;
}

/**
 * The value at `key` in `configuration`'s file, as the encoder writes it (parsed: numbers as
 * JSONNumber), or undefined when the file doesn't have it. `extras` are the files' unknown keys.
 */
export function valueAt(configuration, key, extras = {}) {
  let node;
  try {
    const texts = encodeConfigurationFiles(configuration, extras);
    node = parseJSON5(key.file === SETTINGS_FILE ? texts.settings : texts.config);
  } catch {
    return undefined;
  }
  for (const c of key.components) {
    if (c.key !== undefined) {
      if (node === null || typeof node !== 'object' || Array.isArray(node) || !Object.prototype.hasOwnProperty.call(node, c.key)) return undefined;
      node = node[c.key];
    } else {
      if (!Array.isArray(node) || c.index < 0 || c.index >= node.length) return undefined;
      node = node[c.index];
    }
  }
  return node;
}

/** What Copy Value as JSON copies: the value as the file has it, pretty-printed; null when it's not there. */
export function valueText(configuration, key, extras = {}) {
  const value = valueAt(configuration, key, extras);
  return value === undefined ? null : formatJSON(value);
}

// --- The registry ----------------------------------------------------------------------------------

const S = SETTINGS_FILE;
const C = CONFIG_FILE;
const BOTH = Object.freeze(['gnome', 'mac']);

/** Every setting with a fixed key, by id (the Mac's ids), in the window's order. */
export const SETTINGS = Object.freeze([
  ['launchAtLogin', S, 'general.launchAtLogin', ['mac']],
  ['showStatusIcon', S, 'general.showStatusIcon'],
  ['showActionHUD', S, 'general.showActionHUD'],
  ['showConfigKeys', S, 'general.showConfigKeys'],
  ['islandEnabled', S, 'island.enabled'],
  ['islandCheatSheet', S, 'island.cheatSheet'],
  ['islandCheatSheetDelay', S, 'island.cheatSheetDelay'],
  ['islandShowFailures', S, 'island.showFailures'],
  ['orderScreensLeftToRight', S, 'windows.orderScreensLeftToRight'],
  ['secondsBeforeRepeat', S, 'windows.secondsBeforeRepeat'],
  ['undoMaxStackSize', S, 'windows.undoMaxStackSize'],
  ['hotstringsEnabled', S, 'general.hotstringsEnabled'],
  ['clipboardEnabled', S, 'clipboard.enabled'],
  ['clipboardShortcut', S, 'clipboard.shortcut'],
  ['clipboardPasteAfterSelecting', S, 'clipboard.pasteAfterSelecting'],
  ['clipboardMaxItems', S, 'clipboard.maxItems'],
  ['clipboardRetentionDays', S, 'clipboard.retentionDays'],
  ['clipboardPersist', S, 'clipboard.persist'],
  ['clipboardScreenshots', S, 'clipboard.screenshots'],
  ['clipboardIgnoreConcealed', S, 'clipboard.ignoreConcealed'],
  ['clipboardExcludedApps', S, 'clipboard.excludedApps'],
  ['automationStopShortcut', S, 'automation.stopShortcut'],
  ['automationStopOnAppSwitch', S, 'automation.stopOnAppSwitch'],
  ['automationMaxRunMinutes', S, 'automation.maxRunMinutes'],
  ['automationShowIndicator', S, 'automation.showIndicator'],
  ['capsLock', C, 'keyboard.capsLock'],
  ['capsLockAlone', C, 'keyboard.capsLockAlone'],
  ['hyperModifiers', C, 'keyboard.hyperModifiers'],
  ['keyRepeat', C, 'keyboard.keyRepeat'],
  ['keyRepeatDelay', C, 'keyboard.keyRepeat.delay'],
  ['keyRepeatInterval', C, 'keyboard.keyRepeat.interval'],
].map(([id, file, path, platforms = BOTH]) => Object.freeze({id, key: configKey(file, path), platforms: Object.freeze([...platforms])})));

/** Settings' keys by id: CONFIG_KEYS.islandEnabled. */
export const CONFIG_KEYS = Object.freeze(Object.fromEntries(SETTINGS.map((s) => [s.id, s.key])));

/** The lists items live in. */
export const LISTS = Object.freeze({
  bindings: configKey(C, 'bindings'), hotstrings: configKey(C, 'hotstrings'), layouts: configKey(C, 'layouts'),
});

/** Items' field keys, relative to the item (ConfigKeys.Binding, .Hotstring, .Layout). */
export const FIELDS = Object.freeze({
  binding: Object.freeze(['name', 'keys', 'modal', 'modal.keys', 'modal.toggle', 'action', 'repeats', 'enabled', 'onlyInApps']),
  hotstring: Object.freeze(['trigger', 'replacement', 'action', 'enabled', 'caseSensitive', 'fire', 'wordBoundary', 'method', 'onlyInApps', 'exceptInApps', 'notes']),
  layout: Object.freeze(['name', 'apps', 'before', 'after']),
  layoutApp: Object.freeze(['app', 'operations', 'options.ignoreFail', 'options.repeat', 'options.mainFirst', 'options.sortTitle']),
});

/** Each operation's parameters besides `op` (ConfigKeys.Action.parameters). */
export const ACTION_PARAMETERS = Object.freeze({
  'move': ['x', 'y', 'width', 'height', 'screen'],
  'resize': ['width', 'height', 'anchor'],
  'push': ['direction', 'style', 'screen'],
  'nudge': ['x', 'y'],
  'throw': ['screen', 'width', 'height'],
  'corner': ['direction', 'width', 'height', 'screen'],
  'chain': ['operations'],
  'sequence': ['operations', 'steps'],
  'layout': ['name'],
  'focus': ['direction', 'app'],
  'snapshot': ['name', 'save', 'stack'],
  'delete-snapshot': ['name', 'all'],
  'activate-snapshot': ['name', 'delete'],
  'hint': ['characters'],
  'grid': ['padding', 'grids'],
  'hide': ['app'], 'show': ['app'], 'toggle': ['app'],
  'shell': ['command', 'wait', 'path'],
  'undo': [], 'relaunch': [], 'switch': [],
  'by-orientation': ['landscape', 'portrait'],
  'insert-text': ['text', 'method'],
  'open-url': ['url'],
  'keystroke': ['keys'],
  'click': ['button', 'count'],
  'press': ['input', 'phase'],
  'hold': ['input'],
  'repeat': ['action', 'interval', 'mode', 'times', 'jitter'],
  'wait': ['seconds'],
  'stop-automations': [],
  'clipboard-history': [],
});

/** Keys the files have that no control shows (ConfigKeys.notShown). */
export const NOT_SHOWN = Object.freeze({
  'settings.json › version': 'The format\'s version, written by Slated.',
  'config.json › version': 'The format\'s version, written by Slated.',
  'settings.json › windows': 'Slate\'s own settings: the window shows the three people tune; the rest are for hand edits.',
  'config.json › defaults': 'Slate\'s default layouts per display arrangement: imported from Slate, edited by hand.',
});

// --- Items' keys -------------------------------------------------------------------------------------

/** The binding at `index`, named by its keys when unique; one behind a modal key goes by index. */
export function bindingKey(configuration, index) {
  const names = decodeConfiguration(configuration).bindings.map((b) => (b.modal ? '' : b.keys));
  return itemKey(LISTS.bindings, index, itemName(names, index));
}

/** The hotstring at `index`, named by its trigger when unique. */
export function hotstringKey(configuration, index) {
  return itemKey(LISTS.hotstrings, index, itemName(configuration.hotstrings.map((h) => h.trigger), index));
}

/** The layout at `index`, named by its name when unique. */
export function layoutKey(configuration, index) {
  return itemKey(LISTS.layouts, index, itemName(configuration.layouts.map((l) => l.name), index));
}

/** The app at `index` of `layout`, under the layout's key, named by its app when unique. */
export function layoutAppKey(layout, index, key) {
  return itemKey(appendKey(key, 'apps'), index, itemName((layout.apps ?? []).map((a) => a.app), index));
}
