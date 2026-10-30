// `$XDG_STATE_HOME/slated/status.json`: the running extension's live state, rewritten whenever it
// changes. The preferences app reads it (it can't ask the extension directly).
//
// Schema (exact; prefs depends on it):
//
//   {"session":"abcd1234","version":"0.1.0","running":true,"paused":false,"updatedAt":"<ISO>",
//    "hyper":{"wanted":true,"mode":"xkb|keyd|off","active":true,"keyd":"running|stopped|none|checking"},
//    "hotstrings":{"engine":"espanso|none","espansoInstalled":true,"matchFile":"<path>","count":3},
//    "hotkeys":{"hyper+a":"active","hyper+q":"failed: <reason>","hyper+w":"duplicate","hyper+z":"disabled"},
//    "automation":{"running":["Repeat click left every 100 ms"],"shortcuts":["f6"],"stopShortcut":"hyper+esc",
//                  "whileHeld":"key-repeat"},
//    "clipboard":{"enabled":true,"items":12},
//    "recentApps":[{"id":"steam_app_1086940","name":"steam_app_1086940"},{"id":"firefox","name":"Firefox"}],
//    "lastAction":"Left half · Firefox","lastError":null}
//
// Hotkey keys are config strings ("hyper+a"); modal bindings are "<modal keys> <keys>"
// ("ctrl+alt+f4 1"). "duplicate" means more than one binding uses those keys: the first one in
// config.json is the one that runs.
//
// automation.running lists what runs now (the indicator's titles; insert-text is shown as a length);
// automation.shortcuts holds the hotkey keys (as in "hotkeys") of the shortcuts that started them.
// automation.whileHeld is "key-repeat" when while-held repeats stop as the key is let go (noticed
// through GNOME's key repeat), or "toggle" when keyboard repeat is off and they need a second press.
// paused is "Pause Slated" from the top bar: no shortcuts, Hyper key or hotstrings until resumed.
// hyper.keyd says whether keyd has Caps Lock ("running"), is set up for it but doesn't run ("stopped"),
// isn't set up for it ("none"), or is still being asked ("checking").
// recentApps are the apps focused lately (newest first): the ids "Only in…" app lists offer, including
// games without a desktop file, which are known by their window's WM_CLASS.

import GLib from 'gi://GLib';

import {dirname} from './util.js';

/** "active" | "disabled" | "duplicate" | "failed: <reason>" from a status value. */
export function hotkeyStatusText(status) {
  if (typeof status === 'string') return status;
  if (status && typeof status === 'object' && 'failed' in status) return `failed: ${status.failed}`;
  return 'active';
}

/** The status document, with keys in the schema's order. */
export function buildStatus(state) {
  const hotkeys = {};
  for (const key of Object.keys(state.hotkeys ?? {}).sort()) hotkeys[key] = hotkeyStatusText(state.hotkeys[key]);
  const now = state.now instanceof Date ? state.now : new Date();
  return {
    session: state.session ?? '',
    version: state.version ?? '0.0.0',
    running: !!state.running,
    paused: !!state.paused,
    updatedAt: now.toISOString(),
    hyper: {
      wanted: !!state.hyper?.wanted,
      mode: ['xkb', 'keyd'].includes(state.hyper?.mode) ? state.hyper.mode : 'off',
      active: !!state.hyper?.active,
      keyd: ['running', 'stopped', 'checking'].includes(state.hyper?.keyd) ? state.hyper.keyd : 'none',
    },
    hotstrings: {
      engine: state.hotstrings?.engine ?? 'none',
      espansoInstalled: !!state.hotstrings?.espansoInstalled,
      matchFile: state.hotstrings?.matchFile ?? null,
      count: state.hotstrings?.count ?? 0,
    },
    hotkeys,
    automation: {
      running: (state.automation?.running ?? []).map(String),
      shortcuts: (state.automation?.shortcuts ?? []).map(String),
      stopShortcut: typeof state.automation?.stopShortcut === 'string' ? state.automation.stopShortcut : null,
      whileHeld: state.automation?.whileHeld === 'toggle' ? 'toggle' : 'key-repeat',
    },
    clipboard: {
      enabled: state.clipboard?.enabled !== false,
      items: Number.isFinite(state.clipboard?.items) ? state.clipboard.items : 0,
    },
    recentApps: (state.recentApps ?? []).filter((app) => app?.id).map((app) => ({id: String(app.id), name: String(app.name ?? app.id)})),
    lastAction: state.lastAction ?? null,
    lastError: state.lastError ?? null,
  };
}

export function statusText(state) {
  return `${JSON.stringify(buildStatus(state), null, 2)}\n`;
}

/** Writes the status file atomically (temp file + rename), so readers never see half a file. */
export class StatusFile {
  constructor(path) {
    this.path = path;
    this._last = null;
  }

  /** Writes `state`; returns false (and keeps quiet) if nothing but the timestamp changed. */
  write(state) {
    const doc = buildStatus(state);
    const signature = JSON.stringify({...doc, updatedAt: null});
    if (signature === this._last) return false;
    GLib.mkdir_with_parents(dirname(this.path), 0o755);
    GLib.file_set_contents(this.path, `${JSON.stringify(doc, null, 2)}\n`);
    this._last = signature;
    return true;
  }
}
