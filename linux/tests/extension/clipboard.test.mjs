// Clipboard history on GNOME (lib/platform/clipboard.js and clipboardSwitcher.js) against the simulated
// GNOME Shell: recording copies from Meta.Selection, skipping password managers, excluded apps and
// Slated's own writes, saving privately in the Mac app's format, and the switcher's keys and pasting.

import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, existsSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {after, beforeEach, test} from 'node:test';

import {createFakeGnome, fakeEvent} from './fake-gnome.mjs';
import {MemoryLog} from './fixtures.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {ClipboardService, lineCount, looksLikePassword} = await import('../../gnome-extension/lib/platform/clipboard.js');
const {ClipboardSwitcher, SwitcherModel, itemPreview, lengthDescription, relativeTime, switcherKey} = await import(
  '../../gnome-extension/lib/platform/clipboardSwitcher.js'
);
const {InputInjector} = await import('../../gnome-extension/lib/platform/input.js');
const {Timers} = await import('../../gnome-extension/lib/platform/timers.js');
const {appIdentity} = await import('../../gnome-extension/lib/platform/util.js');
const Core = await import('../../gnome-extension/lib/core/index.js');

const homes = [];
after(() => {
  for (const dir of homes) rmSync(dir, {recursive: true, force: true});
});

/** A switcher stand-in that records what the service asks of it. */
class FakeSwitcher {
  constructor(model) {
    this.model = model;
    this.opened = 0;
    this.closed = 0;
    this.refreshed = 0;
  }
  open() {
    this.opened++;
    this.model.reset();
    return true;
  }
  close() {
    this.closed++;
  }
  refresh() {
    this.refreshed++;
  }
  destroy() {}
}

const NOW = Date.UTC(2026, 9, 22, 12, 0, 0);
let world;

beforeEach(() => {
  const home = mkdtempSync(join(tmpdir(), 'slated-clipboard-'));
  homes.push(home);
  Object.assign(gnome.state, {clipboard: null, clipboardMimeTypes: [], clipboardWrites: [], typed: []});
  world = {
    home,
    path: join(home, '.local/state/slated/clipboard.json'),
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
    makeSwitcher: makeSwitcher ?? ((model) => (world.switcher = new FakeSwitcher(model))),
  });
  s.apply({excludedApps: ['com.bitwarden.desktop', 'org.keepassxc.KeePassXC.desktop'], ...settings});
  return s;
}

const texts = (s) => s.history.items.map((i) => i.text);

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

test('picking an item pastes it into the window you were in; copying doesn’t paste', () => {
  const s = service();
  gnome.copy('older');
  gnome.copy('newest');
  const editor = world.focusedWindow;
  assert.deepEqual(s.showSwitcher(), {ok: true});
  assert.equal(world.switcher.opened, 1);
  world.focusedWindow = {id: 'somewhere else'};
  const olderId = s.history.items.find((i) => i.text === 'older').id;
  s.switcherModel.paste(olderId);
  assert.equal(world.switcher.closed, 1, 'the switcher closes first');
  assert.equal(gnome.state.clipboard, 'older');
  assert.deepEqual(texts(s), ['older', 'newest'], 'moved to the top, not recorded twice');
  assert.deepEqual(world.activated, ['editor'], 'the previous window comes back');
  assert.equal(world.pastes, 0);
  gnome.loop.advance(150);
  assert.equal(world.pastes, 1, 'then the paste shortcut');
  assert.deepEqual(world.log.named('clipboard.pasted')[0].data, {chars: 5, app: 'org.gnome.TextEditor'});
  assert.equal(editor, world.focusedWindow);

  s.showSwitcher();
  s.switcherModel.copy(s.history.items[1].id);
  gnome.loop.advance(500);
  assert.equal(world.pastes, 1, 'copy only');
  assert.equal(gnome.state.clipboard, 'newest');

  s.apply({pasteAfterSelecting: false});
  s.showSwitcher();
  s.switcherModel.paste(s.history.items[1].id);
  gnome.loop.advance(500);
  assert.equal(world.pastes, 1, 'pasteAfterSelecting off: just the clipboard');
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

test('the switcher model: search, selection, keys and Ctrl+1–9', () => {
  const calls = [];
  let history = new Core.ClipboardHistory();
  for (const [i, t] of ['alpha', 'beta', 'gamma', 'delta'].entries()) history.add(t, {at: i, limit: 10});
  const model = new SwitcherModel({
    history: () => history,
    actions: {
      paste: (id) => calls.push(['paste', history.items.find((i) => i.id === id).text]),
      copy: (id) => calls.push(['copy', history.items.find((i) => i.id === id).text]),
      togglePin: (id) => history.togglePin(id),
      delete: (id) => history.remove(id),
      clear: () => history.clear(),
      close: () => calls.push(['close']),
    },
  });
  const changes = [];
  model.onChange = (what) => changes.push(what);
  model.reset();
  const selected = () => history.items.find((i) => i.id === model.selectedId)?.text ?? null;
  assert.equal(selected(), 'delta');
  assert.equal(model.handleKey({name: 'Down'}), true);
  assert.equal(selected(), 'gamma');
  model.handleKey({name: 'Up'});
  model.handleKey({name: 'Up'});
  assert.equal(selected(), 'delta', 'stays on the first item');
  model.handleKey({name: 'Page_Down'});
  assert.equal(selected(), 'alpha', 'stops at the last');
  assert.equal(model.handleKey({name: 'p', ctrl: true}), true);
  assert.equal(history.items.find((i) => i.text === 'alpha').pinned, true);
  assert.equal(model.results[0].text, 'alpha', 'pinned items come first');
  model.setQuery('ta');
  assert.deepEqual(model.results.map((i) => i.text), ['delta', 'beta']);
  assert.equal(selected(), 'delta', 'a new query selects the first result');
  assert.equal(model.handleKey({name: 'x'}), false, 'typing goes to the search field');
  assert.equal(model.handleKey({name: 'c'}), false, 'c without Ctrl is typing too');
  model.handleKey({name: 'BackSpace', ctrl: true});
  assert.deepEqual(history.items.map((i) => i.text).sort(), ['alpha', 'beta', 'gamma']);
  assert.equal(selected(), 'beta', 'the next item takes its place');
  assert.equal(model.handleKey({name: '2', ctrl: true}), true);
  assert.deepEqual(calls, [], 'Ctrl+2 with one result does nothing');
  model.setQuery('');
  model.handleKey({name: '2', ctrl: true});
  assert.deepEqual(calls.slice(-2), [['close'], ['paste', 'gamma']], 'Ctrl+2 pastes the second result');
  model.handleKey({name: 'c', ctrl: true});
  assert.deepEqual(calls.slice(-2), [['close'], ['copy', 'alpha']]);
  model.handleKey({name: 'Return'});
  assert.deepEqual(calls.at(-1), ['paste', 'alpha']);
  model.handleKey({name: 'Escape'});
  assert.deepEqual(calls.at(-1), ['close']);
  model.handleKey({name: 'Delete', ctrl: true, shift: true});
  assert.deepEqual(history.items.map((i) => i.text), ['alpha'], 'Ctrl+Shift+Delete clears all but pinned');
  model.select(model.selectedId);
  assert.ok(changes.includes('selection') && changes.includes('results'));
});

test('switcher keys: keysyms, keypad digits, and keycodes for Ctrl+1 on AZERTY and Ctrl+C on other scripts', () => {
  const masks = {CONTROL_MASK: 4, SHIFT_MASK: 1};
  assert.deepEqual(switcherKey(0xff54, 116, 0, masks), {name: 'Down', ctrl: false, shift: false});
  assert.deepEqual(switcherKey(0xff8d, 104, 0, masks), {name: 'Return', ctrl: false, shift: false});
  assert.deepEqual(switcherKey(0x26, 10, 4, masks), {name: '1', ctrl: true, shift: false}, 'AZERTY: the 1 key types &');
  assert.deepEqual(switcherKey(0xffb3, 89, 4, masks), {name: '3', ctrl: true, shift: false});
  assert.deepEqual(switcherKey(0x6c3, 54, 4, masks), {name: 'c', ctrl: true, shift: false}, 'Cyrillic es on the C key');
  assert.deepEqual(switcherKey(0x43, 54, 5, masks), {name: 'c', ctrl: true, shift: true});
  assert.deepEqual(switcherKey(0xff08, 22, 5, masks), {name: 'BackSpace', ctrl: true, shift: true});
  assert.deepEqual(switcherKey(0x26, 10, 0, masks), {name: '&', ctrl: false, shift: false}, 'without Ctrl it is typing');
});

test('a huge copy is searched only at its start, and searching it twice reuses the fold', () => {
  const history = new Core.ClipboardHistory();
  history.add(`${'a'.repeat(30_000)} needle`, {at: 0, limit: 10});
  history.add('needle in a small copy', {at: 1, limit: 10});
  assert.equal(history.search('needle').length, 2, 'the core searches everything by default');
  const model = new SwitcherModel({history: () => history, actions: {}});
  model.setQuery('needle');
  assert.deepEqual(model.results.map((i) => i.text), ['needle in a small copy'], 'the switcher searches the first 20,000 characters');
  const started = Date.now();
  for (let i = 0; i < 20; i++) model.setQuery(i % 2 ? 'aaa' : 'needle');
  assert.ok(Date.now() - started < 1000, 'typing doesn’t refold the big item');
  assert.equal(itemPreview('x'.repeat(1_000_000)).length, 241);
});

test('previews, lengths and times read like the Mac switcher', () => {
  assert.equal(itemPreview('  first line  \n\n second\r\nthird  '), 'first line ⏎ second ⏎ third');
  assert.equal([...itemPreview('x'.repeat(300))].length, 241);
  assert.equal(lengthDescription('hello'), '5 characters');
  assert.equal(lengthDescription('a\nb\n\nc'), '3 lines');
  assert.equal(lineCount('a\r\nb'), 2);
  const at = Core.referenceSeconds(NOW);
  assert.equal(relativeTime(at, NOW + 20_000), 'just now');
  assert.equal(relativeTime(at, NOW + 5 * 60_000), '5 min ago');
  assert.equal(relativeTime(at, NOW + 3 * 3_600_000), '3 h ago');
  assert.equal(relativeTime(at, NOW + 30 * 3_600_000), 'yesterday');
  assert.equal(relativeTime(at, NOW + 4 * 86_400_000), '4 days ago');
});

test('the St switcher opens modal, filters as you type, and closes on Escape or a click outside', () => {
  const s = service({}, {makeSwitcher: (model) => (world.panel = new ClipboardSwitcher({model, now: () => world.now}))});
  for (const t of ['apple pie', 'banana bread', 'cherry tart']) gnome.copy(t);
  assert.deepEqual(s.showSwitcher(), {ok: true});
  assert.equal(gnome.state.modal.length, 1, 'a modal grab');
  const panel = world.panel;
  const rows = () => panel._list.children;
  const rowText = (row) => row.find((a) => a.style_class === 'slated-clipboard-text')[0].text;
  assert.deepEqual(rows().map(rowText), ['cherry tart', 'banana bread', 'apple pie']);
  assert.ok(rows()[0].pseudoClasses.has('selected'));
  assert.equal(panel._count.text, '3');

  panel._entry.set_text('an');
  assert.deepEqual(rows().map(rowText), ['banana bread']);
  const key = (keysym, state = 0, keycode = 0) =>
    panel._entry.clutter_text.emit('key-press-event', {...fakeEvent({keysym}), get_key_code: () => keycode, get_state: () => state});
  panel._entry.set_text('');
  key(0xff54); // Down
  assert.ok(rows()[1].pseudoClasses.has('selected') && !rows()[0].pseudoClasses.has('selected'), 'only the highlight moves');
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
  assert.equal(gnome.state.clipboard, 'apple pie', 'clicking a row pastes it');
  s.stop();
});
