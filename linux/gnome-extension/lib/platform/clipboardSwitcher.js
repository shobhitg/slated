// The clipboard history switcher (Keyboard Maestro's clipboard switcher): a modal panel with a search
// field and the history, numbered and keyboard-first. A port of the macOS ClipboardSwitcherModel
// (Sources/SlatedUI/Clipboard/ClipboardSwitcher.swift), drawn with St like the other overlays.
//
//   ↑↓ select · ↩ paste into the window you were in · Ctrl+1–9 paste that item · Ctrl+C copy only
//   Ctrl+P pin · Ctrl+Backspace (or Delete) delete · Ctrl+Shift+Backspace clear unpinned · Esc close
//
// `SwitcherModel` and `switcherKey` are pure (tested in Node); `ClipboardSwitcher` is the St view.

import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {referenceToMilliseconds} from '../core/index.js';

const PREVIEW_LIMIT = 240;
/** How much of each item the switcher searches as you type (huge copies stay responsive). */
export const SEARCH_LIMIT = 20_000;

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

/** "12 characters" or "3 lines". */
export function lengthDescription(text) {
  const lines = String(text)
    .split(/\r\n|[\n\r\v\f\u{85}\u{2028}\u{2029}]/u)
    .filter((line) => line !== '').length;
  if (lines > 1) return `${lines} lines`;
  let characters = 0;
  for (const _ of String(text)) characters++;
  return `${characters} characters`;
}

/** "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago". */
export function relativeTime(copiedAt, nowMs = Date.now()) {
  const seconds = Math.max(0, (nowMs - referenceToMilliseconds(copiedAt)) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  const days = Math.floor(seconds / 86_400);
  return days === 1 ? 'yesterday' : `${days} days ago`;
}

// Keysyms (X11 keysymdef.h) and the hardware keycodes (evdev + 8) of the keys the switcher handles,
// so Ctrl+1 works on AZERTY (where the key types "&") and Ctrl+C on non-Latin layouts.
const KEYSYM_NAMES = {
  0xff52: 'Up', 0xff54: 'Down', 0xff55: 'Page_Up', 0xff56: 'Page_Down', 0xff0d: 'Return', 0xff8d: 'Return',
  0xff1b: 'Escape', 0xff08: 'BackSpace', 0xffff: 'Delete', 0xff9f: 'Delete',
};
const DIGIT_KEYCODES = {10: '1', 11: '2', 12: '3', 13: '4', 14: '5', 15: '6', 16: '7', 17: '8', 18: '9'};
const LETTER_KEYCODES = {54: 'c', 33: 'p'};

/**
 * What a key press means to the switcher: {name, ctrl, shift}. `name` is "Up", "Return", "Escape",
 * "BackSpace", "Delete", a digit "1"–"9", a lowercase letter, or null. `masks` holds Clutter's
 * CONTROL_MASK and SHIFT_MASK (passed in so this stays free of gi:// imports).
 */
export function switcherKey(keysym, keycode, state, masks) {
  const ctrl = Boolean(state & masks.CONTROL_MASK);
  const shift = Boolean(state & masks.SHIFT_MASK);
  let name = KEYSYM_NAMES[keysym] ?? null;
  if (name === null && keysym >= 0xffb1 && keysym <= 0xffb9) name = String(keysym - 0xffb0); // keypad digits
  if (name === null && keysym >= 0x20 && keysym < 0x7f) name = String.fromCharCode(keysym).toLowerCase();
  if (ctrl && (name === null || !/^[1-9cp]$/.test(name))) name = DIGIT_KEYCODES[keycode] ?? LETTER_KEYCODES[keycode] ?? name;
  return {name, ctrl, shift};
}

/**
 * The switcher's state: the query, its results (pinned first, newest first) and the selection.
 * `actions` carries out what the user picks: paste(id), copy(id), togglePin(id), delete(id), clear(),
 * close().
 */
export class SwitcherModel {
  constructor({history, actions}) {
    this._history = history;
    this._actions = actions;
    this.query = '';
    this.selectedId = null;
    /** Called with "results" (redraw the list) or "selection" (only the highlight moved). */
    this.onChange = null;
  }

  get results() {
    return this._history().search(this.query, {maxCharacters: SEARCH_LIMIT});
  }

  get isEmpty() {
    return this._history().items.length === 0;
  }

  reset() {
    this.query = '';
    this.selectedId = this.results[0]?.id ?? null;
    this.onChange?.('results');
  }

  setQuery(query) {
    this.query = String(query ?? '');
    this.selectedId = this.results[0]?.id ?? null;
    this.onChange?.('results');
  }

  /** The history changed underneath (a copy arrived): keeps the selection when it's still there. */
  refresh() {
    const list = this.results;
    if (!list.some((item) => item.id === this.selectedId)) this.selectedId = list[0]?.id ?? null;
    this.onChange?.('results');
  }

  select(id) {
    if (this.selectedId === id) return;
    this.selectedId = id;
    this.onChange?.('selection');
  }

  move(delta) {
    const list = this.results;
    if (list.length === 0) return;
    const current = list.findIndex((item) => item.id === this.selectedId);
    const index = Math.min(Math.max((current < 0 ? -1 : current) + delta, 0), list.length - 1);
    this.select(list[index].id);
  }

  close() {
    this._actions.close();
  }

  paste(id = this.selectedId) {
    if (!id) return;
    this._actions.close();
    this._actions.paste(id);
  }

  copy(id = this.selectedId) {
    if (!id) return;
    this._actions.close();
    this._actions.copy(id);
  }

  /** Ctrl+1–9: pastes the n-th result. */
  pick(number) {
    const list = this.results;
    if (number >= 1 && number <= list.length) this.paste(list[number - 1].id);
  }

  togglePin(id = this.selectedId) {
    if (!id) return;
    this._actions.togglePin(id);
    this.onChange?.('results');
  }

  delete(id = this.selectedId) {
    if (!id) return;
    const index = Math.max(this.results.findIndex((item) => item.id === id), 0);
    this._actions.delete(id);
    const remaining = this.results;
    this.selectedId = remaining.length === 0 ? null : remaining[Math.min(index, remaining.length - 1)].id;
    this.onChange?.('results');
  }

  clear() {
    this._actions.clear();
    this.selectedId = this.results[0]?.id ?? null;
    this.onChange?.('results');
  }

  /** Handles a key press ({name, ctrl, shift} from `switcherKey`); false lets the search field have it. */
  handleKey({name, ctrl = false, shift = false}) {
    switch (name) {
      case 'Up': this.move(-1); return true;
      case 'Down': this.move(1); return true;
      case 'Page_Up': this.move(-5); return true;
      case 'Page_Down': this.move(5); return true;
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
    if (name === 'c') {
      this.copy();
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
}

// --- The panel -------------------------------------------------------------------------------------

const PANEL_WIDTH = 600;
const PANEL_HEIGHT = 460;
const HINTS = '↩ Paste   Ctrl+1–9 Pick   Ctrl+C Copy   Ctrl+P Pin   Ctrl+⌫ Delete   Ctrl+Shift+⌫ Clear   Esc Close';

export class ClipboardSwitcher {
  /**
   * @param {object} options
   * @param {SwitcherModel} options.model
   * @param {object} [options.log]
   * @param {() => number} [options.now]  Milliseconds, for "5 min ago".
   * @param {(id: string|null) => string} [options.appName]  A source app's name for its id.
   */
  constructor({model, log = null, now = () => Date.now(), appName = (id) => id ?? ''}) {
    this._model = model;
    this._log = log;
    this._now = now;
    this._appName = appName;
    this._root = null;
    this._grab = null;
    this._rows = new Map();
    model.onChange = (what) => (what === 'selection' ? this._highlight() : this._render());
  }

  get isOpen() {
    return this._root !== null;
  }

  open() {
    this.close();
    this._model.reset();
    this._build();
    this._grab = Main.pushModal(this._root, {actionMode: Shell.ActionMode.SYSTEM_MODAL});
    if (this._grab.get_seat_state() !== Clutter.GrabState.ALL) {
      this._log?.record('clipboard.grab_failed', {}, 'error');
      this.close();
      return false;
    }
    this._entry.clutter_text.grab_key_focus();
    this._render();
    this._root.ease({opacity: 255, duration: 120, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
    return true;
  }

  close() {
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
  }

  /** The history changed while open (a copy arrived): redraw. */
  refresh() {
    if (this.isOpen) this._model.refresh();
  }

  destroy() {
    this.close();
    this._model.onChange = null;
  }

  _build() {
    this._root = new St.Widget({
      style_class: 'slated-overlay', reactive: true, can_focus: true, x: 0, y: 0,
      width: global.stage.width, height: global.stage.height, opacity: 0,
    });
    Main.layoutManager.addTopChrome(this._root);
    this._root.connect('button-press-event', (_actor, event) => {
      if (global.stage.get_event_actor(event) === this._root) this._model.close();
      return Clutter.EVENT_STOP;
    });

    const monitor = global.display.get_current_monitor?.() ?? Main.layoutManager.primaryIndex;
    const area = Main.layoutManager.getWorkAreaForMonitor(monitor);
    const panel = new St.BoxLayout({
      style_class: 'slated-clipboard-panel', vertical: true, reactive: true, width: PANEL_WIDTH, height: PANEL_HEIGHT,
      x: Math.round(area.x + (area.width - PANEL_WIDTH) / 2),
      y: Math.round(area.y + (area.height - PANEL_HEIGHT) / 2 - area.height * 0.1),
    });
    this._root.add_child(panel);

    const header = new St.BoxLayout({style_class: 'slated-clipboard-header'});
    header.add_child(new St.Icon({icon_name: 'edit-paste-symbolic', style_class: 'slated-clipboard-icon', y_align: Clutter.ActorAlign.CENTER}));
    this._entry = new St.Entry({style_class: 'slated-clipboard-search', hint_text: 'Search clipboard history', can_focus: true, x_expand: true});
    header.add_child(this._entry);
    this._count = new St.Label({style_class: 'slated-clipboard-count', y_align: Clutter.ActorAlign.CENTER});
    header.add_child(this._count);
    panel.add_child(header);

    this._list = new St.BoxLayout({style_class: 'slated-clipboard-list', vertical: true, x_expand: true});
    this._scroll = new St.ScrollView({style_class: 'slated-clipboard-scroll', x_expand: true, y_expand: true});
    this._scroll.set_child(this._list);
    panel.add_child(this._scroll);
    this._empty = new St.Label({style_class: 'slated-clipboard-empty', x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER, x_expand: true, y_expand: true});
    panel.add_child(this._empty);
    panel.add_child(new St.Label({style_class: 'slated-clipboard-hints', text: HINTS}));

    const text = this._entry.clutter_text;
    text.connect('text-changed', () => this._model.setQuery(this._entry.get_text()));
    text.connect('key-press-event', (_actor, event) => {
      const key = switcherKey(event.get_key_symbol(), event.get_key_code(), event.get_state(), Clutter.ModifierType);
      return this._model.handleKey(key) ? Clutter.EVENT_STOP : Clutter.EVENT_PROPAGATE;
    });
  }

  _render() {
    if (!this._root) return;
    const results = this._model.results;
    this._count.text = String(results.length);
    this._list.destroy_all_children();
    this._rows.clear();
    results.forEach((item, index) => {
      const row = this._row(item, index);
      this._rows.set(item.id, row);
      this._list.add_child(row);
    });
    const empty = results.length === 0;
    this._scroll.visible = !empty;
    this._empty.visible = empty;
    this._empty.text = this._model.isEmpty ? 'Nothing copied yet. Copy something and it shows up here.' : 'No matches. Try fewer or different words.';
    this._highlight();
  }

  /** Moves the highlight to the selected row and scrolls it into view. */
  _highlight() {
    if (!this._root) return;
    for (const [id, row] of this._rows) {
      if (id === this._model.selectedId) row.add_style_pseudo_class('selected');
      else row.remove_style_pseudo_class('selected');
    }
    const selected = this._rows.get(this._model.selectedId);
    if (selected) this._scrollTo(selected);
  }

  _row(item, index) {
    const row = new St.Button({style_class: 'slated-clipboard-row', x_expand: true, can_focus: false, track_hover: true});
    const box = new St.BoxLayout({x_expand: true});
    const texts = new St.BoxLayout({vertical: true, x_expand: true});
    texts.add_child(new St.Label({style_class: 'slated-clipboard-text', text: itemPreview(item.text)}));
    const meta = [item.pinned ? 'Pinned' : null, relativeTime(item.copiedAt, this._now()), lengthDescription(item.text), item.sourceApp ? this._appName(item.sourceApp) : null];
    texts.add_child(new St.Label({style_class: 'slated-clipboard-meta', text: meta.filter(Boolean).join(' · ')}));
    box.add_child(texts);
    if (index < 9) box.add_child(new St.Label({style_class: 'slated-clipboard-number', text: `Ctrl+${index + 1}`, y_align: Clutter.ActorAlign.CENTER}));
    row.set_child(box);
    row.connect('clicked', () => this._model.paste(item.id));
    row.connect('notify::hover', () => {
      if (row.hover && this._model.selectedId !== item.id) this._model.select(item.id);
    });
    return row;
  }

  _scrollTo(row) {
    try {
      const adjustment = this._scroll.vadjustment ?? this._scroll.get_vscroll_bar?.()?.get_adjustment?.();
      if (!adjustment) return;
      const box = row.get_allocation_box();
      if (box.y1 < adjustment.value) adjustment.value = box.y1;
      else if (box.y2 > adjustment.value + adjustment.page_size) adjustment.value = box.y2 - adjustment.page_size;
    } catch {
      // Not laid out yet: the first rows are visible anyway.
    }
  }
}
