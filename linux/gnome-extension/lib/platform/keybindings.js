// Global shortcuts: registers bindings from every source as GNOME accelerators, including Slate's
// modal keys and repeat-while-held, and tracks each binding's status for the preferences app.
// A port of the macOS HotkeyManager (Sources/Slated/Engine/HotkeyManager.swift).
//
// `KeybindingManager` holds the logic and talks to GNOME only through a grabber (`MutterGrabber`
// below), so the Node tests drive it with a fake.
//
// How grabbing works in GNOME Shell (the same calls the shell uses for its D-Bus GrabAccelerator):
//   action = global.display.grab_accelerator(accelerator, flags)   // Meta.KeyBindingAction.NONE = failed
//   Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), modes)
//   global.display 'accelerator-activated' (display, action, device, timestamp)
//   global.display.ungrab_accelerator(action) + allowKeybinding(name, Shell.ActionMode.NONE)
// Mutter refuses (NONE) an accelerator it can't parse or one that is already bound, by GNOME itself
// (e.g. Super+A), another extension, or an app's global shortcut.
//
// Repeat while held: Mutter re-sends a held shortcut at the keyboard's repeat rate unless the grab
// has IGNORE_AUTOREPEAT, so repeating bindings simply leave it off. (Slate's secondsBeforeRepeat /
// secondsBetweenRepeat don't apply; GNOME's keyboard repeat settings do.)

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export const ACTIVE = 'active';
export const DISABLED = 'disabled';
export const DUPLICATE = 'duplicate';

export function failed(reason) {
  return `failed: ${reason}`;
}

/**
 * Registers hotkey entries:
 *   {id, keys: KeyCombo, modal: {keys, toggle} | null, repeats, source, run()}
 * `id` is the status key ("hyper+a", or "ctrl+alt+f4 1" for modal bindings).
 */
export class KeybindingManager {
  constructor({grabber, log = null, onModalChange = null}) {
    this._grabber = grabber;
    this._log = log;
    this.onModalChange = onModalChange;
    this.statuses = {};
    this.duplicates = [];
    this._handlers = new Map();
    this._grabs = [];
    this._direct = new Map();
    this._modalGroups = new Map();
    this._activeModal = null;
    this._modalGrabs = [];
    this._acceleratorFor = () => null;
    this._escapeKeys = null;
    this._lastLogged = '';
    this._grabber.connect((action) => this._activated(action));
  }

  /**
   * Replaces every registration.
   * @param {object[]} entries  In priority order: the first binding for a key wins.
   * @param {object} options
   * @param {string[]} [options.disabled]  Keys of disabled bindings (status "disabled").
   * @param {(combo: object) => string|null} options.acceleratorFor  KeyCombo → GNOME accelerator.
   * @param {object|null} [options.escapeKeys]  KeyCombo that leaves modal mode (Slate's modalEscapeKey).
   */
  apply(entries, {disabled = [], acceleratorFor, escapeKeys = null} = {}) {
    this.unregisterAll();
    this._acceleratorFor = acceleratorFor ?? (() => null);
    this._escapeKeys = escapeKeys;
    this.statuses = {};
    for (const id of disabled) this.statuses[id] = DISABLED;
    this.duplicates = [];

    const seen = new Set();
    const direct = [];
    for (const entry of entries) {
      if (seen.has(entry.id)) {
        this.duplicates.push(entry.id);
        continue;
      }
      seen.add(entry.id);
      if (entry.modal) {
        const modalId = this._comboKey(entry.modal.keys);
        if (!this._modalGroups.has(modalId)) this._modalGroups.set(modalId, {id: modalId, keys: entry.modal.keys, entries: []});
        this._modalGroups.get(modalId).entries.push(entry);
      } else {
        direct.push(entry);
      }
    }

    for (const entry of direct) {
      const result = this._grab(entry.keys, {repeats: !!entry.repeats}, () => this._run(entry));
      this.statuses[entry.id] = result.ok ? ACTIVE : failed(result.reason);
      if (result.ok) this._direct.set(entry.id, entry);
    }
    for (const group of this._modalGroups.values()) {
      const result = this._grab(group.keys, {repeats: false}, () => this._toggleModal(group));
      for (const entry of group.entries) {
        this.statuses[entry.id] = result.ok ? ACTIVE : failed(`the modal key couldn't be registered: ${result.reason}`);
      }
    }
    for (const id of this.duplicates) if (this.statuses[id] === ACTIVE) this.statuses[id] = DUPLICATE;
    this._logRegistration();
  }

  /** Runs the binding for `id` as if its shortcut was pressed (debug interface). */
  trigger(id) {
    const entry = this._direct.get(id);
    if (entry) {
      this._run(entry);
      return true;
    }
    for (const group of this._modalGroups.values()) {
      const modalEntry = group.entries.find((e) => e.id === id);
      if (modalEntry) {
        this._run(modalEntry);
        return true;
      }
    }
    return false;
  }

  get activeModal() {
    return this._activeModal;
  }

  unregisterAll() {
    this._exitModal({log: false});
    for (const action of this._grabs) this._grabber.ungrab(action);
    this._grabs = [];
    this._handlers.clear();
    this._direct.clear();
    this._modalGroups.clear();
  }

  destroy() {
    this.unregisterAll();
    this._grabber.destroy();
    this.onModalChange = null;
  }

  // --- Internals ---------------------------------------------------------------------------------

  _comboKey(combo) {
    return `${[...(combo.modifiers ?? [])].sort().join('+')}+${combo.key}`;
  }

  /** Grabs `combo`; on success the grab is added to `list` (released by `unregisterAll`/`_exitModal`). */
  _grab(combo, {repeats}, handler, list = this._grabs) {
    let accelerator = null;
    try {
      accelerator = this._acceleratorFor(combo);
    } catch (e) {
      return {ok: false, reason: `can't be expressed as a GNOME shortcut (${e?.message ?? e})`};
    }
    if (!accelerator) return {ok: false, reason: "this key can't be used in a GNOME shortcut"};
    const result = this._grabber.grab(accelerator, {repeats});
    if (!result.ok) return result;
    this._handlers.set(result.action, handler);
    list.push(result.action);
    return result;
  }

  _activated(action) {
    const handler = this._handlers.get(action);
    if (!handler) return false;
    try {
      handler();
    } catch (e) {
      this._log?.error('hotkeys.handler_failed', e?.message ?? String(e));
    }
    return true;
  }

  _run(entry) {
    try {
      entry.run();
    } catch (e) {
      this._log?.error('hotkeys.handler_failed', e?.message ?? String(e), {keys: entry.id});
    }
  }

  // Modal keys (Slate's `bind 1:f4,ctrl,alt`): pressing the modal key grabs the bindings' own keys
  // until one is pressed (or until the modal key or the escape key is pressed again).
  _toggleModal(group) {
    // Grabbing from inside Mutter's key handling is avoided: do it on the next main-loop turn.
    this._grabber.defer(() => {
      // The bindings may have been re-applied since the key press.
      if (this._modalGroups.get(group.id) !== group) return;
      if (this._activeModal === group.id) {
        this._exitModal();
        return;
      }
      this._exitModal({log: false});
      this._activeModal = group.id;
      for (const entry of group.entries) {
        this._grabModal(entry.keys, () => {
          this._run(entry);
          if (!entry.modal?.toggle) this._grabber.defer(() => this._exitModal());
        });
      }
      if (this._escapeKeys) this._grabModal(this._escapeKeys, () => this._grabber.defer(() => this._exitModal()));
      this._log?.record('modal.entered', {keys: group.entries[0]?.id?.split(' ')[0] ?? group.id});
      this.onModalChange?.(group.id);
    });
  }

  _grabModal(combo, handler) {
    // Tracked separately so leaving modal mode releases only these.
    const result = this._grab(combo, {repeats: false}, handler, this._modalGrabs);
    if (!result.ok) this._log?.record('modal.key_failed', {reason: result.reason}, 'notice');
  }

  _exitModal({log = true} = {}) {
    if (this._activeModal === null) return;
    for (const action of this._modalGrabs) {
      this._grabber.ungrab(action);
      this._handlers.delete(action);
    }
    this._modalGrabs = [];
    this._activeModal = null;
    if (log) this._log?.record('modal.exited');
    this.onModalChange?.(null);
  }

  /** Logs a summary when registrations or their problems change (not on every config save). */
  _logRegistration() {
    const entries = Object.entries(this.statuses);
    const failures = entries
      .filter(([, s]) => s.startsWith('failed: '))
      .map(([k, s]) => `${k}: ${s.slice(8)}`)
      .sort();
    const active = entries.filter(([, s]) => s === ACTIVE || s === DUPLICATE).length;
    const signature = JSON.stringify([active, failures, this.duplicates]);
    if (signature === this._lastLogged) return;
    this._lastLogged = signature;
    const data = {active, total: entries.length};
    if (failures.length) data.failed = failures;
    if (this.duplicates.length) data.duplicates = this.duplicates;
    this._log?.record('hotkeys.registered', data, failures.length ? 'error' : 'info');
  }
}

// --- GNOME ---------------------------------------------------------------------------------------

/** Grabs accelerators from Mutter and reports activations. */
export class MutterGrabber {
  constructor({timers, hyperIsSuper = () => false}) {
    this._timers = timers;
    this._hyperIsSuper = hyperIsSuper;
    this._signal = 0;
    this._names = new Map();
    this._onActivated = null;
  }

  connect(callback) {
    this._onActivated = callback;
    if (!this._signal) {
      this._signal = global.display.connect('accelerator-activated', (_display, action) => {
        this._onActivated?.(action);
      });
    }
  }

  grab(accelerator, {repeats}) {
    const flags = repeats
      ? Meta.KeyBindingFlags.NONE
      : Meta.KeyBindingFlags.IGNORE_AUTOREPEAT ?? Meta.KeyBindingFlags.NONE;
    let action = Meta.KeyBindingAction.NONE;
    try {
      action = global.display.grab_accelerator(accelerator, flags);
    } catch (e) {
      return {ok: false, reason: `GNOME rejected ${accelerator}: ${e.message}`};
    }
    if (action === Meta.KeyBindingAction.NONE) return {ok: false, reason: conflictReason(accelerator, this._hyperIsSuper())};
    const name = Meta.external_binding_name_for_action(action);
    Main.wm.allowKeybinding(name, Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW);
    this._names.set(action, name);
    return {ok: true, action};
  }

  ungrab(action) {
    try {
      global.display.ungrab_accelerator(action);
    } catch {
      // Already gone.
    }
    const name = this._names.get(action) ?? Meta.external_binding_name_for_action(action);
    Main.wm.allowKeybinding(name, Shell.ActionMode.NONE);
    this._names.delete(action);
  }

  defer(callback) {
    this._timers.idle(callback);
  }

  destroy() {
    for (const action of [...this._names.keys()]) this.ungrab(action);
    if (this._signal) global.display.disconnect(this._signal);
    this._signal = 0;
    this._onActivated = null;
  }
}

// --- Why a grab failed ---------------------------------------------------------------------------

const MODIFIER_ALIASES = {
  control: 'ctrl',
  ctrl: 'ctrl',
  primary: 'ctrl',
  ctl: 'ctrl',
  alt: 'alt',
  mod1: 'alt',
  shift: 'shift',
  super: 'super',
  mod4: 'super',
  hyper: 'hyper',
  meta: 'meta',
};

/**
 * A comparable form of a GTK-style accelerator: sorted modifiers + lowercase key, e.g.
 * "<Super><Shift>Left" → "shift+super+left". With `hyperIsSuper`, Hyper counts as Super: in the stock
 * keymap both live on Mod4, so Mutter treats `<Hyper>a` and `<Super>a` as the same shortcut.
 */
export function normalizeAccelerator(accelerator, {hyperIsSuper = false} = {}) {
  if (typeof accelerator !== 'string' || !accelerator.trim()) return null;
  const mods = new Set();
  let rest = accelerator.trim();
  for (;;) {
    const match = /^<([^>]+)>/.exec(rest);
    if (!match) break;
    let mod = MODIFIER_ALIASES[match[1].toLowerCase()] ?? match[1].toLowerCase();
    if (mod === 'hyper' && hyperIsSuper) mod = 'super';
    mods.add(mod);
    rest = rest.slice(match[0].length);
  }
  if (!rest) return null;
  return [...[...mods].sort(), rest.toLowerCase()].join('+');
}

const GNOME_SHORTCUT_SCHEMAS = [
  'org.gnome.desktop.wm.keybindings',
  'org.gnome.shell.keybindings',
  'org.gnome.mutter.keybindings',
  'org.gnome.mutter.wayland.keybindings',
  'org.gnome.settings-daemon.plugins.media-keys',
];

/** Finds the GNOME setting that already uses `accelerator`, as "Switch applications (Super+Tab)". */
export function findGnomeShortcut(accelerator, hyperIsSuper) {
  const wanted = normalizeAccelerator(accelerator, {hyperIsSuper});
  if (!wanted) return null;
  const source = Gio.SettingsSchemaSource.get_default();
  for (const id of GNOME_SHORTCUT_SCHEMAS) {
    const schema = source?.lookup(id, true);
    if (!schema) continue;
    const settings = new Gio.Settings({settings_schema: schema});
    for (const key of schema.list_keys()) {
      const type = schema.get_key(key).get_value_type().dup_string();
      let values = [];
      if (type === 'as') values = settings.get_strv(key);
      else if (type === 's') values = [settings.get_string(key)];
      else continue;
      if (values.some((value) => normalizeAccelerator(value, {hyperIsSuper}) === wanted)) {
        const summary = schema.get_key(key).get_summary() || key;
        return `${summary} (${id.split('.').slice(-1)[0]}: ${key})`;
      }
    }
  }
  return null;
}

function conflictReason(accelerator, hyperIsSuper) {
  let owner = null;
  try {
    owner = findGnomeShortcut(accelerator, hyperIsSuper);
  } catch {
    owner = null;
  }
  if (owner) return `GNOME already uses this shortcut for “${owner}”`;
  return `GNOME refused ${accelerator}: another app or extension may already use it`;
}
