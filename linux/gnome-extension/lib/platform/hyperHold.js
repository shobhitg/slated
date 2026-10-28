// Whether the Hyper key is held, for the island's cheat sheet.
//
// GNOME tells an extension about keys only through its own shortcuts: there is no signal for a modifier
// going down or up. So this reads the keyboard's modifier state (the mask `global.get_pointer()`
// returns, which the compositor keeps anyway) on a light timer, faster while one of the Hyper
// modifiers is down, and reports when all of them are held and when they're let go. It runs only
// while the island wants a cheat sheet and the Hyper key is set up.
//
// With keyd, Caps Lock holds Ctrl+Alt+Shift+Super (or the `keyboard.hyperModifiers` set), so all of
// them must be down. With GNOME's `caps:hyper` option the Hyper modifier usually shares Super's (Mod4),
// so holding Super alone counts too: the same reason Hyper shortcuts are Super shortcuts then.

import Clutter from 'gi://Clutter';

/** How often the modifiers are read while none of the Hyper modifiers is down. */
export const IDLE_POLL_MS = 150;
/** How often while one is (20 Hz): the sheet appears on time and goes as soon as you let go. */
export const ACTIVE_POLL_MS = 50;

/**
 * The modifier masks that make up Hyper for `mode` ("keyd" or "xkb"): `required` lists one mask per
 * modifier (any of its bits counts), `any` is every bit that matters (to poll faster).
 * @returns {{required: number[], any: number} | null} null when there's no Hyper key to watch.
 */
export function hyperMasks(mode, hyperModifiers = ['ctrl', 'alt', 'shift', 'cmd'], M = Clutter.ModifierType) {
  const bit = (name) => M[name] ?? 0;
  let required;
  if (mode === 'xkb') {
    // caps:hyper sends Hyper_L, which the stock keymap puts on Mod4 with Super (Mod3 in some layouts).
    required = [bit('MOD3_MASK') | bit('MOD4_MASK') | bit('SUPER_MASK') | bit('HYPER_MASK')];
  } else if (mode === 'keyd') {
    const masks = {
      ctrl: bit('CONTROL_MASK'),
      alt: bit('MOD1_MASK'),
      shift: bit('SHIFT_MASK'),
      cmd: bit('MOD4_MASK') | bit('SUPER_MASK'),
    };
    required = (hyperModifiers ?? []).map((m) => masks[m]).filter(Boolean);
  } else {
    return null;
  }
  if (required.length === 0 || required.some((m) => !m)) return null;
  return {required, any: required.reduce((all, m) => all | m, 0)};
}

export class HyperHoldWatcher {
  /**
   * @param {object} options
   * @param {object} options.timers  timers.js `Timers`.
   * @param {(held: boolean) => void} options.onChange  All of Hyper went down (true) or was let go (false).
   * @param {() => number} [options.readModifiers]  The keyboard's Clutter.ModifierType mask.
   */
  constructor({timers, onChange, readModifiers = () => global.get_pointer()[2]}) {
    this._timers = timers;
    this._onChange = onChange;
    this._read = readModifiers;
    this._masks = null;
    this._timer = 0;
    this._held = false;
  }

  /** Whether all of Hyper is held right now (as of the last reading). */
  get held() {
    return this._held;
  }

  /** Whether the modifiers are being read. */
  get watching() {
    return this._masks !== null;
  }

  /** Starts (or keeps) watching for `masks` (`hyperMasks`), or stops with null. */
  watch(masks) {
    const same = JSON.stringify(masks) === JSON.stringify(this._masks);
    if (same) return;
    this.stop();
    if (!masks) return;
    this._masks = masks;
    this._schedule(IDLE_POLL_MS);
  }

  stop() {
    this._timer = this._timers?.clear(this._timer) ?? 0;
    this._masks = null;
    if (this._held) {
      this._held = false;
      this._notify(false);
    }
  }

  destroy() {
    this.stop();
    this._onChange = null;
  }

  _schedule(ms) {
    this._timer = this._timers.timeout(ms, () => {
      this._timer = 0;
      this._poll();
    });
  }

  _poll() {
    if (!this._masks) return;
    let mods = 0;
    try {
      mods = this._read() ?? 0;
    } catch {
      mods = 0;
    }
    const held = this._masks.required.every((mask) => (mods & mask) !== 0);
    if (held !== this._held) {
      this._held = held;
      this._notify(held);
    }
    // The callback may have stopped the watcher.
    if (this._masks) this._schedule(mods & this._masks.any ? ACTIVE_POLL_MS : IDLE_POLL_MS);
  }

  _notify(held) {
    try {
      this._onChange?.(held);
    } catch (e) {
      console.error(`Slated: Hyper key watcher: ${e}\n${e?.stack ?? ''}`);
    }
  }
}
