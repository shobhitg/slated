// Validates the draft configuration before it is saved (port of
// Sources/SlatedUI/Model/ConfigValidator.swift), and describes what changed between two
// configurations for the event log (port of Sources/Slated/Logging/ConfigDiff.swift).
//
// Errors keep an item from being written: the last saved version of that item stays on disk, so a
// half-typed edit never deletes anything. Warnings are advisory.
//
// Pure ES module.

import {formatList, isObject, deepEqual} from './util.js';
import {keysCombo, keysString, statusKey, isValidKey, isFunctionKey, keyLabel} from './keys.js';
import {checkExpression} from './expressions.js';
import {bindingTitle, actionDetail, isMacOnly} from './actions.js';
import {parseOperation, isNotImplemented, describeError} from './engine.js';

/** Issue targets are strings: "binding:<id>", "hotstring:<id>", "layout:<name>". */
export const target = {
  binding: id => `binding:${id}`,
  hotstring: id => `hotstring:${id}`,
  layout: name => `layout:${name}`,
};

const issue = (severity, targetKey, field, message) => ({severity, target: targetKey, field, message});

/** Every issue in the configuration. */
export function validate(config, {knownLayouts = []} = {}) {
  const layouts = new Set(knownLayouts);
  return [
    ...bindingIssues(config.bindings ?? [], layouts),
    ...hotstringIssues(config.hotstrings ?? []),
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

function bindingIssues(bindings, layouts) {
  const issues = [];
  const byKeys = new Map();
  for (const binding of bindings) {
    const t = target.binding(binding.id);
    const problem = keyProblem(binding.keys);
    if (problem) {
      issues.push(issue('error', t, 'keys', problem));
    } else {
      const warning = typingWarning(binding.keys, binding.modal);
      if (warning) issues.push(issue('warning', t, 'keys', warning));
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
      const others = group.filter(b => b.id !== binding.id).map(b => `“${bindingTitle(b)}”`);
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
    return steps.flatMap((op, i) => prefixed(`Step ${i + 1}`, actionProblems(op, layouts)));
  }
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
  case 'open-url': {
    const url = String(a.url ?? '');
    const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):(.*)$/.exec(url);
    if (!m || !m[2] || url.endsWith('://') || /\s/.test(url)) return err('Enter a full URL, like https://example.com.');
    return [];
  }
  case 'keystroke': {
    const problem = keyProblem(a.keys);
    return problem ? err(problem) : [];
  }
  case 'switch': return [{severity: 'warning', message: "Slated doesn't run the app switcher yet."}];
  case 'hint': case 'undo': case 'relaunch': return [];
  default:
    // The Mac app's automation and clipboard operations: kept as they are, just not run here.
    if (isMacOnly(a)) return [{severity: 'warning', message: 'Only Slated for Mac runs this operation.'}];
    return err(`Slated doesn't know the operation “${a.op}”.`);
  }
}

// --- Hotstrings ----------------------------------------------------------------------------------------

function hotstringIssues(hotstrings) {
  const issues = [];
  for (const h of hotstrings) {
    const t = target.hotstring(h.id);
    const trigger = h.trigger ?? '';
    if (!trigger) {
      issues.push(issue('error', t, 'trigger', 'Type a trigger.'));
      continue;
    }
    if (/[\r\n]/.test(trigger)) issues.push(issue('error', t, 'trigger', "A trigger can't contain a line break."));
    if (!h.replacement && h.action === undefined) {
      issues.push(issue('warning', t, 'replacement', 'The replacement is empty, so the trigger will just be deleted.'));
    }
    if (h.enabled === false) continue;
    for (const other of hotstrings) {
      if (other.id === h.id || other.enabled === false || !other.trigger) continue;
      const insensitive = h.caseSensitive === false || other.caseSensitive === false;
      const mine = insensitive ? trigger.toLowerCase() : trigger;
      const theirs = insensitive ? other.trigger.toLowerCase() : other.trigger;
      if (mine === theirs) {
        issues.push(issue('warning', t, 'trigger', 'Another hotstring uses the same trigger. Only one of them will fire.'));
        break;
      }
      if ((other.fire ?? 'immediately') === 'immediately' && mine.startsWith(theirs) && (!other.wordBoundary || h.wordBoundary)) {
        issues.push(issue('warning', t, 'trigger', `“${other.trigger}” fires as soon as it's typed, so this one never gets the chance.`));
        break;
      }
    }
  }
  return issues;
}

// --- Layouts -------------------------------------------------------------------------------------------

function layoutIssues(layoutList, layouts) {
  const issues = [];
  const seen = new Set();
  for (const layout of layoutList) {
    const t = target.layout(layout.name);
    if (blank(layout.name)) issues.push(issue('error', t, 'name', 'Name the layout.'));
    else if (seen.has(layout.name)) issues.push(issue('error', t, 'name', 'Another layout already has this name.'));
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
 * all layouts as last saved.
 */
export function savable(draft, lastSaved, issues) {
  const bad = new Set(issues.filter(i => i.severity === 'error').map(i => i.target));
  if (!bad.size) return draft;
  const result = {...draft};
  result.bindings = (draft.bindings ?? []).flatMap(b => {
    if (!bad.has(target.binding(b.id))) return [b];
    const previous = (lastSaved.bindings ?? []).find(s => s.id === b.id);
    return previous ? [previous] : [];
  });
  result.hotstrings = (draft.hotstrings ?? []).flatMap(h => {
    if (!bad.has(target.hotstring(h.id))) return [h];
    const previous = (lastSaved.hotstrings ?? []).find(s => s.id === h.id);
    return previous ? [previous] : [];
  });
  if ([...bad].some(t => t.startsWith('layout:'))) result.layouts = lastSaved.layouts ?? [];
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
    changes.push(`keyboard: capsLock ${k.capsLock}, alone ${k.capsLockAlone}, modifiers ${mods}`);
  }
  if (!deepEqual(oldConfig.general, newConfig.general)) {
    const g = newConfig.general ?? {};
    changes.push(`general: launchAtLogin ${g.launchAtLogin}, loadSlateConfigs ${g.loadSlateConfigs}, showActionHUD ${g.showActionHUD}`);
  }
  const oldSettings = oldConfig.settings ?? {};
  const newSettings = newConfig.settings ?? {};
  for (const key of [...new Set([...Object.keys(oldSettings), ...Object.keys(newSettings)])].sort()) {
    if (!deepEqual(oldSettings[key], newSettings[key])) {
      changes.push(`setting ${key}: ${newSettings[key] === undefined ? 'removed' : String(newSettings[key])}`);
    }
  }
  if (!deepEqual(oldConfig.layouts, newConfig.layouts)) {
    changes.push(`layouts: ${(newConfig.layouts ?? []).map(l => l.name).join(', ')}`);
  }
  if (!deepEqual(oldConfig.defaults, newConfig.defaults)) changes.push(`display defaults: ${(newConfig.defaults ?? []).length}`);
  return changes;
}
