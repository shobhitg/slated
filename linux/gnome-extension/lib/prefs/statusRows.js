// Settings → Overview's status rows (Slated, Hyper Key, Hotstrings, Shortcuts): what each says, its
// pill, and the button that fixes what's missing. Never a bare "Waiting": when something isn't
// working, the row says what's missing and offers what fixes it, as plainly as the Overview's
// headline (status.runningSummary).
//
// Pure ES module. ui/overview.js draws the rows; actions are names it turns into buttons:
// runningSummary's ("enableExtensions", "enable", "relogin", "log", "review"), a page to open
// ("keyboard", "hotstrings", "windows"), or {copy: command} for a command to run in a terminal.

import {hotkeyCounts} from './status.js';
import {espansoGuidance} from './hotstrings.js';
import {plural} from './util.js';

/** The command that starts keyd (and starts it at boot), where linux/install.sh set it up. */
export const KEYD_START = 'sudo systemctl enable --now keyd';

const NOT_RUNNING = {label: 'Not running', style: 'warning'};
const PAUSED = {label: 'Paused', style: 'warning'};

/** "Slated is turned off" → "Slated is turned off." (titles end without a period, or with "…"). */
function sentence(text) {
  return /[.…!?]$/.test(text) ? text : `${text}.`;
}

/** The Slated row's pill when Slated isn't running: why, in a word or two. */
function notRunningPill(summary, shell) {
  switch (summary.action) {
  case 'enableExtensions': return {label: 'Extensions off', style: 'error'};
  case 'enable': return {label: 'Off', style: 'warning'};
  case 'relogin': return {label: 'Not loaded', style: 'warning'};
  case 'log': return {label: 'Error', style: 'error'};
  default: return shell.state === 'active' ? {label: 'Starting', style: 'dim'} : NOT_RUNNING;
  }
}

/**
 * @param {object} args
 * @param {object} args.summary status.runningSummary()
 * @param {object} args.status parsed status.json
 * @param {object} args.shell status.extensionState()
 * @param {object} args.config the configuration
 * @param {boolean} [args.keydConfigured] Slated's keyd config is installed (for an older extension
 *   whose status.json doesn't say whether keyd runs)
 * @param {boolean|null} [args.espansoRunning] what `espanso status` says, null when unknown
 * @returns {{extension: Row, hyper: Row, hotstrings: Row, shortcuts: Row}} Row: {value, state: {label,
 *   style}, action}
 */
export function overviewRows({summary, status, shell, config, keydConfigured = false, espansoRunning = null}) {
  const running = summary.running;
  const paused = running && status.paused;
  const why = sentence(summary.title);
  const fix = summary.action && summary.action !== 'review' ? summary.action : null;

  // Slated itself
  let extension;
  if (!running) {
    extension = {value: summary.title, state: notRunningPill(summary, shell), action: fix};
  } else {
    const facts = ['Running', status.session && `session ${status.session}`, status.version].filter(Boolean).join(' · ');
    extension = paused
      ? {value: `${facts} · paused from the top bar`, state: PAUSED, action: null}
      : {value: facts, state: {label: 'Running', style: 'success'}, action: null};
  }

  // The Hyper key
  const hyperOn = config.keyboard.capsLock === 'hyper';
  const hyperStatus = status.hyper ?? {};
  // GNOME's keyboard option always sends the Hyper modifier, whatever hyperModifiers says (see Keyboard).
  const mods = running && hyperStatus.mode === 'xkb' ? 'the Hyper modifier'
    : config.keyboard.hyperModifiers.includes('cmd') ? 'Ctrl Alt Shift Super' : 'Ctrl Alt Shift';
  const keydStopped = hyperStatus.keyd === 'stopped' || (hyperStatus.keyd === null && keydConfigured && hyperStatus.mode === 'xkb');
  let hyper;
  if (!hyperOn) {
    hyper = {value: 'Caps Lock is normal', state: {label: 'Off', style: 'dim'}, action: 'keyboard'};
  } else if (!running) {
    hyper = {value: `Caps Lock becomes ✦ once Slated runs. ${why}`, state: NOT_RUNNING, action: fix};
  } else if (paused) {
    hyper = {value: 'Caps Lock is normal while Slated is paused', state: PAUSED, action: null};
  } else if (hyperStatus.active && hyperStatus.mode === 'xkb' && keydStopped) {
    hyper = {
      value: `keyd isn't running, so GNOME's keyboard option stands in: Caps Lock acts as ${mods}, without the tap for Escape. `
        + `Start keyd with “${KEYD_START}”, or run linux/install.sh again.`,
      state: {label: 'keyd stopped', style: 'warning'}, action: {copy: KEYD_START},
    };
  } else if (hyperStatus.active) {
    hyper = {value: `Caps Lock acts as ${mods} · ${hyperStatus.mode}`, state: {label: 'On', style: 'success'}, action: null};
  } else if (hyperStatus.keyd === 'checking') {
    hyper = {value: 'Checking whether keyd runs, which decides how Caps Lock becomes ✦', state: {label: 'Checking', style: 'dim'}, action: null};
  } else {
    hyper = {
      value: "Caps Lock isn't ✦: GNOME's keyboard option couldn't be set. Run linux/install.sh --hyper-keyd to use keyd instead; the log says more.",
      state: {label: 'Not active', style: 'warning'}, action: 'log',
    };
  }

  // Hotstrings (espanso). Those limited to some apps are Mac only: espanso can't tell apps apart.
  const enabled = config.hotstrings.filter(h => h.enabled !== false);
  const macOnly = enabled.filter(h => h.onlyInApps?.length).length;
  const expanding = enabled.length - macOnly;
  const count = `${plural(expanding, 'hotstring')}${macOnly ? ` · ${macOnly} Mac only` : ''}`;
  let hotstrings;
  if (config.general.hotstringsEnabled === false) {
    hotstrings = {value: 'Text expansion is turned off', state: {label: 'Off', style: 'dim'}, action: 'hotstrings'};
  } else if (!expanding && macOnly) {
    hotstrings = {value: count, state: {label: 'Mac only', style: 'dim'}, action: 'hotstrings'};
  } else if (!running) {
    hotstrings = {value: `${count} expand once Slated runs. ${why}`, state: NOT_RUNNING, action: fix};
  } else if (paused) {
    hotstrings = {value: `${count} · nothing expands while Slated is paused`, state: PAUSED, action: null};
  } else {
    const espanso = espansoGuidance(status.hotstrings, true, espansoRunning);
    if (espanso.level === 'ok') {
      hotstrings = {value: `${count} · ${espanso.title.toLowerCase()}`, state: {label: 'Active', style: 'success'}, action: 'hotstrings'};
    } else if (espanso.command) {
      hotstrings = {value: `${count} · ${espanso.detail}`, state: {label: 'espanso stopped', style: 'warning'}, action: {copy: espanso.command}};
    } else if (!status.hotstrings.espansoInstalled) {
      hotstrings = {
        value: `${count} · espanso isn't installed, and on GNOME only espanso can type them. Run linux/install.sh again: it installs espanso.`,
        state: {label: 'Needs espanso', style: 'warning'}, action: 'hotstrings',
      };
    } else {
      hotstrings = {value: `${count} · ${espanso.title}. ${espanso.detail}`, state: {label: 'Needs espanso', style: 'warning'}, action: 'log'};
    }
  }

  // Shortcuts
  const counts = hotkeyCounts(status);
  const problems = [];
  if (counts.duplicate) problems.push(plural(counts.duplicate, 'duplicate'));
  if (counts.failed) problems.push(`${counts.failed} failed`);
  let shortcuts;
  if (!running) {
    shortcuts = {value: `${plural(config.bindings.length, 'shortcut')} work once Slated runs. ${why}`, state: NOT_RUNNING, action: fix};
  } else if (paused) {
    shortcuts = {value: `${plural(config.bindings.length, 'shortcut')} · off while Slated is paused`, state: PAUSED, action: null};
  } else if (problems.length) {
    shortcuts = {value: problems.join(' · '), state: {label: 'Attention', style: 'warning'}, action: 'review'};
  } else {
    shortcuts = {value: `${plural(config.bindings.length, 'shortcut')} · ${counts.active} active`, state: {label: `${counts.active} active`, style: 'success'},
      action: 'windows'};
  }

  return {extension, hyper, hotstrings, shortcuts};
}
