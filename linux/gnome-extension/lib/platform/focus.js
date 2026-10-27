// Which app has focus, as the identity per-app bindings (onlyInApps), the clipboard's excluded apps
// and automation's "stop when you switch apps" compare against.
//
// An app answers to its desktop file id with or without ".desktop" ("org.gnome.Terminal"), and its
// focused window's WM_CLASS and WM_CLASS instance, GTK application id and sandbox (Flatpak) id. Games
// without a desktop file, such as Steam/Proton games, are known by WM_CLASS ("steam_app_1086940").
//
// While the overview is open no app counts as focused, although Mutter keeps the window's focus: an
// auto-clicker must not click into the overview, and a game's plain-key binding must not swallow what
// you type in its search.

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import * as Windows from './windows.js';
import {appIdentity} from './util.js';

/** The identity of `window`'s app: {id, ids, name}, or null for no window. */
export function windowIdentity(window) {
  if (!window) return null;
  const app = Windows.appOf(window);
  const id = Windows.appId(app, window);
  const desktopId = app && !app.is_window_backed() ? app.get_id() : null;
  const others = [
    desktopId,
    window.get_wm_class?.(),
    window.get_wm_class_instance?.(),
    window.get_gtk_application_id?.(),
    window.get_sandboxed_app_id?.(),
  ];
  return {...appIdentity(id, others), name: Windows.appName(app, window) || id};
}

/** Calls `onChange(identity)` when the focused app changes (null: the overview or the desktop). */
export class FocusTracker {
  constructor(onChange) {
    this._onChange = onChange;
    this._overview = !!Main.overview?.visible;
    this._last = this.current();
    this._signal = global.display.connect('notify::focus-window', () => this._changed());
    this._overviewSignals = [
      Main.overview.connect('showing', () => this._setOverview(true)),
      Main.overview.connect('hidden', () => this._setOverview(false)),
    ];
  }

  /** The focused app's identity right now (null while the overview is open). */
  current() {
    return this._overview ? null : windowIdentity(Windows.focusedWindow());
  }

  /** The focused window (a Meta.Window), or null. */
  window() {
    return Windows.focusedWindow();
  }

  _setOverview(visible) {
    this._overview = visible;
    this._changed();
  }

  _changed() {
    const app = this.current();
    if ((app?.id ?? null) === (this._last?.id ?? null)) return;
    this._last = app;
    this._onChange?.(app);
  }

  destroy() {
    if (this._signal) global.display.disconnect(this._signal);
    for (const id of this._overviewSignals ?? []) Main.overview.disconnect(id);
    this._signal = 0;
    this._overviewSignals = [];
    this._onChange = null;
  }
}
