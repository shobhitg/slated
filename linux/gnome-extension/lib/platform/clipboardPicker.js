// The clipboard picker: a small list that opens where you're typing (port of the macOS
// ClipboardPickerModel and its view, Sources/SlatedUI/Clipboard/ClipboardPicker.swift), drawn with St.
// A filter field that takes typing at once and one-line rows, pinned items first; an image shows as a
// thumbnail (and its name when it has one), copied files as their icon or thumbnail and the first
// file's name ("+ 2 more"), dimmed as "Moved or deleted" once none is left. Selecting an image or
// files shows them larger beside the picker: the image, or the file's thumbnail or icon with its
// name, size and kind.
//
//   ↑↓ select · ↩ or a click: paste into the window you were in · Ctrl+1–9 paste that item · Esc close
//
// GNOME only: Ctrl+P pins, Ctrl+Backspace (or Delete) deletes and Ctrl+Shift+Backspace clears all but
// pinned items, since Settings → Clipboard on GNOME can't reach the history the extension holds.
//
// `PickerModel`, `pickerKey` and the layout helpers are pure (tested in Node); `ClipboardPicker` is
// the St view. Sizes are the Mac's, in logical pixels; the view scales them by GNOME's UI scale.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Pango from 'gi://Pango';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {PopupPlacement, fileDisplayName} from '../core/index.js';

import * as Files from './clipboardFiles.js';
import {currentScreens} from './screens.js';

/** How much of each item the picker searches as you type (huge copies stay responsive). */
export const SEARCH_LIMIT = 20_000;
const PREVIEW_LIMIT = 240;

/** The picker's layout, as on the Mac. */
export const PICKER = Object.freeze({
  width: 320,
  /** Rows shown before the list scrolls; also how many have a Ctrl-number. */
  visibleRows: 9,
  filterHeight: 32,
  hairline: 0.5,
  textRowHeight: 26,
  imageRowHeight: 36,
  thumbnailHeight: 28,
  /** A files row's thumbnail: as wide as a text row's app icon, so names line up; a page gets a little more height. */
  fileThumbnail: Object.freeze({width: 16, height: 20}),
  listPadding: 5,
});

/**
 * The preview beside the picker: an image about 240 px on its long side; a file's icon, when it has
 * no picture, at 64 px, in a panel wide enough for its name.
 */
export const PREVIEW = Object.freeze({maxSide: 240, padding: 8, captionHeight: 19, minWidth: 120, iconSize: 64, fileMinWidth: 200});

/** A files row whose files are all gone. */
export const MISSING = 'Moved or deleted';

/** The hint in the filter field, the picker's only one. */
export const HINT = 'Ctrl+1–9 · esc';

/** PopupPlacement's gaps (below the caret, beside the picker), in logical pixels like the sizes. */
const GAP_BELOW = 4;
const GAP_BESIDE = 6;

// --- Text and layout (pure) ------------------------------------------------------------------------

/** One line for a history item: lines joined with " ⏎ ", trimmed, at most 240 characters. */
export function itemPreview(text) {
  // Only the start can show, so a huge copy isn't split whole on every redraw.
  const collapsed = String(text)
    .slice(0, PREVIEW_LIMIT * 8)
    .split(/\r\n|[\n\r\v\f\u{85}\u{2028}\u{2029}]/u)
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .join(' ⏎ ');
  const chars = [...collapsed];
  return chars.length > PREVIEW_LIMIT ? `${chars.slice(0, PREVIEW_LIMIT).join('')}…` : collapsed;
}

/** An image row's title: its name ("Screenshot 2026-10-30.png"), else "Image · 1280×720 · Firefox". */
export function imageTitle(image, app = null) {
  if (image.name) return image.name;
  return ['Image', `${image.width}×${image.height}`, ...(app ? [app] : [])].join(' · ');
}

/** A files row's title in its two parts: the first file's name, and "+ 2 more" for several (else null). */
export function filesTitleParts(files) {
  return {name: fileDisplayName(files[0] ?? ''), more: files.length > 1 ? `+ ${files.length - 1} more` : null};
}

/** The same on one line: "report.pdf + 2 more". */
export function filesTitle(files) {
  const {name, more} = filesTitleParts(files);
  return more ? `${name} ${more}` : name;
}

/** Under a file's preview: "2.4 MB · PNG image"; a folder's kind alone. */
export function fileDetails({size = null, kind = ''} = {}) {
  return [...(size === null || size === undefined ? [] : [formatBytes(size)]), ...(kind ? [kind] : [])].join(' · ');
}

/** Under a preview: "1280×720 · 245 kB". */
export function imageDetails(image) {
  return `${image.width}×${image.height} · ${formatBytes(image.bytes)}`;
}

const BYTE_UNITS = ['bytes', 'kB', 'MB', 'GB', 'TB', 'PB'];

/**
 * A file size the way the Mac shows it (Foundation's file byte count style): powers of 1000, the next
 * unit from 999 up, whole kB, one decimal for MB and two above, rounded half to even. "245 kB".
 */
export function formatBytes(bytes) {
  const n = Math.max(0, Math.round(Number(bytes) || 0));
  if (n === 0) return 'Zero kB';
  if (n === 1) return '1 byte';
  let unit = 0;
  while (unit < BYTE_UNITS.length - 1 && n >= 999 * 1000 ** unit) unit++;
  const decimals = unit <= 1 ? 0 : unit === 2 ? 1 : 2;
  const scaled = n * 10 ** decimals;
  const divisor = 1000 ** unit;
  let whole = Math.floor(scaled / divisor);
  const rest = scaled - whole * divisor;
  if (2 * rest > divisor || (2 * rest === divisor && whole % 2 === 1)) whole++;
  const text = decimals === 0 ? String(whole) : (whole / 10 ** decimals).toFixed(decimals).replace(/\.?0+$/, '');
  return `${text} ${BYTE_UNITS[unit]}`;
}

/** A row's height: images are taller; text and files (a small thumbnail beside the name) are one line. */
export function rowHeight(item) {
  return item.image ? PICKER.imageRowHeight : PICKER.textRowHeight;
}

/**
 * The list's height: room for the first nine rows (one row's worth when there are none), and half of
 * the next when there are more, so the list shows it scrolls.
 */
export function listHeight(rows) {
  if (rows.length === 0) return PICKER.textRowHeight;
  const shown = rows.slice(0, PICKER.visibleRows).reduce((sum, item) => sum + rowHeight(item), 0);
  return shown + (rows.length > PICKER.visibleRows ? PICKER.textRowHeight / 2 : 0);
}

/** A row thumbnail's width at `height`: the image's shape, within reason (a panorama or a sliver still gets a sensible box). */
export function thumbnailWidth(image, height = PICKER.thumbnailHeight) {
  const aspect = Math.max(image.width, 1) / Math.max(image.height, 1);
  return Math.round(Math.min(Math.max(height * aspect, height * 0.7), height * 1.8));
}

/** The image scaled to fit the preview's 240 px, never enlarged. */
export function previewImageSize(image) {
  const width = Math.max(image.width, 1);
  const height = Math.max(image.height, 1);
  const scale = Math.min(PREVIEW.maxSide / width, PREVIEW.maxSide / height, 1);
  return {width: Math.max(Math.round(width * scale), 1), height: Math.max(Math.round(height * scale), 1)};
}

/** The preview panel's size: the fitted image, room for its caption, and padding. */
export function previewSize(image) {
  const fitted = previewImageSize(image);
  return {
    width: Math.max(fitted.width, PREVIEW.minWidth) + 2 * PREVIEW.padding,
    height: fitted.height + PREVIEW.captionHeight + 2 * PREVIEW.padding,
  };
}

/**
 * A file's preview size: its picture fitted like an image (`shape`, its pixel size) or its icon,
 * then two lines (name; size and kind), in a panel wide enough for a name.
 */
export function filePreviewSize(shape = null) {
  const visual = shape ? previewImageSize(shape) : {width: PREVIEW.iconSize, height: PREVIEW.iconSize};
  return {
    width: Math.max(visual.width, PREVIEW.fileMinWidth) + 2 * PREVIEW.padding,
    height: visual.height + 2 * PREVIEW.captionHeight + 2 * PREVIEW.padding,
  };
}

// --- Keys ------------------------------------------------------------------------------------------

// Keysyms (X11 keysymdef.h) and the hardware keycodes (evdev + 8) of the keys the picker handles, so
// Ctrl+1 works on AZERTY (where the key types "&") and Ctrl+P on non-Latin layouts.
const KEYSYM_NAMES = {
  0xff52: 'Up', 0xff54: 'Down', 0xff0d: 'Return', 0xff8d: 'Return', 0xff1b: 'Escape', 0xff08: 'BackSpace',
  0xffff: 'Delete', 0xff9f: 'Delete',
};
const DIGIT_KEYCODES = {10: '1', 11: '2', 12: '3', 13: '4', 14: '5', 15: '6', 16: '7', 17: '8', 18: '9'};
const LETTER_KEYCODES = {33: 'p'};

/**
 * What a key press means to the picker: {name, ctrl, shift}. `name` is "Up", "Return", "Escape",
 * "BackSpace", "Delete", a digit "1"–"9", a lowercase letter, or null. `masks` holds Clutter's
 * CONTROL_MASK and SHIFT_MASK (passed in so this stays free of gi:// imports).
 */
export function pickerKey(keysym, keycode, state, masks) {
  const ctrl = Boolean(state & masks.CONTROL_MASK);
  const shift = Boolean(state & masks.SHIFT_MASK);
  let name = KEYSYM_NAMES[keysym] ?? null;
  if (name === null && keysym >= 0xffb1 && keysym <= 0xffb9) name = String(keysym - 0xffb0); // keypad digits
  if (name === null && keysym >= 0x20 && keysym < 0x7f) name = String.fromCharCode(keysym).toLowerCase();
  if (ctrl && (name === null || !/^[1-9p]$/.test(name))) name = DIGIT_KEYCODES[keycode] ?? LETTER_KEYCODES[keycode] ?? name;
  return {name, ctrl, shift};
}

// --- The model -------------------------------------------------------------------------------------

const samePoint = (a, b) => a !== null && b !== null && a[0] === b[0] && a[1] === b[1];

/**
 * The picker's state: the filter, its results (pinned first, then newest first) and the selection.
 * `actions` carries out what you pick: paste(id), togglePin(id), delete(id), clear(), close().
 */
export class PickerModel {
  constructor({history, actions}) {
    this._history = history;
    this._actions = actions;
    this.query = '';
    this.selectedId = null;
    this.results = [];
    /** The list's height, set when the picker opens so it doesn't resize as you type. */
    this.listHeight = PICKER.textRowHeight;
    /**
     * Where the pointer was when a key moved the selection (or the picker opened): a row "hovered"
     * under a pointer that hasn't moved since only scrolled there.
     */
    this._restingPointer = null;
    /** Called with "results" (redraw the list) or "selection" (only the highlight moved). */
    this.onChange = null;
  }

  /** Whether nothing was copied at all (not just nothing matching). */
  get isEmpty() {
    return this._history().items.length === 0;
  }

  /** The picker's size for the history it opened with. */
  get size() {
    return {width: PICKER.width, height: PICKER.filterHeight + PICKER.hairline + this.listHeight + 2 * PICKER.listPadding};
  }

  get selectedItem() {
    return this.results.find((item) => item.id === this.selectedId) ?? null;
  }

  /** What's shown larger beside the picker: the selected row, when it's an image or files. */
  get previewItem() {
    const item = this.selectedItem;
    return item?.image || item?.files ? item : null;
  }

  /** The Ctrl-number of the result at `index`: the first nine have one. */
  number(index) {
    return index < PICKER.visibleRows ? index + 1 : null;
  }

  /** Where a row starts in the list, below the ones before it (null when it isn't listed). */
  rowTop(id) {
    let top = 0;
    for (const item of this.results) {
      if (item.id === id) return top;
      top += rowHeight(item);
    }
    return null;
  }

  /** Call each time the picker opens, with the pointer's location ([x, y]). */
  reset(pointer = null) {
    this.query = '';
    this._refilter(true);
    this._restingPointer = pointer;
    this.listHeight = listHeight(this.results);
    this.onChange?.('results');
  }

  setQuery(query) {
    const next = String(query ?? '');
    // St writes the text back on focus; only a real change refilters.
    if (next === this.query) return;
    this.query = next;
    this._refilter(true);
    this.onChange?.('results');
  }

  /** The history changed underneath (a copy arrived, an item was pinned): keeps the selection when it's still there. */
  refresh() {
    this._refilter(false);
    this.onChange?.('results');
  }

  select(id) {
    if (this.selectedId === id) return;
    this.selectedId = id;
    this.onChange?.('selection');
  }

  move(delta, pointer = null) {
    if (pointer) this._restingPointer = pointer;
    if (this.results.length === 0) return;
    const current = this.results.findIndex((item) => item.id === this.selectedId);
    this.select(this.results[Math.min(Math.max(current + delta, 0), this.results.length - 1)].id);
  }

  /**
   * The pointer is over a row: it becomes the selection, so there's one highlight and ↩ pastes what's
   * under the mouse. Not while the pointer rests where it was when a key moved the selection or the
   * picker opened: the list moved under it, the mouse didn't.
   */
  hover(id, pointer = null) {
    if (pointer && samePoint(pointer, this._restingPointer)) return;
    this._restingPointer = null;
    this.select(id);
  }

  close() {
    this._actions.close();
  }

  /** Pastes the item (the selected one by default) into the window you were in. */
  paste(id = this.selectedId) {
    if (!id) return;
    this._actions.close();
    this._actions.paste(id);
  }

  /** Ctrl+1–9. */
  pick(number) {
    if (number >= 1 && number <= Math.min(this.results.length, PICKER.visibleRows)) this.paste(this.results[number - 1].id);
  }

  togglePin(id = this.selectedId) {
    if (id) this._changeHistory(() => this._actions.togglePin(id));
  }

  delete(id = this.selectedId) {
    if (!id) return;
    const index = Math.max(this.results.findIndex((item) => item.id === id), 0);
    this._changeHistory(() => this._actions.delete(id));
    // The next item takes the deleted one's place.
    if (this.results.length > 0) this.select(this.results[Math.min(index, this.results.length - 1)].id);
  }

  clear() {
    this._changeHistory(() => this._actions.clear());
  }

  /** Handles a key press ({name, ctrl, shift} from `pickerKey`); false lets the filter field have it. */
  handleKey({name, ctrl = false, shift = false}, pointer = null) {
    switch (name) {
      case 'Up': this.move(-1, pointer); return true;
      case 'Down': this.move(1, pointer); return true;
      case 'Return': this.paste(); return true;
      case 'Escape': this.close(); return true;
      default: break;
    }
    if (!ctrl) return false;
    if (name === 'BackSpace' || name === 'Delete') {
      if (shift) this.clear();
      else this.delete();
      return true;
    }
    if (name === 'p') {
      this.togglePin();
      return true;
    }
    if (/^[1-9]$/.test(name ?? '')) {
      this.pick(Number(name));
      return true;
    }
    return false;
  }

  /** Runs an action that changes the history, then refilters unless the service already refreshed the picker. */
  _changeHistory(action) {
    const before = this.results;
    action();
    if (this.results !== before) return;
    this._refilter(false);
    this.onChange?.('results');
  }

  _refilter(selectFirst) {
    this.results = this._history().search(this.query, {maxCharacters: SEARCH_LIMIT});
    if (selectFirst || !this.results.some((item) => item.id === this.selectedId)) this.selectedId = this.results[0]?.id ?? null;
  }
}

// --- The view --------------------------------------------------------------------------------------

/** A source app's name and icon (a Gio.Icon), from its desktop file; null when it has none. */
function lookupApp(id) {
  try {
    const system = Shell.AppSystem.get_default();
    const app = system.lookup_app(`${id}.desktop`) ?? system.lookup_app(id);
    return app ? {name: app.get_name(), icon: app.get_icon?.() ?? null} : null;
  } catch {
    return null;
  }
}

const pointerLocation = () => {
  const [x, y] = global.get_pointer();
  return [x, y];
};

/** A label shortened in the middle when it doesn't fit ("quarterly…report.pdf"). */
function middleEllipsized(label) {
  label.clutter_text.ellipsize = Pango.EllipsizeMode.MIDDLE;
  return label;
}

/** What the picker reads about copied files (clipboardFiles.js; tests pass their own). */
const FILE_INFO = Object.freeze({
  describe: Files.describeFile, thumbnail: Files.thumbnailPath, imageSize: Files.imageFileSize, icon: Files.typeIcon,
  kind: Files.fileKind,
});

function uiScale() {
  try {
    return St.ThemeContext.get_for_stage(global.stage).scale_factor || 1;
  } catch {
    return 1;
  }
}

export class ClipboardPicker {
  /**
   * @param {object} options
   * @param {PickerModel} options.model
   * @param {object} [options.log]
   * @param {(image: object) => string|null} [options.imagePath]  An image item's file, or null when it's gone.
   * @param {(id: string) => {name: string, icon: object|null}|null} [options.appInfo]
   * @param {() => object[]} [options.screens]  ScreenInfo list (screens.js).
   * @param {() => number[]} [options.pointer]  The pointer's [x, y].
   * @param {() => void} [options.onClosed]  After it closes, however that happened.
   * @param {object} [options.files]  Reads copied files: describe(path), thumbnail(path, size), imageSize(path),
   *   icon(contentType), kind(contentType) (clipboardFiles.js).
   */
  constructor({
    model, log = null, imagePath = () => null, appInfo = lookupApp, screens = currentScreens, pointer = pointerLocation, onClosed = null,
    files = FILE_INFO,
  }) {
    this._model = model;
    this._files = files;
    /** Each files item's first file still there ({path, info}, or {path, info: null} when none is), by id, while open. */
    this._fileStates = new Map();
    this._log = log;
    this._imagePath = imagePath;
    this._appInfo = appInfo;
    this._screens = screens;
    this._pointer = pointer;
    this.onClosed = onClosed;
    this._root = null;
    this._grab = null;
    this._rows = new Map();
    this._apps = new Map();
    this._frame = null;
    this._preview = null;
    this._previewKey = null;
    this._previewSize = null;
    model.onChange = (what) => (what === 'selection' ? this._selectionMoved() : this._render());
  }

  get isOpen() {
    return this._root !== null;
  }

  /** Opens below `anchor` (the caret, or the pointer as an empty rect), above it near the bottom of the screen. */
  open(anchor) {
    this.close();
    this._scale = uiScale();
    this._apps.clear();
    this._fileStates.clear();
    this._model.reset(this._pointer());
    this._build();
    this._place(anchor);
    this._grab = Main.pushModal(this._root, {actionMode: Shell.ActionMode.SYSTEM_MODAL});
    if (this._grab.get_seat_state() !== Clutter.GrabState.ALL) {
      this._log?.record('clipboard.grab_failed', {}, 'error');
      this.close();
      return false;
    }
    this._entry.clutter_text.grab_key_focus();
    this._render();
    return true;
  }

  close() {
    const wasOpen = this.isOpen;
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
    this._rows.clear();
    this._preview = null;
    this._previewKey = null;
    this._previewSize = null;
    this._frame = null;
    if (wasOpen) this.onClosed?.();
  }

  /** The history changed while open (a copy arrived): redraw. */
  refresh() {
    if (this.isOpen) this._model.refresh();
  }

  destroy() {
    this.close();
    this._model.onChange = null;
  }

  /** The picker's frame on the stage, once open. */
  get frame() {
    return this._frame;
  }

  _px(value) {
    return Math.round(value * this._scale);
  }

  _build() {
    this._root = new St.Widget({reactive: true, x: 0, y: 0, width: global.stage.width, height: global.stage.height});
    Main.layoutManager.addTopChrome(this._root);
    this._root.connect('button-press-event', (_actor, event) => {
      // A click outside the picker (and its preview) closes it, like a menu.
      if (global.stage.get_event_actor(event) === this._root) this._model.close();
      return Clutter.EVENT_STOP;
    });

    this._panel = new St.BoxLayout({style_class: 'slated-clipboard-picker', vertical: true, reactive: true});
    this._root.add_child(this._panel);

    const filter = new St.BoxLayout({style_class: 'slated-clipboard-filter', x_expand: true, height: this._px(PICKER.filterHeight)});
    filter.add_child(new St.Icon({icon_name: 'edit-find-symbolic', style_class: 'slated-clipboard-filter-icon', y_align: Clutter.ActorAlign.CENTER}));
    this._entry = new St.Entry({style_class: 'slated-clipboard-search', hint_text: 'Filter', can_focus: true, x_expand: true, y_align: Clutter.ActorAlign.CENTER});
    filter.add_child(this._entry);
    filter.add_child(new St.Label({style_class: 'slated-clipboard-hint', text: HINT, y_align: Clutter.ActorAlign.CENTER}));
    this._panel.add_child(filter);

    this._list = new St.BoxLayout({style_class: 'slated-clipboard-list', vertical: true, x_expand: true});
    this._scroll = new St.ScrollView({
      style_class: 'slated-clipboard-scroll', x_expand: true, y_expand: true,
      hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC, overlay_scrollbars: true,
    });
    this._scroll.set_child(this._list);
    this._panel.add_child(this._scroll);

    const text = this._entry.clutter_text;
    text.connect('text-changed', () => this._model.setQuery(this._entry.get_text()));
    text.connect('key-press-event', (_actor, event) => {
      const key = pickerKey(event.get_key_symbol(), event.get_key_code(), event.get_state(), Clutter.ModifierType);
      return this._model.handleKey(key, this._pointer()) ? Clutter.EVENT_STOP : Clutter.EVENT_PROPAGATE;
    });
  }

  /** Below the anchor on its screen, kept on that screen (PopupPlacement, as on the Mac). */
  _place(anchor) {
    const {width, height} = this._model.size;
    const size = {width: width * this._scale, height: height * this._scale};
    const screen = PopupPlacement.screen(anchor, this._screens());
    const frame = screen ? PopupPlacement.below(anchor, size, screen.visibleFrame, GAP_BELOW * this._scale) : {x: anchor.x, y: anchor.y, ...size};
    this._frame = {x: Math.round(frame.x), y: Math.round(frame.y), width: Math.round(frame.width), height: Math.round(frame.height)};
    this._panel.set_position(this._frame.x, this._frame.y);
    this._panel.set_size(this._frame.width, this._frame.height);
  }

  _render() {
    if (!this._root) return;
    const results = this._model.results;
    this._list.destroy_all_children();
    this._rows.clear();
    results.forEach((item, index) => {
      const row = this._row(item, index);
      this._rows.set(item.id, row);
      this._list.add_child(row);
    });
    if (results.length === 0) {
      this._list.add_child(new St.Label({
        style_class: 'slated-clipboard-empty', text: this._model.isEmpty ? 'Nothing copied yet' : 'No matches',
        x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER, x_expand: true, height: this._px(PICKER.textRowHeight),
      }));
    }
    this._selectionMoved();
  }

  /** Moves the highlight to the selected row, scrolls it into view, and shows or hides the preview. */
  _selectionMoved() {
    if (!this._root) return;
    for (const [id, row] of this._rows) {
      if (id === this._model.selectedId) row.add_style_pseudo_class('selected');
      else row.remove_style_pseudo_class('selected');
    }
    this._scrollToSelection();
    this._updatePreview();
  }

  _app(id) {
    if (!this._apps.has(id)) this._apps.set(id, this._appInfo(id));
    return this._apps.get(id);
  }

  /**
   * Each files item's first file that's still there (one stat per file until one is), worked out
   * once while the picker is open: {path, info}, info null when they're all gone.
   */
  _fileState(item) {
    let state = this._fileStates.get(item.id);
    if (!state) {
      state = {path: item.files[0] ?? '', info: null};
      for (const path of item.files) {
        const info = this._files.describe(path);
        if (info) {
          state = {path, info};
          break;
        }
      }
      this._fileStates.set(item.id, state);
    }
    return state;
  }

  /**
   * One item on one line: its app's icon and text, an image's thumbnail and size (or name), or the
   * files' icon and names; a pin and the Ctrl-number at the end.
   */
  _row(item, index) {
    const image = item.image ?? null;
    const files = item.files ? this._fileState(item) : null;
    const missing = files !== null && files.info === null;
    const kind = image ? ' slated-clipboard-image-row' : files ? ' slated-clipboard-files-row' : '';
    const row = new St.Button({
      style_class: `slated-clipboard-row${kind}${missing ? ' slated-clipboard-missing' : ''}`,
      x_expand: true, can_focus: false, track_hover: true, height: this._px(rowHeight(item)),
    });
    const box = new St.BoxLayout({style_class: 'slated-clipboard-row-box', x_expand: true});
    const app = item.sourceApp ? this._app(item.sourceApp) : null;
    if (files) {
      // As on the Mac: the name shortened in the middle (so its extension shows), then "+ 2 more".
      const {name, more} = filesTitleParts(item.files);
      box.add_child(this._fileThumbnail(files));
      const line = new St.BoxLayout({style_class: 'slated-clipboard-files-line', x_expand: true});
      line.add_child(middleEllipsized(new St.Label({style_class: 'slated-clipboard-text', text: name, y_align: Clutter.ActorAlign.CENTER})));
      if (more) line.add_child(new St.Label({style_class: 'slated-clipboard-more', text: more, y_align: Clutter.ActorAlign.CENTER}));
      box.add_child(line);
      if (missing) box.add_child(new St.Label({style_class: 'slated-clipboard-missing-label', text: MISSING, y_align: Clutter.ActorAlign.CENTER}));
    } else if (image) {
      box.add_child(this._thumbnail(image));
      const title = new St.Label({
        style_class: 'slated-clipboard-text', text: imageTitle(image, app?.name ?? item.sourceApp ?? null), x_expand: true,
        y_align: Clutter.ActorAlign.CENTER,
      });
      // A file name keeps its extension in sight, as on the Mac.
      box.add_child(image.name ? middleEllipsized(title) : title);
    } else {
      const icon = app?.icon
        ? new St.Icon({gicon: app.icon, style_class: 'slated-clipboard-app-icon', y_align: Clutter.ActorAlign.CENTER})
        : new St.Icon({icon_name: 'edit-paste-symbolic', style_class: 'slated-clipboard-kind-icon', y_align: Clutter.ActorAlign.CENTER});
      box.add_child(icon);
      box.add_child(new St.Label({style_class: 'slated-clipboard-text', text: itemPreview(item.text), x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
    }
    if (item.pinned) box.add_child(new St.Icon({icon_name: 'view-pin-symbolic', style_class: 'slated-clipboard-pin', y_align: Clutter.ActorAlign.CENTER}));
    const number = this._model.number(index);
    if (number !== null) box.add_child(new St.Label({style_class: 'slated-clipboard-number', text: `Ctrl+${number}`, y_align: Clutter.ActorAlign.CENTER}));
    row.set_child(box);
    row.connect('clicked', () => this._model.paste(item.id));
    row.connect('notify::hover', () => {
      if (row.hover) this._model.hover(item.id, this._pointer());
    });
    return row;
  }

  /**
   * A row's thumbnail: the image aspect-fit in a box of its shape, 28 px tall. A file icon, which
   * St decodes at that size off the main thread and keeps (small, and the file's name is its
   * content's hash); the box clips the square icon to the image.
   */
  _thumbnail(image) {
    const width = thumbnailWidth(image);
    const height = PICKER.thumbnailHeight;
    const bin = new St.Bin({
      style_class: 'slated-clipboard-thumbnail', width: this._px(width), height: this._px(height), clip_to_allocation: true,
      y_align: Clutter.ActorAlign.CENTER,
    });
    const path = this._imagePath(image);
    bin.set_child(
      path
        ? new St.Icon({
          gicon: new Gio.FileIcon({file: Gio.File.new_for_path(path)}), icon_size: Math.max(width, height),
          x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER,
        })
        : this._placeholder());
    return bin;
  }

  /**
   * A files row's thumbnail, 16×20 like the Mac's: the thumbnail GNOME already made of the first
   * file, else the icon for its type (from its name, nothing read), else a dimmed generic file for
   * files that are gone. Either fits the 16 px width.
   */
  _fileThumbnail({path, info}) {
    const {width, height} = PICKER.fileThumbnail;
    const bin = new St.Bin({
      style_class: 'slated-clipboard-thumbnail slated-clipboard-file-thumbnail', width: this._px(width), height: this._px(height),
      clip_to_allocation: true, y_align: Clutter.ActorAlign.CENTER, opacity: info ? 255 : 128,
    });
    const thumbnail = info && !info.isDirectory ? this._files.thumbnail(path, 128) : null;
    const gicon = thumbnail
      ? new Gio.FileIcon({file: Gio.File.new_for_path(thumbnail)})
      : this._files.icon(info?.contentType ?? 'application/octet-stream');
    bin.set_child(new St.Icon({gicon, icon_size: width, x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER}));
    return bin;
  }

  /**
   * The selected image at preview size, decoded off the main thread at that size and not kept
   * (St.TextureCache.load_file_async): one at a time, and a history can hold many screenshots.
   */
  _previewImage(image) {
    return this._previewPicture(this._imagePath(image), image);
  }

  /** A picture file (`path`, null when it's gone) fitted to the preview by its pixel size (`shape`). */
  _previewPicture(path, shape) {
    const {width, height} = previewImageSize(shape);
    const bin = new St.Bin({
      style_class: 'slated-clipboard-preview-image', width: this._px(width), height: this._px(height), x_align: Clutter.ActorAlign.CENTER,
    });
    let actor = null;
    if (path) {
      try {
        actor = St.TextureCache.get_default().load_file_async(
          Gio.File.new_for_path(path), width, height, this._scale, this._panel?.get_resource_scale?.() ?? 1);
        actor.set_size(this._px(width), this._px(height));
        actor.content_gravity = Clutter.ContentGravity.RESIZE_ASPECT;
      } catch {
        actor = null;
      }
    }
    bin.set_child(actor ?? this._placeholder());
    return bin;
  }

  _caption(text, styleClass = 'slated-clipboard-preview-caption') {
    return new St.Label({style_class: styleClass, text, x_align: Clutter.ActorAlign.CENTER, height: this._px(PREVIEW.captionHeight)});
  }

  /** A copied image's preview: the image and "1280×720 · 245 kB". */
  _imagePreview(image) {
    const actor = new St.BoxLayout({style_class: 'slated-clipboard-preview', vertical: true, reactive: true});
    actor.add_child(this._previewImage(image));
    actor.add_child(this._caption(imageDetails(image)));
    return {actor, size: previewSize(image)};
  }

  /**
   * Copied files' preview, for the first one still there: an image file shown fitted (GNOME's large
   * thumbnail of it when there is one), another file's thumbnail (a PDF's first page, a video's
   * frame) or else its icon; then its name ("+ 2 more") and its size and kind. None when all are gone.
   */
  _filesPreview(item) {
    const {path, info} = this._fileState(item);
    if (!info) return null;
    const thumbnail = info.isDirectory ? null : this._files.thumbnail(path, PREVIEW.maxSide);
    const original = info.isDirectory ? null : this._files.imageSize(path);
    const shape = original ?? (thumbnail ? this._files.imageSize(thumbnail) : null);
    const actor = new St.BoxLayout({style_class: 'slated-clipboard-preview slated-clipboard-file-preview', vertical: true, reactive: true});
    if (shape) actor.add_child(this._previewPicture(thumbnail ?? path, shape));
    else {
      actor.add_child(new St.Icon({
        gicon: this._files.icon(info.contentType), icon_size: PREVIEW.iconSize, style_class: 'slated-clipboard-preview-icon',
        x_align: Clutter.ActorAlign.CENTER,
      }));
    }
    actor.add_child(this._caption(filesTitle(item.files), 'slated-clipboard-preview-name'));
    actor.add_child(this._caption(fileDetails({size: info.size, kind: this._files.kind(info.contentType)})));
    return {actor, size: filePreviewSize(shape)};
  }

  /** Stands in for an image whose file is gone. */
  _placeholder() {
    return new St.Icon({icon_name: 'image-x-generic-symbolic', style_class: 'slated-clipboard-image-placeholder'});
  }

  /** Keeps the selected row in view, using the rows' known heights (they may not be laid out yet). */
  _scrollToSelection() {
    const top = this._model.rowTop(this._model.selectedId);
    const adjustment = this._scroll?.vadjustment;
    if (top === null || !adjustment || !(adjustment.page_size > 0)) return;
    const item = this._model.selectedItem;
    const y1 = this._px(PICKER.listPadding + top);
    const y2 = y1 + this._px(rowHeight(item));
    const padding = this._px(PICKER.listPadding);
    if (y1 - padding < adjustment.value) adjustment.value = Math.max(y1 - padding, 0);
    else if (y2 + padding > adjustment.value + adjustment.page_size) adjustment.value = y2 + padding - adjustment.page_size;
  }

  /** The selected row's frame on the stage. */
  _rowFrame() {
    const top = this._model.rowTop(this._model.selectedId);
    if (top === null || !this._frame) return this._frame;
    const offset = PICKER.filterHeight + PICKER.hairline + PICKER.listPadding + top;
    return {
      x: this._frame.x + this._px(PICKER.listPadding),
      y: this._frame.y + this._px(offset) - (this._scroll?.vadjustment?.value ?? 0),
      width: this._frame.width - this._px(2 * PICKER.listPadding),
      height: this._px(rowHeight(this._model.selectedItem)),
    };
  }

  /** Shows the selected image or files larger beside the picker, level with its row, or hides the preview. */
  _updatePreview() {
    const item = this._frame ? this._model.previewItem : null;
    const key = item ? (item.image ? `image:${item.image.file}` : `files:${item.id}`) : null;
    if (key !== this._previewKey) {
      this._preview?.destroy();
      this._preview = null;
      this._previewKey = key;
      const built = item ? (item.image ? this._imagePreview(item.image) : this._filesPreview(item)) : null;
      if (built) {
        this._preview = built.actor;
        this._previewSize = built.size;
        this._root.add_child(this._preview);
      }
    }
    if (!this._preview) return;
    const {width, height} = this._previewSize;
    const size = {width: this._px(width), height: this._px(height)};
    const visible = PopupPlacement.screen(this._frame, this._screens())?.visibleFrame ?? this._frame;
    const frame = PopupPlacement.beside(this._frame, this._rowFrame(), size, visible, GAP_BESIDE * this._scale);
    this._preview.set_position(Math.round(frame.x), Math.round(frame.y));
    this._preview.set_size(size.width, size.height);
  }
}
