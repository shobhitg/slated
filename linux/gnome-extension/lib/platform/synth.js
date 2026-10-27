// Synthesized mouse buttons and keys for game automation (`click`, `press`, `hold`, `repeat`): a
// Clutter virtual pointer and keyboard, the devices GNOME's on-screen keyboard and remote desktop
// use. Events go through Mutter like real input, at the pointer's position, to the focused window.
//
// - Mouse buttons are Clutter button numbers (left 1, middle 2, right 3).
// - Modifier keys are pressed by their keysyms: Shift_L, Control_L, Alt_L, Super_L and the
//   right-hand Shift_R, Control_R, Alt_R, Super_R. (Where the layout puts AltGr on the right Alt key,
//   it has no Alt_R and Mutter drops the press.)
// - Other keys follow `keystroke` (input.js): named keys by layout-independent evdev code, letters by
//   keysym on Latin layouts (so key:w is the key labeled W on AZERTY too) and by US position otherwise.
// - Unlike `keystroke`, nothing waits for the shortcut's modifiers to be let go: a held key is held
//   now. Everything still down is released on `releaseAll()` and `destroy()`.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import {getInputSourceManager} from 'resource:///org/gnome/shell/ui/status/keyboard.js';

import {keyFor, keymapIsLatin} from './input.js';

/** Clutter's button numbers. */
export const BUTTONS = Object.freeze({left: 1, middle: 2, right: 3});

/** Keysyms of the modifier keys Slated presses (X11 keysymdef.h). */
export const MODIFIER_KEYSYMS = Object.freeze({
  shift: 0xffe1, rightShift: 0xffe2, ctrl: 0xffe3, rightCtrl: 0xffe4, alt: 0xffe9, rightAlt: 0xffea, cmd: 0xffeb, rightCmd: 0xffec,
});

const COMBO_MODIFIERS = ['ctrl', 'alt', 'shift', 'cmd'];

/**
 * The Clutter modifier bits a held modifier keysym can set: Alt may also read as Meta, and Super as
 * Hyper (they share Mod1 and Mod4 in the stock keymaps). Right Alt sets none here: where the layout
 * puts AltGr on that key, Mutter drops Slated's Alt_R, and an Alt that's down is then yours.
 */
function modifierBits(keysym) {
  const M = Clutter.ModifierType;
  switch (keysym) {
    case MODIFIER_KEYSYMS.shift:
    case MODIFIER_KEYSYMS.rightShift:
      return M.SHIFT_MASK;
    case MODIFIER_KEYSYMS.ctrl:
    case MODIFIER_KEYSYMS.rightCtrl:
      return M.CONTROL_MASK;
    case MODIFIER_KEYSYMS.alt:
      return M.MOD1_MASK | M.META_MASK;
    case MODIFIER_KEYSYMS.cmd:
    case MODIFIER_KEYSYMS.rightCmd:
      return M.MOD4_MASK | M.SUPER_MASK | M.HYPER_MASK;
    default:
      return 0;
  }
}

/** How to press one key for automation: {keysym} for modifier keys, else what `keystroke` sends. */
export function automationKey(key, {latin = true} = {}) {
  if (Object.prototype.hasOwnProperty.call(MODIFIER_KEYSYMS, key)) return {keysym: MODIFIER_KEYSYMS[key]};
  return keyFor(key, {latin});
}

/**
 * The presses that hold a combo down, in order: its modifiers (by keysym), then the key. Releasing
 * goes in reverse. Null when the key can't be pressed.
 */
export function holdPlan(combo, {latin = true} = {}) {
  const key = automationKey(combo.key, {latin});
  if (!key) return null;
  const modifiers = COMBO_MODIFIERS.filter((m) => (combo.modifiers ?? []).includes(m) && m !== combo.key).map((m) => ({keysym: MODIFIER_KEYSYMS[m]}));
  return [...modifiers, key];
}

function defaultSeat() {
  const stage = global.stage;
  const context = typeof stage.get_context === 'function' ? stage.get_context() : stage.context;
  const backend = context?.get_backend?.() ?? Clutter.get_default_backend();
  return backend.get_default_seat();
}

export class InputSynthesizer {
  constructor({log = null} = {}) {
    this._log = log;
    this._pointer = null;
    this._keyboard = null;
    this._clock = 0;
    /** What's down, so it can always be released: "button:1", "code:17", "keysym:65505" → count. */
    this._down = new Map();
    this._destroyed = false;
  }

  /** Clicks `button` at the pointer `count` times in a row (2 is a double-click). */
  click(button, count = 1) {
    const number = BUTTONS[button];
    if (!number) return {ok: false, error: `Unknown mouse button ${button}`};
    for (let i = 0; i < Math.max(1, count); i++) {
      this._button(number, true);
      this._button(number, false);
    }
    return {ok: true};
  }

  /** Presses or releases a mouse button at the pointer. */
  mouse(button, down) {
    const number = BUTTONS[button];
    if (!number) return {ok: false, error: `Unknown mouse button ${button}`};
    this._button(number, down);
    return {ok: true};
  }

  /** Moves the pointer to a point in stage coordinates (the debug interface's MovePointer). */
  moveTo(x, y) {
    this._device('pointer').notify_absolute_motion(this._time(), x, y);
    return {ok: true};
  }

  /** Presses (modifiers first) or releases (key first) a combo. */
  key(combo, down) {
    const plan = holdPlan(combo, {latin: this._latin()});
    if (!plan) return {ok: false, error: `${combo.key} isn't a key on this keyboard layout`};
    for (const key of down ? plan : [...plan].reverse()) this._key(key, down);
    return {ok: true};
  }

  /**
   * The modifier bits of the modifier keys held down here (a held Shift for sprinting). Typing
   * (input.js) doesn't wait for these to be let go: they stay down until the automation stops.
   */
  heldModifierMask() {
    let mask = 0;
    for (const id of this._down.keys()) if (id.startsWith('keysym:')) mask |= modifierBits(Number(id.slice('keysym:'.length)));
    return mask;
  }

  /** Lets go of everything Slated still holds down. */
  releaseAll() {
    for (const [id, count] of [...this._down]) {
      const [kind, value] = id.split(':');
      for (let i = 0; i < count; i++) {
        if (kind === 'button') this._button(Number(value), false);
        else this._key(kind === 'code' ? {code: Number(value)} : {keysym: Number(value)}, false);
      }
    }
    this._down.clear();
  }

  destroy() {
    try {
      this.releaseAll();
    } catch (e) {
      this._log?.error('automation.release_failed', e?.message ?? String(e));
    }
    this._destroyed = true;
    // Disposing a virtual device also releases anything it still holds.
    this._pointer?.run_dispose();
    this._keyboard?.run_dispose();
    this._pointer = this._keyboard = null;
  }

  // --- Internals -----------------------------------------------------------------------------------

  _latin() {
    try {
      return keymapIsLatin(getInputSourceManager()?.currentSource ?? null);
    } catch {
      return true;
    }
  }

  _device(type) {
    if (this._destroyed) throw new Error('Slated is stopping');
    if (type === 'pointer') {
      this._pointer ??= defaultSeat().create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
      return this._pointer;
    }
    this._keyboard ??= defaultSeat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    return this._keyboard;
  }

  /** Microsecond timestamps that always move forward. */
  _time() {
    this._clock = Math.max(this._clock + 1000, GLib.get_monotonic_time());
    return this._clock;
  }

  _track(id, down) {
    const count = this._down.get(id) ?? 0;
    if (down) this._down.set(id, count + 1);
    else if (count <= 1) this._down.delete(id);
    else this._down.set(id, count - 1);
  }

  _button(number, down) {
    this._device('pointer').notify_button(this._time(), number, down ? Clutter.ButtonState.PRESSED : Clutter.ButtonState.RELEASED);
    this._track(`button:${number}`, down);
  }

  _key(key, down) {
    const state = down ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED;
    const keyboard = this._device('keyboard');
    if (key.code !== undefined) {
      keyboard.notify_key(this._time(), key.code, state);
      this._track(`code:${key.code}`, down);
    } else {
      keyboard.notify_keyval(this._time(), key.keysym, state);
      this._track(`keysym:${key.keysym}`, down);
    }
  }
}
