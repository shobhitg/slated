// Going to sleep stops automations, as on the Mac (NSWorkspace.willSleepNotification). GNOME locks the
// screen on suspend by default, which disables extensions and so releases everything; with that lock
// turned off, a held key or a running auto-clicker would carry on after waking up. logind announces a
// suspend or hibernation with PrepareForSleep(true) on the system bus, and the wake-up with false.

import Gio from 'gi://Gio';

const LOGIND = 'org.freedesktop.login1';

/** Calls `onSleep()` when the computer is about to suspend or hibernate. */
export class SleepWatcher {
  constructor(onSleep) {
    this._bus = Gio.DBus.system;
    this._id = this._bus.signal_subscribe(
      LOGIND,
      `${LOGIND}.Manager`,
      'PrepareForSleep',
      '/org/freedesktop/login1',
      null,
      Gio.DBusSignalFlags.NONE,
      (_bus, _sender, _path, _iface, _signal, parameters) => {
        let starting = false;
        try {
          [starting] = parameters.deep_unpack();
        } catch {
          return;
        }
        if (starting === true) onSleep();
      },
    );
  }

  destroy() {
    if (this._id) this._bus.signal_unsubscribe(this._id);
    this._id = 0;
  }
}
