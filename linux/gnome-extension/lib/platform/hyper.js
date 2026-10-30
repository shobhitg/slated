// Caps Lock → Hyper on GNOME, when `keyboard.capsLock` is "hyper".
//
// - **keyd mode**: when a keyd config maps Caps Lock (Slated's own `/etc/keyd/slated.conf` from
//   `linux/install.sh --hyper-keyd`, or a `capslock =` line in another config's [main]) and keyd runs,
//   keyd sends Ctrl+Alt+Shift+Super for Caps Lock, so Slated uses plain accelerators. keyd can also
//   make a tap send Escape. Whether keyd runs is systemd's answer (`systemctl is-active keyd`); only
//   without systemd does its socket count, since keyd leaves `/run/keyd.socket` behind when it stops.
//   A keyd that runs without mapping Caps Lock (for a mouse's side buttons) leaves Slated in xkb mode.
//   Slated follows keyd's config folder, its socket and keyd.service's state over D-Bus, so setting
//   keyd up, removing its config or stopping it switches the mode without logging out.
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

import {exists, findProgram, listDirectory, readText, remove, watchFile, writeTextAtomic} from './files.js';
import {dirname} from './util.js';

export const CAPS_HYPER = 'caps:hyper';
export const KEYD_SOCKET = '/run/keyd.socket';
/** Where `linux/install.sh --hyper-keyd` writes Slated's keyd config (paths.js `keydConfigPath`). */
export const KEYD_CONFIG = '/etc/keyd/slated.conf';
const INPUT_SOURCES = 'org.gnome.desktop.input-sources';
const SYSTEMD = 'org.freedesktop.systemd1';
const SYSTEMD_PATH = '/org/freedesktop/systemd1';
/** keyd.service's object (D-Bus object paths spell "." as "_2e"). */
const KEYD_UNIT_PATH = '/org/freedesktop/systemd1/unit/keyd_2eservice';

/** Whether keyd config text maps Caps Lock: a `capslock = …` line in its [main] section. */
export function mapsCapsLock(text) {
  let main = false;
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, '').trim();
    const section = /^\[([^\]]*)\]$/.exec(line);
    if (section) main = section[1].trim().toLowerCase() === 'main';
    else if (main && /^capslock\s*=/i.test(line)) return true;
  }
  return false;
}

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
   *   keyd later starts, stops, or gets or loses its Caps Lock mapping.
   * @param {string} [options.socketPath]  keyd's socket (tests point it elsewhere).
   * @param {string} [options.keydConfigPath]  Slated's keyd config; keyd's other configs are next to it.
   */
  constructor({log, statePath, onDetected = null, socketPath = KEYD_SOCKET, keydConfigPath = KEYD_CONFIG}) {
    this._log = log;
    this._statePath = statePath;
    this._onDetected = onDetected;
    this._socketPath = socketPath;
    this._keydConfigPath = keydConfigPath;
    this._watches = [];
    /** keyd.service followed over D-Bus: {bus, signal, subscribed}. */
    this._service = null;
    this._checks = 0;
    this._settings = null;
    this._keyd = null;
    /** Whether a keyd config maps Caps Lock (as of the last check). */
    this._keydConfigured = false;
    this._cancellable = new Gio.Cancellable();
    this._logged = '';
    this._warnedEscape = false;
    this._state = this._readState();
  }

  /**
   * Finds out whether keyd is the Hyper key: a keyd config maps Caps Lock, and keyd runs (systemd's
   * answer comes asynchronously). Then follows keyd's config folder (linux/install.sh --hyper-keyd and
   * --remove), its socket (made when keyd starts) and, with systemd, keyd.service's state (keyd
   * leaves its socket behind when it stops), so the mode switches without logging out.
   */
  detect() {
    if (this._watches.length === 0) {
      this._watches = [
        watchFile(this._socketPath, () => this._recheck()),
        watchFile(dirname(this._keydConfigPath), () => this._recheck(), {directory: true}),
      ];
    }
    this._recheck(true);
  }

  /** Asks again; `onDetected` hears about a changed answer (detect()'s first one goes without saying). */
  _recheck(initial = false) {
    const check = ++this._checks;
    const settle = (keyd, later) => {
      if (check !== this._checks) return; // a newer check is under way
      const before = this._keyd;
      this._keyd = keyd;
      if (keyd !== before && (later || !initial)) this._onDetected?.();
    };
    this._keydConfigured = this._keydMapsCapsLock();
    if (!this._keydConfigured) {
      settle(false, false);
      return;
    }
    const systemctl = findProgram('systemctl');
    if (!systemctl) {
      settle(exists(this._socketPath), false);
      return;
    }
    this._followService();
    try {
      const proc = Gio.Subprocess.new(
        [systemctl, 'is-active', '--quiet', 'keyd'],
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
        settle(active, true);
      });
    } catch {
      settle(false, false);
    }
  }

  /** Whether a keyd config maps Caps Lock: Slated's own, or another with a capslock line. */
  _keydMapsCapsLock() {
    if (exists(this._keydConfigPath)) return true;
    const dir = dirname(this._keydConfigPath);
    return listDirectory(dir).some((name) => name.endsWith('.conf') && mapsCapsLock(readText(`${dir}/${name}`)));
  }

  /** Follows keyd.service's ActiveState over D-Bus (once keyd matters): keyd stopping is noticed too. */
  _followService() {
    if (this._service) return;
    this._service = {bus: null, signal: 0, subscribed: false};
    try {
      const bus = Gio.DBus.system;
      this._service.bus = bus;
      this._service.signal = bus.signal_subscribe(
        SYSTEMD,
        'org.freedesktop.DBus.Properties',
        'PropertiesChanged',
        KEYD_UNIT_PATH,
        `${SYSTEMD}.Unit`,
        Gio.DBusSignalFlags.NONE,
        (_bus, _sender, _path, _iface, _signal, parameters) => {
          let changed = {};
          let invalidated = [];
          try {
            [, changed, invalidated] = parameters.deep_unpack();
          } catch {
            return;
          }
          if ('ActiveState' in changed || invalidated.includes('ActiveState')) this._recheck();
        },
      );
      // systemd announces unit changes only while some client has subscribed.
      const service = this._service;
      bus.call(SYSTEMD, SYSTEMD_PATH, `${SYSTEMD}.Manager`, 'Subscribe', null, null, Gio.DBusCallFlags.NONE, -1, this._cancellable, (connection, result) => {
        try {
          connection.call_finish(result);
          service.subscribed = true;
        } catch {
          // Another part of GNOME Shell subscribed first (it's one connection), or there's no systemd.
        }
      });
    } catch (e) {
      this._log?.error('keyboard.keyd_watch_failed', e?.message ?? String(e));
    }
  }

  /** True once keyd is known to map Caps Lock and run; null while still checking. */
  get keyd() {
    return this._keyd;
  }

  /**
   * keyd as status.json reports it, so the settings window can say what's missing: "running" (it has
   * Caps Lock), "stopped" (a config maps Caps Lock but keyd doesn't run), "none" (no config maps it)
   * or "checking".
   */
  get keydState() {
    if (!this._keydConfigured) return 'none';
    if (this._keyd === null) return 'checking';
    return this._keyd ? 'running' : 'stopped';
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
    const result = {wanted: !!wanted, mode, active, hyperIsSuper: mode === 'xkb', pending, keyd: this.keydState};
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
    for (const watch of this._watches) watch.cancel();
    this._watches = [];
    const service = this._service;
    this._service = null;
    if (service?.bus) {
      if (service.signal) service.bus.signal_unsubscribe(service.signal);
      if (service.subscribed) service.bus.call(SYSTEMD, SYSTEMD_PATH, `${SYSTEMD}.Manager`, 'Unsubscribe', null, null, Gio.DBusCallFlags.NONE, -1, null, null);
    }
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
