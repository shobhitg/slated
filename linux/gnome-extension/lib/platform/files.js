// File helpers for the runtime: small synchronous reads and atomic writes of config-sized files, and
// file monitors. GNOME Shell runs extensions on its main loop, so only small local files go through
// here.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {dirname} from './util.js';

const decoder = new TextDecoder('utf-8');
const encoder = new TextEncoder();

export function exists(path) {
  return GLib.file_test(path, GLib.FileTest.EXISTS);
}

export function isDirectory(path) {
  return GLib.file_test(path, GLib.FileTest.IS_DIR);
}

/** The file's text, or null when it can't be read. */
export function readText(path) {
  try {
    const [ok, bytes] = Gio.File.new_for_path(path).load_contents(null);
    return ok ? decoder.decode(bytes) : null;
  } catch {
    return null;
  }
}

/** Writes `text` atomically (temp file + rename), creating parent directories. Throws on failure. */
export function writeTextAtomic(path, text) {
  GLib.mkdir_with_parents(dirname(path), 0o755);
  GLib.file_set_contents(path, encoder.encode(text));
}

/**
 * Writes `text` so only you can read it (mode 0600, for private content like clipboard history),
 * replacing the file atomically and creating its folder (0700). Throws on failure.
 */
export function writePrivateTextAtomic(path, text) {
  GLib.mkdir_with_parents(dirname(path), 0o700);
  const file = Gio.File.new_for_path(path);
  file.replace_contents(encoder.encode(text), null, false, Gio.FileCreateFlags.PRIVATE | Gio.FileCreateFlags.REPLACE_DESTINATION, null);
  // A file that existed before keeps its old mode through a replace: make sure it's private.
  file.set_attribute_uint32('unix::mode', 0o600, Gio.FileQueryInfoFlags.NONE, null);
}

/** Deletes a file; returns false when it wasn't there. */
export function remove(path) {
  try {
    return Gio.File.new_for_path(path).delete(null);
  } catch {
    return false;
  }
}

/** Seconds since the epoch of the last modification, or null. */
export function modificationTime(path) {
  try {
    const info = Gio.File.new_for_path(path).query_info('time::modified', Gio.FileQueryInfoFlags.NONE, null);
    return info.get_attribute_uint64('time::modified');
  } catch {
    return null;
  }
}

/** The names of the entries in a directory ([] when it can't be read). */
export function listDirectory(path) {
  try {
    const enumerator = Gio.File.new_for_path(path).enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
    const names = [];
    for (let info = enumerator.next_file(null); info; info = enumerator.next_file(null)) names.push(info.get_name());
    enumerator.close(null);
    return names;
  } catch {
    return [];
  }
}

/**
 * Watches one file, including atomic saves (write a temp file, rename over) and the file appearing
 * or disappearing. GIO watches the parent directory for this. With `directory`, watches the files in
 * that directory instead (added, removed or changed). `onChange` gets no arguments; callers
 * debounce. Returns an object with `cancel()`.
 */
export function watchFile(path, onChange, {directory = false} = {}) {
  const file = Gio.File.new_for_path(path);
  let monitor = null;
  let id = 0;
  try {
    monitor = directory
      ? file.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null)
      : file.monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
    id = monitor.connect('changed', (_monitor, _file, _other, eventType) => {
      // Attribute-only changes (touch -a, chmod) don't change content.
      if (eventType === Gio.FileMonitorEvent.ATTRIBUTE_CHANGED || eventType === Gio.FileMonitorEvent.PRE_UNMOUNT) return;
      onChange();
    });
  } catch (e) {
    console.warn(`Slated: can't watch ${path}: ${e.message}`);
  }
  return {
    path,
    cancel() {
      if (!monitor) return;
      if (id) monitor.disconnect(id);
      monitor.cancel();
      monitor = null;
      id = 0;
    },
  };
}

/** Finds a program in PATH or a few usual install locations. */
export function findProgram(name, extraDirs = []) {
  const found = GLib.find_program_in_path(name);
  if (found) return found;
  for (const dir of extraDirs) {
    const candidate = `${dir}/${name}`;
    if (GLib.file_test(candidate, GLib.FileTest.IS_EXECUTABLE)) return candidate;
  }
  return null;
}
