// Clipboard history on GNOME: records copies of text and images, keeps them private, and pastes a
// picked item back into the window you were using. A port of the macOS ClipboardService
// (Sources/Slated/Engine/ClipboardService.swift); the history itself is the core's ClipboardHistory.
//
// - Copies: GNOME Shell's Meta.Selection reports every new clipboard owner; the text is read through
//   St.Clipboard. A copy without text that offers `image/png` (a screenshot, a browser's Copy Image)
//   is an image: its bytes are stored in `clipboard-images/` beside the history (clipboardImages.js)
//   and deleted when its item goes. A copy with text and a picture of it (spreadsheet cells) counts
//   as text, as on the Mac. Skipped: copies whose MIME types include `x-kde-passwordManagerHint` (KeePassXC,
//   Firefox and other password managers mark secrets that way) when `ignoreConcealed` is on, copies
//   made in `excludedApps`, and Slated's own writes (insert-text's temporary paste, the switcher's
//   picks). Chrome and other Chromium browsers mark copied passwords on macOS but not on Linux, so
//   with `ignoreConcealed` on, a copy from one of them that looks like a password is skipped too.
// - Saving: `$XDG_STATE_HOME/slated/clipboard.json`, mode 0600, in the Mac app's format, a second
//   after the last change; deleted when `persist` is turned off (and its images when Slated stops).
//   Unpinned items older than `retentionDays` are forgotten when settings are applied and with every
//   new copy.
// - The picker (clipboardPicker.js) opens below the text cursor when the input method knows where it
//   is (caret.js), else at the pointer.
// - The log records counts, lengths, image sizes and app ids, never the text or the image, and which
//   anchor placed the picker, never where.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import St from 'gi://St';

import * as Core from '../core/index.js';

import {CaretTracker} from './caret.js';
import {ClipboardImageStore, imageMimeType} from './clipboardImages.js';
import {ClipboardPicker, PickerModel} from './clipboardPicker.js';
import {readText, remove, writePrivateTextAtomic} from './files.js';
import {currentScreens} from './screens.js';
import {Debouncer} from './timers.js';
import {appMatchesAny, dirname} from './util.js';

/** What password managers put on the clipboard alongside a secret (KDE's convention, used by KeePassXC). */
export const CONCEALED_MIME_TYPES = Object.freeze(['x-kde-passwordManagerHint']);

/**
 * Browsers whose password managers copy passwords without that hint on Linux: Chrome and the other
 * Chromium browsers, as native packages and Flatpaks (desktop ids or WM_CLASS).
 */
export const UNMARKED_PASSWORD_APPS = Object.freeze([
  'google-chrome', 'google-chrome-beta', 'google-chrome-unstable', 'com.google.Chrome', 'chromium',
  'chromium-browser', 'chromium_chromium', 'org.chromium.Chromium', 'brave-browser', 'com.brave.Browser',
  'microsoft-edge', 'com.microsoft.Edge', 'vivaldi-stable', 'com.vivaldi.Vivaldi', 'opera', 'com.opera.Opera',
]);

/**
 * Whether `text` looks like a password rather than something you'd want in your history: one word
 * of 8–128 characters with both lowercase and uppercase letters plus a digit or symbol (as every
 * browser-generated password has), and not a link or an email address. Lowercase-only technical text
 * ("factorio-2.0.32", "user_name2") doesn't count. Used only for copies from
 * `UNMARKED_PASSWORD_APPS`, where a false alarm just leaves an item out of the history (pasting it
 * still works).
 */
export function looksLikePassword(text) {
  const s = String(text ?? '');
  const length = [...s].length;
  if (length < 8 || length > 128 || /\s/u.test(s)) return false;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s) || /^www\./i.test(s)) return false;
  if (/^[^@]+@[^@]+\.[a-z]{2,}$/i.test(s)) return false;
  return /\p{Ll}/u.test(s) && /\p{Lu}/u.test(s) && /[^\p{L}]/u.test(s);
}

/** How long Slated waits for the window it re-focuses before pressing Ctrl+V. */
const PASTE_DELAY_MS = 150;
/** How long a write of Slated's own is remembered, to skip it when it shows up as a copy. */
const OWN_WRITE_MS = 3000;
/** The image type GNOME apps put on the clipboard (and the only one recorded). */
const PNG = 'image/png';

/** What the log says about an item: its length, or an image's size and dimensions. Never content. */
function logFields(item) {
  if (!item.image) return {chars: [...item.text].length};
  return {kind: 'image', bytes: item.image.bytes, width: item.image.width, height: item.image.height};
}

/** A GLib.Bytes (or a Uint8Array) as a Uint8Array; null when there's nothing. */
function bytesOf(content) {
  if (!content) return null;
  if (content instanceof Uint8Array) return content;
  try {
    return content.get_data?.() ?? content.toArray?.() ?? null;
  } catch {
    return null;
  }
}

const pointerLocation = () => {
  const [x, y] = global.get_pointer();
  return [x, y];
};

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
   * @param {string} [options.imagesDirectory]  Copied images (default: `clipboard-images` beside `path`).
   * @param {object} [options.caret]  caret.js `CaretTracker`: where the text cursor is.
   * @param {() => object[]} [options.screens]  The displays (screens.js `currentScreens`).
   * @param {() => number[]} [options.pointer]  The pointer's [x, y].
   * @param {(model: PickerModel, service: ClipboardService) => object} [options.makeSwitcher]  The St
   *   picker (tests pass a fake).
   */
  constructor({
    timers, log = null, path, focus, input, now = () => Date.now(), imagesDirectory = null, caret = null,
    screens = currentScreens, pointer = pointerLocation, makeSwitcher = null,
  }) {
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
    this.images = new ClipboardImageStore(imagesDirectory ?? `${dirname(path)}/clipboard-images`);
    this._caret = caret ?? new CaretTracker();
    this._screens = screens;
    this._pointer = pointer;
    this._model = new PickerModel({
      history: () => this.history,
      actions: {
        paste: (id) => this.paste(id),
        togglePin: (id) => this.togglePin(id),
        delete: (id) => this.delete(id),
        clear: () => this.clear(),
        close: () => this._switcher?.close(),
      },
    });
    this._makeSwitcher =
      makeSwitcher ??
      ((model, service) =>
        new ClipboardPicker({
          model, log, screens, pointer, imagePath: (image) => service.imagePath(image), onClosed: () => service.pickerClosed(),
        }));
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
      // History that isn't kept across restarts doesn't leave its images behind either.
      else this._removeImages('history is not kept');
    }
    if (next.enabled) this._watch();
    else this._unwatch();
    this._changeHistory((history) => {
      history.enforce(next.maxItems);
      history.prune(next.retentionDays, Core.referenceSeconds(this._now()));
    });
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
    this._caret?.destroy();
    if (this.settings.persist && this._loaded) this._saveNow();
    // History that isn't kept across restarts doesn't leave its images behind either.
    else if (this._loaded) this._removeImages('history is not kept');
    this._saver.cancel();
    this._stopped = true;
  }

  /** Remembers that Slated itself put `text` on the clipboard, so it isn't recorded as a copy. */
  markOwnWrite(text) {
    this._markOwn({text});
  }

  /** An image's file, for thumbnails and previews; null once it's gone. */
  imagePath(image) {
    return this.images.has(image) ? this.images.path(image.file) : null;
  }

  _markOwn(write) {
    const now = this._now();
    this._ownWrites = this._ownWrites.filter((w) => w.expires > now);
    this._ownWrites.push({...write, expires: now + OWN_WRITE_MS});
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
    const clipboard = St.Clipboard.get_default();
    clipboard.get_text(St.ClipboardType.CLIPBOARD, (_clipboard, text) => {
      // Only a copy without text is an image: cells and files come with a picture of themselves.
      if (typeof text === 'string') this._record(text, app);
      else if (mimeTypes.includes(PNG)) clipboard.get_content(St.ClipboardType.CLIPBOARD, PNG, (_c, bytes) => this._recordImage(bytes, app));
    });
  }

  _record(text, app) {
    if (this._stopped || !this.settings.enabled || typeof text !== 'string') return;
    if (this._takeOwnWrite((w) => w.text === text)) return;
    if (this.settings.ignoreConcealed && app && appMatchesAny(app, UNMARKED_PASSWORD_APPS) && looksLikePassword(text)) {
      this._log?.record('clipboard.skipped', {reason: 'looks like a password', app: app.id}, 'debug');
      return;
    }
    if (!this._add((history, at) => history.add(text, {app: app?.id ?? null, at, limit: this.settings.maxItems}))) return;
    this._log?.record('clipboard.captured', {chars: [...text].length, lines: lineCount(text), app: app?.id ?? 'unknown', items: this.count});
    this._changed();
  }

  /** Stores a copied image and adds it. The log gets its size and dimensions only. */
  _recordImage(content, app) {
    if (this._stopped || !this.settings.enabled) return;
    const bytes = bytesOf(content);
    if (!bytes || bytes.length === 0) return;
    const described = this.images.describe(bytes);
    if (described.tooLarge) {
      const {bytes: size, width, height} = described;
      this._log?.record('clipboard.skipped', {reason: 'image too large', bytes: size, width, height, maxBytes: this.images.maxBytes}, 'notice');
      return;
    }
    const image = described.image ?? null;
    // Slated's own paste of an image coming back as a copy.
    if (image && this._takeOwnWrite((w) => w.image === image.file)) return;
    if (!image || !this.images.write(bytes, image)) {
      this._log?.record('clipboard.skipped', {reason: 'image unreadable or not saved', bytes: bytes.length}, 'notice');
      return;
    }
    if (!this._add((history, at) => history.addImage(image, {app: app?.id ?? null, at, limit: this.settings.maxItems}))) {
      if (!this.history.imageFiles.has(image.file)) this.images.remove([image.file]);
      return;
    }
    this._log?.record('clipboard.captured', {kind: 'image', bytes: image.bytes, width: image.width, height: image.height, items: this.count});
    this._changed();
  }

  /**
   * Adds a copy with `add` (given the time), then forgets what expired: GNOME Shell runs for the whole
   * session, so retentionDays applies with every copy, not only when settings change. Returns what
   * `add` did.
   */
  _add(add) {
    const at = Core.referenceSeconds(this._now());
    return this._changeHistory((history) => {
      const added = add(history, at);
      if (added) history.prune(this.settings.retentionDays, at);
      return added;
    });
  }

  /** Takes the first unexpired write of Slated's own that `matches`; false when there's none. */
  _takeOwnWrite(matches) {
    const now = this._now();
    this._ownWrites = this._ownWrites.filter((w) => w.expires > now);
    const index = this._ownWrites.findIndex(matches);
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

  // --- The picker ------------------------------------------------------------------------------------

  /** Opens the picker below the text cursor, or at the pointer. Returns {ok, error}. */
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
    const anchor = this._anchor();
    this._switcher ??= this._makeSwitcher(this._model, this);
    // The picker's own filter field takes the input method while it's open.
    this._caret?.suspend();
    if (this._switcher.open(anchor.rect) === false) {
      this._caret?.resume();
      return {ok: false, error: "Couldn't open the clipboard picker"};
    }
    const source = anchor.source ? {source: anchor.source} : {};
    this._log?.record('clipboard.switcher_opened', {items: this.count, anchor: anchor.kind, ...source});
    return {ok: true};
  }

  /** The picker closed, however that happened. */
  pickerClosed() {
    this._caret?.resume();
  }

  get switcherModel() {
    return this._model;
  }

  /**
   * Where the picker opens: below the text cursor when the input method reported one in the focused
   * window, else at the pointer (an empty rect). `kind` and `source` say which, for the log.
   */
  _anchor() {
    let screens = [];
    try {
      screens = this._screens();
    } catch {
      screens = [];
    }
    const caret = this._caret?.location() ?? null;
    if (caret && Core.PopupPlacement.isUsable(caret.rect, screens.map((s) => s.frame))) {
      return {rect: caret.rect, kind: 'caret', source: caret.source};
    }
    const [x, y] = this._pointer();
    return {rect: {x, y, width: 0, height: 0}, kind: 'pointer'};
  }

  /** Puts the item on the clipboard and, when `pasteAfterSelecting`, pastes it into the previous window. */
  paste(id) {
    const item = this.history.items.find((i) => i.id === id);
    if (!item) return;
    const target = this._previous;
    if (!this._put(item)) return;
    if (!this.settings.pasteAfterSelecting) {
      this._log?.record('clipboard.copied', logFields(item));
      return;
    }
    this._refocus(target);
    this._timers.timeout(PASTE_DELAY_MS, () => {
      if (this._stopped) return;
      const result = this._input.pasteShortcut();
      if (result?.ok === false) this._log?.error('clipboard.paste_failed', result.error ?? "Couldn't press the paste shortcut");
    });
    this._log?.record('clipboard.pasted', {...logFields(item), app: target?.app?.id ?? 'unknown'});
  }

  delete(id) {
    this._changeHistory((history) => history.remove(id));
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
    this._changeHistory((history) => history.clear({keepPinned: true}));
    this._log?.record('clipboard.cleared', {kept: this.count});
    this._changed();
  }

  /**
   * Writes the item to the clipboard and moves it to the top, without recording the write as a copy.
   * False when an image's file is gone: the clipboard is left as it was.
   */
  _put(item) {
    const at = Core.referenceSeconds(this._now());
    const limit = this.settings.maxItems;
    const clipboard = St.Clipboard.get_default();
    if (item.image) {
      const bytes = this.images.load(item.image);
      if (!bytes) {
        this._log?.record('clipboard.paste_skipped', {reason: "the image's file is missing", bytes: item.image.bytes}, 'error');
        return false;
      }
      this._markOwn({image: item.image.file});
      clipboard.set_content(St.ClipboardType.CLIPBOARD, imageMimeType(item.image.file), new GLib.Bytes(bytes));
      this._changeHistory((history) => history.addImage(item.image, {app: item.sourceApp, at, limit}));
    } else {
      this.markOwnWrite(item.text);
      clipboard.set_text(St.ClipboardType.CLIPBOARD, item.text);
      this._changeHistory((history) => history.add(item.text, {app: item.sourceApp, at, limit}));
    }
    this._changed();
    return true;
  }

  /**
   * Changes the history, then deletes the files of images it no longer has: deleted, pruned, pushed
   * out by the limit or cleared. Returns what `change` returned.
   */
  _changeHistory(change) {
    const before = this.history.imageFiles;
    const result = change(this.history);
    const after = this.history.imageFiles;
    const gone = [...before].filter((file) => !after.has(file));
    if (gone.length > 0) this.images.remove(gone);
    return result;
  }

  /** Deletes every stored image (for history that isn't kept). */
  _removeImages(reason) {
    const files = this.images.removeFilesExcept(new Set());
    if (files > 0) this._log?.record('clipboard.images_removed', {files, reason});
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
    if (text !== null) {
      try {
        this.history = Core.ClipboardHistory.fromJSON(JSON.parse(text));
        this._log?.record('clipboard.loaded', {items: this.count});
      } catch (e) {
        this._log?.error('clipboard.load_failed', `Couldn't read the saved clipboard history: ${e?.message ?? e}`, {path: this._path});
        // A history that can't be read may still name the stored images: they stay.
        return;
      }
    }
    // Images whose items went while Slated wasn't saving (a crash, or history kept only in memory),
    // and items whose image is gone (deleted by hand): neither can be shown or pasted.
    const orphans = this.images.removeFilesExcept(this.history.imageFiles);
    if (orphans > 0) this._log?.record('clipboard.images_removed', {files: orphans, reason: 'not in the history'});
    const missing = this.history.items.filter((item) => item.image && !this.images.has(item.image));
    for (const item of missing) this.history.remove(item.id);
    if (missing.length > 0) this._log?.record('clipboard.items_removed', {items: missing.length, reason: 'image file missing'});
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
