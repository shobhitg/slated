// Get Started, the settings window's first-run page (port of AppModel+GetStarted.swift and
// GetStarted/GetStartedSteps.swift): welcome, Hyper key, hotstrings, Slate config, done. GNOME asks
// for no permission, so where the Mac asks for Accessibility, GNOME checks the two helpers Slated
// relies on there: keyd for the Hyper key (recommended) and espanso, which types hotstrings.
//
// Whether it was finished is the settings window's own state, kept in settings-window.json next to
// status.json (the Mac keeps it in its user defaults), not in config.json, which the Mac shares.
//
// Pure ES module (no gi:// imports): the texts and decisions. ui/getstarted.js draws them.

import {keysCombo, keysString, isHyper} from './keys.js';
import {matchingPreset, starterBindings} from './presets.js';
import {actionTitle, bindingTitle} from './actions.js';
import {espansoGuidance} from './hotstrings.js';
import {plural, isObject} from './util.js';

/** The steps, in order. */
export const STEPS = Object.freeze(['welcome', 'hyperKey', 'hotstrings', 'slateConfig', 'done']);

/** settings-window.json → its state. A missing or unreadable file is a first run. Other keys are kept. */
export function parseWindowState(text) {
  let raw = null;
  try {
    raw = typeof text === 'string' ? JSON.parse(text) : null;
  } catch {
    raw = null;
  }
  const state = isObject(raw) ? {...raw} : {};
  state.setupFinished = state.setupFinished === true;
  return state;
}

export function windowStateText(state) {
  return `${JSON.stringify(state, null, 2)}\n`;
}

/**
 * The pane a newly opened window shows (AppModel.prepareToShowMainWindow): Get Started until it's
 * finished, then Overview. Never the pane it was left on, where an empty state ("No hotstrings yet")
 * read like a step to do.
 */
export function startingPane(setupFinished) {
  return setupFinished ? 'overview' : 'getStarted';
}

/**
 * The footer's main button. Hotstrings without espanso can be skipped, as the Mac skips its
 * permission step.
 */
export function primaryTitle(step, {hotstringsReady = true} = {}) {
  switch (step) {
  case 'welcome': return 'Set Up Slated';
  case 'hotstrings': return hotstringsReady ? 'Continue' : 'Skip for Now';
  case 'done': return 'Start Using Slated';
  default: return 'Continue';
  }
}

/** The Slate files' bindings that run: none while Slated doesn't load the files. */
export function loadedSourceBindings(sources, slateLoading) {
  return slateLoading ? sources.filter(s => s.exists).flatMap(s => s.bindings) : [];
}

/**
 * The Hyper switch's subtitle (HyperKeyStep.hyperSubtitle): points out when the user's own shortcuts
 * already use all four Hyper modifiers, so the choice is obvious.
 */
export function hyperSubtitle({bindings, sourceBindings, hyperOn}) {
  const usesHyper = b => isHyper(keysCombo(b.keys).modifiers);
  const count = bindings.filter(usesHyper).length + sourceBindings.filter(usesHyper).length;
  if (!count || hyperOn) return 'You can change this any time under Keyboard.';
  return `${count === 1 ? '1 of your shortcuts uses' : `${count} of your shortcuts use`} ✦ (Ctrl+Alt+Shift+Super). `
    + `Turn this on to press ${count === 1 ? 'it' : 'them'} with Caps Lock.`;
}

/** The "Tap alone for Escape" switch's subtitle: on GNOME only keyd can tell a tap from a hold. */
export function tapSubtitle({running, hyper}) {
  if (running && hyper.mode === 'xkb') return "Needs keyd: GNOME's keyboard option can't tell a tap from a hold.";
  if (running && hyper.mode === 'keyd') {
    return 'A quick tap sends Escape; holding it is Hyper. Run linux/install.sh --hyper-keyd again after changing this.';
  }
  return 'A quick tap sends Escape; holding it is Hyper. On GNOME this needs keyd.';
}

/**
 * What the Hyper key step says about keyd, the recommended way: from status.json's "hyper" entry
 * and whether `linux/install.sh --hyper-keyd` installed Slated's keyd configuration.
 * @returns {{level: string, title: string, detail: string, offerSetup: boolean}}
 */
export function keydAdvice({running, hyper, keydConfigured}) {
  if (running && hyper.mode === 'keyd') {
    return {
      level: 'ok', title: 'keyd is in charge of Caps Lock', offerSetup: false,
      detail: "Caps Lock works exactly like the Mac's Hyper key, in every app, and a tap can send Escape.",
    };
  }
  if (keydConfigured && running && hyper.mode === 'xkb') {
    return {
      level: 'warning', title: "keyd is set up but isn't running", offerSetup: false,
      detail: "Slated uses GNOME's keyboard option meanwhile. Start keyd with “sudo systemctl enable --now keyd”.",
    };
  }
  if (keydConfigured) {
    return {
      level: 'ok', title: 'keyd is set up', offerSetup: false,
      detail: 'Slated hands Caps Lock to keyd while keyd runs: Caps Lock works exactly like the Mac\'s Hyper key.',
    };
  }
  return {
    level: 'info', title: 'Recommended: keyd', offerSetup: true,
    detail: "keyd makes Caps Lock work exactly like the Mac's Hyper key, in every app, and lets a tap send Escape. "
      + "Set it up once from the Slated source folder (it asks for your password). Until then, Slated uses GNOME's "
      + 'own keyboard option, which needs nothing installed.',
  };
}

/**
 * The hotstrings step: espanso's state (espansoGuidance), what the footer says, and a summary of the
 * hotstrings. Hotstrings limited to some apps are Mac only (espanso can't tell apps apart on GNOME).
 */
export function hotstringsStep({config, status, running}) {
  const enabled = config.general.hotstringsEnabled !== false;
  const all = config.hotstrings.filter(h => h.enabled !== false);
  const macOnly = all.filter(h => h.onlyInApps?.length).length;
  const expanding = all.length - macOnly;
  const guidance = enabled
    ? espansoGuidance(status.hotstrings, running)
    : {level: 'info', title: 'Text expansion is turned off', detail: 'Turn it on under Hotstrings when you want it.'};
  const summary = all.length
    ? `${plural(expanding, 'hotstring')} to expand${macOnly ? ` · ${macOnly} Mac only` : ''}`
    : 'None yet. Add them under Hotstrings.';
  const first = all.find(h => h.trigger && !h.onlyInApps?.length)?.trigger ?? null;
  return {guidance, ready: guidance.level === 'ok' || !enabled, summary, first, installLink: guidance.link ?? null};
}

/**
 * The Slate config step (SlateConfigStep): the Slate files found, whether Slated loads them, and
 * whether to offer the starter shortcuts (when Slated has none of its own, or there's no Slate file).
 */
export function slateStep({sources, slateLoading, bindings}) {
  const found = sources.filter(s => s.exists);
  const count = found.reduce((n, s) => n + s.bindings.length, 0);
  const offerStarter = !bindings.length || !found.length;
  if (!found.length) {
    return {
      state: 'none', found, offerStarter, title: 'Start with a few great shortcuts',
      subtitle: 'No ~/.slate or ~/.slate.js here — no problem. Add a starter set now and make it yours under Windows.',
    };
  }
  if (!slateLoading) {
    return {
      state: 'off', found, offerStarter, title: 'Your Slate config is here',
      subtitle: "Slated isn't loading it. Turn it on to run its shortcuts alongside Slated's own. Nothing is converted or changed.",
    };
  }
  return {
    state: 'loaded', found, offerStarter, title: 'Your Slate config works as-is',
    subtitle: `Slated found ${plural(count, 'binding')} and will run them alongside its own. Nothing is converted or changed.`,
  };
}

/** A Slate file's line in the Slate config step: "21 bindings · 2 layouts", or why it isn't loaded. */
export function sourceSummary(source, slateLoading) {
  if (source.error) return source.error;
  if (!slateLoading) return 'Not loaded';
  return plural(source.bindings.length, 'binding') + (source.layouts.length ? ` · ${plural(source.layouts.length, 'layout')}` : '');
}

/** Whether every starter shortcut's keys are taken by one of Slated's own bindings already. */
export function starterAdded(bindings) {
  const taken = new Set(bindings.map(b => keysString(b.keys)));
  return starterBindings(() => '').every(s => taken.has(keysString(s.keys)));
}

/**
 * The done step's checklist (DoneStep): what works now. Where the Mac lists Accessibility access,
 * GNOME lists whether GNOME Shell runs Slated (with the button that fixes it) and espanso.
 * @returns {Array<{title: string, done: boolean, detail: string, action: string|null}>}
 */
export function doneChecklist({summary, config, status, running, totalShortcuts}) {
  const hyperOn = config.keyboard.capsLock === 'hyper';
  const mode = running && status.hyper.mode !== 'off' ? ` · ${status.hyper.mode}` : '';
  const {guidance} = hotstringsStep({config, status, running});
  const hotstringsOff = config.general.hotstringsEnabled === false;
  let hotstrings;
  if (hotstringsOff) hotstrings = 'Off';
  else if (guidance.level === 'ok') hotstrings = 'espanso is in sync';
  else if (!running) hotstrings = 'Once Slated runs';
  else hotstrings = status.hotstrings.espansoInstalled ? "espanso isn't running" : 'Needs espanso';
  return [
    {title: 'Slated is running', done: summary.running, detail: summary.running ? 'In GNOME Shell' : summary.title,
      action: summary.running ? null : summary.action},
    {title: 'Hyper key', done: hyperOn, detail: hyperOn ? `Caps Lock is ✦${mode}` : 'Off', action: null},
    {title: 'Hotstrings', done: !hotstringsOff && guidance.level === 'ok', detail: hotstrings, action: null},
    {title: 'Shortcuts', done: totalShortcuts > 0, detail: `${totalShortcuts} ready`, action: null},
  ];
}

/**
 * "Try it now" on the done step (DoneStep.tipBinding): one of Slated's shortcuts that snaps a window
 * to a half, else a Slate file's shortcut that places it ("for first third").
 * @returns {{keys, modal, text: string}|null}
 */
export function tryItTip({bindings, sourceBindings}) {
  const own = bindings.find(b => b.enabled !== false && keysString(b.keys) && matchingPreset(b.action)?.group === 'halves');
  if (own) return {keys: own.keys, modal: own.modal ?? null, text: `to snap this window to the ${bindingTitle(own)}`.toLowerCase()};
  for (const b of sourceBindings) {
    let action = b.action ?? null;
    try {
      if (!action) action = b.probe?.()?.action ?? null;
    } catch {
      action = null;
    }
    if (action && matchingPreset(action)) return {keys: b.keys, modal: b.modal ?? null, text: `for ${actionTitle(action)}`.toLowerCase()};
  }
  return null;
}
