// Typing text and pressing key combos (`insert-text`, `keystroke`) through a Clutter virtual keyboard,
// the device GNOME's on-screen keyboard uses. Events go through Mutter like real key presses.
//
// - Slated waits until you let go of the shortcut's modifiers first, so typed keys don't combine with
//   a still-held Hyper or Ctrl.
// - A virtual keyboard can only produce characters the active layout has (Mutter looks keysyms up in
//   the current layout group and silently drops the rest). So modifiers and named keys (arrows, F-keys,
//   Return…) are sent as Linux evdev key codes, which don't depend on the layout; character keys are
//   sent by keysym on Latin layouts, so `cmd+z` means the key labeled Z on QWERTZ too, and by their US
//   position on other layouts (apps match Ctrl+V and friends by key position there).
// - Text is typed only when the current input source is a Latin layout without an input method, and
//   only plain ASCII. Anything else is pasted: Slated puts it on the clipboard, presses Ctrl+V
//   (Ctrl+Shift+V in terminals), and puts the previous clipboard text back. Non-text clipboard content
//   can't be restored.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {getInputSourceManager} from 'resource:///org/gnome/shell/ui/status/keyboard.js';

// --- Key tables (pure, tested in Node) ---------------------------------------------------------------

/** Linux evdev codes (linux/input-event-codes.h) for the modifiers Slated presses. */
export const EVDEV_MODIFIERS = Object.freeze({ctrl: 29, shift: 42, alt: 56, cmd: 125});

/** Layout-independent keys, by Slate key name. */
const EVDEV_NAMED = {
  esc: 1,
  delete: 14, // Slate's "delete" is the backspace key
  tab: 15,
  return: 28,
  space: 57,
  caps: 58,
  padClear: 69,
  pad7: 71,
  pad8: 72,
  pad9: 73,
  'pad-': 74,
  pad4: 75,
  pad5: 76,
  pad6: 77,
  'pad+': 78,
  pad1: 79,
  pad2: 80,
  pad3: 81,
  pad0: 82,
  'pad.': 83,
  'pad*': 55,
  padEnter: 96,
  'pad/': 98,
  home: 102,
  up: 103,
  pageUp: 104,
  left: 105,
  right: 106,
  end: 107,
  down: 108,
  pageDown: 109,
  forwardDelete: 111,
  mute: 113,
  volumeDown: 114,
  volumeUp: 115,
  'pad=': 117,
  help: 138,
  backslash: 43,
};

/** Character keys at their US positions, for layouts that don't have Latin characters. */
const EVDEV_US = {
  1: 2,
  2: 3,
  3: 4,
  4: 5,
  5: 6,
  6: 7,
  7: 8,
  8: 9,
  9: 10,
  0: 11,
  '-': 12,
  '=': 13,
  q: 16,
  w: 17,
  e: 18,
  r: 19,
  t: 20,
  y: 21,
  u: 22,
  i: 23,
  o: 24,
  p: 25,
  '[': 26,
  ']': 27,
  a: 30,
  s: 31,
  d: 32,
  f: 33,
  g: 34,
  h: 35,
  j: 36,
  k: 37,
  l: 38,
  ';': 39,
  "'": 40,
  '`': 41,
  '\\': 43,
  z: 44,
  x: 45,
  c: 46,
  v: 47,
  b: 48,
  n: 49,
  m: 50,
  ',': 51,
  '.': 52,
  '/': 53,
  ' ': 57,
};

const RETURN_KEYSYM = 0xff0d;
const TAB_KEYSYM = 0xff09;

function evdevFunctionKey(n) {
  if (n >= 1 && n <= 10) return 58 + n; // F1 = 59
  if (n === 11) return 87;
  if (n === 12) return 88;
  if (n >= 13 && n <= 24) return 170 + n; // F13 = 183
  return null;
}

/** The keysym (Latin-1 = code point) for a single character key, or null. */
export function keysymForCharacter(key) {
  if (typeof key !== 'string' || [...key].length !== 1) return null;
  const code = key.toLowerCase().codePointAt(0);
  if ((code >= 0x20 && code <= 0x7e) || (code >= 0xa0 && code <= 0xff)) return code;
  return null;
}

/**
 * How to press one Slate key: `{code}` (evdev, layout-independent) or `{keysym}` (looked up in the
 * current layout). Character keys use their keysym on Latin layouts and their US position otherwise.
 */
export function keyFor(key, {latin = true} = {}) {
  if (typeof key !== 'string' || key.length === 0) return null;
  const lower = key.toLowerCase();
  for (const [name, code] of Object.entries(EVDEV_NAMED)) if (name.toLowerCase() === lower) return {code};
  const fn = /^f(\d{1,2})$/.exec(lower);
  if (fn) {
    const code = evdevFunctionKey(Number(fn[1]));
    return code ? {code} : null;
  }
  if ([...key].length !== 1) return null;
  if (latin) {
    const keysym = keysymForCharacter(key);
    if (keysym !== null) return {keysym};
  }
  const code = EVDEV_US[lower];
  return code ? {code} : null;
}

/** The presses for a combo: modifier codes, then the key. Null when the key can't be pressed. */
export function keyPlan(combo, {latin = true} = {}) {
  const key = keyFor(combo.key, {latin});
  if (!key) return null;
  const modifiers = ['ctrl', 'alt', 'shift', 'cmd']
    .filter((m) => (combo.modifiers ?? []).includes(m))
    .map((m) => EVDEV_MODIFIERS[m]);
  return {modifiers, key};
}

/** Keysyms that type `text`, or null when it has characters that can't be typed reliably. */
export function keysymsForText(text) {
  const keysyms = [];
  const chars = [...String(text)];
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    if (ch === '\r') {
      if (chars[i + 1] === '\n') continue;
      keysyms.push(RETURN_KEYSYM);
    } else if (ch === '\n') {
      keysyms.push(RETURN_KEYSYM);
    } else if (ch === '\t') {
      keysyms.push(TAB_KEYSYM);
    } else {
      const code = ch.codePointAt(0);
      if (code < 0x20 || code > 0x7e) return null;
      keysyms.push(code);
    }
  }
  return keysyms;
}

// xkb layouts whose letters aren't Latin (a `latin` variant, like rs+latin, is).
const NON_LATIN_LAYOUTS = new Set([
  'af',
  'am',
  'ara',
  'bd',
  'bg',
  'bt',
  'by',
  'et',
  'ge',
  'gr',
  'il',
  'in',
  'iq',
  'ir',
  'kg',
  'kh',
  'kz',
  'la',
  'lk',
  'ma',
  'mk',
  'mm',
  'mn',
  'mv',
  'np',
  'pk',
  'rs',
  'ru',
  'sy',
  'th',
  'tj',
  'ua',
  'uz',
]);

/**
 * The keyboard layout behind a GNOME input source (`getInputSourceManager().currentSource`): its xkb
 * layout and variant, and whether an input method (IBus engine other than a plain layout) is active.
 */
export function sourceLayout(source) {
  if (!source) return null;
  const id = String(source.id ?? '');
  let xkb = typeof source.xkbId === 'string' && source.xkbId ? source.xkbId : source.type === 'xkb' ? id : '';
  if (!xkb && id.startsWith('xkb:')) xkb = id.split(':').slice(1, 3).filter(Boolean).join('+');
  const [layout, variant = ''] = xkb.split('+');
  return {layout: layout || 'us', variant, ime: source.type === 'ibus' && !id.startsWith('xkb:')};
}

/** Whether the active keymap has Latin letters (unknown sources count as Latin). */
export function keymapIsLatin(source) {
  const layout = sourceLayout(source);
  if (!layout) return true;
  return layout.variant.includes('latin') || !NON_LATIN_LAYOUTS.has(layout.layout);
}

/** Whether ASCII can be typed key by key: a Latin keymap and no input method to intercept it. */
export function canTypeText(source) {
  return keymapIsLatin(source) && !sourceLayout(source)?.ime;
}

/** Whether `method` and `text` call for pasting rather than typing. */
export function shouldPaste(text, method, {typeable = true, threshold = 80} = {}) {
  if (method === 'paste') return true;
  if (!typeable || keysymsForText(text) === null) return true;
  return method === 'auto' && [...text].length > threshold;
}

const TERMINALS = new Set(
  [
    'org.gnome.Terminal',
    'org.gnome.Console',
    'kgx',
    'org.gnome.Ptyxis',
    'org.gnome.Ptyxis.Devel',
    'com.mitchellh.ghostty',
    'kitty',
    'Alacritty',
    'org.wezfurlong.wezterm',
    'foot',
    'org.codeberg.dnkl.foot',
    'org.kde.konsole',
    'xterm',
    'com.gexperts.Tilix',
    'io.elementary.terminal',
    'terminator',
    'dev.warp.Warp',
  ].map((id) => id.toLowerCase()),
);

export function isTerminal(appId) {
  return TERMINALS.has(String(appId ?? '').toLowerCase());
}

// --- The virtual keyboard ----------------------------------------------------------------------------

function defaultSeat() {
  // GNOME 47+ also reaches the backend through the stage's context; both ways work in 46–49.
  const stage = global.stage;
  const context = typeof stage.get_context === 'function' ? stage.get_context() : stage.context;
  const backend = context?.get_backend?.() ?? Clutter.get_default_backend();
  return backend.get_default_seat();
}

export class InputInjector {
  /**
   * @param {object} options
   * @param {object} options.timers  A Timers instance (cleared by the runtime on disable).
   * @param {object} [options.log]
   * @param {() => string|null} [options.focusedAppId]  For choosing the terminal paste shortcut.
   */
  constructor({timers, log = null, focusedAppId = () => null}) {
    this._timers = timers;
    this._log = log;
    this._focusedAppId = focusedAppId;
    this._device = null;
    this._clock = 0;
    this._destroyed = false;
    /** Called with text Slated puts on the clipboard for a moment, so clipboard history skips it. */
    this.onClipboardWrite = null;
    this._waiting = [];
    this._poller = 0;
  }

  insertText(text, method = 'auto') {
    if (!text) return {ok: true};
    const typeable = canTypeText(this._currentSource());
    const paste = shouldPaste(text, method, {typeable});
    if (paste && method === 'type') {
      const reason = typeable ? "text outside ASCII can't be typed on Wayland" : 'the current input source has no Latin letters or uses an input method';
      this._log?.record('text.paste_fallback', {reason, chars: [...text].length}, 'notice');
    }
    const keysyms = paste ? null : keysymsForText(text);
    this._whenModifiersReleased(() => (paste ? this._paste(text) : this._type(keysyms)));
    return {ok: true};
  }

  pressKeys(combo) {
    const plan = keyPlan(combo, {latin: keymapIsLatin(this._currentSource())});
    if (!plan) return {ok: false, error: `Unknown key ${combo.key}`};
    this._whenModifiersReleased(() => this._chord(plan));
    return {ok: true};
  }

  /** Presses the focused app's paste shortcut: Ctrl+V, or Ctrl+Shift+V in terminals. */
  pasteShortcut() {
    this._whenModifiersReleased(() => this._chord(this._pastePlan()));
    return {ok: true};
  }

  /**
   * Drops keys and text still waiting for modifiers to be let go (automations were stopped). An
   * auto-repeat keeps queueing while you hold a modifier, as for Alt+Tab, and none of that may be
   * typed into the app you switch to.
   */
  cancelPending() {
    this._waiting = [];
    this._poller = this._timers.clear(this._poller);
  }

  destroy() {
    this._destroyed = true;
    this._waiting = [];
    this._poller = this._timers.clear(this._poller);
    // Releases anything the virtual device still holds right away (as GNOME's keyboard does).
    this._device?.run_dispose();
    this._device = null;
  }

  // --- Internals ---------------------------------------------------------------------------------

  _currentSource() {
    try {
      return getInputSourceManager()?.currentSource ?? null;
    } catch {
      return null;
    }
  }

  _virtualKeyboard() {
    // A clipboard callback can arrive after disable(); never create a device then.
    if (this._destroyed) throw new Error('Slated is stopping');
    this._device ??= defaultSeat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    return this._device;
  }

  /** Microsecond timestamps that always move forward. */
  _time() {
    this._clock = Math.max(this._clock + 1000, GLib.get_monotonic_time());
    return this._clock;
  }

  _press(key, pressed) {
    const state = pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED;
    if (key.code !== undefined) this._virtualKeyboard().notify_key(this._time(), key.code, state);
    else this._virtualKeyboard().notify_keyval(this._time(), key.keysym, state);
  }

  _chord(plan) {
    try {
      for (const code of plan.modifiers) this._press({code}, true);
      this._press(plan.key, true);
      this._press(plan.key, false);
      for (const code of [...plan.modifiers].reverse()) this._press({code}, false);
    } catch (e) {
      this._log?.error('text.keys_failed', e.message ?? String(e));
    }
  }

  _type(keysyms) {
    let i = 0;
    // A few characters per main-loop turn, so apps keep up and the shell stays responsive.
    const step = () => {
      try {
        const end = Math.min(i + 8, keysyms.length);
        for (; i < end; i++) {
          this._press({keysym: keysyms[i]}, true);
          this._press({keysym: keysyms[i]}, false);
        }
      } catch (e) {
        this._log?.error('text.type_failed', e.message ?? String(e));
        return false;
      }
      return i < keysyms.length;
    };
    if (step()) this._timers.interval(10, step);
  }

  _pastePlan() {
    const modifiers = isTerminal(this._focusedAppId()) ? ['ctrl', 'shift'] : ['ctrl'];
    return keyPlan({key: 'v', modifiers}, {latin: keymapIsLatin(this._currentSource())});
  }

  _paste(text) {
    const clipboard = St.Clipboard.get_default();
    clipboard.get_text(St.ClipboardType.CLIPBOARD, (_clipboard, previous) => {
      if (this._destroyed) return;
      this.onClipboardWrite?.(text);
      clipboard.set_text(St.ClipboardType.CLIPBOARD, text);
      this._chord(this._pastePlan());
      // Give the app time to read the clipboard before restoring it.
      this._timers.timeout(400, () => {
        if (previous === null || previous === undefined || this._destroyed) return;
        this.onClipboardWrite?.(previous);
        clipboard.set_text(St.ClipboardType.CLIPBOARD, previous);
      });
    });
  }

  /**
   * Runs `callback` once no modifier is held (at most 1.5 s after it was asked for). Callbacks that
   * wait share one poller and run in order, so a fast auto-repeat can't pile up timers.
   */
  _whenModifiersReleased(callback) {
    const deadline = GLib.get_monotonic_time() + 1_500_000;
    if (this._waiting.length === 0 && this._modifiersUp()) {
      callback();
      return;
    }
    this._waiting.push({callback, deadline});
    if (this._poller) return;
    this._poller = this._timers.interval(25, () => {
      const up = this._modifiersUp();
      const now = GLib.get_monotonic_time();
      while (this._waiting.length > 0 && (up || now > this._waiting[0].deadline)) {
        const {callback: next} = this._waiting.shift();
        try {
          next();
        } catch (e) {
          this._log?.error('text.keys_failed', e?.message ?? String(e));
        }
      }
      if (this._waiting.length > 0) return true;
      this._poller = 0;
      return false;
    });
  }

  _modifiersUp() {
    const mask =
      Clutter.ModifierType.SHIFT_MASK |
      Clutter.ModifierType.CONTROL_MASK |
      Clutter.ModifierType.MOD1_MASK |
      Clutter.ModifierType.MOD4_MASK |
      Clutter.ModifierType.SUPER_MASK |
      Clutter.ModifierType.HYPER_MASK |
      Clutter.ModifierType.META_MASK;
    const [, , mods] = global.get_pointer();
    return (mods & mask) === 0;
  }
}
