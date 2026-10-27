// File access for the preferences window (GJS): reading and atomically writing config.json, appending
// to the event log, watching status.json and config.json, and reading build-info.json.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {formatEvent} from './eventlog.js';

const decoder = new TextDecoder();
const encoder = new TextEncoder();

/** The text of a file, or null when it doesn't exist. Throws for other errors (permissions…). */
export function readText(path) {
  if (!GLib.file_test(path, GLib.FileTest.EXISTS)) return null;
  const [, bytes] = GLib.file_get_contents(path);
  return decoder.decode(bytes);
}

/** Whether a file exists (a symbolic link counts when it leads to one). */
export function fileExists(path) {
  return GLib.file_test(path, GLib.FileTest.EXISTS);
}

/**
 * The last `maxBytes` of a file (the log can grow to several megabytes; only its tail matters), or
 * null when it doesn't exist. The first, possibly partial, line is dropped.
 */
export function readTail(path, maxBytes = 256 * 1024) {
  const file = Gio.File.new_for_path(path);
  if (!file.query_exists(null)) return null;
  const info = file.query_info('standard::size', Gio.FileQueryInfoFlags.NONE, null);
  const size = info.get_size();
  const stream = file.read(null);
  try {
    const start = Math.max(0, size - maxBytes);
    if (start > 0) stream.seek(start, GLib.SeekType.SET, null);
    // read_bytes may return less than asked for: read until the end.
    const chunks = [];
    let total = 0;
    for (;;) {
      const data = stream.read_bytes(64 * 1024, null).get_data();
      if (!data || !data.length) break;
      chunks.push(data);
      total += data.length;
    }
    const all = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      all.set(chunk, offset);
      offset += chunk.length;
    }
    const text = decoder.decode(all);
    return start > 0 ? text.slice(text.indexOf('\n') + 1) : text;
  } finally {
    stream.close(null);
  }
}

function ensureParent(path, mode) {
  GLib.mkdir_with_parents(GLib.path_get_dirname(path), mode);
}

/**
 * Replaces a file's contents atomically (a temporary file renamed over it), creating its folder.
 * Symbolic links are followed, so a config.json kept in a dotfiles repo stays a link.
 */
export function writeTextAtomic(path, text) {
  ensureParent(path, 0o700);
  Gio.File.new_for_path(path).replace_contents(encoder.encode(text), null, false, Gio.FileCreateFlags.NONE, null);
}

/** Appends text to a file: open, append, close, so it never holds the log open or races a rotation. */
export function appendText(path, text) {
  ensureParent(path, 0o755);
  const stream = Gio.File.new_for_path(path).append_to(Gio.FileCreateFlags.NONE, null);
  try {
    stream.write_all(encoder.encode(text), null);
  } finally {
    stream.close(null);
  }
}

/** build-info.json written by linux/install.sh into the extension folder, or null. */
export function readBuildInfo(extensionPath) {
  try {
    const text = readText(GLib.build_filenamev([extensionPath, 'build-info.json']));
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}

/** setTimeout/clearTimeout on the GLib main loop, for the model's debounced saving. */
export const glibScheduler = {
  setTimeout(fn, ms) {
    return GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
      fn();
      return GLib.SOURCE_REMOVE;
    });
  },
  clearTimeout(id) {
    GLib.source_remove(id);
  },
};

/**
 * Calls `callback` (debounced) whenever `path` changes, is created, deleted or renamed over. Its
 * folder is created first, so the file can appear later. Returns {cancel()}; keep the result
 * referenced, or the monitor is garbage-collected and stops.
 */
export function watchFile(path, callback, debounceMs = 150) {
  ensureParent(path, 0o755);
  const monitor = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
  let timer = 0;
  const handler = monitor.connect('changed', () => {
    if (timer) GLib.source_remove(timer);
    timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, debounceMs, () => {
      timer = 0;
      callback();
      return GLib.SOURCE_REMOVE;
    });
  });
  return {
    monitor,
    cancel() {
      if (timer) GLib.source_remove(timer);
      timer = 0;
      monitor.disconnect(handler);
      monitor.cancel();
    },
  };
}

/** Appends `ui.*` and other events to Slated's log, in the macOS format (see eventlog.js). */
export class EventLogWriter {
  /**
   * @param {string} path the log file
   * @param {() => string} session the session to record under (the running extension's, when known)
   */
  constructor(path, session) {
    this.path = path;
    this.session = session;
  }

  record(event, data = {}, level = 'info') {
    try {
      appendText(this.path, formatEvent(event, {session: this.session(), level, data}));
    } catch (error) {
      // Logging must never break the settings window.
      console.warn(`Slated: couldn't write to ${this.path}: ${error.message}`);
    }
  }
}
