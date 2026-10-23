// `$XDG_STATE_HOME/slated/status.json`: the running extension's live state, rewritten whenever it
// changes. The preferences app reads it (it can't ask the extension directly).
//
// Schema (exact; prefs depends on it):
//
//   {"session":"abcd1234","version":"0.1.0","running":true,"updatedAt":"<ISO>",
//    "hyper":{"wanted":true,"mode":"xkb|keyd|off","active":true},
//    "hotstrings":{"engine":"espanso|none","espansoInstalled":true,"matchFile":"<path>","count":3},
//    "hotkeys":{"hyper+a":"active","hyper+q":"failed: <reason>","hyper+w":"duplicate","hyper+z":"disabled"},
//    "sources":[{"path":"~/.slate.js","kind":"javascript","exists":true,"loaded":true,"bindings":21,
//                "diagnostics":["..."]}],
//    "lastAction":"Left half · Firefox","lastError":null}
//
// Hotkey keys are config strings ("hyper+a"); modal bindings are "<modal keys> <keys>"
// ("ctrl+alt+f4 1"). "duplicate" means more than one binding uses those keys: the first one
// (config.json before Slate files, then file order) is the one that runs.

import GLib from 'gi://GLib';

import {diagnosticText, dirname} from './util.js';

/** "active" | "disabled" | "duplicate" | "failed: <reason>" from a status value. */
export function hotkeyStatusText(status) {
  if (typeof status === 'string') return status;
  if (status && typeof status === 'object' && 'failed' in status) return `failed: ${status.failed}`;
  return 'active';
}

export function sourceStatus(source) {
  return {
    path: source.path,
    kind: source.kind,
    exists: !!source.exists,
    loaded: !!source.loaded,
    bindings: Array.isArray(source.bindings) ? source.bindings.length : Number(source.bindings ?? 0),
    diagnostics: (source.diagnostics ?? []).map(diagnosticText),
  };
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
    updatedAt: now.toISOString(),
    hyper: {
      wanted: !!state.hyper?.wanted,
      mode: ['xkb', 'keyd'].includes(state.hyper?.mode) ? state.hyper.mode : 'off',
      active: !!state.hyper?.active,
    },
    hotstrings: {
      engine: state.hotstrings?.engine ?? 'none',
      espansoInstalled: !!state.hotstrings?.espansoInstalled,
      matchFile: state.hotstrings?.matchFile ?? null,
      count: state.hotstrings?.count ?? 0,
    },
    hotkeys,
    sources: (state.sources ?? []).map(sourceStatus),
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
