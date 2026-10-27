// Clipboard history on GNOME: records copies, keeps them private, and pastes a picked item back into
// the window you were using. A port of the macOS ClipboardService
// (Sources/Slated/Engine/ClipboardService.swift); the history itself is the core's ClipboardHistory.
//
// - Copies: GNOME Shell's Meta.Selection reports every new clipboard owner; the text is read through
//   St.Clipboard. Skipped: copies whose MIME types include `x-kde-passwordManagerHint` (KeePassXC and
//   other password managers mark secrets that way) when `ignoreConcealed` is on, copies made in
//   `excludedApps`, and Slated's own writes (insert-text's temporary paste, the switcher's picks).
// - Saving: `$XDG_STATE_HOME/slated/clipboard.json`, mode 0600, in the Mac app's format, a second
//   after the last change; deleted when `persist` is turned off.
// - The log records counts, lengths and app ids, never the text.

import Meta from 'gi://Meta';
import St from 'gi://St';

import * as Core from '../core/index.js';

import {ClipboardSwitcher, SwitcherModel} from './clipboardSwitcher.js';
import {readText, remove, writePrivateTextAtomic} from './files.js';
import {Debouncer} from './timers.js';
import {appMatchesAny} from './util.js';

/** What password managers put on the clipboard alongside a secret (KDE's convention, used by KeePassXC). */
export const CONCEALED_MIME_TYPES = Object.freeze(['x-kde-passwordManagerHint']);

/** How long Slated waits for the window it re-focuses before pressing Ctrl+V. */
const PASTE_DELAY_MS = 150;
/** How long a write of Slated's own is remembered, to skip it when it shows up as a copy. */
const OWN_WRITE_MS = 3000;

export function defaultClipboardSettings() {
  return {
    enabled: true, shortcut: 'shift+cmd+v', maxItems: 200, persist: true, retentionDays: 30, ignoreConcealed: true,
    excludedApps: [], pasteAfterSelecting: true,
  };
}

/** The line count the log records for a copy (Swift's `split(whereSeparator: \.isNewline).count`). */
export function lineCount(text) {
  return String(text)
    .split(/\r\n|[\n\r\v\f\u{85}\u{2028}\u{2029}]/u)
    .filter((line) => line !== '').length;
}

export class ClipboardService {
  /**
   * @param {object} options
   * @param {object} options.timers   timers.js `Timers`.
   * @param {object} [options.log]
   * @param {string} options.path      Where history is saved (paths.clipboardPath()).
   * @param {object} options.focus     {window(), app(), activate(window), isAlive(window)}: the focused
   *                                   window and app (util.appIdentity), and bringing a window back.
   * @param {object} options.input     input.js `InputInjector` (`pasteShortcut()`).
   * @param {() => number} [options.now]  Milliseconds since 1970.
   * @param {(model: SwitcherModel) => object} [options.makeSwitcher]  The St panel (tests pass a fake).
   */
  constructor({timers, log = null, path, focus, input, now = () => Date.now(), makeSwitcher = null}) {
    this._timers = timers;
    this._log = log;
    this._path = path;
    this._focus = focus;
    this._input = input;
    this._now = now;
    this.settings = defaultClipboardSettings();
    this.history = new Core.ClipboardHistory();
    /** History or settings changed (status.json refreshes). */
    this.onChange = null;
    this._selection = null;
    this._ownerChanged = 0;
    this._ownWrites = [];
    this._previous = null;
    this._stopped = false;
    this._loaded = false;
    this._saver = new Debouncer(timers, 1000, () => this._saveNow());
    this._model = new SwitcherModel({
      history: () => this.history,
      actions: {
        paste: (id) => this.paste(id),
        copy: (id) => this.copy(id),
        togglePin: (id) => this.togglePin(id),
        delete: (id) => this.delete(id),
        clear: () => this.clear(),
        close: () => this._switcher?.close(),
      },
    });
    this._makeSwitcher = makeSwitcher ?? ((model) => new ClipboardSwitcher({model, log, now}));
    this._switcher = null;
  }

  get count() {
    return this.history.items.length;
  }

  get isWatching() {
    return this._selection !== null;
  }

  /** Applies `clipboard` settings from config.json (also the first time: loads saved history). */
  apply(settings) {
    const next = {...defaultClipboardSettings(), ...(settings ?? {})};
    const changed = JSON.stringify(next) !== JSON.stringify(this.settings) || !this._loaded;
    this.settings = next;
    if (!this._loaded) {
      this._loaded = true;
      if (next.persist) this._load();
    }
    if (next.enabled) this._watch();
    else this._unwatch();
    this.history.enforce(next.maxItems);
    this.history.prune(next.retentionDays, Core.referenceSeconds(this._now()));
    if (next.persist) {
      this._saver.trigger();
    } else {
      this._saver.cancel();
      if (remove(this._path)) this._log?.record('clipboard.forgotten', {reason: 'persist is off'});
    }
    if (changed) {
      this._log?.record('clipboard.settings', {enabled: next.enabled, persist: next.persist, maxItems: next.maxItems, items: this.count});
    }
    this._switcher?.refresh();
  }

  /** Stops watching and saves now (disable, screen lock). */
  stop() {
    this._unwatch();
    this._switcher?.destroy();
    this._switcher = null;
    if (this.settings.persist && this._loaded) this._saveNow();
    this._saver.cancel();
    this._stopped = true;
  }

  /** Remembers that Slated itself put `text` on the clipboard, so it isn't recorded as a copy. */
  markOwnWrite(text) {
    const now = this._now();
    this._ownWrites = this._ownWrites.filter((w) => w.expires > now);
    this._ownWrites.push({text, expires: now + OWN_WRITE_MS});
  }

  // --- Recording -------------------------------------------------------------------------------------

  _watch() {
    if (this._selection) return;
    this._selection = global.display.get_selection();
    this._ownerChanged = this._selection.connect('owner-changed', (_selection, type) => {
      if (type === Meta.SelectionType.SELECTION_CLIPBOARD) this._copied();
    });
  }

  _unwatch() {
    if (!this._selection) return;
    this._selection.disconnect(this._ownerChanged);
    this._selection = null;
    this._ownerChanged = 0;
  }

  /** A new clipboard owner: decide whether to keep it before reading anything. */
  _copied() {
    if (!this.settings.enabled || this._stopped) return;
    let mimeTypes = [];
    try {
      mimeTypes = this._selection?.get_mimetypes(Meta.SelectionType.SELECTION_CLIPBOARD) ?? [];
    } catch {
      mimeTypes = [];
    }
    const app = this._safeApp();
    if (this.settings.ignoreConcealed && mimeTypes.some((type) => CONCEALED_MIME_TYPES.includes(type))) {
      this._log?.record('clipboard.skipped', {reason: 'concealed', app: app?.id ?? 'unknown'}, 'debug');
      return;
    }
    if (app && appMatchesAny(app, this.settings.excludedApps)) {
      this._log?.record('clipboard.skipped', {reason: 'excluded app', app: app.id}, 'debug');
      return;
    }
    St.Clipboard.get_default().get_text(St.ClipboardType.CLIPBOARD, (_clipboard, text) => this._record(text, app));
  }

  _record(text, app) {
    if (this._stopped || !this.settings.enabled || typeof text !== 'string') return;
    if (this._takeOwnWrite(text)) return;
    if (!this.history.add(text, {app: app?.id ?? null, at: Core.referenceSeconds(this._now()), limit: this.settings.maxItems})) return;
    this._log?.record('clipboard.captured', {chars: [...text].length, lines: lineCount(text), app: app?.id ?? 'unknown', items: this.count});
    this._changed();
  }

  _takeOwnWrite(text) {
    const now = this._now();
    this._ownWrites = this._ownWrites.filter((w) => w.expires > now);
    const index = this._ownWrites.findIndex((w) => w.text === text);
    if (index < 0) return false;
    this._ownWrites.splice(index, 1);
    return true;
  }

  _safeApp() {
    try {
      return this._focus.app();
    } catch {
      return null;
    }
  }

  // --- The switcher ----------------------------------------------------------------------------------

  /** Opens the switcher. Returns {ok, error}. */
  showSwitcher() {
    if (!this.settings.enabled) {
      this._log?.record('clipboard.switcher_unavailable', {reason: 'clipboard history is off'}, 'notice');
      return {ok: false, error: 'Clipboard history is turned off (clipboard.enabled)'};
    }
    let window = null;
    try {
      window = this._focus.window();
    } catch {
      window = null;
    }
    this._previous = {window, app: this._safeApp()};
    this._switcher ??= this._makeSwitcher(this._model);
    if (this._switcher.open() === false) return {ok: false, error: "Couldn't open the clipboard switcher"};
    this._log?.record('clipboard.switcher_opened', {items: this.count});
    return {ok: true};
  }

  get switcherModel() {
    return this._model;
  }

  /** Puts the item on the clipboard and, when `pasteAfterSelecting`, pastes it into the previous window. */
  paste(id) {
    const item = this.history.items.find((i) => i.id === id);
    if (!item) return;
    const chars = [...item.text].length;
    this._put(item);
    const target = this._previous;
    if (!this.settings.pasteAfterSelecting) {
      this._log?.record('clipboard.copied', {chars});
      return;
    }
    this._refocus(target);
    this._timers.timeout(PASTE_DELAY_MS, () => {
      if (this._stopped) return;
      const result = this._input.pasteShortcut();
      if (result?.ok === false) this._log?.error('clipboard.paste_failed', result.error ?? "Couldn't press the paste shortcut");
    });
    this._log?.record('clipboard.pasted', {chars, app: target?.app?.id ?? 'unknown'});
  }

  /** Puts the item on the clipboard without pasting. */
  copy(id) {
    const item = this.history.items.find((i) => i.id === id);
    if (!item) return;
    this._put(item);
    this._refocus(this._previous);
    this._log?.record('clipboard.copied', {chars: [...item.text].length});
  }

  delete(id) {
    this.history.remove(id);
    this._log?.record('clipboard.deleted', {items: this.count});
    this._changed();
  }

  togglePin(id) {
    this.history.togglePin(id);
    this._log?.record('clipboard.pin_toggled', {pinned: this.history.items.find((i) => i.id === id)?.pinned ?? false});
    this._changed();
  }

  /** Forgets everything but pinned items. */
  clear() {
    this.history.clear({keepPinned: true});
    this._log?.record('clipboard.cleared', {kept: this.count});
    this._changed();
  }

  /** Writes the item to the clipboard and moves it to the top, without recording the write as a copy. */
  _put(item) {
    this.markOwnWrite(item.text);
    St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, item.text);
    this.history.add(item.text, {app: item.sourceApp, at: Core.referenceSeconds(this._now()), limit: this.settings.maxItems});
    this._changed();
  }

  _refocus(target) {
    const window = target?.window;
    if (!window) return;
    try {
      if (this._focus.isAlive(window) && this._focus.window() !== window) this._focus.activate(window);
    } catch {
      // The window went away: paste where the focus is.
    }
  }

  // --- Persistence -----------------------------------------------------------------------------------

  _changed() {
    if (this.settings.persist) this._saver.trigger();
    this._switcher?.refresh();
    this.onChange?.();
  }

  _load() {
    const text = readText(this._path);
    if (text === null) return;
    try {
      this.history = Core.ClipboardHistory.fromJSON(JSON.parse(text));
      this._log?.record('clipboard.loaded', {items: this.count});
    } catch (e) {
      this._log?.error('clipboard.load_failed', `Couldn't read the saved clipboard history: ${e?.message ?? e}`, {path: this._path});
    }
  }

  _saveNow() {
    if (!this.settings.persist) return;
    try {
      writePrivateTextAtomic(this._path, `${JSON.stringify(this.history.toJSON())}\n`);
    } catch (e) {
      this._log?.error('clipboard.save_failed', e?.message ?? String(e), {path: this._path});
    }
  }
}
