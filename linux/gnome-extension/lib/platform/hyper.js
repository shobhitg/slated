// Caps Lock → Hyper on GNOME, when `keyboard.capsLock` is "hyper".
//
// - **keyd mode**: if keyd runs (`/run/keyd.socket` exists, or `keyd` is installed and its systemd
//   service is active), Slated assumes keyd maps Caps Lock to Ctrl+Alt+Shift+Super, as the setup docs
//   say, and uses plain accelerators. keyd can also make a tap send Escape. The socket is watched, so
//   keyd started (or stopped) while Slated runs switches the mode without logging out.
// - **xkb mode** (default): Slated adds the keyboard option `caps:hyper` to
//   `org.gnome.desktop.input-sources xkb-options`, keeping the user's other options, and removes it
//   again when Hyper is turned off and on `disable()`. Other `caps:*` options would fight over the
//   key, so they are set aside while Slated owns it and put back afterwards. What Slated changed is
//   remembered in `~/.local/state/slated/hyper.json`, so it is undone even after a crash. Hyper
//   bindings then use `<Hyper>` accelerators.
//
//   Caveat: in the stock keymap Hyper shares the Mod4 modifier with Super, so for Mutter `<Hyper>a`
//   is the same shortcut as `<Super>a`; GNOME's own Super shortcuts (Super+A, Super+Tab…) win and
//   those bindings report "failed". keyd mode doesn't have this problem.

import Gio from 'gi://Gio';

import {exists, findProgram, readText, remove, watchFile, writeTextAtomic} from './files.js';

export const CAPS_HYPER = 'caps:hyper';
export const KEYD_SOCKET = '/run/keyd.socket';
const INPUT_SOURCES = 'org.gnome.desktop.input-sources';

/** The options with `caps:hyper` added and conflicting `caps:*` options set aside. */
export function withCapsHyper(options) {
  const conflicting = options.filter((o) => o.startsWith('caps:') && o !== CAPS_HYPER);
  const kept = options.filter((o) => !o.startsWith('caps:'));
  const next = [...kept, CAPS_HYPER];
  const changed = next.length !== options.length || next.some((o, i) => o !== options[i]);
  const added = !options.includes(CAPS_HYPER);
  return {options: changed ? next : options, removed: conflicting, added, changed};
}

/** The options without `caps:hyper`, with the options Slated set aside put back. */
export function withoutCapsHyper(options, restore = []) {
  const kept = options.filter((o) => o !== CAPS_HYPER);
  return [...kept, ...restore.filter((o) => !kept.includes(o))];
}

export function chooseHyperMode({wanted, keyd}) {
  if (!wanted) return 'off';
  return keyd ? 'keyd' : 'xkb';
}

/** Options for the core's `toGnomeAccelerator`. */
export function acceleratorOptions(mode) {
  return mode === 'xkb' ? {hyperMode: 'xkb'} : {};
}

export class HyperManager {
  /**
   * @param {object} options
   * @param {object} options.log
   * @param {string} options.statePath  Where to remember what Slated changed (hyper.json).
   * @param {() => void} options.onDetected  Called when the asynchronous keyd check finishes, and when
   *   keyd starts or stops later.
   * @param {string} [options.socketPath]  keyd's socket (tests point it elsewhere).
   */
  constructor({log, statePath, onDetected = null, socketPath = KEYD_SOCKET}) {
    this._log = log;
    this._statePath = statePath;
    this._onDetected = onDetected;
    this._socketPath = socketPath;
    this._socketWatch = null;
    this._settings = null;
    this._keyd = null;
    this._cancellable = new Gio.Cancellable();
    this._logged = '';
    this._warnedEscape = false;
    this._state = this._readState();
  }

  /**
   * Finds out whether keyd runs. Synchronous when its socket exists; otherwise asks systemd. Then
   * keeps watching the socket: keyd set up while Slated runs (linux/install.sh --hyper-keyd) is
   * picked up without logging out, and Slated falls back to GNOME's option if keyd goes away.
   */
  detect() {
    this._socketWatch ??= watchFile(this._socketPath, () => {
      const before = this._keyd;
      this._check();
      if (this._keyd !== null && this._keyd !== before) this._onDetected?.();
    });
    this._check();
  }

  _check() {
    if (exists(this._socketPath)) {
      this._keyd = true;
      return;
    }
    if (!findProgram('keyd', ['/usr/local/bin', '/usr/bin', '/usr/sbin'])) {
      this._keyd = false;
      return;
    }
    this._keyd = null;
    try {
      const proc = Gio.Subprocess.new(
        ['systemctl', 'is-active', '--quiet', 'keyd'],
        Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE,
      );
      proc.wait_async(this._cancellable, (p, result) => {
        let active = false;
        try {
          p.wait_finish(result);
          active = p.get_successful();
        } catch {
          return; // Cancelled by destroy().
        }
        // keyd may have started while systemd was answering: its socket says so.
        this._keyd = active || exists(this._socketPath);
        this._onDetected?.();
      });
    } catch {
      this._keyd = false;
    }
  }

  /** True once keyd is known to run; null while still checking. */
  get keyd() {
    return this._keyd;
  }

  /**
   * Makes the keyboard match the configuration. Returns `{wanted, mode, active, hyperIsSuper, pending}`,
   * where `mode` is "xkb", "keyd" or "off" (status.json's values); `pending` is true (with mode "off")
   * for the moment it takes to ask systemd whether keyd runs.
   */
  apply({wanted, capsLockAlone = 'nothing'}) {
    let mode;
    let active = false;
    let reason;
    const pending = !!wanted && this._keyd === null;
    if (pending) {
      mode = 'off';
      reason = 'checking whether keyd runs';
    } else {
      mode = chooseHyperMode({wanted, keyd: this._keyd});
    }
    if (mode === 'xkb') {
      active = this._addOption();
      reason = active ? 'caps:hyper keyboard option' : "couldn't set the caps:hyper keyboard option";
      if (capsLockAlone === 'escape' && !this._warnedEscape) {
        this._warnedEscape = true;
        this._log?.record(
          'keyboard.unsupported',
          {option: 'capsLockAlone', value: 'escape', advice: 'Tapping Caps Lock for Escape needs keyd on GNOME'},
          'notice',
        );
      }
    } else if (!pending) {
      this._removeOption();
      if (mode === 'keyd') {
        active = true;
        reason = 'keyd maps Caps Lock to Ctrl+Alt+Shift+Super';
      } else {
        reason = 'Hyper is off';
      }
    }
    const result = {wanted: !!wanted, mode, active, hyperIsSuper: mode === 'xkb', pending};
    const signature = JSON.stringify(result);
    if (signature !== this._logged) {
      this._logged = signature;
      this._log?.record('keyboard.state', {mode, wantsHyper: !!wanted, hyper: active, reason});
    }
    return result;
  }

  /**
   * Puts the keyboard options back the way they were (disable, or Hyper turned off). Returns whether
   * caps:hyper is still set afterwards, as when you had set it yourself.
   */
  restore() {
    this._removeOption();
    try {
      return this._inputSources().get_strv('xkb-options').includes(CAPS_HYPER);
    } catch {
      return false;
    }
  }

  /** Stops watching and restores the keyboard options; returns `restore()`'s answer. */
  destroy() {
    this._cancellable.cancel();
    this._socketWatch?.cancel();
    this._socketWatch = null;
    const capsHyperLeft = this.restore();
    this._settings = null;
    this._onDetected = null;
    return capsHyperLeft;
  }

  // --- xkb-options -------------------------------------------------------------------------------

  _inputSources() {
    if (!this._settings) this._settings = new Gio.Settings({schema_id: INPUT_SOURCES});
    return this._settings;
  }

  _addOption() {
    try {
      const settings = this._inputSources();
      const current = settings.get_strv('xkb-options');
      const change = withCapsHyper(current);
      if (change.changed) {
        settings.set_strv('xkb-options', change.options);
        // Only what Slated added is ever removed again.
        this._state = {
          addedCapsHyper: this._state.addedCapsHyper || change.added,
          removedOptions: [...new Set([...this._state.removedOptions, ...change.removed])],
        };
        this._writeState();
        this._log?.record('keyboard.xkb_option', {added: CAPS_HYPER, setAside: change.removed});
      }
      return settings.get_strv('xkb-options').includes(CAPS_HYPER);
    } catch (e) {
      this._log?.error('keyboard.xkb_failed', e.message ?? String(e));
      return false;
    }
  }

  _removeOption() {
    if (!this._state.addedCapsHyper && this._state.removedOptions.length === 0) return;
    try {
      const settings = this._inputSources();
      const current = settings.get_strv('xkb-options');
      const next = this._state.addedCapsHyper
        ? withoutCapsHyper(current, this._state.removedOptions)
        : [...current, ...this._state.removedOptions.filter((o) => !current.includes(o))];
      if (next.length !== current.length || next.some((o, i) => o !== current[i])) settings.set_strv('xkb-options', next);
      this._log?.record('keyboard.xkb_option', {removed: CAPS_HYPER, restored: this._state.removedOptions});
      this._state = {addedCapsHyper: false, removedOptions: []};
      this._writeState();
    } catch (e) {
      this._log?.error('keyboard.xkb_failed', e.message ?? String(e));
    }
  }

  _readState() {
    try {
      const parsed = JSON.parse(readText(this._statePath) ?? '{}');
      return {
        addedCapsHyper: parsed.addedCapsHyper === true,
        removedOptions: Array.isArray(parsed.removedOptions) ? parsed.removedOptions.map(String) : [],
      };
    } catch {
      return {addedCapsHyper: false, removedOptions: []};
    }
  }

  _writeState() {
    try {
      if (!this._state.addedCapsHyper && this._state.removedOptions.length === 0) remove(this._statePath);
      else writeTextAtomic(this._statePath, `${JSON.stringify(this._state, null, 2)}\n`);
    } catch (e) {
      this._log?.error('keyboard.state_file_failed', e.message ?? String(e), {path: this._statePath});
    }
  }
}
