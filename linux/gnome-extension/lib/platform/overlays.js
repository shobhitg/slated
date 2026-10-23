// Slate's two interactive overlays, as GNOME Shell chrome with a modal grab:
// - **Window hints**: a letter on every window of the current workspace; press it to focus that window.
// - **Grid**: a miniature grid of each monitor; drag across cells to place the window.
// Escape, any other key, or clicking outside dismisses either. A port of the macOS OverlayController.
//
// St/Clutter notes for GNOME 46–49: children are added with add_child (Clutter.Container is gone since
// 46); the actor under an event comes from global.stage.get_event_actor(); Main.pushModal returns a
// Clutter.Grab whose seat state says whether input was grabbed.

import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {currentScreens} from './screens.js';
import {gridCellAt, gridSizeFor, gridTarget, intersectionArea, orderedLeftToRight} from './util.js';
import * as Windows from './windows.js';

const HINT_SIZE = 96;

export class OverlayController {
  /**
   * @param {object} options
   * @param {object} options.log
   * @param {(window: object, frame: object) => void} options.place  Moves a window with undo (the runner's `place`).
   */
  constructor({log, place}) {
    this._log = log;
    this._place = place;
    this._root = null;
    this._grab = null;
  }

  // --- Hints -------------------------------------------------------------------------------------

  showHints(characters) {
    this.dismiss();
    const letters = [...String(characters || '').toUpperCase()].filter((c) => c.trim());
    const windows = Windows.stackedWindows().slice(0, letters.length);
    if (windows.length === 0) {
      this._log?.record('hints.none', {}, 'notice');
      return;
    }
    const targets = new Map();
    this._root = this._makeRoot();
    windows.forEach((window, i) => {
      const letter = letters[i];
      targets.set(letter.toLowerCase(), window);
      const frame = Windows.frameOf(window);
      const bubble = this._hintBubble(letter, Windows.appOf(window));
      bubble.set_position(Math.round(frame.x + frame.width / 2 - HINT_SIZE / 2), Math.round(frame.y + frame.height / 2 - HINT_SIZE / 2));
      this._root.add_child(bubble);
    });
    this._log?.record('hints.shown', {windows: targets.size});
    this._present({
      onKey: (event) => {
        const window = targets.get(keyText(event));
        if (window && Windows.isAlive(window)) {
          this._log?.record('hints.picked', {app: Windows.appId(Windows.appOf(window), window)});
          this.dismiss();
          Windows.activate(window);
        } else {
          this._log?.record('hints.dismissed');
          this.dismiss();
        }
      },
      onClickOutside: () => {
        this._log?.record('hints.dismissed');
        this.dismiss();
      },
    });
  }

  _hintBubble(letter, app) {
    // A gradient ring around a dark bubble: St has gradient backgrounds but no gradient borders.
    const ring = new St.Bin({style_class: 'slated-hint-ring', width: HINT_SIZE, height: HINT_SIZE});
    const bubble = new St.Widget({style_class: 'slated-hint', layout_manager: new Clutter.BinLayout(), x_expand: true, y_expand: true});
    bubble.add_child(
      new St.Label({
        text: letter,
        style_class: 'slated-hint-letter',
        x_align: Clutter.ActorAlign.CENTER,
        y_align: Clutter.ActorAlign.CENTER,
        x_expand: true,
        y_expand: true,
      }),
    );
    if (app) {
      bubble.add_child(
        new St.Bin({
          style_class: 'slated-hint-icon',
          child: app.create_icon_texture(26),
          x_align: Clutter.ActorAlign.END,
          y_align: Clutter.ActorAlign.END,
          x_expand: true,
          y_expand: true,
        }),
      );
    }
    ring.set_child(bubble);
    return ring;
  }

  // --- Grid --------------------------------------------------------------------------------------

  showGrid({padding = 2, grids = [], window}) {
    this.dismiss();
    if (!window || !Windows.isAlive(window)) return;
    const windowFrame = Windows.frameOf(window);
    const app = Windows.appOf(window);
    const appName = Windows.appName(app, window) || 'Window';
    const appId = Windows.appId(app, window);
    const screens = currentScreens();
    const ordered = orderedLeftToRight(screens);
    this._root = this._makeRoot();
    for (const screen of screens) {
      const index = ordered.findIndex((s) => s.displayID === screen.displayID);
      const {columns, rows} = gridSizeFor(screen, index, grids);
      this._root.add_child(
        this._gridPanel({screen, columns, rows, padding, windowFrame, title: `${appName} — ${columns}×${rows}`}, (target) => {
          this._log?.record('grid.placed', {app: appId, frame: target});
          this.dismiss();
          if (!Windows.isAlive(window)) return;
          this._place(window, target);
          Windows.activate(window);
        }),
      );
    }
    this._log?.record('grid.shown', {screens: screens.length, app: appId});
    this._present({
      onKey: () => {
        this._log?.record('grid.dismissed');
        this.dismiss();
      },
      onClickOutside: () => {
        this._log?.record('grid.dismissed');
        this.dismiss();
      },
    });
  }

  /** A miniature of the screen's work area, centered on it, like Slate's grid. */
  _gridPanel({screen, columns, rows, padding, windowFrame, title}, onSelect) {
    const visible = screen.visibleFrame;
    const scale = Math.min(560 / visible.width, 420 / visible.height, 0.4);
    const areaWidth = Math.round(visible.width * scale);
    const areaHeight = Math.round(visible.height * scale);
    const panelWidth = areaWidth + 32;
    const panelHeight = areaHeight + 56;
    const panel = new St.Widget({
      style_class: 'slated-grid-panel',
      reactive: true,
      clip_to_allocation: true,
      x: Math.round(visible.x + (visible.width - panelWidth) / 2),
      y: Math.round(visible.y + (visible.height - panelHeight) / 2),
      width: panelWidth,
      height: panelHeight,
    });
    panel.add_child(new St.Label({text: title, style_class: 'slated-grid-title', x: 18, y: 12, width: panelWidth - 36}));

    const area = new St.Widget({reactive: true, x: 16, y: 40, width: areaWidth, height: areaHeight});
    panel.add_child(area);
    const cellWidth = areaWidth / columns;
    const cellHeight = areaHeight / rows;
    const inset = Math.max(Number(padding) || 0, 0) / 2;
    const cells = [];
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < columns; col++) {
        const cell = new St.Widget({
          style_class: 'slated-grid-cell',
          x: Math.round(col * cellWidth + inset),
          y: Math.round(row * cellHeight + inset),
          width: Math.max(Math.round(cellWidth - 2 * inset), 1),
          height: Math.max(Math.round(cellHeight - 2 * inset), 1),
        });
        area.add_child(cell);
        cells.push({col, row, actor: cell});
      }
    }

    // Where the window is now, as an outline.
    if (intersectionArea(visible, windowFrame) > 0) {
      const sx = areaWidth / visible.width;
      const sy = areaHeight / visible.height;
      const x0 = Math.max((windowFrame.x - visible.x) * sx, 0);
      const y0 = Math.max((windowFrame.y - visible.y) * sy, 0);
      const x1 = Math.min((windowFrame.x + windowFrame.width - visible.x) * sx, areaWidth);
      const y1 = Math.min((windowFrame.y + windowFrame.height - visible.y) * sy, areaHeight);
      area.add_child(
        new St.Widget({
          style_class: 'slated-grid-window',
          x: Math.round(x0),
          y: Math.round(y0),
          width: Math.max(Math.round(x1 - x0), 1),
          height: Math.max(Math.round(y1 - y0), 1),
        }),
      );
    }

    let anchor = null;
    let current = null;
    const cellAt = (event) => {
      const [stageX, stageY] = event.get_coords();
      const [ok, x, y] = area.transform_stage_point(stageX, stageY);
      return ok ? gridCellAt(x, y, areaWidth, areaHeight, columns, rows) : null;
    };
    const highlight = () => {
      for (const cell of cells) {
        const selected =
          anchor &&
          current &&
          cell.col >= Math.min(anchor.col, current.col) &&
          cell.col <= Math.max(anchor.col, current.col) &&
          cell.row >= Math.min(anchor.row, current.row) &&
          cell.row <= Math.max(anchor.row, current.row);
        if (selected) cell.actor.add_style_pseudo_class('selected');
        else cell.actor.remove_style_pseudo_class('selected');
      }
    };
    area.connect('button-press-event', (_actor, event) => {
      anchor = cellAt(event);
      current = anchor;
      highlight();
      return Clutter.EVENT_STOP;
    });
    // Clutter keeps sending the pointer to the pressed actor until release (implicit grab).
    area.connect('motion-event', (_actor, event) => {
      if (anchor) {
        current = cellAt(event) ?? current;
        highlight();
      }
      return Clutter.EVENT_STOP;
    });
    area.connect('button-release-event', (_actor, event) => {
      if (!anchor) return Clutter.EVENT_STOP;
      const end = cellAt(event) ?? current ?? anchor;
      const start = anchor;
      anchor = null;
      onSelect(gridTarget(visible, columns, rows, start, end));
      return Clutter.EVENT_STOP;
    });
    return panel;
  }

  // --- Plumbing ----------------------------------------------------------------------------------

  _makeRoot() {
    const root = new St.Widget({
      style_class: 'slated-overlay',
      reactive: true,
      can_focus: true,
      x: 0,
      y: 0,
      width: global.stage.width,
      height: global.stage.height,
      opacity: 0,
    });
    Main.layoutManager.addTopChrome(root);
    return root;
  }

  _present({onKey, onClickOutside}) {
    const root = this._root;
    this._grab = Main.pushModal(root, {actionMode: Shell.ActionMode.SYSTEM_MODAL});
    if (this._grab.get_seat_state() !== Clutter.GrabState.ALL) {
      this._log?.record('overlay.grab_failed', {}, 'error');
      this.dismiss();
      return;
    }
    root.grab_key_focus();
    root.connect('key-press-event', (_actor, event) => {
      // A modifier on its own (e.g. still holding Hyper) neither picks nor dismisses.
      if (!isModifierKeysym(event.get_key_symbol())) onKey(event);
      return Clutter.EVENT_STOP;
    });
    root.connect('button-press-event', (_actor, event) => {
      if (global.stage.get_event_actor(event) === root) onClickOutside();
      return Clutter.EVENT_STOP;
    });
    root.ease({opacity: 255, duration: 120, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
  }

  dismiss() {
    if (this._grab) {
      Main.popModal(this._grab);
      this._grab = null;
    }
    if (this._root) {
      const root = this._root;
      this._root = null;
      Main.layoutManager.removeChrome(root);
      root.destroy();
    }
  }

  destroy() {
    this.dismiss();
    this._place = null;
  }
}

/** Shift, Control, Caps Lock, Meta, Alt, Super, Hyper (left and right) and AltGr. */
export function isModifierKeysym(keysym) {
  return (keysym >= 0xffe1 && keysym <= 0xffee) || keysym === 0xfe03;
}

/** The lowercase character a key press typed ("a"), or the Escape marker. */
function keyText(event) {
  if (event.get_key_symbol() === Clutter.KEY_Escape) return 'escape';
  let text = '';
  try {
    text = event.get_key_unicode() ?? '';
  } catch {
    text = '';
  }
  if (!text || text === '\0') {
    const code = Clutter.keysym_to_unicode(event.get_key_symbol());
    text = code ? String.fromCodePoint(code) : '';
  }
  return text.toLowerCase();
}
