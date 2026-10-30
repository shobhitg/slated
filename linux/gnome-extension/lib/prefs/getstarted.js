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
import {bindingTitle} from './actions.js';
import {importedText} from './migration.js';
import {espansoGuidance} from './hotstrings.js';
import {plural, isObject} from './util.js';

/**
 * What keeps Slated from running that the window can fix or explain, shown first on Get Started's
 * first step (where the Mac asks for Accessibility access): GNOME's Extensions switch, Slated turned
 * off, a login still needed, an error. Null while Slated runs, or is only starting.
 * @param {object} summary status.runningSummary()
 * @returns {{level: string, title: string, detail: string, action: string}|null}
 */
export function setupBlocker(summary) {
  if (summary.running || !summary.action || summary.action === 'review') return null;
  return {level: summary.level === 'error' ? 'error' : 'warning', title: summary.title, detail: summary.detail, action: summary.action};
}

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

/**
 * The Hyper switch's subtitle (HyperKeyStep.hyperSubtitle): points out when the user's own shortcuts
 * already use all four Hyper modifiers, so the choice is obvious.
 */
export function hyperSubtitle({bindings, hyperOn}) {
  const usesHyper = b => isHyper(keysCombo(b.keys).modifiers);
  const count = bindings.filter(usesHyper).length;
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
export function hotstringsStep({config, status, running, espansoRunning = null}) {
  const enabled = config.general.hotstringsEnabled !== false;
  const all = config.hotstrings.filter(h => h.enabled !== false);
  const macOnly = all.filter(h => h.onlyInApps?.length).length;
  const expanding = all.length - macOnly;
  const guidance = enabled
    ? espansoGuidance(status.hotstrings, running, espansoRunning)
    : {level: 'info', title: 'Text expansion is turned off', detail: 'Turn it on under Hotstrings when you want it.'};
  const summary = all.length
    ? `${plural(expanding, 'hotstring')} to expand${macOnly ? ` · ${macOnly} Mac only` : ''}`
    : 'None yet. Add them under Hotstrings.';
  const first = all.find(h => h.trigger && !h.onlyInApps?.length)?.trigger ?? null;
  return {guidance, ready: guidance.level === 'ok' || !enabled, summary, first, installLink: guidance.link ?? null};
}

/**
 * The Slate config step (SlateConfigStep). Slated doesn't load Slate files: a first run imports one
 * into its own shortcuts, and so does the move from version 1. The step says what was imported (from
 * config-migration.json's record), or offers the import when a Slate config is here but wasn't
 * imported, or the starter shortcuts when there's none (or Slated has no shortcuts of its own).
 * @param {object} args
 * @param {object|null} args.record what a migration or first run imported (migration.js)
 * @param {Array} args.slateFiles the Slate configs found (model.slateFiles)
 * @param {boolean} args.importedHere whether an import ran in this window (settings-window.json)
 * @param {Array} args.bindings Slated's bindings
 */
export function slateStep({record, slateFiles, importedHere = false, bindings}) {
  const offerStarter = !bindings.length || !slateFiles.length;
  const files = slateFiles.map(f => f.displayPath);
  if (record?.slate) {
    return {
      state: 'imported', offerStarter, offerImport: false, title: 'Your Slate shortcuts are in Slated',
      subtitle: `${importedText(record)} Edit them under Windows. Slated doesn't read Slate files any more.`,
    };
  }
  if (importedHere) {
    return {
      state: 'imported', offerStarter, offerImport: true, title: 'Your Slate shortcuts are in Slated',
      subtitle: "Edit them under Windows. Slated doesn't read Slate files any more; import again any time to bring over new ones.",
    };
  }
  if (slateFiles.length) {
    return {
      state: 'found', offerStarter, offerImport: true, title: 'Your Slate config is here',
      subtitle: `Import the shortcuts in ${files.join(' and ')} to use them in Slated. Slated doesn't read Slate files directly, `
        + "and your file isn't changed.",
    };
  }
  return {
    state: 'none', offerStarter, offerImport: false, title: 'Start with a few great shortcuts',
    subtitle: 'No ~/.slate or ~/.slate.js here — no problem. Add a starter set now and make it yours under Windows.',
  };
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
export function doneChecklist({summary, config, status, running, totalShortcuts, espansoRunning = null}) {
  const hyperOn = config.keyboard.capsLock === 'hyper';
  const mode = running && status.hyper.mode !== 'off' ? ` · ${status.hyper.mode}` : '';
  const {guidance} = hotstringsStep({config, status, running, espansoRunning});
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
 * to a half.
 * @returns {{keys, modal, text: string}|null}
 */
export function tryItTip({bindings}) {
  const own = bindings.find(b => b.enabled !== false && keysString(b.keys) && matchingPreset(b.action)?.group === 'halves');
  return own ? {keys: own.keys, modal: own.modal ?? null, text: `to snap this window to the ${bindingTitle(own)}`.toLowerCase()} : null;
}
