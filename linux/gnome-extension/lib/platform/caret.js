// Where the text cursor is, as GNOME Shell's input method hears it, so the clipboard picker can open
// below it. GNOME Shell's on-screen keyboard follows the cursor the same way (ui/keyboard.js):
//
// - Wayland apps (GTK, Qt, Firefox, …) report their cursor rectangle through the text-input
//   protocol; Mutter passes it to Main.inputMethod, which emits `cursor-location-changed` with a
//   Graphene.Rect in stage coordinates. Main.inputMethod.currentFocus is set while such a field has
//   the keyboard.
// - X11 apps (XWayland, through IBus's GTK or Qt module) report it to IBus, whose panel service in
//   GNOME Shell re-emits it as the IBus manager's `set-cursor-location`. Wayland fields reach IBus
//   through GNOME Shell too, so IBus reports count only while no text-input field has focus.
//
// Nothing can be asked on demand: the last report is kept with the window it came from, and counts
// only while that window still has focus (and, for text-input, its field still does). Apps that use
// neither (most terminals' own input handling, games, Electron without IBus) report nothing; the
// picker then opens at the pointer. Only reports are kept, never what's typed.

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {getIBusManager} from 'resource:///org/gnome/shell/misc/ibusManager.js';

/** A Graphene.Rect, or IBus's {x, y, width, height}, as a plain rect. */
function plainRect(rect) {
  if (typeof rect?.get_x === 'function') return {x: rect.get_x(), y: rect.get_y(), width: rect.get_width(), height: rect.get_height()};
  if (rect?.origin && rect?.size) return {x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height};
  return {x: rect?.x, y: rect?.y, width: rect?.width, height: rect?.height};
}

function defaultIBus() {
  try {
    return getIBusManager();
  } catch {
    return null;
  }
}

export class CaretTracker {
  /**
   * @param {object} [options]
   * @param {object} [options.inputMethod]  Main.inputMethod (a Clutter.InputMethod).
   * @param {object} [options.ibus]  GNOME Shell's IBus manager, or null without IBus.
   * @param {() => object} [options.focusWindow]  The focused Meta.Window.
   */
  constructor({inputMethod = Main.inputMethod ?? null, ibus = defaultIBus(), focusWindow = () => global.display.get_focus_window()} = {}) {
    this._inputMethod = inputMethod;
    this._ibus = ibus;
    this._focusWindow = focusWindow;
    this._last = null;
    this._suspended = false;
    this._connections = [];
    this._connect(inputMethod, 'cursor-location-changed', (_im, rect) => this._report(rect, 'input-method'));
    this._connect(ibus, 'set-cursor-location', (_manager, rect) => {
      // A Wayland field's report, passed on to IBus by GNOME Shell: text-input already told us.
      if (!this._hasTextInputFocus()) this._report(rect, 'ibus');
    });
    this._connect(ibus, 'focus-out', () => {
      if (this._last?.source === 'ibus') this._last = null;
    });
  }

  /** The text cursor in the focused window: {rect, source: "input-method" | "ibus"}, or null. */
  location() {
    const last = this._last;
    if (!last || last.window !== this._safeFocusWindow()) return null;
    if (last.source === 'input-method' && !this._hasTextInputFocus()) return null;
    return {rect: {...last.rect}, source: last.source};
  }

  /** Ignores reports (the picker's own filter field has the input method while it's open). */
  suspend() {
    this._suspended = true;
  }

  /** Listens again, forgetting the last report: pasting moved the cursor, and the app reports it anew. */
  resume() {
    this._suspended = false;
    this._last = null;
  }

  destroy() {
    for (const [object, id] of this._connections) {
      try {
        object.disconnect(id);
      } catch {
        // Already gone with GNOME Shell's object.
      }
    }
    this._connections = [];
    this._last = null;
  }

  _connect(object, signal, callback) {
    if (!object?.connect) return;
    try {
      this._connections.push([object, object.connect(signal, callback)]);
    } catch {
      // An older or newer GNOME without this signal: that source just never reports.
    }
  }

  _report(rect, source) {
    if (this._suspended || !rect) return;
    this._last = {rect: plainRect(rect), source, window: this._safeFocusWindow()};
  }

  _hasTextInputFocus() {
    try {
      return Boolean(this._inputMethod?.currentFocus);
    } catch {
      return false;
    }
  }

  _safeFocusWindow() {
    try {
      return this._focusWindow() ?? null;
    } catch {
      return null;
    }
  }
}
