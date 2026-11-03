// Validates the draft configuration before it is saved (port of
// Sources/SlatedUI/Model/ConfigValidator.swift), and describes what changed between two
// configurations for the event log (port of Sources/Slated/Logging/ConfigDiff.swift).
//
// Errors keep an item from being written: the last saved version of that item stays on disk, so a
// half-typed edit never deletes anything. Warnings are advisory.
//
// Pure ES module.

import {formatList, isObject, deepEqual} from './util.js';
import {
  keysCombo, keysString, statusKey, isValidKey, isFunctionKey, keyLabel, comboLabel, isModifierKey, isMouseButton,
} from './keys.js';
import {checkExpression} from './expressions.js';
import {bindingTitle, actionDetail, resolveAction, layoutNames} from './actions.js';
import {
  BUILT_IN_SHORTCUTS, GNOME_NOTES, sharesApps, unreleasedPresses, inputName, parseInput, clipboardSettings,
  automationSettings,
} from './automation.js';
import {parseOperation, isNotImplemented, describeError, isHotstringDelimiter} from './engine.js';
import {islandSettings} from './island.js';
import {hotstringText} from '../core/index.js';

/** Issue targets are strings: "binding:<id>", "hotstring:<id>", "layout:<name>". */
export const target = {
  binding: id => `binding:${id}`,
  hotstring: id => `hotstring:${id}`,
  layout: name => `layout:${name}`,
};

const issue = (severity, targetKey, field, message) => ({severity, target: targetKey, field, message});

/** Every issue in the configuration. */
export function validate(config, {knownLayouts = [], secrets = {}} = {}) {
  const layouts = new Set(knownLayouts);
  const builtIns = BUILT_IN_SHORTCUTS.map(builtIn => ({builtIn, keys: builtIn.keys(config)})).filter(b => b.keys);
  return [
    ...bindingIssues(config.bindings ?? [], layouts, builtIns),
    ...hotstringIssues(config.hotstrings ?? [], secrets),
    ...layoutIssues(config.layouts ?? [], layouts),
  ];
}

// --- Bindings ------------------------------------------------------------------------------------------

export function keyProblem(keys) {
  const combo = keysCombo(keys);
  if (!combo.key) return 'Record a shortcut.';
  return isValidKey(combo.key) ? null : `“${combo.key}” isn't a key Slated knows.`;
}

/** A warning when a shortcut would swallow ordinary typing. */
export function typingWarning(keys, modal) {
  const combo = keysCombo(keys);
  if (modal) return null;
  const mods = combo.modifiers;
  if (mods.includes('ctrl') || mods.includes('alt') || mods.includes('cmd') || isFunctionKey(combo.key)) return null;
  return `Without Ctrl, Alt or Super this shortcut takes over typing ${keyLabel(combo.key)} everywhere.`;
}

export const MODIFIER_KEY_PROBLEM = "A modifier key can't be a shortcut on its own. Add a key, or use it as a held input instead.";

function bindingIssues(bindings, layouts, builtIns = []) {
  const issues = [];
  const byKeys = new Map();
  for (const binding of bindings) {
    const t = target.binding(binding.id);
    const combo = keysCombo(binding.keys);
    const problem = keyProblem(binding.keys);
    if (problem) {
      issues.push(issue('error', t, 'keys', problem));
    } else if (isModifierKey(combo.key)) {
      issues.push(issue('error', t, 'keys', MODIFIER_KEY_PROBLEM));
    } else if (isMouseButton(combo.key)) {
      // Fine on the Mac, which shares this config.json: a warning, so the binding is still saved.
      issues.push(issue('warning', t, 'keys', GNOME_NOTES.mouseTrigger));
    } else if (!(binding.onlyInApps ?? []).length) {
      // Limited to some apps, a plain key is fine: it's grabbed only while one of them has focus.
      const warning = typingWarning(binding.keys, binding.modal);
      if (warning) issues.push(issue('warning', t, 'keys', warning));
    }
    // Bindings are registered before the built-in shortcuts, so they win.
    if (binding.enabled !== false && !binding.modal && combo.key) {
      const keys = keysString(binding.keys);
      for (const {builtIn, keys: builtInKeys} of builtIns) {
        if (builtInKeys !== keys || deepEqual(resolveAction(binding.action), builtIn.action)) continue;
        issues.push(issue('warning', t, 'keys',
          `Same keys as ${builtIn.title}. This shortcut wins, so ${comboLabel(keys)} won't ${builtIn.effect}.`));
      }
    }
    if (resolveAction(binding.action)?.op === 'wait') {
      issues.push(issue('warning', t, 'action', 'A wait on its own does nothing. Use it as a step in a sequence, between other steps.'));
    }
    for (const p of actionProblems(binding.action, layouts)) issues.push(issue(p.severity, t, 'action', p.message));
    if (binding.enabled !== false && keysCombo(binding.keys).key) {
      const key = statusKey(binding.keys, binding.modal);
      if (!byKeys.has(key)) byKeys.set(key, []);
      byKeys.get(key).push(binding);
    }
  }
  for (const group of byKeys.values()) {
    if (group.length < 2) continue;
    for (const binding of group) {
      // Bindings limited to different apps never run at the same time.
      const others = group.filter(b => b.id !== binding.id && sharesApps(b, binding)).map(b => `“${bindingTitle(b)}”`);
      if (!others.length) continue;
      issues.push(issue('warning', target.binding(binding.id), 'keys',
        `Same shortcut as ${formatList(others)}. Only one of them can run.`));
    }
  }
  return issues;
}

// --- Actions -------------------------------------------------------------------------------------------

const err = message => [{severity: 'error', message}];
const blank = s => typeof s !== 'string' || !s.trim();

function expressions(pairs, relative = false) {
  const problems = [];
  for (const [label, value] of pairs) {
    if (value === undefined || value === null) continue;
    const result = checkExpression(value, {relative});
    if (result.status === 'empty') problems.push({severity: 'error', message: `${label} is empty.`});
    else if (result.status === 'invalid') problems.push({severity: 'error', message: `${label}: ${result.message}`});
  }
  return problems;
}

function prefixed(label, problems) {
  return problems.map(p => ({severity: p.severity, message: `${label}: ${p.message}`}));
}

/** Problems with one action ([{severity, message}]). */
export function actionProblems(action, knownLayouts = new Set()) {
  const layouts = knownLayouts instanceof Set ? knownLayouts : new Set(knownLayouts);
  if (typeof action === 'string') {
    if (!action.trim()) return err('Enter an operation.');
    try {
      return actionProblems(parseOperation(action), layouts);
    } catch (error) {
      // Without the engine, Slate syntax can't be checked here; the engine reports it when loading.
      return isNotImplemented(error) ? [] : err(describeError(error));
    }
  }
  if (!isObject(action)) return err('Choose an operation.');
  const a = action;
  switch (a.op) {
  case 'move': return expressions([['X', a.x], ['Y', a.y], ['Width', a.width], ['Height', a.height]]);
  case 'resize': return expressions([['Width', a.width], ['Height', a.height]], true);
  case 'push':
    return typeof a.style === 'string' && a.style.startsWith('bar-resize:')
      ? expressions([['Size', a.style.slice('bar-resize:'.length)]]) : [];
  case 'nudge': return expressions([['Horizontal', a.x], ['Vertical', a.y]], true);
  case 'throw': case 'corner': return expressions([['Width', a.width], ['Height', a.height]]);
  case 'chain': {
    const ops = a.operations ?? [];
    if (!ops.length) return err('Add at least one operation to the chain.');
    return ops.flatMap((op, i) => prefixed(`Step ${i + 1}`, actionProblems(op, layouts)));
  }
  case 'sequence': {
    const steps = a.steps ? a.steps.map(s => s.action) : (a.operations ?? []);
    if (!steps.length) return err('Add at least one step to the sequence.');
    const problems = steps.flatMap((op, i) => prefixed(`Step ${i + 1}`, actionProblems(op, layouts)));
    for (const input of unreleasedPresses(steps)) {
      problems.push({severity: 'warning',
        message: `${inputName(input)} stays down after the last step. Add a Release step, or press the stop shortcut to let go.`});
    }
    return problems;
  }
  case 'repeat': {
    const problems = prefixed('Repeated', actionProblems(a.action, layouts));
    if (!(a.interval >= 0.01)) problems.push(...err('Repeat at most 100 times a second (an interval of 10 ms or more).'));
    const repeated = resolveAction(a.action);
    if (repeated?.op === 'repeat') problems.push(...err("An auto-repeat can't repeat another auto-repeat."));
    else if (repeated?.op === 'wait') problems.push({severity: 'warning', message: 'Repeating a wait does nothing. Repeat a click or a key.'});
    else if (repeated?.op === 'stop-automations') problems.push({severity: 'warning', message: 'This would stop itself the first time it runs.'});
    return problems;
  }
  case 'press': case 'hold': {
    const input = parseInput(a.input);
    if (!input) return err('Choose a mouse button or a key.');
    const problem = input.kind === 'key' ? keyProblem(input.keys) : null;
    return problem ? err(problem) : [];
  }
  case 'wait':
    return a.seconds > 600 ? [{severity: 'warning', message: "That's a wait of over 10 minutes."}] : [];
  case 'click': case 'stop-automations': case 'clipboard-history': return [];
  case 'by-orientation':
    return [...prefixed('Landscape', actionProblems(a.landscape, layouts)),
      ...prefixed('Portrait', actionProblems(a.portrait, layouts))];
  case 'layout':
    if (blank(a.name)) return err('Choose a layout.');
    if (!layouts.has(a.name)) return [{severity: 'warning', message: `There's no layout named “${a.name}” yet.`}];
    return [];
  case 'focus':
    if (typeof a.app === 'string') return blank(a.app) ? err('Choose an app to focus.') : [];
    return [];
  case 'snapshot': case 'delete-snapshot': case 'activate-snapshot':
    return blank(a.name) ? err('Name the snapshot.') : [];
  case 'grid': {
    const grids = Object.values(a.grids ?? {});
    return grids.some(g => !(g.width >= 1) || !(g.height >= 1)) ? err('Grid sizes must be at least 1 × 1.') : [];
  }
  case 'hide': case 'show': case 'toggle':
    if (Array.isArray(a.app) && !a.app.length) return err('Choose at least one app.');
    if (typeof a.app === 'string' && a.app.startsWith('all-but:') && !a.app.slice(8)) return err('Choose the app to leave alone.');
    return [];
  case 'shell': return blank(a.command) ? err('Enter a command to run.') : [];
  case 'insert-text': return !a.text ? err('Enter the text to insert.') : [];
  case 'open-url': return isFullURL(String(a.url ?? '')) ? [] : err('Enter a full URL, like https://example.com.');
  case 'keystroke': {
    const problem = keyProblem(a.keys);
    return problem ? err(problem) : [];
  }
  case 'switch': return [{severity: 'warning', message: "Slated doesn't run the app switcher yet."}];
  case 'hint': case 'undo': case 'relaunch': return [];
  default:
    return err(`Slated doesn't know the operation “${a.op}”.`);
  }
}

// --- URLs ----------------------------------------------------------------------------------------------

// A host's ASCII characters: RFC 3986's reg-name (unreserved, sub-delims, percent-encodings).
const REG_NAME = /^(?:[A-Za-z0-9\-._~!$&'()*+,;=]|%[0-9A-Fa-f]{2}|[^\x00-\x7f])*$/u;
// Characters IDNA drops from a host name, and the other non-ASCII ones it refuses there: white space,
// controls, private-use and unassigned code points, and the remaining format characters.
const IDNA_DROPPED = /[­᠎​⁠-⁤⁪-⁯﻿︀-️\u{1bca0}-\u{1bca3}\u{1d173}-\u{1d17a}]/gu;
const IDNA_REFUSED = /[\p{White_Space}\p{Cc}\p{Co}\p{Cn}\p{Cf}￼�]/u;
const IDNA_DOTS = /[.。．｡]/;

function isURLHost(host) {
  // An IP literal: IPv6 or IPvFuture characters, then maybe a zone id ("%25en0"), anything up to "]".
  if (host.startsWith('[')) {
    return host.indexOf(']') === host.length - 1 && /^[A-Za-z0-9\-._~!$&'()*+,;=:]*$/.test(host.slice(1, -1).split('%')[0]);
  }
  if (!/[^\x00-\x7f]/.test(host)) return REG_NAME.test(host);
  // IDNA maps other characters to ASCII label by label: a fullwidth "：" becomes ":", which no host has.
  const mapped = host.normalize('NFKC');
  const kept = mapped.replace(IDNA_DROPPED, '');
  if (!REG_NAME.test(mapped) || IDNA_REFUSED.test(kept)) return false;
  const labels = kept.split(IDNA_DOTS);
  if (IDNA_DOTS.test(mapped.slice(-1))) labels.pop();
  // No empty label, none starting with a combining mark or starting or ending with a hyphen, and
  // "--" in the third and fourth places only for punycode ("xn--"), which is ASCII already.
  return labels.every(label => label && !/^\p{M}|^-|-$/u.test(label)
    && (/^xn--/i.test(label) ? /^[a-z0-9-]+$/i.test(label) : !/^..--/u.test(label)));
}

/**
 * Whether the Mac takes `url` as a full URL: URL(string:) reads it, with more than a scheme
 * (ConfigValidator.swift). Since macOS 14, URL(string:) percent-encodes what doesn't belong in a path,
 * query, fragment or user name, so "…/search?q=a b" is fine; a host or port must be RFC 3986's, and a
 * host with other characters must pass IDNA. Checked against Foundation on macOS 26 (the URLs in
 * validator.test.mjs, also in SettingsUITests.swift, and random ones).
 */
export function isFullURL(url) {
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):(.*)$/s.exec(url);
  if (!m || !m[2] || url.endsWith('://')) return false;
  if (!m[2].startsWith('//')) return true;
  const authority = m[2].slice(2).split(/[/?#]/)[0];
  const hostPort = authority.slice(authority.lastIndexOf('@') + 1);
  const close = hostPort.startsWith('[') ? hostPort.indexOf(']') : 0;
  if (close < 0) return false;
  const portAt = hostPort.indexOf(':', close);
  const host = portAt < 0 ? hostPort : hostPort.slice(0, portAt);
  return /^[0-9]*$/.test(portAt < 0 ? '' : hostPort.slice(portAt + 1)) && isURLHost(host);
}

// --- Hotstrings ----------------------------------------------------------------------------------------

/**
 * Whether some app has both hotstrings available (Hotstring.sharesApps in ConfigValidator.swift). The
 * Mac only considers the hotstrings available in the app in front, so two with the same trigger in
 * different apps each fire in their own. App filters hold Mac bundle ids.
 */
export function hotstringsShareApps(a, b) {
  const [onlyA, exceptA, onlyB, exceptB] = [a.onlyInApps, a.exceptInApps, b.onlyInApps, b.exceptInApps].map(list => list ?? []);
  const mine = onlyA.filter(app => !exceptA.includes(app));
  const theirs = onlyB.filter(app => !exceptB.includes(app));
  if (!onlyA.length && !onlyB.length) return true;
  if (!onlyB.length) return mine.some(app => !exceptB.includes(app));
  if (!onlyA.length) return theirs.some(app => !exceptA.includes(app));
  return mine.some(app => theirs.includes(app));
}

/**
 * The apps a hotstring can fire in (HotstringApps in ConfigValidator.swift): {apps, allBut}, the
 * bundle ids listed, or every app but those.
 */
function hotstringApps(h) {
  const only = h.onlyInApps ?? [];
  const except = h.exceptInApps ?? [];
  return only.length ? {apps: new Set(only.filter(app => !except.includes(app))), allBut: false}
    : {apps: new Set(except), allBut: true};
}

const NO_APPS = {apps: new Set(), allBut: false};
const noApps = s => !s.allBut && s.apps.size === 0;
const otherApps = s => ({apps: s.apps, allBut: !s.allBut});

function appsIntersection(a, b) {
  if (!a.allBut && !b.allBut) return {apps: new Set([...a.apps].filter(app => b.apps.has(app))), allBut: false};
  if (!a.allBut) return {apps: new Set([...a.apps].filter(app => !b.apps.has(app))), allBut: false};
  if (!b.allBut) return {apps: new Set([...b.apps].filter(app => !a.apps.has(app))), allBut: false};
  return {apps: new Set([...a.apps, ...b.apps]), allBut: true};
}

const appsUnion = (a, b) => otherApps(appsIntersection(otherApps(a), otherApps(b)));
const appsSubtracting = (a, b) => appsIntersection(a, otherApps(b));
const fireMode = h => h.fire ?? 'immediately';

/**
 * When hotstrings with the same trigger make `h` never fire (sameTriggerWarning in
 * ConfigValidator.swift). Where both are available, the Mac's matcher picks the first in the list, but
 * one that fires as soon as it's typed beats one waiting for a delimiter. A first one limited to some
 * apps is a per-app override: `h` still fires everywhere else.
 */
function sameTriggerWarning(h, index, others) {
  const mine = hotstringApps(h);
  let shadowed = NO_APPS;
  let shadowedByFiringFirst = NO_APPS;
  for (const [otherIndex, other] of others) {
    if (!alwaysMatchesFirst(other, h)) continue;
    const firesFirst = fireMode(other) === 'immediately' && fireMode(h) === 'afterDelimiter';
    if (!firesFirst && !(fireMode(other) === fireMode(h) && otherIndex < index)) continue;
    const apps = appsIntersection(hotstringApps(other), mine);
    shadowed = appsUnion(shadowed, apps);
    if (firesFirst) shadowedByFiringFirst = appsUnion(shadowedByFiringFirst, apps);
  }
  if (noApps(mine) || !noApps(appsSubtracting(mine, shadowed))) return null;
  if (noApps(appsSubtracting(mine, shadowedByFiringFirst))) {
    return 'Another hotstring with the same trigger fires as soon as it\'s typed, so this one never gets the chance.';
  }
  // The Mac adds "Drag this one above it to use it."; this list can't be reordered.
  return 'Another hotstring with the same trigger is higher in the list, so this one never fires.';
}

/** Whether `other` matches wherever `h` would: the same trigger in every case `h` accepts, and no extra word boundary. */
function alwaysMatchesFirst(other, h) {
  const sameTrigger = other.caseSensitive === false
    ? other.trigger.toLowerCase() === h.trigger.toLowerCase()
    : h.caseSensitive !== false && other.trigger === h.trigger;
  return sameTrigger && (!other.wordBoundary || Boolean(h.wordBoundary));
}

/**
 * When typing `h`'s trigger completes another one that fires as soon as it's typed ("sh" inside
 * ";shrug"), so `h` never gets the chance where that one is available (firesOnTheWayWarning in
 * ConfigValidator.swift). Names the one typed first, and the apps (Mac bundle ids, shown as they are)
 * when it's only available in some of `h`'s.
 */
function firesOnTheWayWarning(h, others) {
  let first = null;
  for (const other of others) {
    if (fireMode(other) !== 'immediately') continue;
    const end = completesOnTheWay(other, h);
    if (end === null) continue;
    // The matcher prefers the longer of two triggers completed by the same character.
    if (first && (first.end < end || (first.end === end && [...first.other.trigger].length >= [...other.trigger].length))) continue;
    first = {end, other};
  }
  if (!first) return null;
  const mine = hotstringApps(h);
  const theirs = hotstringApps(first.other);
  const fires = `“${first.other.trigger}” fires as soon as it's typed`;
  const unaffected = appsSubtracting(mine, theirs);
  if (noApps(unaffected)) return `${fires}, so this one never gets the chance.`;
  const names = apps => formatList([...apps].sort());
  const affected = appsIntersection(mine, theirs);
  if (!affected.allBut) return `In ${names(affected.apps)}, ${fires}, so this one never gets the chance there.`;
  return `${fires}, so this one only works in ${names(unaffected.apps)}.`;
}

/**
 * How many characters of `h`'s trigger are typed when `other`'s first completes inside it, if that's
 * before the end: "sh" completes after 3 characters of ";shrug". Null otherwise.
 */
function completesOnTheWay(other, h) {
  const insensitive = h.caseSensitive === false || other.caseSensitive === false;
  const mine = [...(insensitive ? h.trigger.toLowerCase() : h.trigger)];
  const theirs = [...(insensitive ? other.trigger.toLowerCase() : other.trigger)];
  if (!theirs.length || theirs.length >= mine.length) return null;
  for (let start = 0; start < mine.length - theirs.length; start++) {
    if (!theirs.every((c, k) => mine[start + k] === c)) continue;
    // At the start, what comes before is whatever precedes `h`'s trigger: a delimiter only if `h`
    // needs one too.
    if (other.wordBoundary && !(start === 0 ? Boolean(h.wordBoundary) : isHotstringDelimiter(mine[start - 1]))) continue;
    return start + theirs.length;
  }
  return null;
}

/** A sensitive hotstring whose text isn't in secrets.json: a warning, not an error (it's saved, and expands once its text is entered). */
export const MISSING_SECRET = "Its text isn't on this computer yet. Type it below; it's kept in secrets.json.";

function hotstringIssues(hotstrings, secrets = {}) {
  const issues = [];
  for (const [index, h] of hotstrings.entries()) {
    const t = target.hotstring(h.id);
    const trigger = h.trigger ?? '';
    if (!trigger) {
      issues.push(issue('error', t, 'trigger', 'Type a trigger.'));
      continue;
    }
    // Every character Swift's Character.isNewline takes for one.
    if (/[\n\v\f\r\u0085\u2028\u2029]/.test(trigger)) issues.push(issue('error', t, 'trigger', "A trigger can't contain a line break."));
    // A sensitive hotstring's text is its secret's (null while it isn't on this computer).
    const text = hotstringText(h, secrets);
    if (text === null) issues.push(issue('warning', t, 'replacement', MISSING_SECRET));
    else if (!text && h.action === undefined) {
      issues.push(issue('warning', t, 'replacement', 'The replacement is empty, so the trigger will just be deleted.'));
    }
    if (h.enabled === false) continue;
    const others = [...hotstrings.entries()]
      .filter(([i, other]) => i !== index && other.enabled !== false && other.trigger && hotstringsShareApps(h, other));
    const message = sameTriggerWarning(h, index, others) ?? firesOnTheWayWarning(h, others.map(([, other]) => other));
    if (message) issues.push(issue('warning', t, 'trigger', message));
  }
  return issues;
}

// --- Layouts -------------------------------------------------------------------------------------------

export const LAYOUT_NAME_MISSING = 'Name the layout.';
export const LAYOUT_NAME_TAKEN = 'Another layout already has this name.';

function layoutIssues(layoutList, layouts) {
  const issues = [];
  const seen = new Set();
  for (const layout of layoutList) {
    const t = target.layout(layout.name);
    if (blank(layout.name)) issues.push(issue('error', t, 'name', LAYOUT_NAME_MISSING));
    else if (seen.has(layout.name)) issues.push(issue('error', t, 'name', LAYOUT_NAME_TAKEN));
    else seen.add(layout.name);
    for (const app of layout.apps ?? []) {
      for (const op of app.operations ?? []) {
        for (const p of actionProblems(op, layouts)) {
          if (p.severity === 'error') issues.push(issue('error', t, 'action', `${app.app}: ${p.message}`));
        }
      }
    }
  }
  return issues;
}

// --- Saving --------------------------------------------------------------------------------------------

/**
 * The configuration to write: the draft, except that items with errors fall back to their last saved
 * version (or are left out if they were never saved). Layouts have no identity beyond their name,
 * which is exactly what's being edited when a name clashes or is empty, so any layout error keeps
 * all layouts as last saved. What applies a layout by a name only the draft has (renamed or added
 * since) then waits too, display defaults with the layouts: on disk it would apply no layout.
 */
export function savable(draft, lastSaved, issues) {
  const bad = new Set(issues.filter(i => i.severity === 'error').map(i => i.target));
  if (!bad.size) return draft;
  const result = {...draft};
  const layoutsHeld = [...bad].some(t => t.startsWith('layout:'));
  const savedNames = new Set((lastSaved.layouts ?? []).map(l => l.name));
  const unsaved = new Set(layoutsHeld ? (draft.layouts ?? []).map(l => l.name).filter(name => !savedNames.has(name)) : []);
  const waits = action => unsaved.size > 0 && layoutNames(action).some(name => unsaved.has(name));
  result.bindings = (draft.bindings ?? []).flatMap(b => {
    if (!bad.has(target.binding(b.id)) && !waits(b.action)) return [b];
    const previous = (lastSaved.bindings ?? []).find(s => s.id === b.id);
    return previous ? [previous] : [];
  });
  result.hotstrings = (draft.hotstrings ?? []).flatMap(h => {
    if (!bad.has(target.hotstring(h.id)) && !waits(h.action)) return [h];
    const previous = (lastSaved.hotstrings ?? []).find(s => s.id === h.id);
    return previous ? [previous] : [];
  });
  if (layoutsHeld) {
    result.layouts = lastSaved.layouts ?? [];
    result.defaults = lastSaved.defaults ?? [];
  }
  return result;
}

// --- Change descriptions for the log -------------------------------------------------------------------

function diffList(oldList, newList, noun, describe) {
  const oldById = new Map(oldList.map(item => [item.id, item]));
  const newIds = new Set(newList.map(item => item.id));
  const out = [];
  for (const item of newList) {
    const previous = oldById.get(item.id);
    if (!previous) out.push(`${noun} added: ${describe(item)}`);
    else if (!deepEqual(previous, item)) out.push(`${noun} changed: ${describe(item)}`);
  }
  for (const item of oldList) if (!newIds.has(item.id)) out.push(`${noun} removed: ${describe(item)}`);
  return out;
}

const MOD_SYMBOLS = {ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', cmd: 'Super'};

/** "binding added: Left half (hyper+a)" etc. Never includes hotstring replacements. */
export function configChanges(oldConfig, newConfig) {
  const changes = [];
  changes.push(...diffList(oldConfig.bindings ?? [], newConfig.bindings ?? [], 'binding',
    b => `${b.name ?? actionDetail(b.action)} (${keysString(b.keys)})`));
  changes.push(...diffList(oldConfig.hotstrings ?? [], newConfig.hotstrings ?? [], 'hotstring', h => h.trigger));
  if (!deepEqual(oldConfig.keyboard, newConfig.keyboard)) {
    const k = newConfig.keyboard ?? {};
    const mods = (k.hyperModifiers ?? []).map(m => MOD_SYMBOLS[m] ?? m).join('+');
    const repeat = k.keyRepeat ? `${k.keyRepeat.delay}/${k.keyRepeat.interval} ms` : 'system';
    changes.push(`keyboard: capsLock ${k.capsLock}, alone ${k.capsLockAlone}, modifiers ${mods}, keyRepeat ${repeat}`);
  }
  if (!deepEqual(oldConfig.general, newConfig.general)) {
    const g = newConfig.general ?? {};
    changes.push(`general: launchAtLogin ${g.launchAtLogin}, showActionHUD ${g.showActionHUD}, `
      + `hotstringsEnabled ${g.hotstringsEnabled}, showStatusIcon ${g.showStatusIcon}, showConfigKeys ${g.showConfigKeys}`);
  }
  const oldSettings = oldConfig.windows ?? {};
  const newSettings = newConfig.windows ?? {};
  for (const key of [...new Set([...Object.keys(oldSettings), ...Object.keys(newSettings)])].sort()) {
    if (!deepEqual(oldSettings[key], newSettings[key])) {
      changes.push(`setting ${key}: ${newSettings[key] === undefined ? 'removed' : String(newSettings[key])}`);
    }
  }
  if (!deepEqual(oldConfig.layouts, newConfig.layouts)) {
    changes.push(`layouts: ${(newConfig.layouts ?? []).map(l => l.name).join(', ')}`);
  }
  if (!deepEqual(oldConfig.defaults, newConfig.defaults)) changes.push(`display defaults: ${(newConfig.defaults ?? []).length}`);
  // Settings → Clipboard and Settings → Automation. App ids are counted, not listed.
  if (!deepEqual(oldConfig.clipboard, newConfig.clipboard)) {
    const c = clipboardSettings(newConfig);
    changes.push(`clipboard: enabled ${c.enabled}, shortcut ${c.shortcut ?? 'none'}, maxItems ${c.maxItems}, persist ${c.persist}, `
      + `retentionDays ${c.retentionDays}, secrets ${c.secrets}, secretMinutes ${c.secretMinutes}, secretPatterns ${c.secretPatterns}, `
      + `excludedApps ${(c.excludedApps ?? []).length}, `
      + `pasteAfterSelecting ${c.pasteAfterSelecting}, screenshots ${c.screenshots}`);
  }
  if (!deepEqual(oldConfig.automation, newConfig.automation)) {
    const a = automationSettings(newConfig);
    changes.push(`automation: stopShortcut ${a.stopShortcut ?? 'none'}, stopOnAppSwitch ${a.stopOnAppSwitch}, `
      + `maxRunMinutes ${a.maxRunMinutes}, showIndicator ${a.showIndicator}`);
  }
  // Settings → General's island group.
  if (!deepEqual(oldConfig.island, newConfig.island)) {
    const i = islandSettings(newConfig);
    changes.push(`island: enabled ${i.enabled}, cheatSheet ${i.cheatSheet}, cheatSheetDelay ${i.cheatSheetDelay}, showFailures ${i.showFailures}`);
  }
  return changes;
}
