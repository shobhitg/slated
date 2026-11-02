// Caps Lock stuck on under the Hyper key. Once Caps Lock is the Hyper key (keyd, or GNOME's caps:hyper
// option), no key can turn the lock off any more, so a lock that was on when Hyper was turned on
// stays on. Slated clears it:
//
// - when Hyper is about to become active (the extension starts with it on, or it's turned on), before
//   the caps:hyper option is added: after that, the keymap may have no Caps_Lock key left to tap;
// - whenever the lock turns on while Hyper is active (Clutter's keymap reports 'state-changed'):
//   nothing physical can do that then, so it's stuck;
// - a moment after the Hyper key's mode changes (keyd set up while GNOME's option was in use, say):
//   once the option is gone and Mutter has reloaded the keymap, Caps_Lock can be tapped again.
//
// It taps Caps_Lock on the virtual keyboard Slated's automation uses (synth.js). That device lives
// inside Mutter, below keyd (which remaps the real keyboards at the evdev level), so keyd doesn't turn
// the tap into Hyper. With caps:hyper already set there may be no Caps_Lock in the keymap: Mutter then
// drops the tap, and the lock stays on; that's logged (hyper.caps_lock_clear_failed) with advice.
// Only the fact is logged, never a keystroke.

/** X11's Caps_Lock keysym. */
export const CAPS_LOCK_KEYSYM = 0xffe5;

/** How long to wait for the lock to go off after a tap before calling it a failure. */
export const VERIFY_MS = 300;

/** How long `clearSoon` waits: Mutter reloads the keymap a moment after the keyboard options change. */
export const CLEAR_SOON_MS = 500;

export class CapsLockGuard {
  /**
   * @param {object} options
   * @param {object} options.keymap  Clutter's keymap (seat.get_keymap()): get_caps_lock_state(), 'state-changed'.
   * @param {() => {ok: boolean, error?: string}} options.tap  Presses and releases Caps_Lock once.
   * @param {object} options.timers
   * @param {object} [options.log]
   * @param {() => boolean} options.hyperActive  Whether Caps Lock is the Hyper key right now.
   */
  constructor({keymap, tap, timers, log = null, hyperActive}) {
    this._keymap = keymap;
    this._tap = tap;
    this._timers = timers;
    this._log = log;
    this._hyperActive = hyperActive;
    this._signal = 0;
    /** Why a tap was sent, until the lock is seen off (or the check gives up). */
    this._pending = null;
    this._verify = 0;
    this._soon = 0;
    /** A failure was logged; not again until the lock has been off. */
    this._failed = false;
  }

  start() {
    if (!this._signal && this._keymap) this._signal = this._keymap.connect('state-changed', () => this._stateChanged());
    return this;
  }

  /** The Caps Lock lock is on. */
  get isOn() {
    try {
      return !!this._keymap?.get_caps_lock_state();
    } catch {
      return false;
    }
  }

  /** Turns the lock off if it's on; `reason` goes in the log. Returns whether it tapped Caps_Lock. */
  clear(reason) {
    if (this._pending || !this.isOn) return false;
    // Set first: the keymap may report the change while the tap is still being sent.
    this._pending = reason;
    let result;
    try {
      result = this._tap();
    } catch (e) {
      result = {ok: false, error: e?.message ?? String(e)};
    }
    if (!result?.ok) {
      this._pending = null;
      this._fail(reason, result?.error ?? "couldn't tap Caps Lock");
      return false;
    }
    if (this._pending) {
      this._verify = this._timers.timeout(VERIFY_MS, () => {
        this._verify = 0;
        this._settle(true);
      });
    }
    return true;
  }

  /** `clear(reason)` after the keymap has had time to change (CLEAR_SOON_MS). */
  clearSoon(reason) {
    if (this._soon) this._timers.clear(this._soon);
    this._soon = this._timers.timeout(CLEAR_SOON_MS, () => {
      this._soon = 0;
      if (this._hyperActive()) this.clear(reason);
    });
  }

  _stateChanged() {
    if (this._pending) {
      this._settle();
      return;
    }
    if (!this.isOn) {
      this._failed = false;
      return;
    }
    if (this._hyperActive()) this.clear('caps lock turned on');
  }

  /** After a tap: the lock went off (cleared) or it didn't (the keymap had no Caps_Lock to tap). */
  _settle(checked = false) {
    const reason = this._pending;
    if (!reason) return;
    if (this.isOn) {
      // A 'state-changed' can come for something else (Num Lock); keep waiting for the check.
      if (!checked) return;
      this._pending = null;
      this._fail(reason, 'the lock stayed on: the keyboard layout has no Caps Lock key while Caps Lock is the Hyper key');
      return;
    }
    this._pending = null;
    if (this._verify) this._timers.clear(this._verify);
    this._verify = 0;
    this._failed = false;
    this._log?.record('hyper.caps_lock_cleared', {reason}, 'notice');
  }

  _fail(reason, error) {
    if (this._failed) return;
    this._failed = true;
    this._log?.record(
      'hyper.caps_lock_clear_failed',
      {reason, error, advice: 'Turn the Hyper key off, press Caps Lock to turn the lock off, then turn Hyper back on'},
      'error',
    );
  }

  destroy() {
    if (this._signal) this._keymap?.disconnect(this._signal);
    if (this._verify) this._timers?.clear(this._verify);
    if (this._soon) this._timers?.clear(this._soon);
    this._signal = this._verify = this._soon = 0;
    this._pending = null;
  }
}
