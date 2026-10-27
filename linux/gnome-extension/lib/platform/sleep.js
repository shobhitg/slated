// Going to sleep stops automations, as on the Mac (NSWorkspace.willSleepNotification). GNOME locks the
// screen on suspend by default, which disables extensions and so releases everything; with that lock
// turned off, a held key or a running auto-clicker would carry on after waking up.
//
// logind announces a suspend or hibernation with PrepareForSleep(true) on the system bus. GNOME
// Shell's login manager (the one its screen shield uses) already follows it and re-emits it as
// 'prepare-for-sleep'; without systemd it's a stand-in that never fires.

import {getLoginManager} from 'resource:///org/gnome/shell/misc/loginManager.js';

/** Calls `onSleep()` when the computer is about to suspend or hibernate. */
export class SleepWatcher {
  constructor(onSleep) {
    this._manager = getLoginManager();
    this._id = this._manager.connect('prepare-for-sleep', (_manager, aboutToSuspend) => {
      if (aboutToSuspend === true) onSleep();
    });
  }

  destroy() {
    if (this._id) this._manager.disconnect(this._id);
    this._id = 0;
  }
}
