// Clipboard history on GNOME (lib/platform/clipboard.js, clipboardPicker.js, clipboardImages.js and
// caret.js) against the simulated GNOME Shell: recording copies from Meta.Selection (text and PNG
// images), skipping password managers, excluded apps and Slated's own writes, saving privately in the
// Mac app's format with images beside it, and the picker: where it opens, its keys, and pasting.

import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, existsSync, mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {after, beforeEach, test} from 'node:test';

import {createFakeGnome, fakeEvent} from './fake-gnome.mjs';
import {MemoryLog, landscape, portrait} from './fixtures.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {ClipboardService, lineCount, looksLikePassword} = await import('../../gnome-extension/lib/platform/clipboard.js');
const Picker = await import('../../gnome-extension/lib/platform/clipboardPicker.js');
const {ClipboardPicker, PickerModel, PICKER, HINT, itemPreview, imageTitle, imageDetails, formatBytes, pickerKey} = Picker;
const {ClipboardImageStore, MAX_IMAGE_BYTES, isImageFile, pngSize} = await import('../../gnome-extension/lib/platform/clipboardImages.js');
const {CaretTracker} = await import('../../gnome-extension/lib/platform/caret.js');
const {InputInjector} = await import('../../gnome-extension/lib/platform/input.js');
const {Timers} = await import('../../gnome-extension/lib/platform/timers.js');
const {appIdentity} = await import('../../gnome-extension/lib/platform/util.js');
const Core = await import('../../gnome-extension/lib/core/index.js');

const homes = [];
after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

/** A picker stand-in that records what the service asks of it. */
class FakeSwitcher {
  constructor(model, service) {
    this.model = model;
    this.service = service;
    this.opened = 0;
    this.closed = 0;
    this.refreshed = 0;
    this.anchors = [];
  }
  open(anchor) {
    this.opened++;
    this.anchors.push(anchor);
    this.model.reset();
    return true;
  }
  close() {
    this.closed++;
    this.service.pickerClosed();
  }
  refresh() {
    this.refreshed++;
  }
  destroy() {}
}

/** A PNG's signature and header for this size, then `extra` bytes of `fill` (never decoded here). */
function png(width, height, {fill = 0, extra = 64} = {}) {
  const bytes = new Uint8Array(33 + extra).fill(fill);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  new DataView(bytes.buffer).setUint32(16, width);
  new DataView(bytes.buffer).setUint32(20, height);
  bytes.set([8, 6, 0, 0, 0], 24);
  return bytes;
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const NOW = Date.UTC(2026, 9, 22, 12, 0, 0);
let world;

beforeEach(() => {
  const home = mkdtempSync(join(tmpdir(), 'slated-clipboard-'));
  homes.push(home);
  Object.assign(gnome.state, {
    clipboard: null, clipboardMimeTypes: [], clipboardWrites: [], clipboardContent: {}, clipboardReads: [], typed: [],
    textureLoads: [], pointer: [0, 0], textInputFocus: null, focused: null, scaleFactor: 1, fileQueries: null, home,
  });
  world = {
    home,
    path: join(home, '.local/state/slated/clipboard.json'),
    images: join(home, '.local/state/slated/clipboard-images'),
    focusedWindow: {id: 'editor'},
    app: appIdentity('org.gnome.TextEditor'),
    activated: [],
    pastes: 0,
    now: NOW,
    log: new MemoryLog(),
    timers: new Timers(),
  };
});

function service(settings = {}, {makeSwitcher} = {}) {
  const s = new ClipboardService({
    timers: world.timers,
    log: world.log,
    path: world.path,
    now: () => world.now,
    input: {
      pasteShortcut: () => {
        world.pastes++;
        return {ok: true};
      },
    },
    focus: {
      window: () => world.focusedWindow,
      app: () => world.app,
      activate: (window) => {
        world.activated.push(window.id);
        world.focusedWindow = window;
      },
      isAlive: () => true,
    },
    makeSwitcher: makeSwitcher ?? ((model, svc) => (world.switcher = new FakeSwitcher(model, svc))),
  });
  s.apply({excludedApps: ['com.bitwarden.desktop', 'org.keepassxc.KeePassXC.desktop'], ...settings});
  return s;
}

const texts = (s) => s.history.items.map((i) => i.text);
const files = () => (existsSync(world.images) ? readdirSync(world.images).sort() : []);
const imageOf = (s, bytes) => s.history.items.find((i) => i.image?.file === `${sha256(bytes)}.png`);

test('copies are recorded newest first with their app; the log has counts, never text', () => {
  const s = service();
  gnome.copy('first secret line');
  world.app = appIdentity('firefox');
  world.now += 1000;
  gnome.copy('second\nmultiline\ncopy');
  assert.deepEqual(texts(s), ['second\nmultiline\ncopy', 'first secret line']);
  assert.deepEqual(s.history.items.map((i) => i.sourceApp), ['firefox', 'org.gnome.TextEditor']);
  assert.equal(s.history.items[0].copiedAt, Core.referenceSeconds(NOW + 1000));
  const captured = world.log.named('clipboard.captured');
  assert.deepEqual(captured[1].data, {chars: 21, lines: 3, app: 'firefox', items: 2});
  assert.ok(!JSON.stringify(world.log.events).includes('secret'), 'no clipboard text in the log');
  gnome.copy('   ');
  assert.equal(s.count, 2, 'whitespace isn’t kept');
  gnome.copy('first secret line');
  assert.deepEqual(texts(s), ['first secret line', 'second\nmultiline\ncopy'], 'a copy again moves to the top');
  s.stop();
});

test('password managers’ concealed copies and excluded apps are skipped before reading', () => {
  const s = service();
  gnome.copy('hunter2', ['text/plain;charset=utf-8', 'x-kde-passwordManagerHint']);
  assert.equal(s.count, 0);
  assert.equal(world.log.named('clipboard.skipped')[0].data.reason, 'concealed');
  world.app = appIdentity('org.keepassxc.KeePassXC', ['keepassxc']);
  gnome.copy('from the vault');
  world.app = appIdentity('window:3', ['com.bitwarden.desktop']);
  gnome.copy('also secret');
  assert.equal(s.count, 0);
  assert.deepEqual(world.log.named('clipboard.skipped').map((e) => e.data.reason), ['concealed', 'excluded app', 'excluded app']);
  s.apply({ignoreConcealed: false, excludedApps: []});
  gnome.copy('hunter2', ['text/plain;charset=utf-8', 'x-kde-passwordManagerHint']);
  assert.deepEqual(texts(s), ['hunter2'], 'kept once ignoreConcealed is off');
  s.stop();
});

test('a password-like copy from Chrome is skipped: Chromium doesn’t mark passwords on Linux', () => {
  const s = service();
  world.app = appIdentity('google-chrome', ['google-chrome']);
  gnome.copy('8VXdsiXkqQ5D3P9');
  gnome.copy('Rt7!kw-Pq2');
  assert.equal(s.count, 0, 'generated passwords stay out of the history');
  assert.deepEqual(world.log.named('clipboard.skipped').map((e) => e.data.reason), ['looks like a password', 'looks like a password']);
  assert.ok(!JSON.stringify(world.log.events).includes('8VXdsiXkqQ5D3P9'), 'the log never has the text');
  gnome.copy('Meet at 5pm in Room B2');
  gnome.copy('https://example.com/Docs?Page=2');
  gnome.copy('factorio-2.0.32');
  assert.deepEqual(
    texts(s), ['factorio-2.0.32', 'https://example.com/Docs?Page=2', 'Meet at 5pm in Room B2'], 'everything else is kept');
  world.app = appIdentity('org.gnome.TextEditor', ['org.gnome.texteditor']);
  gnome.copy('8VXdsiXkqQ5D3P9');
  assert.equal(texts(s)[0], '8VXdsiXkqQ5D3P9', 'other apps aren’t second-guessed');
  world.app = appIdentity('window:7', ['com.brave.Browser']);
  s.apply({ignoreConcealed: false, excludedApps: []});
  gnome.copy('Zq9vLm4TxB2w');
  assert.equal(texts(s)[0], 'Zq9vLm4TxB2w', 'kept once ignoreConcealed is off');
  s.stop();
});

test('what looks like a password', () => {
  for (const text of ['8VXdsiXkqQ5D3P9', 'Rt7!kw-Pq2', 'hunter2!X', 'pässWört123', 'a1B2c3D4', 'Summer2024']) {
    assert.equal(looksLikePassword(text), true, text);
  }
  for (const text of [
    'short1A', 'all lowercase words', 'nouppercase123', 'NOLOWER123', 'factorio-2.0.32', 'user_name2', 'OnlyLetters',
    'With Spaces 123!', 'https://Example.com/a1', 'www.Example1.com', 'Name.Surname1@example.com', 'x'.repeat(129) + 'A1',
    '', null,
  ]) {
    assert.equal(looksLikePassword(text), false, String(text));
  }
});

test('Slated’s own writes aren’t recorded, and expire', () => {
  const s = service();
  s.markOwnWrite('typed by insert-text');
  gnome.copy('typed by insert-text');
  assert.equal(s.count, 0);
  gnome.copy('typed by insert-text');
  assert.equal(s.count, 1, 'only once');
  s.markOwnWrite('later');
  world.now += 5000;
  gnome.copy('later');
  assert.deepEqual(texts(s), ['later', 'typed by insert-text'], 'an old mark no longer applies');
  s.stop();
});

test('insert-text’s temporary paste tells clipboard history to skip both writes', () => {
  const s = service();
  gnome.copy('the user’s clipboard');
  const input = new InputInjector({timers: world.timers, focusedAppId: () => 'org.gnome.TextEditor'});
  input.onClipboardWrite = (text) => s.markOwnWrite(text);
  assert.deepEqual(input.insertText('a long replacement '.repeat(6), 'paste'), {ok: true});
  gnome.loop.advance(500);
  assert.deepEqual(texts(s), ['the user’s clipboard'], 'neither the pasted text nor the restore');
  assert.equal(gnome.state.clipboard, 'the user’s clipboard', 'restored');
  input.destroy();
  s.stop();
});

test('history is saved privately in the Mac app’s format and read back', () => {
  let s = service();
  gnome.copy('keep me');
  s.togglePin(s.history.items[0].id);
  world.app = null;
  gnome.copy('no app');
  assert.equal(existsSync(world.path), false, 'saved a second after the last change');
  gnome.loop.advance(1000);
  assert.equal(statSync(world.path).mode & 0o777, 0o600);
  const saved = JSON.parse(readFileSync(world.path, 'utf8'));
  assert.deepEqual(Object.keys(saved), ['items']);
  assert.deepEqual(Object.keys(saved.items[1]), ['id', 'text', 'copiedAt', 'sourceApp', 'pinned']);
  assert.deepEqual(Object.keys(saved.items[0]), ['id', 'text', 'copiedAt', 'pinned'], 'no sourceApp when unknown');
  assert.match(saved.items[0].id, /^[0-9A-F-]{36}$/);
  assert.deepEqual([saved.items[1].text, saved.items[1].pinned, saved.items[1].sourceApp], ['keep me', true, 'org.gnome.TextEditor']);
  s.stop();

  s = service();
  assert.deepEqual(texts(s), ['no app', 'keep me'], 'loaded on start');
  assert.equal(world.log.named('clipboard.loaded').at(-1).data.items, 2);
  s.apply({persist: false});
  assert.equal(existsSync(world.path), false, 'persist off forgets the file');
  assert.equal(s.count, 2, 'but keeps this session’s history');
  s.stop();
});

test('a corrupt or foreign file is reported, not trusted; an existing file is made private', () => {
  mkdirSync(dirname(world.path), {recursive: true});
  writeFileSync(world.path, '{"items": [{"text": "no id"}]}', {mode: 0o644});
  const s = service();
  assert.equal(s.count, 0);
  assert.equal(world.log.named('clipboard.load_failed').length, 1);
  gnome.copy('x');
  gnome.loop.advance(1000);
  assert.equal(statSync(world.path).mode & 0o777, 0o600);
  s.stop();
});

test('settings apply the limit and retention; turning it off stops watching', () => {
  const s = service({maxItems: 2});
  for (const t of ['a', 'b', 'c']) gnome.copy(t);
  assert.deepEqual(texts(s), ['c', 'b']);
  world.now += 31 * 86_400_000;
  s.apply({maxItems: 2, retentionDays: 30});
  assert.deepEqual(texts(s), [], 'older than 30 days');
  s.apply({enabled: false});
  assert.equal(s.isWatching, false);
  gnome.copy('ignored');
  assert.equal(s.count, 0);
  assert.deepEqual(s.showSwitcher(), {ok: false, error: 'Clipboard history is turned off (clipboard.enabled)'});
  assert.equal(world.log.named('clipboard.switcher_unavailable').length, 1);
  s.stop();
});

test('a new copy also forgets items older than retentionDays, in a session that never reapplies settings', () => {
  const s = service({retentionDays: 2});
  gnome.copy('old');
  s.togglePin(s.history.items[0].id);
  gnome.copy('older, unpinned');
  world.now += 3 * 86_400_000;
  gnome.copy('today');
  assert.deepEqual(texts(s), ['today', 'old'], 'pinned items stay, as on settings changes');
  s.stop();
  assert.deepEqual(JSON.parse(readFileSync(world.path, 'utf8')).items.map((i) => i.text), ['today', 'old'], 'and they’re gone from disk too');
});

test('picking an item pastes it into the window you were in; with pasteAfterSelecting off it only copies', () => {
  const s = service();
  gnome.copy('older');
  gnome.copy('newest');
  const editor = world.focusedWindow;
  assert.deepEqual(s.showSwitcher(), {ok: true});
  assert.equal(world.switcher.opened, 1);
  world.focusedWindow = {id: 'somewhere else'};
  const olderId = s.history.items.find((i) => i.text === 'older').id;
  s.switcherModel.paste(olderId);
  assert.equal(world.switcher.closed, 1, 'the picker closes first');
  assert.equal(gnome.state.clipboard, 'older');
  assert.deepEqual(texts(s), ['older', 'newest'], 'moved to the top, not recorded twice');
  assert.deepEqual(world.activated, ['editor'], 'the previous window comes back');
  assert.equal(world.pastes, 0);
  gnome.loop.advance(150);
  assert.equal(world.pastes, 1, 'then the paste shortcut');
  assert.deepEqual(world.log.named('clipboard.pasted')[0].data, {chars: 5, app: 'org.gnome.TextEditor'});
  assert.equal(editor, world.focusedWindow);

  s.apply({pasteAfterSelecting: false});
  s.showSwitcher();
  s.switcherModel.paste(s.history.items[1].id);
  gnome.loop.advance(500);
  assert.equal(world.pastes, 1, 'pasteAfterSelecting off: just the clipboard');
  assert.equal(gnome.state.clipboard, 'newest');
  assert.deepEqual(world.log.named('clipboard.copied')[0].data, {chars: 6});
  s.stop();
});

test('pin, delete and clear (which keeps pinned items)', () => {
  const s = service();
  for (const t of ['a', 'b', 'c']) gnome.copy(t);
  const id = (t) => s.history.items.find((i) => i.text === t).id;
  s.togglePin(id('a'));
  assert.equal(world.log.named('clipboard.pin_toggled')[0].data.pinned, true);
  s.delete(id('b'));
  assert.deepEqual(texts(s), ['c', 'a']);
  s.clear();
  assert.deepEqual(texts(s), ['a']);
  assert.deepEqual(world.log.named('clipboard.cleared')[0].data, {kept: 1});
  s.stop();
});

// --- Where the picker opens ---------------------------------------------------------------------------

test('the picker opens below the text cursor the input method reports, else at the pointer; the log says only which', () => {
  const s = service();
  gnome.copy('x');
  const editor = {id: 'editor window'};
  gnome.focus(editor);
  gnome.state.pointer = [1500, 700];
  const open = () => {
    s.showSwitcher();
    const anchor = world.switcher.anchors.at(-1);
    world.switcher.close();
    return anchor;
  };
  const opened = () => world.log.named('clipboard.switcher_opened').at(-1).data;

  assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, 'nothing reported: the pointer');
  assert.deepEqual(opened(), {items: 1, anchor: 'pointer'});

  gnome.caret({x: 400, y: 300, width: 2, height: 18});
  assert.deepEqual(open(), {x: 400, y: 300, width: 2, height: 18}, 'a Wayland field (text-input)');
  assert.deepEqual(opened(), {items: 1, anchor: 'caret', source: 'input-method'}, 'which source, never where');
  assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, 'forgotten once the picker closed: pasting moved the cursor');

  gnome.caret({x: 400, y: 320, width: 0, height: 18});
  s.showSwitcher();
  gnome.caret({x: 900, y: 900, width: 2, height: 18}); // the picker's own filter field
  world.switcher.close();
  assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, 'reports while the picker is open are its own');

  gnome.caret({x: 400, y: 340, width: 2, height: 18});
  gnome.focus({id: 'another window'});
  assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, 'another window has focus now');
  gnome.focus(editor);
  gnome.caret({x: 400, y: 360, width: 2, height: 18});
  gnome.caretFocusOut();
  assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, 'the field lost the input method');

  gnome.caret({x: 500, y: 200, width: 1, height: 20}, 'ibus');
  assert.deepEqual(open(), {x: 500, y: 200, width: 1, height: 20}, 'an X11 app, through IBus');
  assert.deepEqual(opened(), {items: 1, anchor: 'caret', source: 'ibus'});
  gnome.caret({x: 500, y: 200, width: 1, height: 20}, 'ibus');
  gnome.caretFocusOut('ibus');
  assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, 'IBus lost focus');

  gnome.caret({x: 400, y: 380, width: 2, height: 18});
  gnome.caret({x: 10, y: 10, width: 2, height: 18}, 'ibus');
  assert.deepEqual(open(), {x: 400, y: 380, width: 2, height: 18}, 'IBus only echoes a text-input field');

  for (const rect of [{x: 400, y: 300, width: 2, height: 0}, {x: 9000, y: 300, width: 2, height: 18}, {x: NaN, y: 1, width: 1, height: 1}]) {
    gnome.caret(rect);
    assert.deepEqual(open(), {x: 1500, y: 700, width: 0, height: 0}, `not usable: ${JSON.stringify(rect)}`);
  }
  assert.ok(world.log.named('clipboard.switcher_opened').every((e) => !('x' in e.data) && !('rect' in e.data)));
  s.stop();
});

test('the caret tracker disconnects, and works without IBus or a newer input method', () => {
  const tracker = new CaretTracker();
  assert.equal(gnome.signals.inputMethod.count('cursor-location-changed') > 0, true);
  tracker.destroy();
  const before = gnome.signals.ibus.size;
  const quiet = new CaretTracker({ibus: null, inputMethod: {connect() { throw new Error('no such signal'); }}});
  assert.equal(quiet.location(), null);
  assert.equal(gnome.signals.ibus.size, before);
  quiet.destroy();
});

test('the St picker sits below the caret, above it near the bottom, kept on the anchor’s screen (PopupPlacement)', () => {
  const s = service({}, {makeSwitcher: (model, svc) => (world.panel = new ClipboardPicker({model, imagePath: (i) => svc.imagePath(i), onClosed: () => svc.pickerClosed()}))});
  for (const t of ['one', 'two', 'three']) gnome.copy(t);
  const height = PICKER.filterHeight + PICKER.hairline + 3 * PICKER.textRowHeight + 2 * PICKER.listPadding;
  const place = (anchor, screen = landscape) =>
    Core.PopupPlacement.below(anchor, {width: 320, height}, screen.visibleFrame);
  const round = (r) => ({x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height)});
  const openAt = () => {
    s.showSwitcher();
    const frame = world.panel.frame;
    const panel = world.panel._panel;
    assert.deepEqual([panel.x, panel.y, panel.width, panel.height], [frame.x, frame.y, frame.width, frame.height]);
    world.panel.close();
    return frame;
  };

  gnome.focus({id: 'w'});
  gnome.caret({x: 400, y: 300, width: 2, height: 18});
  assert.deepEqual(openAt(), {x: 400, y: 322, width: 320, height: 121}, '4 px below the caret, left edges aligned');
  gnome.caret({x: 400, y: 1050, width: 2, height: 18});
  assert.deepEqual(openAt(), round(place({x: 400, y: 1050, width: 2, height: 18})));
  gnome.caret({x: 400, y: 1050, width: 2, height: 18});
  assert.equal(openAt().y, Math.round(1050 - 4 - height), 'above, near the bottom of the screen');
  gnome.state.pointer = [1900, 500];
  assert.deepEqual(openAt(), {x: 1600, y: 504, width: 320, height: 121}, 'at the pointer, kept on its screen');
  gnome.state.pointer = [2500, 1900];
  assert.deepEqual(openAt(), round(place({x: 2500, y: 1900, width: 0, height: 0}, portrait)), 'the portrait screen');

  gnome.state.scaleFactor = 2;
  gnome.state.pointer = [100, 100];
  assert.deepEqual(openAt(), {x: 100, y: 108, width: 640, height: 241}, 'twice the size (and gap) at 200%');
  s.stop();
});

// --- The picker's model and keys ----------------------------------------------------------------------

function modelWith(texts, calls = []) {
  const history = new Core.ClipboardHistory();
  for (const [i, t] of texts.entries()) history.add(t, {at: i, limit: 100});
  const model = new PickerModel({
    history: () => history,
    actions: {
      paste: (id) => calls.push(['paste', history.items.find((i) => i.id === id).text]),
      togglePin: (id) => history.togglePin(id),
      delete: (id) => history.remove(id),
      clear: () => history.clear(),
      close: () => calls.push(['close']),
    },
  });
  return {history, model, calls, selected: () => history.items.find((i) => i.id === model.selectedId)?.text ?? null};
}

test('the picker model: filter, selection, ↑↓, ↩, esc and Ctrl+1–9 for the first nine', () => {
  const {model, calls, selected} = modelWith(['alpha', 'beta', 'gamma', 'delta']);
  const changes = [];
  model.onChange = (what) => changes.push(what);
  model.reset();
  assert.equal(selected(), 'delta');
  assert.equal(model.handleKey({name: 'Down'}), true);
  assert.equal(selected(), 'gamma');
  model.handleKey({name: 'Up'});
  model.handleKey({name: 'Up'});
  assert.equal(selected(), 'delta', 'stays on the first item');
  model.setQuery('ta');
  assert.deepEqual(model.results.map((i) => i.text), ['delta', 'beta']);
  assert.equal(selected(), 'delta', 'a new filter selects the first result');
  assert.equal(model.handleKey({name: 'x'}), false, 'typing goes to the filter field');
  assert.equal(model.handleKey({name: '2'}), false, 'digits without Ctrl filter too (dates, prices)');
  assert.equal(model.handleKey({name: '3', ctrl: true}), true);
  assert.deepEqual(calls, [], 'Ctrl+3 with two results does nothing');
  model.handleKey({name: '2', ctrl: true});
  assert.deepEqual(calls.splice(0), [['close'], ['paste', 'beta']], 'Ctrl+2 pastes the second result');
  model.setQuery('');
  model.handleKey({name: 'Return'});
  assert.deepEqual(calls.splice(0), [['close'], ['paste', 'delta']]);
  model.handleKey({name: 'Escape'});
  assert.deepEqual(calls.splice(0), [['close']]);
  assert.ok(changes.includes('selection') && changes.includes('results'));

  const many = modelWith(Array.from({length: 12}, (_, i) => `item ${i}`));
  many.model.reset();
  assert.deepEqual([many.model.number(0), many.model.number(8), many.model.number(9)], [1, 9, null]);
  many.model.handleKey({name: '9', ctrl: true});
  assert.deepEqual(many.calls.at(-1), ['paste', 'item 3'], 'Ctrl+9 is the ninth');
  assert.equal(many.model.listHeight, 9 * 26 + 13, 'nine rows and half of the next');
  assert.deepEqual(many.model.size, {width: 320, height: 32 + 0.5 + 247 + 10});
});

test('GNOME-only keys: Ctrl+P pins (pinned first, with a pin), Ctrl+Backspace deletes, Ctrl+Shift+Backspace clears', () => {
  const {history, model, selected} = modelWith(['alpha', 'beta', 'gamma', 'delta']);
  model.reset();
  model.handleKey({name: 'Down'});
  model.handleKey({name: 'Down'});
  model.handleKey({name: 'Down'});
  assert.equal(model.handleKey({name: 'p', ctrl: true}), true);
  assert.deepEqual(model.results.map((i) => i.text), ['alpha', 'delta', 'gamma', 'beta'], 'pinned first');
  assert.equal(selected(), 'alpha', 'the selection stays on it');
  model.handleKey({name: 'Down'});
  model.handleKey({name: 'BackSpace', ctrl: true});
  assert.deepEqual(model.results.map((i) => i.text), ['alpha', 'gamma', 'beta']);
  assert.equal(selected(), 'gamma', 'the next item takes its place');
  model.handleKey({name: 'Delete', ctrl: true, shift: true});
  assert.deepEqual(history.items.map((i) => i.text), ['alpha'], 'everything but pinned items');
});

test('the pointer selects the row under it, except while it rests where a key moved the selection', () => {
  const {model, selected} = modelWith(['a', 'b', 'c']);
  model.reset([50, 50]);
  const id = (t) => model.results.find((i) => i.text === t).id;
  model.hover(id('b'), [50, 50]);
  assert.equal(selected(), 'c', 'the list appeared under a resting pointer');
  model.hover(id('b'), [50, 60]);
  assert.equal(selected(), 'b', 'the pointer moved');
  model.move(1, [50, 60]);
  assert.equal(selected(), 'a');
  model.hover(id('c'), [50, 60]);
  assert.equal(selected(), 'a', 'the row scrolled under the pointer: the key wins');
  model.hover(id('c'), [51, 60]);
  assert.equal(selected(), 'c');
});

test('picker keys: keysyms, keypad digits, and keycodes for Ctrl+1 on AZERTY and Ctrl+P on other scripts', () => {
  const masks = {CONTROL_MASK: 4, SHIFT_MASK: 1};
  assert.deepEqual(pickerKey(0xff54, 116, 0, masks), {name: 'Down', ctrl: false, shift: false});
  assert.deepEqual(pickerKey(0xff8d, 104, 0, masks), {name: 'Return', ctrl: false, shift: false});
  assert.deepEqual(pickerKey(0x26, 10, 4, masks), {name: '1', ctrl: true, shift: false}, 'AZERTY: the 1 key types &');
  assert.deepEqual(pickerKey(0xffb3, 89, 4, masks), {name: '3', ctrl: true, shift: false});
  assert.deepEqual(pickerKey(0x6da, 33, 4, masks), {name: 'p', ctrl: true, shift: false}, 'Cyrillic ze on the P key');
  assert.deepEqual(pickerKey(0xff08, 22, 5, masks), {name: 'BackSpace', ctrl: true, shift: true});
  assert.deepEqual(pickerKey(0x26, 10, 0, masks), {name: '&', ctrl: false, shift: false}, 'without Ctrl it is typing');
});

test('a huge copy is filtered only at its start, and filtering it twice reuses the fold', () => {
  const history = new Core.ClipboardHistory();
  history.add(`${'a'.repeat(30_000)} needle`, {at: 0, limit: 10});
  history.add('needle in a small copy', {at: 1, limit: 10});
  assert.equal(history.search('needle').length, 2, 'the core searches everything by default');
  const model = new PickerModel({history: () => history, actions: {}});
  model.setQuery('needle');
  assert.deepEqual(model.results.map((i) => i.text), ['needle in a small copy'], 'the picker searches the first 20,000 characters');
  const started = Date.now();
  for (let i = 0; i < 20; i++) model.setQuery(i % 2 ? 'aaa' : 'needle');
  assert.ok(Date.now() - started < 1000, 'typing doesn’t refold the big item');
  assert.equal(itemPreview('x'.repeat(1_000_000)).length, 241);
});

test('rows, image titles and sizes read like the Mac picker', () => {
  assert.equal(itemPreview('  first line  \n\n second\r\nthird  '), 'first line ⏎ second ⏎ third');
  assert.equal([...itemPreview('x'.repeat(300))].length, 241);
  assert.equal(lineCount('a\r\nb'), 2);
  const image = {file: 'a.png', width: 1280, height: 720, bytes: 245_000};
  assert.equal(imageTitle(image, 'Firefox'), 'Image · 1280×720 · Firefox');
  assert.equal(imageTitle(image), 'Image · 1280×720');
  assert.equal(imageDetails(image), '1280×720 · 245 kB');
  // Foundation's file byte counts, as the Mac shows them.
  const sizes = {
    0: 'Zero kB', 1: '1 byte', 998: '998 bytes', 999: '1 kB', 1500: '2 kB', 949_999: '950 kB', 998_000: '998 kB',
    999_499: '1 MB', 1_050_000: '1 MB', 2_450_000: '2.4 MB', 2_500_000: '2.5 MB', 9_950_000: '10 MB', 20_971_520: '21 MB',
    99_949_999: '99.9 MB', 999_949_999: '1 GB', 1_234_567_890: '1.23 GB', 12_345_678_901: '12.35 GB',
  };
  for (const [bytes, text] of Object.entries(sizes)) assert.equal(formatBytes(Number(bytes)), text, bytes);
  assert.equal(Picker.thumbnailWidth(image), 50, '16:9 at 28 px');
  assert.equal(Picker.thumbnailWidth({width: 10, height: 1000}), 20, 'a sliver gets 0.7 of the height');
  assert.equal(Picker.thumbnailWidth({width: 5000, height: 100}), 50, 'a panorama 1.8');
  assert.deepEqual(Picker.previewImageSize(image), {width: 240, height: 135});
  assert.deepEqual(Picker.previewImageSize({width: 20, height: 10}), {width: 20, height: 10}, 'never enlarged');
  assert.deepEqual(Picker.previewSize({width: 20, height: 10}), {width: 136, height: 45}, 'at least 120 wide, plus caption and padding');
  assert.equal(Picker.listHeight([]), 26);
  assert.equal(Picker.listHeight([{text: 'a'}, {text: '', image}]), 62);
});

// --- Images -------------------------------------------------------------------------------------------

test('a copied PNG is stored privately under its SHA-256, once, and the log has only its size', () => {
  const s = service();
  world.app = appIdentity('org.gnome.Loupe');
  const shot = png(1280, 720, {fill: 7});
  gnome.copyContent({'image/png': shot});
  const item = s.history.items[0];
  assert.deepEqual(item.image, {file: `${sha256(shot)}.png`, width: 1280, height: 720, bytes: shot.length});
  assert.equal(item.text, '');
  assert.equal(item.sourceApp, 'org.gnome.Loupe');
  assert.deepEqual(files(), [`${sha256(shot)}.png`]);
  assert.equal(statSync(world.images).mode & 0o777, 0o700, 'the folder is yours only');
  assert.equal(statSync(join(world.images, item.image.file)).mode & 0o777, 0o600);
  assert.deepEqual(new Uint8Array(readFileSync(join(world.images, item.image.file))), shot);
  assert.deepEqual(world.log.named('clipboard.captured').at(-1).data, {kind: 'image', bytes: shot.length, width: 1280, height: 720, items: 1});

  gnome.copy('text in between');
  gnome.copyContent({'image/png': shot});
  assert.deepEqual(s.history.items.map((i) => i.image?.width ?? i.text), [1280, 'text in between'], 'the same image again moves up');
  assert.equal(files().length, 1, 'one file');

  gnome.copyContent({'image/png': png(10, 10)}, {text: 'A1:B2'});
  assert.equal(texts(s)[0], 'A1:B2', 'a copy with text is text (cells come with a picture of themselves)');
  assert.equal(files().length, 1);

  gnome.copyContent({'image/jpeg': new Uint8Array([0xff, 0xd8, 0xff])});
  assert.equal(s.count, 3, 'only PNG is recorded');
  gnome.copyContent({'image/png': new Uint8Array(40).fill(1)});
  assert.equal(world.log.named('clipboard.skipped').at(-1).data.reason, 'image unreadable or not saved');
  const huge = new Uint8Array(MAX_IMAGE_BYTES + 1);
  huge.set(png(6000, 4000).subarray(0, 33));
  gnome.copyContent({'image/png': huge});
  assert.deepEqual(world.log.named('clipboard.skipped').at(-1).data, {
    reason: 'image too large', bytes: MAX_IMAGE_BYTES + 1, width: 6000, height: 4000, maxBytes: MAX_IMAGE_BYTES,
  });
  assert.equal(s.count, 3);
  assert.equal(files().length, 1, 'nothing written for either');

  gnome.state.clipboardReads = [];
  gnome.copyContent({'image/png': png(5, 5), 'x-kde-passwordManagerHint': new Uint8Array([1])});
  world.app = appIdentity('window:3', ['com.bitwarden.desktop']);
  gnome.copyContent({'image/png': png(6, 6)});
  assert.deepEqual(gnome.state.clipboardReads, [], 'concealed copies and excluded apps aren’t read');
  s.stop();
});

test('pasting an image puts its PNG back on the clipboard, isn’t recorded again, and presses paste', () => {
  const s = service();
  const shot = png(64, 32, {fill: 3});
  gnome.copyContent({'image/png': shot});
  gnome.copy('newer text');
  s.showSwitcher();
  const item = imageOf(s, shot);
  s.switcherModel.paste(item.id);
  assert.deepEqual(gnome.state.clipboardMimeTypes, ['image/png']);
  assert.deepEqual(gnome.state.clipboardContent['image/png'], shot);
  assert.equal(s.count, 2, 'Slated’s own write isn’t a new copy');
  assert.equal(s.history.items[0].image?.file, `${sha256(shot)}.png`, 'moved to the top');
  gnome.loop.advance(150);
  assert.equal(world.pastes, 1);
  assert.deepEqual(world.log.named('clipboard.pasted').at(-1).data, {kind: 'image', bytes: shot.length, width: 64, height: 32, app: 'org.gnome.TextEditor'});

  rmSync(join(world.images, item.image.file));
  gnome.copy('on the clipboard');
  s.showSwitcher();
  s.switcherModel.paste(s.history.items.find((i) => i.image).id);
  gnome.loop.advance(500);
  assert.equal(gnome.state.clipboard, 'on the clipboard', 'a missing file leaves the clipboard alone');
  assert.equal(world.pastes, 1, 'and pastes nothing');
  assert.equal(world.log.named('clipboard.paste_skipped')[0].level, 'error');
  s.stop();
});

test('an image’s file goes with its item: deleted, cleared, pushed out or past retention; pinned ones stay', () => {
  const s = service({maxItems: 3, retentionDays: 2});
  const [a, b, c, d] = [1, 2, 3, 4].map((n) => png(n, n, {fill: n}));
  for (const shot of [a, b, c]) gnome.copyContent({'image/png': shot});
  assert.equal(files().length, 3);
  s.delete(imageOf(s, a).id);
  assert.equal(files().includes(`${sha256(a)}.png`), false, 'deleted');
  s.togglePin(imageOf(s, b).id);
  s.clear();
  assert.deepEqual(files(), [`${sha256(b)}.png`], 'cleared, except the pinned one');
  gnome.copyContent({'image/png': c});
  gnome.copy('t1');
  gnome.copy('t2');
  gnome.copy('t3');
  assert.equal(imageOf(s, c), undefined, 'pushed out by the limit');
  assert.deepEqual(files(), [`${sha256(b)}.png`]);
  gnome.copyContent({'image/png': d});
  world.now += 3 * 86_400_000;
  gnome.copy('today');
  assert.equal(imageOf(s, d), undefined, 'past retention');
  assert.deepEqual(files(), [`${sha256(b)}.png`], 'the pinned image stays');
  s.stop();
});

test('saved images come back with the history; strays are removed, and items whose file is gone are dropped', () => {
  let s = service();
  const kept = png(30, 20, {fill: 9});
  gnome.copyContent({'image/png': kept});
  gnome.copy('words');
  s.stop();
  const saved = JSON.parse(readFileSync(world.path, 'utf8'));
  assert.deepEqual(saved.items[1].image, {file: `${sha256(kept)}.png`, width: 30, height: 20, bytes: kept.length}, 'the Mac app’s format');

  writeFileSync(join(world.images, `${'f'.repeat(64)}.png`), 'left by a crash');
  writeFileSync(join(world.images, 'notes.txt'), 'not ours');
  writeFileSync(join(world.images, '.hidden.png'), 'not ours either');
  saved.items.push({id: '00000000-0000-4000-8000-000000000009', text: '', copiedAt: 1, pinned: true, image: {file: 'gone.png', width: 1, height: 1, bytes: 1}});
  writeFileSync(world.path, JSON.stringify(saved));
  s = service();
  assert.deepEqual(s.history.items.map((i) => i.image?.file ?? i.text), ['words', `${sha256(kept)}.png`]);
  assert.deepEqual(files(), ['.hidden.png', `${sha256(kept)}.png`, 'notes.txt'], 'only files the store writes are removed');
  assert.deepEqual(world.log.named('clipboard.images_removed').at(-1).data, {files: 1, reason: 'not in the history'});
  assert.deepEqual(world.log.named('clipboard.items_removed').at(-1).data, {items: 1, reason: 'image file missing'});
  s.stop();

  writeFileSync(world.path, '{"items": [{"text": "broken"}]}');
  s = service();
  assert.equal(s.count, 0);
  assert.ok(files().includes(`${sha256(kept)}.png`), 'a history that can’t be read keeps its images');
  s.stop();
});

test('history that isn’t kept leaves no images behind: removed when Slated stops, and at start', () => {
  let s = service({persist: false});
  gnome.copyContent({'image/png': png(8, 8)});
  assert.equal(files().length, 1, 'kept for this session');
  s.stop();
  assert.deepEqual(files(), []);
  assert.equal(world.log.named('clipboard.images_removed').at(-1).data.reason, 'history is not kept');

  s = service();
  gnome.copyContent({'image/png': png(9, 9)});
  s.stop();
  assert.equal(files().length, 1, 'kept with the history');
  s = service({persist: false});
  assert.deepEqual(files(), [], 'persist turned off while Slated wasn’t running');
  s.stop();
});

test('the image store only reads, writes and deletes names it makes', () => {
  const store = new ClipboardImageStore(world.images);
  assert.equal(store.path('../../.bashrc'), null);
  assert.equal(store.load({file: '../clipboard.json'}), null);
  assert.equal(store.has({file: '/etc/passwd'}), false);
  for (const name of ['a.png', 'b.tiff']) assert.equal(isImageFile(name), true, name);
  for (const name of ['../a.png', '.a.png', 'a.jpg', 'a.png/', '', null]) assert.equal(isImageFile(name), false, String(name));
  assert.deepEqual(pngSize(png(3000, 2000)), {width: 3000, height: 2000});
  assert.deepEqual(pngSize(png(0xffffffff, 1)), {width: 0xffffffff, height: 1});
  assert.equal(pngSize(new Uint8Array(10)), null);
  assert.deepEqual(store.describe(png(0, 5)), {failed: true, bytes: 97}, 'no pixels');
});

// --- The St picker ------------------------------------------------------------------------------------

test('the St picker: a filter with its one hint, one-line rows with Ctrl-numbers and pins, keys, hover and clicks', () => {
  const s = service({}, {makeSwitcher: (model, svc) => (world.panel = new ClipboardPicker({model, imagePath: (i) => svc.imagePath(i), onClosed: () => svc.pickerClosed()}))});
  gnome.addWindow({id: 'editor', app: {id: 'org.gnome.TextEditor', name: 'Text Editor'}, frame: {x: 0, y: 32, width: 800, height: 600}});
  for (const t of ['apple pie', 'banana bread', 'cherry tart']) gnome.copy(t);
  s.togglePin(s.history.items.find((i) => i.text === 'apple pie').id);
  assert.deepEqual(s.showSwitcher(), {ok: true});
  assert.equal(gnome.state.modal.length, 1, 'a modal grab');
  const panel = world.panel;
  const all = (cls) => panel._root.find((a) => String(a.style_class ?? '').split(' ').includes(cls));
  assert.deepEqual(all('slated-clipboard-hint').map((l) => l.text), [HINT]);
  assert.equal(HINT, 'Ctrl+1–9 · esc');
  for (const gone of ['slated-clipboard-header', 'slated-clipboard-hints', 'slated-clipboard-count']) assert.equal(all(gone).length, 0, gone);
  const rows = () => panel._list.children;
  const rowText = (row) => row.find((a) => a.style_class === 'slated-clipboard-text')[0].text;
  assert.deepEqual(rows().map(rowText), ['apple pie', 'cherry tart', 'banana bread'], 'pinned first');
  assert.equal(rows()[0].find((a) => a.style_class === 'slated-clipboard-pin').length, 1);
  assert.equal(rows()[1].find((a) => a.style_class === 'slated-clipboard-pin').length, 0);
  assert.deepEqual(rows().map((r) => r.find((a) => a.style_class === 'slated-clipboard-number')[0].text), ['Ctrl+1', 'Ctrl+2', 'Ctrl+3']);
  assert.deepEqual(rows()[1].find((a) => a.style_class === 'slated-clipboard-app-icon')[0].gicon, {icon: 'org.gnome.TextEditor'});
  assert.ok(rows().every((r) => r.height === 26));
  assert.ok(rows()[0].pseudoClasses.has('selected'));

  panel._entry.set_text('an');
  assert.deepEqual(rows().map(rowText), ['banana bread']);
  panel._entry.set_text('zzz');
  assert.deepEqual(panel._list.children.map((a) => a.text), ['No matches']);
  panel._entry.set_text('');
  const key = (keysym, state = 0, keycode = 0) =>
    panel._entry.clutter_text.emit('key-press-event', {...fakeEvent({keysym}), get_key_code: () => keycode, get_state: () => state});
  gnome.state.pointer = [5, 5];
  key(0xff54); // Down
  assert.ok(rows()[1].pseudoClasses.has('selected') && !rows()[0].pseudoClasses.has('selected'), 'only the highlight moves');
  const hover = (row) => {
    row.hover = true;
    row.emit('notify::hover');
  };
  hover(rows()[2]);
  assert.ok(rows()[1].pseudoClasses.has('selected'), 'a row scrolled under a resting pointer isn’t picked');
  gnome.state.pointer = [5, 40];
  hover(rows()[2]);
  assert.ok(rows()[2].pseudoClasses.has('selected'), 'the pointer moved: the row under it is selected');
  key(0xff1b); // Escape
  assert.equal(panel.isOpen, false);
  assert.equal(gnome.state.modal.length, 0);
  assert.equal(gnome.state.chrome.size, 0);

  s.showSwitcher();
  const root = panel._root;
  root.emit('button-press-event', fakeEvent({actor: root}));
  assert.equal(panel.isOpen, false, 'a click outside closes it');

  s.showSwitcher();
  panel._list.children[2].emit('clicked');
  assert.equal(panel.isOpen, false);
  assert.equal(gnome.state.clipboard, 'banana bread', 'clicking a row pastes it');

  s.showSwitcher();
  assert.deepEqual(rows().map(rowText), ['apple pie', 'banana bread', 'cherry tart']);
  key(0xff54); // Down
  key(0xff08, 4, 22); // Ctrl+Backspace
  assert.deepEqual(rows().map(rowText), ['apple pie', 'cherry tart']);
  assert.ok(rows()[1].pseudoClasses.has('selected'), 'the next item takes the deleted one’s place');
  key(0x70, 4, 33); // Ctrl+P
  assert.deepEqual(rows().map(rowText), ['cherry tart', 'apple pie'], 'both pinned now, newest first');
  assert.equal(rows()[0].find((a) => a.style_class === 'slated-clipboard-pin').length, 1);
  assert.ok(rows()[0].pseudoClasses.has('selected'), 'still selected');
  panel.close();

  s.history.clear({keepPinned: false});
  s.showSwitcher();
  assert.deepEqual(panel._list.children.map((a) => a.text), ['Nothing copied yet']);
  key(0x31, 4, 10); // Ctrl+1 with nothing listed
  assert.equal(panel.isOpen, true);
  s.stop();
});

test('the St picker shows an image as a thumbnail and, selected, larger beside the picker, level with its row', () => {
  const s = service({}, {makeSwitcher: (model, svc) => (world.panel = new ClipboardPicker({model, imagePath: (i) => svc.imagePath(i), onClosed: () => svc.pickerClosed()}))});
  gnome.addWindow({id: 'viewer', app: {id: 'org.gnome.Loupe', name: 'Image Viewer'}, frame: {x: 0, y: 32, width: 800, height: 600}});
  world.app = appIdentity('org.gnome.Loupe');
  const shot = png(1600, 900, {fill: 4});
  gnome.copyContent({'image/png': shot});
  gnome.copy('a line of text');
  gnome.caret({x: 300, y: 200, width: 2, height: 18});
  s.showSwitcher();
  const panel = world.panel;
  const [textRow, imageRow] = panel._list.children;
  assert.equal(imageRow.height, 36, 'image rows are taller');
  assert.equal(imageRow.find((a) => a.style_class === 'slated-clipboard-text')[0].text, 'Image · 1600×900 · Image Viewer');
  const thumbnail = imageRow.find((a) => a.style_class === 'slated-clipboard-thumbnail')[0];
  assert.deepEqual([thumbnail.width, thumbnail.height, thumbnail.clip_to_allocation], [50, 28, true]);
  const path = join(world.images, `${sha256(shot)}.png`);
  const [icon] = thumbnail.children;
  assert.deepEqual([icon.gicon.file.path, icon.icon_size], [path, 50], 'a square file icon, clipped to the image’s shape');
  assert.deepEqual(gnome.state.textureLoads, [], 'nothing decoded at full size');
  assert.equal(textRow.find((a) => a.style_class === 'slated-clipboard-app-icon').length, 1);
  assert.equal(panel._preview, null, 'no preview for text');

  const key = (keysym) => panel._entry.clutter_text.emit('key-press-event', {...fakeEvent({keysym}), get_key_code: () => 0, get_state: () => 0});
  key(0xff54); // Down, onto the image
  const preview = panel._preview;
  assert.ok(preview, 'selecting an image shows it larger');
  const frame = panel.frame;
  assert.deepEqual([frame.x, frame.y], [300, 222]);
  const rowTop = frame.y + Math.round(PICKER.filterHeight + PICKER.hairline + PICKER.listPadding + 26);
  const expected = Core.PopupPlacement.beside(frame, {x: frame.x + 5, y: rowTop, width: 310, height: 36}, {width: 256, height: 170}, landscape.visibleFrame);
  assert.deepEqual([preview.x, preview.y, preview.width, preview.height], [expected.x, expected.y, 256, 170]);
  assert.deepEqual([preview.x, preview.y], [626, rowTop], 'to the right of the picker, level with the row');
  assert.equal(preview.find((a) => a.style_class === 'slated-clipboard-preview-caption')[0].text, `1600×900 · ${formatBytes(shot.length)}`);
  assert.deepEqual(gnome.state.textureLoads.at(-1), {path, width: 240, height: 135, paintScale: 1, resourceScale: 1});
  key(0xff52); // Up, back to text
  assert.equal(panel._preview, null);
  assert.equal(preview.destroyed, true);

  key(0xff54);
  key(0xff0d); // Return pastes the image
  assert.equal(panel.isOpen, false);
  assert.deepEqual(gnome.state.clipboardContent['image/png'], shot);

  rmSync(path);
  s.showSwitcher();
  const placeholder = panel._list.children[0].find((a) => a.style_class === 'slated-clipboard-image-placeholder');
  assert.equal(placeholder.length, 1, 'a missing file shows a placeholder');
  s.stop();
});

// --- Copied files and screenshots ------------------------------------------------------------------

const Files = await import('../../gnome-extension/lib/platform/clipboardFiles.js');
const encode = (text) => new TextEncoder().encode(text);
const decode = (bytes) => new TextDecoder().decode(bytes);

/** Files in the test home's Documents: {name: contents} (a name ending in "/" is a folder). Returns their paths. */
function makeFiles(spec) {
  return Object.entries(spec).map(([name, contents]) => {
    const path = join(world.home, 'Documents', name);
    if (name.endsWith('/')) mkdirSync(path, {recursive: true});
    else {
      mkdirSync(dirname(path), {recursive: true});
      writeFileSync(path, contents);
    }
    return name.endsWith('/') ? path.slice(0, -1) : path;
  });
}

/** Nautilus copies files: its own list, a URI list and the names as text. */
function nautilusCopy(paths, {operation = 'copy'} = {}) {
  const uris = paths.map(Files.fileUri);
  gnome.copyContent(
    {'x-special/gnome-copied-files': encode([operation, ...uris].join('\n')), 'text/uri-list': encode(uris.map((u) => `${u}\r\n`).join(''))},
    {text: paths.map((p) => p.split('/').pop()).join('\n')},
  );
}

test('file URIs and the copied-files formats', () => {
  assert.equal(Files.fileUri('/home/me/a b#?é;[x]%.txt'), 'file:///home/me/a%20b%23%3F%C3%A9%3B%5Bx%5D%25.txt');
  assert.equal(Files.fileUri("/keep/-._~!$&'()*+,=:@"), "file:///keep/-._~!$&'()*+,=:@", 'what GLib leaves unescaped');
  for (const path of ['/home/me/a b#?é;[x]%.txt', '/日本/😀', '/']) assert.equal(Files.pathFromFileUri(Files.fileUri(path)), path, path);
  assert.equal(Files.pathFromFileUri('file://localhost/etc/hosts'), '/etc/hosts');
  assert.equal(Files.pathFromFileUri('FILE:///x%c3%a9'), '/xé', 'scheme and escapes in any case');
  for (const uri of ['https://example.com/a', 'smb://server/share/a', 'file://server/share/a', 'file:relative', 'file:///a%FF',
    'file:///a%00b', 'file:///a%G1', 'file:///a#frag', '']) {
    assert.equal(Files.pathFromFileUri(uri), null, uri);
  }
  assert.deepEqual(Files.parseCopiedFiles('copy\nfile:///home/me/a%20b.pdf\nfile:///home/me/%C3%A9t%C3%A9\n'), ['/home/me/a b.pdf', '/home/me/été']);
  assert.deepEqual(Files.parseCopiedFiles('cut\r\nfile:///a\r\nfile:///a\r\n'), ['/a'], 'a cut too, each file once');
  assert.deepEqual(Files.parseCopiedFiles('# a comment\r\nhttps://example.com/\r\nsmb://nas/x\r\nfile:///b\r\n'), ['/b'], 'local files only');
  assert.deepEqual(Files.parseCopiedFiles('https://example.com/'), []);
  assert.deepEqual(Files.parseCopiedFiles(null), []);
  assert.equal(Files.copiedFilesText(['/a b', '/c']), 'copy\nfile:///a%20b\nfile:///c');
});

test('files copied in Files are one item: their names as text, read from Nautilus’s list; the log has only how many', () => {
  const s = service();
  world.app = appIdentity('org.gnome.Nautilus');
  const [report, photo] = makeFiles({'quarterly report.pdf': 'pdf', 'été.png': png(4, 3)});
  nautilusCopy([report, photo]);
  const item = s.history.items[0];
  assert.deepEqual(item.files, [report, photo]);
  assert.equal(item.text, 'quarterly report.pdf\nété.png');
  assert.equal(item.sourceApp, 'org.gnome.Nautilus');
  assert.deepEqual(gnome.state.clipboardReads, ['x-special/gnome-copied-files'], 'the text that comes with them isn’t read');
  assert.deepEqual(world.log.named('clipboard.captured').at(-1).data, {kind: 'files', count: 2, app: 'org.gnome.Nautilus', items: 1});
  const logged = JSON.stringify(world.log.events);
  for (const secret of ['quarterly', 'été', world.home, 'Documents']) assert.ok(!logged.includes(secret), `no ${secret} in the log`);

  gnome.copy('in between');
  nautilusCopy([report, photo], {operation: 'cut'});
  assert.equal(s.count, 2, 'the same files again move up');
  assert.deepEqual(s.history.items[0].files, [report, photo]);

  gnome.state.clipboardReads = [];
  gnome.copyContent({'text/uri-list': encode(`${Files.fileUri(report)}\r\n`)}, {text: report});
  assert.deepEqual(gnome.state.clipboardReads, ['text/uri-list'], 'a URI list alone (Dolphin, Qt apps)');
  assert.deepEqual(s.history.items[0].files, [report]);

  gnome.copyContent({'text/uri-list': encode('https://example.com/page\r\n')}, {text: 'https://example.com/page'});
  assert.equal(s.history.items[0].text, 'https://example.com/page', 'web links stay text');
  assert.equal(s.history.items[0].files, undefined);
  assert.equal(s.count, 4);

  gnome.state.clipboardReads = [];
  world.app = appIdentity('window:3', ['com.bitwarden.desktop']);
  nautilusCopy([photo]);
  assert.deepEqual(gnome.state.clipboardReads, [], 'excluded apps aren’t read');
  assert.equal(s.count, 4);

  gnome.loop.advance(1000);
  const saved = JSON.parse(readFileSync(world.path, 'utf8'));
  assert.deepEqual(saved.items.find((i) => i.files)?.files, [report], 'saved in the Mac app’s format');
  s.stop();
  rmSync(report);
  const again = service();
  assert.deepEqual(again.history.items.filter((i) => i.files).map((i) => i.files), [[report], [report, photo]], 'moved files stay listed');
  again.stop();
});

test('pasting files puts Nautilus’s list back, leaves out what was moved or deleted, and nothing when all are gone', () => {
  const s = service();
  const [a, b] = makeFiles({'a.txt': 'a', 'b.txt': 'b'});
  nautilusCopy([a, b]);
  gnome.copy('newer text');
  s.showSwitcher();
  const item = () => s.history.items.find((i) => i.files); // a new id each time it moves up
  s.switcherModel.paste(item().id);
  assert.deepEqual(gnome.state.clipboardMimeTypes, ['x-special/gnome-copied-files']);
  assert.equal(decode(gnome.state.clipboardContent['x-special/gnome-copied-files']), Files.copiedFilesText([a, b]));
  assert.equal(s.count, 2, 'Slated’s own write isn’t a new copy');
  assert.deepEqual(s.history.items[0].files, [a, b], 'moved to the top');
  gnome.loop.advance(150);
  assert.equal(world.pastes, 1);
  assert.deepEqual(world.log.named('clipboard.pasted').at(-1).data, {kind: 'files', count: 2, app: 'org.gnome.TextEditor'});

  rmSync(a);
  s.showSwitcher();
  s.switcherModel.paste(item().id);
  assert.equal(decode(gnome.state.clipboardContent['x-special/gnome-copied-files']), Files.copiedFilesText([b]));
  assert.deepEqual(s.history.items[0].files, [a, b], 'the item keeps both');
  assert.equal(s.count, 2);
  assert.deepEqual(world.log.named('clipboard.pasted').at(-1).data, {kind: 'files', count: 2, missing: 1, app: 'org.gnome.TextEditor'});
  gnome.loop.advance(150);

  rmSync(b);
  gnome.copy('on the clipboard');
  s.showSwitcher();
  s.switcherModel.paste(item().id);
  gnome.loop.advance(500);
  assert.equal(gnome.state.clipboard, 'on the clipboard', 'all gone: the clipboard is left alone');
  assert.equal(world.pastes, 2, 'and nothing is pasted');
  const skipped = world.log.named('clipboard.paste_skipped').at(-1);
  assert.deepEqual([skipped.data, skipped.level], [{reason: 'files missing', count: 2}, 'notice']);
  s.apply({pasteAfterSelecting: false});
  writeFileSync(b, 'back');
  s.showSwitcher();
  s.switcherModel.paste(item().id);
  assert.deepEqual(world.log.named('clipboard.copied').at(-1).data, {kind: 'files', count: 2, missing: 1});
  s.stop();
});

test('screenshots GNOME copies are images from GNOME Shell itself, left out with `screenshots` off', () => {
  const s = service();
  const shot = png(1920, 1080, {fill: 9});
  gnome.screenshot(shot);
  assert.equal(s.history.items[0].image?.file, `${sha256(shot)}.png`);
  assert.deepEqual(world.log.named('clipboard.captured').at(-1).data, {
    kind: 'image', source: 'screenshot', bytes: shot.length, width: 1920, height: 1080, items: 1,
  });
  gnome.copyContent({'image/png': png(8, 8)});
  assert.equal(world.log.named('clipboard.captured').at(-1).data.source, undefined, 'an app’s image isn’t a screenshot');

  s.apply({screenshots: false});
  gnome.screenshot(png(1920, 1080, {fill: 5}));
  assert.equal(s.count, 2);
  assert.equal(world.log.named('clipboard.skipped').at(-1).data.reason, 'screenshots are off');
  gnome.copyContent({'image/png': png(9, 9)});
  assert.equal(s.count, 3, 'apps’ images are still kept');
  s.showSwitcher();
  s.switcherModel.paste(s.history.items.find((i) => i.image?.width === 1920).id);
  assert.equal(s.count, 3, 'Slated’s own paste of a screenshot isn’t a copy either way');
  assert.equal(s.history.items[0].image.width, 1920);
  s.stop();
});

test('picker text for files and named images', () => {
  assert.equal(Picker.filesTitle(['/home/me/report.pdf']), 'report.pdf');
  assert.equal(Picker.filesTitle(['/home/me/report.pdf', '/home/me/Photos/', '/x']), 'report.pdf + 2 more');
  assert.equal(Picker.fileDetails({size: 2_450_000, kind: 'PNG image'}), '2.4 MB · PNG image');
  assert.equal(Picker.fileDetails({size: null, kind: 'Folder'}), 'Folder');
  const named = {file: 'a.png', width: 1, height: 1, bytes: 1, name: 'Screenshot 2026-10-30 at 09.41.png'};
  assert.equal(imageTitle(named, 'Firefox'), 'Screenshot 2026-10-30 at 09.41.png');
  assert.equal(Picker.rowHeight({text: 'a', files: ['/a']}), PICKER.imageRowHeight, 'files rows are as tall as image rows');
  assert.deepEqual(Picker.filePreviewSize(), {width: 216, height: 118}, 'an icon, two lines, room for a name');
  assert.deepEqual(Picker.filePreviewSize({width: 1600, height: 900}), {width: 256, height: 189});
  assert.equal(Picker.MISSING, 'Moved or deleted');
});

test('the St picker shows files with their thumbnail or icon, dims them when gone, and previews them beside the picker', () => {
  const s = service({}, {makeSwitcher: (model, svc) => (world.panel = new ClipboardPicker({model, imagePath: (i) => svc.imagePath(i), onClosed: () => svc.pickerClosed()}))});
  gnome.addWindow({id: 'files', app: {id: 'org.gnome.Nautilus', name: 'Files'}, frame: {x: 0, y: 32, width: 800, height: 600}});
  const [pdf, photo, folder, gone] = makeFiles({'report.pdf': 'pdf', 'photo.png': png(1600, 900), 'Folder/': null, 'gone.txt': 'x'});
  // GNOME already made thumbnails of the PDF (Files does as you browse).
  const md5 = createHash('md5').update(Files.fileUri(pdf)).digest('hex');
  const normal = join(world.home, '.cache/thumbnails/normal', `${md5}.png`);
  const large = join(world.home, '.cache/thumbnails/large', `${md5}.png`);
  for (const [path, size] of [[normal, 128], [large, 256]]) {
    mkdirSync(dirname(path), {recursive: true});
    writeFileSync(path, png(size * 0.75, size));
  }
  nautilusCopy([gone]);
  nautilusCopy([folder]);
  nautilusCopy([photo]);
  nautilusCopy([pdf, photo]);
  rmSync(gone);
  gnome.caret({x: 300, y: 200, width: 2, height: 18});
  gnome.state.fileQueries = [];
  s.showSwitcher();
  const panel = world.panel;
  const rows = panel._list.children;
  const text = (row, cls = 'slated-clipboard-text') => row.find((a) => a.style_class === cls)[0]?.text;
  assert.deepEqual(rows.map((r) => text(r)), ['report.pdf + 1 more', 'photo.png', 'Folder', 'gone.txt']);
  assert.ok(rows.every((r) => r.height === 36), 'as tall as image rows');
  const icon = (row) => row.find((a) => String(a.style_class).includes('slated-clipboard-file-thumbnail'))[0].children[0];
  assert.equal(icon(rows[0]).gicon.file.path, normal, 'the thumbnail GNOME made, the small one for a row');
  assert.deepEqual(icon(rows[1]).gicon, {themed: 'image-png'}, 'else the icon for its type');
  assert.deepEqual(icon(rows[2]).gicon, {themed: 'inode-directory'});
  assert.ok(String(rows[3].style_class).includes('slated-clipboard-missing'), 'gone: dimmed');
  assert.equal(text(rows[3], 'slated-clipboard-missing-label'), 'Moved or deleted');
  assert.ok(!rows.slice(0, 3).some((r) => String(r.style_class).includes('missing')));
  assert.deepEqual(gnome.state.fileQueries.sort(), [folder, gone, pdf, photo].sort(), 'one look at each file, the first still there');

  // The selected row is previewed beside the picker.
  let preview = panel._preview;
  assert.ok(preview, 'the first row is selected');
  const captions = () => preview.children.filter((a) => a.text !== undefined).map((a) => a.text);
  assert.deepEqual(captions(), ['report.pdf + 1 more', '3 bytes · PDF document']);
  assert.deepEqual(gnome.state.textureLoads.at(-1), {path: large, width: 180, height: 240, paintScale: 1, resourceScale: 1}, 'its large thumbnail');
  assert.deepEqual([preview.width, preview.height], [216, 240 + 38 + 16]);
  const key = (keysym) => panel._entry.clutter_text.emit('key-press-event', {...fakeEvent({keysym}), get_key_code: () => 0, get_state: () => 0});
  key(0xff54);
  preview = panel._preview;
  assert.deepEqual(gnome.state.textureLoads.at(-1), {path: photo, width: 240, height: 135, paintScale: 1, resourceScale: 1}, 'an image file itself, fitted');
  assert.deepEqual(captions(), ['photo.png', `${formatBytes(statSync(photo).size)} · PNG image`]);
  key(0xff54);
  preview = panel._preview;
  assert.deepEqual(preview.find((a) => a.style_class === 'slated-clipboard-preview-icon')[0].gicon, {themed: 'inode-directory'});
  assert.deepEqual(captions(), ['Folder', 'Folder']);
  assert.deepEqual([preview.width, preview.height], [216, 118]);
  key(0xff54);
  assert.equal(panel._preview, null, 'nothing to preview when the files are gone');
  key(0xff0d);
  assert.equal(world.log.named('clipboard.paste_skipped').at(-1).data.reason, 'files missing');
  s.stop();
});
