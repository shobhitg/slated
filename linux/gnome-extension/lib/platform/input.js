// Typing text and pressing key combos (`insert-text`, `keystroke`) through a Clutter virtual keyboard,
// the device GNOME's on-screen keyboard uses. Events go through Mutter like real key presses.
//
// - Slated waits until you let go of the shortcut's modifiers first, so typed letters don't combine
//   with a still-held Hyper or Ctrl.
// - Only plain ASCII can be typed reliably on Wayland (a virtual keyboard can only press keys the
//   current layout has). Other text is pasted: Slated puts it on the clipboard, presses Ctrl+V (or
//   Ctrl+Shift+V in terminals), and puts the previous clipboard text back. Non-text clipboard content
//   can't be restored.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

// X keysyms (Clutter.KEY_*), so this table needs no GNOME imports and can be tested in Node.
const NAMED_KEYSYMS = {
  left: 0xff51,
  up: 0xff52,
  right: 0xff53,
  down: 0xff54,
  return: 0xff0d,
  tab: 0xff09,
  space: 0x0020,
  delete: 0xff08, // Slate's "delete" is the backspace key
  forwardDelete: 0xffff,
  esc: 0xff1b,
  home: 0xff50,
  end: 0xff57,
  pageUp: 0xff55,
  pageDown: 0xff56,
  help: 0xff6a,
  caps: 0xffe5,
  mute: 0x1008ff12,
  volumeUp: 0x1008ff13,
  volumeDown: 0x1008ff11,
  backslash: 0x005c,
  padClear: 0xff0b,
  padEnter: 0xff8d,
  'pad=': 0xffbd,
  'pad*': 0xffaa,
  'pad+': 0xffab,
  'pad-': 0xffad,
  'pad.': 0xffae,
  'pad/': 0xffaf,
};

export const MODIFIER_KEYSYMS = Object.freeze({ctrl: 0xffe3, alt: 0xffe9, shift: 0xffe1, cmd: 0xffeb});
const KEY_V = 0x0076;

/** The keysym for a Slate key name ("a", "left", "f13", "pad5", "'"), or null. */
export function keysymForKey(key) {
  if (typeof key !== 'string' || key.length === 0) return null;
  if (key in NAMED_KEYSYMS) return NAMED_KEYSYMS[key];
  const lower = key.toLowerCase();
  for (const name of Object.keys(NAMED_KEYSYMS)) if (name.toLowerCase() === lower) return NAMED_KEYSYMS[name];
  let match = /^f(\d{1,2})$/.exec(lower);
  if (match && Number(match[1]) >= 1 && Number(match[1]) <= 35) return 0xffbe + Number(match[1]) - 1;
  match = /^pad(\d)$/.exec(lower);
  if (match) return 0xffb0 + Number(match[1]);
  if ([...key].length === 1) {
    const code = lower.codePointAt(0);
    // Latin-1 keysyms equal their code points.
    if ((code >= 0x20 && code <= 0x7e) || (code >= 0xa0 && code <= 0xff)) return code;
  }
  return null;
}

/** Keysyms that type `text`, or null when it has characters that can't be typed reliably. */
export function keysymsForText(text) {
  const keysyms = [];
  const chars = [...String(text)];
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    if (ch === '\r') {
      if (chars[i + 1] === '\n') continue;
      keysyms.push(NAMED_KEYSYMS.return);
    } else if (ch === '\n') {
      keysyms.push(NAMED_KEYSYMS.return);
    } else if (ch === '\t') {
      keysyms.push(NAMED_KEYSYMS.tab);
    } else {
      const code = ch.codePointAt(0);
      if (code < 0x20 || code > 0x7e) return null;
      keysyms.push(code);
    }
  }
  return keysyms;
}

/** Whether `method` and `text` call for pasting rather than typing. */
export function shouldPaste(text, method, threshold = 80) {
  if (method === 'paste') return true;
  if (keysymsForText(text) === null) return true;
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

function defaultSeat() {
  // GNOME 47+ reaches the backend through the stage's context; clutter_get_default_backend() is the
  // older way and is deprecated.
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
  }

  insertText(text, method = 'auto') {
    if (!text) return {ok: true};
    const paste = shouldPaste(text, method);
    if (paste && method === 'type') {
      this._log?.record('text.paste_fallback', {reason: "text outside ASCII can't be typed on Wayland", chars: [...text].length}, 'notice');
    }
    const keysyms = paste ? null : keysymsForText(text);
    this._whenModifiersReleased(() => (paste ? this._paste(text) : this._type(keysyms)));
    return {ok: true};
  }

  pressKeys(combo) {
    const keysym = keysymForKey(combo.key);
    if (keysym === null) return {ok: false, error: `Unknown key ${combo.key}`};
    const modifiers = (combo.modifiers ?? []).map((m) => MODIFIER_KEYSYMS[m]).filter(Boolean);
    this._whenModifiersReleased(() => this._chord(modifiers, keysym));
    return {ok: true};
  }

  destroy() {
    this._destroyed = true;
    // Releases anything the virtual device still holds right away (as GNOME's keyboard does).
    this._device?.run_dispose();
    this._device = null;
  }

  // --- Internals ---------------------------------------------------------------------------------

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

  _key(keysym, pressed) {
    this._virtualKeyboard().notify_keyval(this._time(), keysym, pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
  }

  _chord(modifiers, keysym) {
    try {
      for (const m of modifiers) this._key(m, true);
      this._key(keysym, true);
      this._key(keysym, false);
      for (const m of [...modifiers].reverse()) this._key(m, false);
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
          this._key(keysyms[i], true);
          this._key(keysyms[i], false);
        }
      } catch (e) {
        this._log?.error('text.type_failed', e.message ?? String(e));
        return false;
      }
      return i < keysyms.length;
    };
    if (step()) this._timers.interval(10, step);
  }

  _paste(text) {
    const clipboard = St.Clipboard.get_default();
    clipboard.get_text(St.ClipboardType.CLIPBOARD, (_clipboard, previous) => {
      if (this._destroyed) return;
      clipboard.set_text(St.ClipboardType.CLIPBOARD, text);
      const modifiers = isTerminal(this._focusedAppId())
        ? [MODIFIER_KEYSYMS.ctrl, MODIFIER_KEYSYMS.shift]
        : [MODIFIER_KEYSYMS.ctrl];
      this._chord(modifiers, KEY_V);
      // Give the app time to read the clipboard before restoring it.
      this._timers.timeout(400, () => {
        if (previous !== null && previous !== undefined) clipboard.set_text(St.ClipboardType.CLIPBOARD, previous);
      });
    });
  }

  /** Runs `callback` once no modifier is held (at most 1.5 s later). */
  _whenModifiersReleased(callback) {
    const mask =
      Clutter.ModifierType.SHIFT_MASK |
      Clutter.ModifierType.CONTROL_MASK |
      Clutter.ModifierType.MOD1_MASK |
      Clutter.ModifierType.MOD4_MASK |
      Clutter.ModifierType.SUPER_MASK |
      Clutter.ModifierType.HYPER_MASK |
      Clutter.ModifierType.META_MASK;
    const deadline = GLib.get_monotonic_time() + 1_500_000;
    const ready = () => {
      const [, , mods] = global.get_pointer();
      return (mods & mask) === 0 || GLib.get_monotonic_time() > deadline;
    };
    if (ready()) {
      callback();
      return;
    }
    this._timers.interval(25, () => {
      if (!ready()) return true;
      callback();
      return false;
    });
  }
}
