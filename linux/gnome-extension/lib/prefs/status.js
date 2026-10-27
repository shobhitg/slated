// The running extension's state, as the preferences learn it:
//
// - status.json ($XDG_STATE_HOME/slated/status.json), written by the extension;
// - GNOME Shell's own view of the extension (org.gnome.Shell.Extensions.GetExtensionInfo);
// - build-info.json next to prefs.js, written by linux/install.sh.
//
// This module only parses and interprets them. Pure ES module.

import {isObject, plural, deepEqual} from './util.js';

/** What the preferences assume when status.json is missing or unreadable. */
export function emptyStatus() {
  return {
    present: false,
    error: null,
    session: null,
    version: null,
    running: false,
    updatedAt: null,
    hyper: {wanted: false, mode: 'off', active: false},
    hotstrings: {engine: 'none', espansoInstalled: false, matchFile: null, count: 0},
    hotkeys: {},
    sources: [],
    screens: null,
    // What runs now (titles as the indicator shows them), the shortcuts that started it, and whether
    // while-held repeats stop as you let go ("key-repeat") or work like toggles ("toggle").
    automation: {running: [], shortcuts: [], stopShortcut: null, whileHeld: 'key-repeat'},
    clipboard: {enabled: false, items: 0},
    /** Apps used lately, newest first: [{id, name}], the ids onlyInApps takes. */
    recentApps: [],
    lastAction: null,
    lastError: null,
  };
}

const str = value => (typeof value === 'string' ? value : null);
const bool = value => value === true;
const num = (value, fallback = 0) => (typeof value === 'number' && Number.isFinite(value) ? value : fallback);

function rect(value) {
  if (!isObject(value)) return null;
  const r = {x: num(value.x, NaN), y: num(value.y, NaN), width: num(value.width, NaN), height: num(value.height, NaN)};
  return Object.values(r).every(Number.isFinite) && r.width > 0 && r.height > 0 ? r : null;
}

/** A hotkey state string from status.json → {state, reason}. */
export function hotkeyState(raw) {
  const text = String(raw ?? '');
  if (text === 'active' || text === 'duplicate' || text === 'disabled') return {state: text, reason: null};
  if (text.startsWith('failed')) {
    const reason = text.replace(/^failed:?\s*/, '');
    return {state: 'failed', reason: reason || 'GNOME refused the shortcut.'};
  }
  return {state: 'unknown', reason: null};
}

function screenInfo(value, index) {
  if (!isObject(value)) return null;
  const frame = rect(value.frame);
  if (!frame) return null;
  return {
    displayID: num(value.displayID, index + 1),
    name: str(value.name) ?? `Display ${index + 1}`,
    frame,
    visibleFrame: rect(value.visibleFrame) ?? frame,
    isMain: bool(value.isMain),
    scale: num(value.scale, 1),
  };
}

/** Parses status.json text. Never throws: problems come back in `error`. */
export function parseStatus(text) {
  const status = emptyStatus();
  if (text === null || text === undefined) return status;
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    return {...status, error: `status.json isn't valid JSON (${error.message})`};
  }
  if (!isObject(raw)) return {...status, error: 'status.json must contain a JSON object'};
  status.present = true;
  status.session = str(raw.session);
  status.version = str(raw.version);
  status.running = bool(raw.running);
  const updated = str(raw.updatedAt) ? new Date(raw.updatedAt) : null;
  status.updatedAt = updated && !Number.isNaN(updated.getTime()) ? updated : null;
  if (isObject(raw.hyper)) {
    status.hyper = {
      wanted: bool(raw.hyper.wanted),
      mode: ['xkb', 'keyd', 'off'].includes(raw.hyper.mode) ? raw.hyper.mode : 'off',
      active: bool(raw.hyper.active),
    };
  }
  if (isObject(raw.hotstrings)) {
    status.hotstrings = {
      engine: raw.hotstrings.engine === 'espanso' ? 'espanso' : 'none',
      espansoInstalled: bool(raw.hotstrings.espansoInstalled),
      matchFile: str(raw.hotstrings.matchFile),
      count: num(raw.hotstrings.count),
    };
  }
  if (isObject(raw.hotkeys)) {
    for (const [key, value] of Object.entries(raw.hotkeys)) status.hotkeys[key] = hotkeyState(value);
  }
  if (Array.isArray(raw.sources)) {
    status.sources = raw.sources.filter(isObject).map(s => ({
      path: str(s.path) ?? '',
      kind: s.kind === 'classic' ? 'classic' : 'javascript',
      exists: bool(s.exists),
      loaded: bool(s.loaded),
      bindings: num(s.bindings),
      diagnostics: Array.isArray(s.diagnostics) ? s.diagnostics.map(String) : [],
    }));
  }
  if (Array.isArray(raw.screens)) {
    const screens = raw.screens.map(screenInfo).filter(Boolean);
    status.screens = screens.length ? screens : null;
  }
  if (isObject(raw.automation)) {
    const a = raw.automation;
    status.automation = {
      running: Array.isArray(a.running) ? a.running.filter(t => typeof t === 'string') : [],
      shortcuts: Array.isArray(a.shortcuts) ? a.shortcuts.filter(t => typeof t === 'string') : [],
      stopShortcut: str(a.stopShortcut),
      whileHeld: a.whileHeld === 'toggle' ? 'toggle' : 'key-repeat',
    };
  }
  if (isObject(raw.clipboard)) {
    status.clipboard = {enabled: bool(raw.clipboard.enabled), items: Math.max(0, Math.round(num(raw.clipboard.items)))};
  }
  if (Array.isArray(raw.recentApps)) {
    status.recentApps = raw.recentApps
      .filter(app => isObject(app) && typeof app.id === 'string' && app.id)
      .map(app => ({id: app.id, name: str(app.name) || app.id}));
  }
  status.lastAction = str(raw.lastAction);
  status.lastError = str(raw.lastError);
  return status;
}

/** Counts of hotkeys by state. */
export function hotkeyCounts(status) {
  const counts = {active: 0, failed: 0, duplicate: 0, disabled: 0, unknown: 0};
  for (const {state} of Object.values(status.hotkeys ?? {})) counts[state] = (counts[state] ?? 0) + 1;
  return counts;
}

// --- GNOME Shell's view of the extension --------------------------------------------------------------

/**
 * GNOME Shell's ExtensionState numbers (js/misc/extensionUtils.js). 46 renamed ENABLED/DISABLED to
 * ACTIVE/INACTIVE; the numbers didn't change.
 */
const SHELL_STATES = {
  1: 'active', 2: 'inactive', 3: 'error', 4: 'out-of-date', 5: 'downloading', 6: 'initialized',
  7: 'deactivating', 8: 'activating', 99: 'uninstalled',
};

/**
 * Interprets GetExtensionInfo's a{sv} result (already unpacked to a plain object). An empty object
 * means the shell doesn't know the extension: on Wayland that's a fresh install before relogging.
 */
export function extensionState(info) {
  if (info === null || info === undefined) return {known: false, reachable: false, state: 'unknown', error: null, enabled: null};
  if (!isObject(info) || !Object.keys(info).length) return {known: false, reachable: true, state: 'unknown', error: null, enabled: null};
  const state = SHELL_STATES[Math.round(num(info.state, -1))] ?? 'unknown';
  const error = str(info.error) || null;
  return {known: true, reachable: true, state, error, enabled: typeof info.enabled === 'boolean' ? info.enabled : null};
}

/**
 * One headline for the Overview, from everything the preferences know. `level` is "ok", "warning"
 * or "error"; `action` names the button to offer ("enable", "relogin", "log", "review" or null).
 *
 * @param {object} args
 * @param {object} args.status parsed status.json
 * @param {object} args.shell extensionState()
 * @param {object|null} args.build build-info.json contents
 * @param {string|null} args.runningCommit the commit the running extension logged in app.start
 */
export function runningSummary({status, shell, build = null, runningCommit = null}) {
  const relogin = 'On Wayland, GNOME loads a new or updated extension only when you log in. Log out and back in, then come back here.';
  if (shell.reachable && !shell.known) {
    return {
      level: 'warning', running: false, title: 'Log out and back in to start Slated', action: 'relogin',
      detail: `GNOME Shell doesn't know about Slated yet. ${relogin}`,
    };
  }
  if (shell.state === 'error' || shell.state === 'out-of-date') {
    return {
      level: 'error', running: false, action: 'log',
      title: shell.state === 'error' ? 'Slated stopped with an error' : "This GNOME version isn't supported yet",
      detail: shell.error
        ? `${shell.error}\nDetails: journalctl -f -o cat /usr/bin/gnome-shell`
        : 'See the GNOME Shell log for details: journalctl -f -o cat /usr/bin/gnome-shell',
    };
  }
  if (shell.state === 'inactive' || shell.state === 'deactivating') {
    return {
      level: 'warning', running: false, title: 'Slated is turned off', action: 'enable',
      detail: 'Turn it on to use your shortcuts, the Hyper key and hotstrings. Your settings are kept.',
    };
  }
  if (shell.state === 'initialized' || shell.state === 'uninstalled') {
    return {level: 'warning', running: false, title: 'Log out and back in to start Slated', action: 'relogin', detail: relogin};
  }
  if (!status.present) {
    if (!shell.reachable) {
      return {
        level: 'warning', running: false, title: "Slated isn't running", action: 'relogin',
        detail: `Couldn't reach GNOME Shell, and Slated hasn't written its status file yet. Make sure the extension is enabled (gnome-extensions enable slated@…). ${relogin}`,
      };
    }
    return {
      level: 'warning', running: false, title: 'Slated is starting…', action: null,
      detail: "GNOME Shell reports Slated as active, but it hasn't written its status yet. If this doesn't change in a few seconds, check the log.",
    };
  }
  if (!status.running) {
    return {
      level: 'warning', running: false, title: "Slated isn't running", action: shell.reachable ? 'enable' : 'relogin',
      detail: 'Its status file says it stopped. Turn it on again, or log out and back in after an update.',
    };
  }
  if (build?.commit && runningCommit && build.commit !== runningCommit) {
    return {
      level: 'warning', running: true, title: 'A newer build is installed', action: 'relogin',
      detail: `Slated ${runningCommit} is running; ${build.commit} is installed. ${relogin}`,
    };
  }
  const counts = hotkeyCounts(status);
  if (counts.failed || counts.duplicate) {
    const parts = [];
    if (counts.duplicate) parts.push(plural(counts.duplicate, 'duplicate shortcut'));
    if (counts.failed) parts.push(`${counts.failed} that GNOME refused`);
    return {level: 'warning', running: true, title: 'Some shortcuts need attention', action: 'review', detail: parts.join(' and ')};
  }
  return {level: 'ok', running: true, title: "Everything's running", action: null, detail: null};
}

/**
 * The binding state shown in lists and editors (port of AppModel.state(for:)).
 *
 * @param {object} args
 * @param {object} args.binding the binding (a config binding, or a Slate source binding)
 * @param {string} args.key its status.json "hotkeys" key (keys.statusKey)
 * @param {object|undefined} args.saved the same binding as last saved (Slated bindings only)
 * @param {Array} args.issues validation issues for this binding
 * @param {object} args.status parsed status.json
 * @param {boolean} args.running whether the extension is running
 */
export function bindingState({binding, key, saved, issues = [], status, running, slateLoading = true, isSource = false, imported = false}) {
  if (isSource) {
    if (!slateLoading) return {state: 'slate-off'};
    // In general.importedSlateShortcuts: Slated's copy runs instead.
    if (imported) return {state: 'imported'};
  } else {
    const wasSaved = Boolean(saved);
    const keys = binding.keys;
    const empty = !keys || (typeof keys === 'string' ? !keys.trim() : !keys.key);
    if (empty && !wasSaved) return {state: 'new'};
    if (binding.enabled === false) return {state: 'disabled'};
    const error = issues.find(i => i.severity === 'error');
    if (error) return {state: 'not-saved', message: error.message, wasSaved};
    // Key order doesn't matter: a binding made here lists its fields in another order than config.json.
    if (!saved || !deepEqual(saved, binding)) return {state: 'saving'};
  }
  if (!running) return {state: 'not-running'};
  const reported = status.hotkeys?.[key];
  if (!reported) return {state: 'inactive'};
  return reported.state === 'failed' ? {state: 'failed', reason: reported.reason} : {state: reported.state};
}

/** Label, style ("success", "warning", "error", "accent", "dim") and icon for a binding state. */
export function statePresentation(state) {
  switch (state.state) {
  case 'active': return {label: 'Active', style: 'success', icon: null, row: null};
  case 'disabled': return {label: 'Off', style: 'dim', icon: null, row: 'Off'};
  case 'duplicate': return {label: 'Duplicate', style: 'warning', icon: 'dialog-warning-symbolic', row: 'Duplicate shortcut'};
  case 'failed': return {label: 'Failed', style: 'error', icon: 'dialog-error-symbolic', row: "Couldn't register"};
  case 'new': return {label: 'New', style: 'accent', icon: 'media-record-symbolic', row: 'Waiting for keys'};
  case 'not-saved': return {label: 'Not saved', style: 'error', icon: 'dialog-error-symbolic', row: state.message};
  case 'saving': return {label: 'Saving…', style: 'dim', icon: null, row: null};
  case 'not-running': return {label: 'Not running', style: 'dim', icon: null, row: null};
  case 'slate-off': return {label: 'Not loaded', style: 'dim', icon: null, row: 'Slate files off'};
  case 'imported': return {label: 'Imported', style: 'dim', icon: null, row: 'Imported'};
  default: return {label: 'Not registered', style: 'dim', icon: null, row: null};
  }
}

/** A sentence explaining a problem state, for the editor (null for healthy states). */
export function stateExplanation(state) {
  switch (state.state) {
  case 'duplicate':
    return 'Another shortcut uses the same keys, so only one of them can run. Change one of them, or turn one off.';
  case 'failed':
    return `${state.reason} Another app or GNOME itself may already use these keys.`;
  case 'not-saved':
    return state.wasSaved
      ? `${state.message} Until then, the last saved version of this shortcut stays in effect.`
      : `${state.message} The shortcut is saved as soon as that's fixed.`;
  case 'slate-off': return 'Loading Slate files is turned off in Slate Compatibility.';
  case 'imported': return "Imported into Slated's own shortcuts, where you can change it. Slated ignores this copy in your Slate file.";
  case 'not-running': return "Slated isn't running, so this shortcut does nothing right now. See Overview.";
  default: return null;
  }
}
