// Settings → Automation and Settings → Clipboard without the GTK parts: the recipes (port of
// Sources/SlatedUI/Model/AutomationRecipes.swift), plain-language descriptions of automation
// actions, the choices offered for time limits and clipboard history, Slated's two built-in
// shortcuts, which apps a binding works in, and what GNOME does differently from the Mac (a
// while-held repeat notices the key is let go through key repeat; mouse buttons can't be shortcuts).
//
// Pure ES module.

import {isObject, deepEqual} from './util.js';
import {actionTitle, secondsText, containsAutomation, resolveAction} from './actions.js';
import {keysCombo, keysString, keyLabel, comboLabel, isModifierKey, statusKey} from './keys.js';

// --- Settings defaults (Swift's ClipboardSettings and AutomationSettings) ---------------------------

/** The Mac's default excluded apps: password managers, by bundle identifier. */
export const MAC_PASSWORD_MANAGERS = Object.freeze([
  'com.1password.1password', 'com.agilebits.onepassword7', 'com.bitwarden.desktop', 'com.apple.keychainaccess',
  'com.apple.Passwords', 'com.lastpass.LastPass', 'com.dashlane.dashlanephonefinal',
]);

export function defaultClipboardSettings() {
  return {
    enabled: true, shortcut: 'shift+cmd+v', maxItems: 200, persist: true, retentionDays: 30, ignoreConcealed: true,
    excludedApps: [...MAC_PASSWORD_MANAGERS], pasteAfterSelecting: true,
  };
}

export function defaultAutomationSettings() {
  return {stopShortcut: 'hyper+esc', stopOnAppSwitch: true, maxRunMinutes: 0, showIndicator: true};
}

/** The configuration's clipboard settings with every default filled in. */
export function clipboardSettings(config) {
  return {...defaultClipboardSettings(), ...(isObject(config?.clipboard) ? config.clipboard : {})};
}

/** The configuration's automation settings with every default filled in. */
export function automationSettings(config) {
  return {...defaultAutomationSettings(), ...(isObject(config?.automation) ? config.automation : {})};
}

// --- Choices -------------------------------------------------------------------------------------------

/** Time limits for automations, in minutes (0: none). */
export const TIME_LIMITS = Object.freeze([0, 1, 5, 15, 30, 60]);

export function timeLimitTitle(minutes) {
  if (minutes === 0) return 'No limit';
  if (minutes === 60) return '1 hour';
  return `${Number.isInteger(minutes) ? minutes : minutes.toFixed(1)} min`;
}

export const MAX_ITEMS = Object.freeze([50, 100, 200, 500, 1000]);
/** Days to keep clipboard items; 0 is forever (listed last). */
export const RETENTION_DAYS = Object.freeze([1, 7, 30, 90, 0]);

export function retentionTitle(days) {
  if (days === 0) return 'Forever';
  if (days === 1) return '1 day';
  if (days === 7) return '1 week';
  return `${days} days`;
}

/**
 * `values`, plus `current` in order when a hand edit set something else (kept and shown as its own
 * choice). A 0 ("no limit", "forever") stays first or last, where the list has it.
 */
export function withCurrent(values, current) {
  if (values.includes(current)) return [...values];
  const zeroFirst = values[0] === 0;
  const zeroLast = !zeroFirst && values[values.length - 1] === 0;
  const merged = [...values.filter(v => v !== 0), current].sort((a, b) => a - b);
  if (zeroFirst) return [0, ...merged];
  return zeroLast ? [...merged, 0] : merged;
}

// --- Plain-language descriptions (AutomationDescriber) ---------------------------------------------

const MOUSE_TITLES = {left: 'Left', right: 'Right', middle: 'Middle'};
const mouseTitle = button => MOUSE_TITLES[button] ?? String(button ?? 'left');

/** "10 per second", "2.5 per second", "once every 2 seconds". */
export function rate(interval) {
  if (!(interval > 0) || !Number.isFinite(interval)) return '—';
  if (interval > 1.0001) return `once every ${Number.isInteger(interval) ? interval : interval.toFixed(1)} seconds`;
  const perSecond = 1 / interval;
  return Math.abs(perSecond - Math.round(perSecond)) < 0.05 ? `${Math.round(perSecond)} per second` : `${perSecond.toFixed(1)} per second`;
}

/** "10/s", "1 per 2 s": the short form for chips. */
export function shortRate(interval) {
  if (!(interval > 0) || !Number.isFinite(interval)) return '—';
  if (interval > 1.0001) return `1 per ${secondsText(interval)}`;
  const perSecond = 1 / interval;
  return Math.abs(perSecond - Math.round(perSecond)) < 0.05 ? `${Math.round(perSecond)}/s` : `${perSecond.toFixed(1)}/s`;
}

export function modeTitle(mode) {
  return mode === 'while-held' ? 'While held' : 'Toggle';
}

export function modeExplanation(mode) {
  return mode === 'while-held' ? 'Runs only while you hold the shortcut down.' : 'Press the shortcut to start, press it again to stop.';
}

/** "±15%". */
export function jitterText(value) {
  return `±${Math.round(value * 100)}%`;
}

/** Modifier keys that can be held on their own (they can't be recorded alone), with their names on Linux. */
export const MODIFIER_KEY_CHOICES = Object.freeze([
  {key: 'shift', title: 'Shift'}, {key: 'ctrl', title: 'Ctrl'}, {key: 'alt', title: 'Alt'}, {key: 'cmd', title: 'Super'},
  {key: 'rightShift', title: 'Right Shift'}, {key: 'rightCtrl', title: 'Right Ctrl'}, {key: 'rightAlt', title: 'Right Alt'},
  {key: 'rightCmd', title: 'Right Super'},
]);

/** Keys games commonly use, offered as one-click choices in key pickers. */
export const COMMON_GAME_KEYS = Object.freeze(['w', 'a', 's', 'd', 'space', 'e', 'f', 'r', 'q', '1', '2', '3']);

/** "mouse:left" → {kind: 'mouse', button}; "key:w" → {kind: 'key', keys: 'w'}; anything else → null. */
export function parseInput(input) {
  const text = String(input ?? '').trim();
  const lower = text.toLowerCase();
  if (lower.startsWith('mouse:')) {
    const button = lower.slice('mouse:'.length);
    return ['left', 'right', 'middle'].includes(button) ? {kind: 'mouse', button} : null;
  }
  if (lower.startsWith('key:')) {
    const keys = text.slice('key:'.length);
    return keysCombo(keys).key ? {kind: 'key', keys: keysString(keys)} : null;
  }
  return null;
}

/** "Left Button", "W", "Shift": what an input is called in sentences. */
export function inputName(input) {
  const parsed = parseInput(input);
  if (!parsed) return 'a key';
  if (parsed.kind === 'mouse') return `${mouseTitle(parsed.button)} Button`;
  const combo = keysCombo(parsed.keys);
  if (!combo.modifiers.length && isModifierKey(combo.key)) return keyLabel(combo.key);
  return comboLabel(parsed.keys);
}

/** The key part of a "key:…" input as a combo, else null. */
function inputCombo(input) {
  const parsed = parseInput(input);
  return parsed?.kind === 'key' ? keysCombo(parsed.keys) : null;
}

/** The total time a macro's steps take: the sum of its waits (MacroSchedule.duration). */
export function macroDuration(steps) {
  return (steps ?? []).reduce((sum, step) => {
    const a = resolveAction(step);
    return a?.op === 'wait' && a.seconds > 0 ? sum + a.seconds : sum;
  }, 0);
}

const sequenceSteps = a => (a.steps ? a.steps.map(step => step?.action) : (a.operations ?? []));

/** One sentence for lists: "Clicks the left button 10 times a second until pressed again". */
export function sentence(action) {
  const a = resolveAction(action);
  if (!a) return actionTitle(action);
  switch (a.op) {
  case 'repeat': {
    const repeated = resolveAction(a.action);
    let what;
    if (repeated?.op === 'click') {
      what = `${repeated.count === 2 ? 'Double-clicks the ' : 'Clicks the '}${mouseTitle(repeated.button).toLowerCase()} button`;
    } else if (repeated?.op === 'keystroke') {
      what = `Presses ${keysCombo(repeated.keys).key ? comboLabel(repeated.keys) : 'a key'}`;
    } else {
      what = `Runs ${actionTitle(a.action)}`;
    }
    const speed = rate(a.interval).replace('per second', 'times a second');
    let text = Number.isInteger(a.times) ? `${what} ${a.times} time${a.times === 1 ? '' : 's'}, ${speed}` : `${what} ${speed}`;
    text += a.mode === 'while-held' ? ' while held' : Number.isInteger(a.times) ? '' : ' until pressed again';
    if (a.jitter > 0) text += `, timing varied ${jitterText(a.jitter)}`;
    return text;
  }
  case 'hold': {
    const parsed = parseInput(a.input);
    if (parsed?.kind === 'mouse') return `Holds the ${mouseTitle(parsed.button).toLowerCase()} button down until pressed again`;
    return `Holds ${inputName(a.input)} down until pressed again`;
  }
  case 'click': {
    const button = mouseTitle(a.button).toLowerCase();
    const count = Number.isInteger(a.count) ? a.count : 1;
    if (count === 1) return `Clicks the ${button} button once`;
    if (count === 2) return `Double-clicks the ${button} button`;
    return `Clicks the ${button} button ${count} times`;
  }
  case 'press': return `${a.phase === 'up' ? 'Releases ' : 'Presses '}${inputName(a.input)}`;
  case 'wait': return `Waits ${secondsText(a.seconds)}`;
  case 'stop-automations': return 'Stops every automation and lets go of anything held';
  case 'sequence': {
    const steps = sequenceSteps(a);
    const titles = steps.slice(0, 4).map(actionTitle);
    return `${steps.length} step${steps.length === 1 ? '' : 's'}: ${titles.join(' → ')}${steps.length > 4 ? ' → …' : ''}`;
  }
  default:
    return actionTitle(a);
  }
}

/** Short facts for chips: "10/s", "Toggle"; "4 steps", "2 s". */
export function facts(action) {
  const a = resolveAction(action);
  switch (a?.op) {
  case 'repeat': {
    const out = [shortRate(a.interval), Number.isInteger(a.times) ? `${a.times}×` : modeTitle(a.mode)];
    if (a.jitter > 0) out.push(jitterText(a.jitter));
    return out;
  }
  case 'hold': return ['Toggle'];
  case 'click': {
    const count = Number.isInteger(a.count) ? a.count : 1;
    return [count === 1 ? '1 click' : count === 2 ? '2 clicks' : `${count} clicks`];
  }
  case 'sequence': {
    const steps = sequenceSteps(a);
    const duration = macroDuration(steps);
    return [`${steps.length} steps`, ...(duration > 0 ? [secondsText(duration)] : [])];
  }
  default: return [];
  }
}

// --- Recipes -------------------------------------------------------------------------------------------

const recipe = (id, title, summary, detail, icon, action, options = []) => Object.freeze({id, title, summary, detail, icon, action, options});
const repeatClick = (button, extra = {}) => ({op: 'repeat', action: {op: 'click', button}, interval: 0.1, ...extra});

/**
 * Ready-made automations for Settings → Automation, as on the Mac. Adding one creates an ordinary
 * binding in config.bindings, edited like any other shortcut.
 */
export const RECIPES = Object.freeze([
  // Clicking
  recipe('auto-click-left', 'Auto-Click Left', 'Clicks the left button 10 times a second.',
    'Clicks the left mouse button wherever the pointer is, 10 times a second, until you press the shortcut again.',
    'media-playlist-repeat-symbolic', repeatClick('left'), ['speed', 'humanize']),
  recipe('auto-click-right', 'Auto-Click Right', 'Clicks the right button 10 times a second.',
    'Clicks the right mouse button wherever the pointer is, 10 times a second, until you press the shortcut again.',
    'media-playlist-repeat-symbolic', repeatClick('right'), ['speed', 'humanize']),
  recipe('double-click', 'Double-Click', 'A perfect double-click from one keystroke.',
    'Double-clicks where the pointer is. Handy where double-clicking is tiring, or for a mouse that misfires.',
    'input-mouse-symbolic', {op: 'click', button: 'left', count: 2}, ['button']),
  recipe('click-times', 'Click 50 Times', '50 clicks, 10 a second, then it stops by itself.',
    'Clicks the left mouse button 50 times, 10 a second, then stops on its own. Press the shortcut again to stop early.',
    'view-list-ordered-symbolic', repeatClick('left', {times: 50}), ['count', 'speed']),
  // Holding
  recipe('hold-left', 'Hold Left Click', 'Keeps the left button down: mine, drag or fire.',
    'Presses the left mouse button and keeps it down until you press the shortcut again.',
    'input-mouse-symbolic', {op: 'hold', input: 'mouse:left'}),
  recipe('hold-right', 'Hold Right Click', 'Keeps the right button down: aim, block or charge.',
    'Presses the right mouse button and keeps it down until you press the shortcut again.',
    'input-mouse-symbolic', {op: 'hold', input: 'mouse:right'}),
  recipe('hold-w', 'Hold W (Auto-Run)', 'Keeps W pressed so your character keeps running.',
    'Presses W and keeps it down until you press the shortcut again. Steer with the mouse meanwhile.',
    'input-keyboard-symbolic', {op: 'hold', input: 'key:w'}, ['key']),
  recipe('toggle-sprint', 'Toggle Sprint (Shift)', 'Holds Shift for you, so sprint stays on.',
    'Presses Shift and keeps it down until you press the shortcut again, for games that only sprint while Shift is held.',
    'input-keyboard-symbolic', {op: 'hold', input: 'key:shift'}, ['modifierKey']),
  recipe('toggle-crouch', 'Toggle Crouch (Ctrl)', 'Holds Ctrl for you, so you stay crouched.',
    "Presses Ctrl and keeps it down until you press the shortcut again, for games that only crouch while it's held.",
    'input-keyboard-symbolic', {op: 'hold', input: 'key:ctrl'}, ['modifierKey']),
  // Keys and macros
  recipe('spam-key', 'Spam a Key', 'Presses E 20 times a second while you hold the shortcut.',
    'Presses E over and over, 20 times a second, for as long as you hold the shortcut down.',
    'input-keyboard-symbolic', {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05, mode: 'while-held'},
    ['key', 'speed', 'humanize']),
  recipe('macro', 'Macro: Walk, Then Click', 'Holds W for 2 seconds, lets go, then clicks.',
    'A sequence with a wait: press W down, wait 2 seconds, release W, then click. A starting point for your own macros: add, remove or reorder steps in the editor.',
    'view-list-ordered-symbolic', {op: 'sequence', operations: [
      {op: 'press', input: 'key:w', phase: 'down'}, {op: 'wait', seconds: 2}, {op: 'press', input: 'key:w', phase: 'up'},
      {op: 'click', button: 'left'},
    ]}),
]);

export function recipeById(id) {
  return RECIPES.find(r => r.id === id) ?? null;
}

/** The binding name for a recipe's (possibly adjusted) action: "Click 25 Times", "Spam F", "Hold Space". */
export function recipeBindingName(r, action) {
  const a = resolveAction(action);
  if (r.id === 'click-times' && a?.op === 'repeat' && resolveAction(a.action)?.op === 'click' && Number.isInteger(a.times)) {
    return `Click ${a.times} Time${a.times === 1 ? '' : 's'}`;
  }
  if (r.id === 'spam-key' && a?.op === 'repeat') {
    const repeated = resolveAction(a.action);
    if (repeated?.op === 'keystroke' && keysString(repeated.keys) !== 'e') return `Spam ${comboLabel(repeated.keys)}`;
  }
  if (r.id === 'hold-w' && a?.op === 'hold') {
    const combo = inputCombo(a.input);
    if (combo && !(combo.key === 'w' && !combo.modifiers.length)) return `Hold ${inputName(a.input)}`;
  }
  return r.title;
}

/** Whether `action` is this recipe, adjusted or not (an auto-clicker at another speed still counts). */
export function recipeMatches(r, action) {
  const a = resolveAction(action);
  if (!a) return false;
  const repeated = a.op === 'repeat' ? resolveAction(a.action) : null;
  const plainClick = (button) => repeated?.op === 'click' && (repeated.button ?? 'left') === button && (repeated.count ?? 1) === 1;
  switch (r.id) {
  case 'auto-click-left': return a.op === 'repeat' && plainClick('left') && a.mode !== 'while-held' && !Number.isInteger(a.times);
  case 'auto-click-right': return a.op === 'repeat' && plainClick('right') && a.mode !== 'while-held' && !Number.isInteger(a.times);
  case 'click-times': return a.op === 'repeat' && repeated?.op === 'click' && Number.isInteger(a.times);
  case 'spam-key': return a.op === 'repeat' && repeated?.op === 'keystroke' && a.mode === 'while-held';
  case 'double-click': return a.op === 'click' && a.count === 2;
  case 'hold-left': return a.op === 'hold' && parseInput(a.input)?.button === 'left';
  case 'hold-right': return a.op === 'hold' && parseInput(a.input)?.button === 'right';
  case 'hold-w': {
    const combo = a.op === 'hold' ? inputCombo(a.input) : null;
    return Boolean(combo) && !isModifierKey(combo.key);
  }
  case 'toggle-sprint': {
    const combo = a.op === 'hold' ? inputCombo(a.input) : null;
    return Boolean(combo) && combo.key.toLowerCase().endsWith('shift');
  }
  case 'toggle-crouch': {
    const combo = a.op === 'hold' ? inputCombo(a.input) : null;
    return Boolean(combo) && combo.key.toLowerCase().endsWith('ctrl');
  }
  default: return deepEqual(a, r.action);
  }
}

/** The number a recipe row shows: the speed or the count. */
export function recipeBadge(action) {
  const a = resolveAction(action);
  if (a?.op === 'repeat') return Number.isInteger(a.times) ? `×${a.times}` : shortRate(a.interval);
  if (a?.op === 'click' && a.count > 1) return `${a.count}×`;
  return null;
}

/** How a recipe starts and stops, for its chip: "Toggle", "While held", "Auto-stops", "Instant", "4 steps". */
export function recipeChip(action) {
  const a = resolveAction(action);
  switch (a?.op) {
  case 'repeat': return Number.isInteger(a.times) ? 'Auto-stops' : modeTitle(a.mode);
  case 'hold': return 'Toggle';
  case 'click': return 'Instant';
  case 'sequence': return `${sequenceSteps(a).length} steps`;
  default: return actionTitle(a);
  }
}

// --- Automation bindings ---------------------------------------------------------------------------

/** Slated bindings that click, press or hold, anywhere in their action, in config order. */
export function automationBindings(config) {
  return (config?.bindings ?? []).filter(b => containsAutomation(b.action));
}

/** A binding already set up from the recipe (adjusted or not), if there is one. */
export function bindingForRecipe(config, r) {
  return (config?.bindings ?? []).find(b => recipeMatches(r, b.action)) ?? null;
}

/**
 * Keys to offer for a new automation, as on the Mac: the first free function key from F6 up, then a
 * free ✦ digit when Caps Lock is the Hyper key, then more function keys. `used` holds status keys
 * ("f6", "hyper+1") already taken.
 */
export function suggestedAutomationKeys(config, used, limit = 2) {
  const preferred = [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 5].map(n => `f${n}`);
  const free = preferred.filter(k => !used.has(k));
  const result = free.slice(0, 1);
  if (config?.keyboard?.capsLock === 'hyper') {
    const digit = [1, 2, 3, 4, 5, 6, 7, 8, 9].map(n => keysString(`hyper+${n}`)).find(k => !used.has(k));
    if (digit) result.push(digit);
  }
  result.push(...free.slice(1, 1 + Math.max(0, limit - result.length)));
  return result.slice(0, limit);
}

/** Status keys of the enabled bindings and built-in shortcuts, for suggestions. */
export function usedShortcutKeys(config) {
  const used = new Set();
  for (const b of config?.bindings ?? []) {
    if (b.enabled !== false && keysString(b.keys)) used.add(statusKey(b.keys, b.modal));
  }
  for (const builtIn of BUILT_IN_SHORTCUTS) {
    const keys = builtIn.keys(config);
    if (keys) used.add(keysString(keys));
  }
  return used;
}

// --- Built-in shortcuts --------------------------------------------------------------------------------

/**
 * Slated's own global shortcuts, which live in Settings → Clipboard and Settings → Automation rather
 * than in config.bindings. A binding on the same keys wins over them (it's registered first).
 */
export const BUILT_IN_SHORTCUTS = Object.freeze([
  Object.freeze({
    id: 'clipboard', title: 'the clipboard history shortcut', effect: 'open the clipboard history', action: {op: 'clipboard-history'},
    keys: config => {
      const c = clipboardSettings(config);
      return c.enabled && c.shortcut ? keysString(c.shortcut) : null;
    },
  }),
  Object.freeze({
    id: 'stopAutomations', title: 'the stop-automations shortcut', effect: 'stop automations', action: {op: 'stop-automations'},
    keys: config => {
      const c = automationSettings(config);
      return c.stopShortcut ? keysString(c.stopShortcut) : null;
    },
  }),
]);

export function builtInShortcut(id) {
  return BUILT_IN_SHORTCUTS.find(b => b.id === id) ?? null;
}

// --- Which apps a binding works in ------------------------------------------------------------------

/** An app id as the extension compares them: no ".desktop", any case. */
export function normalizeAppId(id) {
  return String(id ?? '').trim().toLowerCase().replace(/\.desktop$/, '');
}

/** Whether two bindings can be live at the same time: either works everywhere, or they share an app. */
export function sharesApps(a, b) {
  const mine = (a?.onlyInApps ?? []).map(normalizeAppId);
  const theirs = (b?.onlyInApps ?? []).map(normalizeAppId);
  return !mine.length || !theirs.length || mine.some(id => theirs.includes(id));
}

/** Known names of the Mac's default excluded apps, for rows in Settings → Clipboard. */
export const MAC_APP_NAMES = Object.freeze({
  'com.1password.1password': '1Password', 'com.agilebits.onepassword7': '1Password 7', 'com.bitwarden.desktop': 'Bitwarden',
  'com.apple.keychainaccess': 'Keychain Access', 'com.apple.Passwords': 'Passwords', 'com.lastpass.LastPass': 'LastPass',
  'com.dashlane.dashlanephonefinal': 'Dashlane',
});

/** Linux password managers by desktop id (Flatpak or distribution package). */
export const LINUX_PASSWORD_MANAGERS = Object.freeze([
  {id: 'org.keepassxc.KeePassXC', name: 'KeePassXC'},
  {id: 'com.bitwarden.desktop', name: 'Bitwarden'},
  {id: 'bitwarden', name: 'Bitwarden'},
  {id: '1password', name: '1Password'},
  {id: 'org.gnome.World.Secrets', name: 'Secrets'},
  {id: 'org.gnome.seahorse.Application', name: 'Passwords and Keys'},
]);

const PASSWORD_MANAGER_NAME = /password|keepass|bitwarden|1password|secrets|keyring|enpass|lastpass|dashlane|proton pass/i;

/** Installed apps that look like password managers ({id, name} from the app list), known ids first. */
export function passwordManagerApps(installed) {
  const known = new Set(LINUX_PASSWORD_MANAGERS.map(m => normalizeAppId(m.id)));
  return installed.filter(app => known.has(normalizeAppId(app.id)) || PASSWORD_MANAGER_NAME.test(app.name));
}

/**
 * A name for an app id in lists: the installed app's name, a recent app's, a Mac password manager's
 * (marked "Mac"), else the id itself.
 */
export function appDisplayName(id, {installed = [], recent = []} = {}) {
  const key = normalizeAppId(id);
  const app = [...installed, ...recent].find(a => normalizeAppId(a.id) === key);
  if (app?.name) return app.name;
  if (MAC_APP_NAMES[id]) return `${MAC_APP_NAMES[id]} (Mac)`;
  return id;
}

// --- GNOME's differences -------------------------------------------------------------------------------

/** The first while-held `repeat` an action runs (itself, or a step of it), or null (as in the extension). */
export function whileHeldRepeat(action) {
  const a = resolveAction(action);
  if (!a) return null;
  if (a.op === 'repeat') return a.mode === 'while-held' ? a : null;
  for (const child of nestedSteps(a)) {
    const found = whileHeldRepeat(child);
    if (found) return found;
  }
  return null;
}

function nestedSteps(a) {
  switch (a?.op) {
  case 'sequence': return sequenceSteps(a);
  case 'chain': return a.operations ?? [];
  case 'by-orientation': return [a.landscape, a.portrait];
  default: return [];
  }
}

/**
 * Whether an action types or presses keys. Any key press or release stops GNOME's key repeat, which
 * is how Slated notices a while-held shortcut is still down, so such repeats work like toggles there.
 */
export function sendsKeys(action) {
  const a = resolveAction(action);
  if (!a) return false;
  switch (a.op) {
  case 'keystroke': case 'insert-text': return true;
  case 'press': case 'hold': return String(a.input ?? '').toLowerCase().startsWith('key:');
  case 'repeat': return sendsKeys(a.action);
  default: return nestedSteps(a).some(sendsKeys);
  }
}

/** Inputs a macro presses down without a later step releasing them (`hold` steps are left out). */
export function unreleasedPresses(steps) {
  const down = [];
  for (const step of steps ?? []) {
    const a = resolveAction(step);
    if (a?.op !== 'press') continue;
    const key = String(a.input ?? '').toLowerCase();
    const index = down.findIndex(d => d.key === key);
    if (a.phase === 'up') {
      if (index >= 0) down.splice(index, 1);
    } else if (index < 0) {
      down.push({key, input: a.input});
    }
  }
  return down.map(d => d.input);
}

/**
 * What GNOME does with a binding's while-held repeat, as the extension decides it (runtime.js):
 * null (there's none), "key-repeat" (stops as you let go), or why it works like a toggle instead:
 * "repeat-off" (keyboard repeat is off; `statusMode` is status.json's automation.whileHeld),
 * "sends-keys" (the repeat presses keys) or "modal" (a modal key's shortcut).
 */
export function whileHeldBehavior(binding, statusMode = 'key-repeat') {
  const repeat = whileHeldRepeat(binding?.action);
  if (!repeat) return null;
  if (statusMode === 'toggle') return 'repeat-off';
  if (binding.modal) return 'modal';
  return sendsKeys(repeat.action) ? 'sends-keys' : 'key-repeat';
}

export const GNOME_NOTES = Object.freeze({
  whileHeld: 'On GNOME, Slated notices you let go of the shortcut through key repeat, about a tenth of a second later.',
  repeatOff: 'Key repeat is off in GNOME Settings → Keyboard, so while-held repeats work like toggles: press the shortcut again to stop.',
  sendsKeys: "This repeat presses keys, which stops GNOME's key repeat, so here it works like a toggle: press the shortcut again to stop.",
  modal: "GNOME can't tell when a modal key's shortcut is let go, so here it works like a toggle: press the shortcut again to stop.",
  mouseTrigger: "GNOME can't use mouse buttons as shortcuts, so this one works only in Slated for Mac. To use the button here, map it to a key with keyd (for example mouse1 = f13), then use that key as the shortcut.",
});

/** The note for a binding's while-held repeat on GNOME, or null. */
export function whileHeldNote(binding, statusMode = 'key-repeat') {
  switch (whileHeldBehavior(binding, statusMode)) {
  case 'repeat-off': return GNOME_NOTES.repeatOff;
  case 'sends-keys': return GNOME_NOTES.sendsKeys;
  case 'modal': return GNOME_NOTES.modal;
  case 'key-repeat': return GNOME_NOTES.whileHeld;
  default: return null;
  }
}
