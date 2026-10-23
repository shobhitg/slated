// Slated's preferences window (GNOME 46–49): the GNOME counterpart of the macOS settings app.
//
// It edits ~/.config/slated/config.json, which the running extension watches and applies, and
// shows what the extension reports in $XDG_STATE_HOME/slated/status.json. See lib/prefs/ui/window.js
// for the window and docs/LINUX.md for how the pieces fit together.

import Adw from 'gi://Adw';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {SlatedSettings} from './lib/prefs/ui/window.js';

export default class SlatedPreferences extends ExtensionPreferences {
  fillPreferencesWindow(window) {
    // GNOME Shell checks that the window shows a page before it presents it. Slated replaces the
    // window's content with its own sidebar navigation, so this page only appears if building that
    // fails (then GNOME Shell shows its error page in its place).
    window.add(new Adw.PreferencesPage({title: 'Slated', icon_name: 'preferences-system-symbolic'}));
    // Keep a reference for as long as the window lives.
    window._slated = new SlatedSettings(window, {path: this.path, uuid: this.uuid, metadata: this.metadata});
  }
}
