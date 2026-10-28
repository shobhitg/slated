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
//
// Knowing when a key is let go (while-held auto-repeats): Mutter reports only presses. A held key
// keeps re-sending its shortcut at the keyboard's repeat rate, so for `holdable` entries the repeats
// are heartbeats, and none arriving for about twice the repeat interval (after the first, the
// repeat delay plus that) means the key was let go. GNOME's key repeat also stops when any other key
// is pressed or released, so the release is then reported early. With key repeat off, nothing
// arrives: holdable entries aren't made then, and while-held repeats work like toggles.
//
// App-specific bindings (`apps`, a binding's onlyInApps) are grabbed only while one of their apps
// has focus (`setFocusedApp`), so a plain key like F can drive a game without taking F anywhere else.

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import * as Core from '../core/index.js';

import {appMatchesAny} from './util.js';

export const ACTIVE = 'active';
export const DISABLED = 'disabled';
export const DUPLICATE = 'duplicate';

export function failed(reason) {
  return `failed: ${reason}`;
}

/** Why mouse3–mouse5 can't be shortcuts on GNOME, and what to do instead. */
export const MOUSE_BUTTON_REASON =
  "GNOME can't use mouse buttons as shortcuts. Map the button to a key with keyd (for example mouse1 = f13), then bind that key (F13–F20)";
export const MODIFIER_KEY_REASON = "A modifier key can't be a shortcut on its own";

/** No repeat for at least this long counts as a release, however fast the keyboard repeats. */
export const MIN_RELEASE_MS = 100;

/**
 * Release timing from GNOME's keyboard repeat settings (org.gnome.desktop.peripherals.keyboard):
 * `firstMs` after the press (the repeat delay plus a margin), then `nextMs` after each repeat.
 */
export function releaseTiming({delayMs = 500, intervalMs = 30} = {}) {
  const nextMs = Math.max(2 * intervalMs, MIN_RELEASE_MS);
  return {firstMs: delayMs + nextMs, nextMs};
}

/**
 * Registers hotkey entries:
 *   {id, keys: KeyCombo, modal: {keys, toggle} | null, repeats, source, run(), apps?, holdable?}
 * `id` is the status key ("hyper+a", or "ctrl+alt+f4 1" for modal bindings). `apps` limits an entry
 * to some apps (onlyInApps); `holdable` asks for `onRelease(entry)` when its key is let go.
 */
export class KeybindingManager {
  constructor({grabber, log = null, onModalChange = null, onRelease = null, onFire = null}) {
    this._grabber = grabber;
    this._log = log;
    /** A modal key was pressed (`(id, keys)`, keys its KeyCombo) or modal mode ended (`(null)`). */
    this.onModalChange = onModalChange;
    /** A binding fired (not a held key's repeats): the island lights it up in the cheat sheet. */
    this.onFire = onFire;
    /** A holdable entry's key was let go (while-held auto-repeats stop then). */
    this.onRelease = onRelease;
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
    this._lastEntries = [];
    this._lastOptions = {};
    /** The focused app (util.appIdentity), for app-specific entries. */
    this._focusedApp = null;
    /** Release detection from key repeat ({firstMs, nextMs}), or null when keyboard repeat is off. */
    this._holdTiming = null;
    /** Holdable entries whose key is down: id → {entry, timer}. */
    this._held = new Map();
    this._liveSignature = '';
    this._grabber.connect((action) => this._activated(action));
  }

  /**
   * Replaces every registration.
   * @param {object[]} entries  In priority order: the first binding for a key wins.
   * @param {object} options
   * @param {string[]} [options.disabled]  Keys of disabled bindings (status "disabled").
   * @param {(combo: object) => string|null} options.acceleratorFor  KeyCombo → GNOME accelerator.
   * @param {object|null} [options.escapeKeys]  KeyCombo that leaves modal mode (Slate's modalEscapeKey).
   * @param {object|null} [options.holdTiming]  `releaseTiming(…)` from GNOME's keyboard repeat
   *   settings, or null when keyboard repeat is off (then nothing is holdable).
   */
  apply(entries, {disabled = [], acceleratorFor, escapeKeys = null, holdTiming = null} = {}) {
    this.unregisterAll();
    this._lastEntries = entries;
    this._lastOptions = {disabled, acceleratorFor, escapeKeys, holdTiming};
    this._acceleratorFor = acceleratorFor ?? (() => null);
    this._escapeKeys = escapeKeys;
    this._holdTiming = holdTiming;
    this.statuses = {};
    for (const id of disabled) this.statuses[id] = DISABLED;
    this.duplicates = [];

    // App-specific entries are live only while one of their apps has focus. The others count as
    // ready, unless GNOME can't take their keys at all.
    const live = entries.filter((entry) => this._isLive(entry));
    this._liveSignature = this._signature(live);
    for (const entry of entries) {
      if (live.includes(entry) || this.statuses[entry.id] !== undefined) continue;
      const unusable = this._unusableReason(entry.keys) ?? (entry.modal ? this._unusableReason(entry.modal.keys) : null);
      this.statuses[entry.id] = unusable ? failed(unusable) : ACTIVE;
    }

    const seen = new Set();
    const direct = [];
    for (const entry of live) {
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
      const holdable = this._isHoldable(entry);
      const result = this._grab(entry.keys, {repeats: !!entry.repeats || holdable}, () => this._activate(entry));
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

  /** Holdable entries whose key is down right now (ids). */
  get heldKeys() {
    return [...this._held.keys()];
  }

  /**
   * The focused app changed (an `appIdentity`, or null): grabs the app-specific bindings for the new
   * app and lets go of the previous app's. Returns true when the registrations change.
   */
  setFocusedApp(app) {
    this._focusedApp = app;
    if (!this._lastEntries.some((entry) => entry.apps?.length)) return false;
    const signature = this._signature(this._lastEntries.filter((entry) => this._isLive(entry)));
    if (signature === this._liveSignature) return false;
    this._liveSignature = signature;
    // Grabbing from inside Mutter's key handling (an Alt+Tab ends in one) is avoided.
    this._grabber.defer(() => {
      this.apply(this._lastEntries, this._lastOptions);
      this._log?.record('hotkeys.app_bindings', {app: app?.id ?? null, live: this._lastEntries.filter((e) => e.apps?.length && this._isLive(e)).length}, 'debug');
    });
    return true;
  }

  unregisterAll() {
    this._exitModal({log: false});
    // Whatever was held is let go as far as Slated knows, so while-held repeats don't run on.
    for (const id of [...this._held.keys()]) this._released(id);
    for (const action of this._grabs) this._grabber.ungrab(action);
    this._grabs = [];
    this._handlers.clear();
    this._direct.clear();
    this._modalGroups.clear();
  }

  destroy() {
    this.unregisterAll();
    this._grabber.destroy();
    this.onModalChange = this.onRelease = this.onFire = null;
  }

  // --- Internals ---------------------------------------------------------------------------------

  _comboKey(combo) {
    return `${[...(combo.modifiers ?? [])].sort().join('+')}+${combo.key}`;
  }

  _isLive(entry) {
    return !entry.apps?.length || appMatchesAny(this._focusedApp, entry.apps);
  }

  _signature(entries) {
    return entries
      .filter((entry) => entry.apps?.length)
      .map((entry) => entry.id)
      .join('\n');
  }

  _isHoldable(entry) {
    return !!entry.holdable && this._holdTiming !== null;
  }

  /** Why GNOME can't take a key at all (mouse buttons, modifiers alone), or null. */
  _unusableReason(combo) {
    if (!combo) return null;
    if (Core.isMouseButton(combo.key)) return MOUSE_BUTTON_REASON;
    if (Core.isModifierKey(combo.key)) return MODIFIER_KEY_REASON;
    return null;
  }

  /** A press (or, for holdable entries, maybe a key-repeat heartbeat while the key is held). */
  _activate(entry) {
    if (this._isHoldable(entry)) {
      const held = this._held.get(entry.id);
      if (held) {
        this._grabber.clearTimeout(held.timer);
        held.timer = this._grabber.timeout(this._holdTiming.nextMs, () => this._released(entry.id));
        return;
      }
      this._held.set(entry.id, {entry, timer: this._grabber.timeout(this._holdTiming.firstMs, () => this._released(entry.id))});
    }
    this._run(entry);
  }

  _released(id) {
    const held = this._held.get(id);
    if (!held) return;
    this._held.delete(id);
    this._grabber.clearTimeout(held.timer);
    try {
      this.onRelease?.(held.entry);
    } catch (e) {
      this._log?.error('hotkeys.release_failed', e?.message ?? String(e), {keys: id});
    }
  }

  /** Grabs `combo`; on success the grab is added to `list` (released by `unregisterAll`/`_exitModal`). */
  _grab(combo, {repeats}, handler, list = this._grabs) {
    const unusable = this._unusableReason(combo);
    if (unusable) return {ok: false, reason: unusable};
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
    try {
      this.onFire?.(entry);
    } catch (e) {
      this._log?.error('hotkeys.fire_failed', e?.message ?? String(e), {keys: entry.id});
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
      this.onModalChange?.(group.id, group.keys);
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

/** GNOME's keyboard repeat settings (Settings → Keyboard → Repeat Keys): {enabled, delayMs, intervalMs}. */
export function readKeyboardRepeat() {
  try {
    const settings = new Gio.Settings({schema_id: 'org.gnome.desktop.peripherals.keyboard'});
    return {enabled: settings.get_boolean('repeat'), delayMs: settings.get_uint('delay'), intervalMs: settings.get_uint('repeat-interval')};
  } catch {
    return {enabled: true, delayMs: 500, intervalMs: 30};
  }
}

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

  timeout(ms, callback) {
    return this._timers.timeout(ms, callback);
  }

  clearTimeout(id) {
    this._timers.clear(id);
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
