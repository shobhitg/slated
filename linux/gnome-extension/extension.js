// Slated for GNOME: keyboard-first window management (Slate-compatible shortcuts, layouts and
// overlays), a Caps Lock Hyper key, hotstrings through espanso, game automation and clipboard
// history. GNOME Shell 46–51.
//
// Everything is created in enable() and torn down in disable(), per the extensions.gnome.org review
// guidelines; the work happens in lib/platform/runtime.js.

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {SlatedRuntime} from './lib/platform/runtime.js';

export default class SlatedExtension extends Extension {
  enable() {
    // Never throw out of enable(): GNOME would mark the extension as failed. Log instead.
    try {
      this._runtime = new SlatedRuntime({path: this.path, metadata: this.metadata, uuid: this.uuid});
      this._runtime.start();
    } catch (e) {
      console.error(`Slated couldn't start: ${e}\n${e?.stack ?? ''}`);
      try {
        this._runtime?.stop();
      } catch (stopError) {
        console.error(`Slated couldn't clean up after a failed start: ${stopError}`);
      }
      this._runtime = null;
    }
  }

  disable() {
    try {
      this._runtime?.stop();
    } catch (e) {
      console.error(`Slated couldn't stop cleanly: ${e}\n${e?.stack ?? ''}`);
    }
    this._runtime = null;
  }
}
