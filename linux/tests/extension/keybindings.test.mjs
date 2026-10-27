import assert from 'node:assert/strict';
import {test} from 'node:test';

import {
  KeybindingManager,
  MIN_RELEASE_MS,
  MODIFIER_KEY_REASON,
  MOUSE_BUTTON_REASON,
  normalizeAccelerator,
  releaseTiming,
} from '../../gnome-extension/lib/platform/keybindings.js';
import {appIdentity} from '../../gnome-extension/lib/platform/util.js';
import * as realCore from '../../gnome-extension/lib/core/index.js';
import {fakeCore} from './fake-core.mjs';
import {FakeTimers, MemoryLog} from './fixtures.mjs';

/** Mutter's accelerator grabs in miniature: refuses taken accelerators, records repeat flags. */
class FakeGrabber {
  constructor({taken = []} = {}) {
    this.taken = new Set(taken);
    this.grabs = new Map();
    this.next = 1;
    this.timers = new FakeTimers();
    this.deferred = 0;
  }
  timeout(ms, callback) {
    return this.timers.timeout(ms, callback);
  }
  clearTimeout(id) {
    this.timers.clear(id);
  }
  connect(callback) {
    this.callback = callback;
  }
  grab(accelerator, {repeats}) {
    if (this.taken.has(accelerator) || [...this.grabs.values()].some((g) => g.accelerator === accelerator)) {
      return {ok: false, reason: `${accelerator} is taken`};
    }
    const action = this.next++;
    this.grabs.set(action, {accelerator, repeats});
    return {ok: true, action};
  }
  ungrab(action) {
    this.grabs.delete(action);
  }
  defer(callback) {
    this.deferred += 1;
    callback();
  }
  destroy() {
    this.destroyed = true;
  }
  /** Simulates pressing the shortcut. */
  press(accelerator) {
    for (const [action, grab] of this.grabs) {
      if (grab.accelerator === accelerator) {
        this.callback(action);
        return true;
      }
    }
    return false;
  }
  accelerators() {
    return [...this.grabs.values()].map((g) => g.accelerator).sort();
  }
}

const acceleratorFor = (combo) => fakeCore.toGnomeAccelerator(combo);
const combo = (text) => fakeCore.parseKeyCombo(text);

function entry(keys, {modal = null, repeats = false, runs = []} = {}) {
  const id = (modal ? `${modal.text} ` : '') + keys;
  return {
    id,
    keys: combo(keys),
    modal: modal ? {keys: combo(modal.text), toggle: !!modal.toggle} : null,
    repeats,
    source: 'test',
    run: () => runs.push(id),
  };
}

test('bindings register, run on activation, and report statuses', () => {
  const grabber = new FakeGrabber({taken: ['<Super>a']});
  const log = new MemoryLog();
  const manager = new KeybindingManager({grabber, log});
  const runs = [];
  manager.apply(
    [
      entry('hyper+a', {runs}),
      entry('cmd+a', {runs}),
      entry('hyper+d', {runs, repeats: true}),
      entry('hyper+a', {runs}), // a Slate-file duplicate
    ],
    {disabled: ['hyper+z', 'hyper+d'], acceleratorFor},
  );
  assert.deepEqual(manager.statuses, {
    'hyper+a': 'duplicate',
    'cmd+a': 'failed: <Super>a is taken',
    'hyper+d': 'active',
    'hyper+z': 'disabled',
  });
  assert.deepEqual(manager.duplicates, ['hyper+a']);
  assert.ok(grabber.press('<Control><Alt><Shift><Super>a'));
  assert.deepEqual(runs, ['hyper+a']);
  // Repeating bindings leave Mutter's auto-repeat on; others ignore it.
  const flags = Object.fromEntries([...grabber.grabs.values()].map((g) => [g.accelerator, g.repeats]));
  assert.deepEqual(flags, {'<Control><Alt><Shift><Super>a': false, '<Control><Alt><Shift><Super>d': true});

  const registered = log.named('hotkeys.registered');
  assert.equal(registered.length, 1);
  assert.equal(registered[0].level, 'error');
  assert.deepEqual(registered[0].data, {active: 2, total: 4, failed: ['cmd+a: <Super>a is taken'], duplicates: ['hyper+a']});
});

test('re-applying the same bindings ungrabs everything first and logs only changes', () => {
  const grabber = new FakeGrabber();
  const log = new MemoryLog();
  const manager = new KeybindingManager({grabber, log});
  const entries = [entry('hyper+a'), entry('hyper+s')];
  manager.apply(entries, {acceleratorFor});
  manager.apply(entries, {acceleratorFor});
  assert.equal(grabber.grabs.size, 2);
  assert.equal(log.named('hotkeys.registered').length, 1);
  manager.unregisterAll();
  assert.equal(grabber.grabs.size, 0);
  manager.destroy();
  assert.ok(grabber.destroyed);
});

test('keys GNOME can’t express fail with a reason instead of throwing', () => {
  const manager = new KeybindingManager({grabber: new FakeGrabber()});
  manager.apply([entry('fn+a'), entry('hyper+b')], {
    acceleratorFor: (c) => {
      if (c.key === 'b') throw new Error('unknown key');
      return null;
    },
  });
  assert.equal(manager.statuses['fn+a'], "failed: this key can't be used in a GNOME shortcut");
  assert.match(manager.statuses['hyper+b'], /^failed: can't be expressed as a GNOME shortcut \(unknown key\)$/);
});

test('modal keys grab their bindings only while modal mode is on', () => {
  const grabber = new FakeGrabber();
  const log = new MemoryLog();
  const modalChanges = [];
  const manager = new KeybindingManager({grabber, log, onModalChange: (id) => modalChanges.push(id)});
  const runs = [];
  const modal = {text: 'ctrl+alt+f4'};
  manager.apply([entry('1', {modal, runs}), entry('2', {modal, runs})], {acceleratorFor, escapeKeys: combo('esc')});
  assert.deepEqual(manager.statuses, {'ctrl+alt+f4 1': 'active', 'ctrl+alt+f4 2': 'active'});
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt>f4']);

  grabber.press('<Control><Alt>f4');
  assert.deepEqual(grabber.accelerators(), ['1', '2', '<Control><Alt>f4', 'Escape']);
  assert.equal(log.named('modal.entered')[0].data.keys, 'ctrl+alt+f4');

  grabber.press('2');
  assert.deepEqual(runs, ['ctrl+alt+f4 2']);
  // Without :toggle, one binding ends modal mode.
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt>f4']);
  assert.equal(log.named('modal.exited').length, 1);
  assert.equal(modalChanges.length, 2);
  assert.equal(modalChanges[1], null);
});

test('toggle modal bindings stay in modal mode until the escape key', () => {
  const grabber = new FakeGrabber();
  const manager = new KeybindingManager({grabber});
  const runs = [];
  const modal = {text: 'ctrl+alt+f4', toggle: true};
  manager.apply([entry('1', {modal, runs})], {acceleratorFor, escapeKeys: combo('esc')});
  grabber.press('<Control><Alt>f4');
  grabber.press('1');
  grabber.press('1');
  assert.deepEqual(runs, ['ctrl+alt+f4 1', 'ctrl+alt+f4 1']);
  assert.ok(manager.activeModal);
  grabber.press('Escape');
  assert.equal(manager.activeModal, null);
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt>f4']);
});

test('pressing the modal key again leaves modal mode', () => {
  const grabber = new FakeGrabber();
  const manager = new KeybindingManager({grabber});
  manager.apply([entry('1', {modal: {text: 'ctrl+alt+f4'}})], {acceleratorFor});
  grabber.press('<Control><Alt>f4');
  assert.ok(manager.activeModal);
  grabber.press('<Control><Alt>f4');
  assert.equal(manager.activeModal, null);
});

test('trigger runs a binding as if pressed (debug interface)', () => {
  const runs = [];
  const manager = new KeybindingManager({grabber: new FakeGrabber()});
  manager.apply([entry('hyper+a', {runs}), entry('1', {modal: {text: 'ctrl+alt+f4'}, runs})], {acceleratorFor});
  assert.equal(manager.trigger('hyper+a'), true);
  assert.equal(manager.trigger('ctrl+alt+f4 1'), true);
  assert.equal(manager.trigger('hyper+q'), false);
  assert.deepEqual(runs, ['hyper+a', 'ctrl+alt+f4 1']);
});

test('a throwing binding is logged, not propagated into Mutter', () => {
  const grabber = new FakeGrabber();
  const log = new MemoryLog();
  const manager = new KeybindingManager({grabber, log});
  const bad = entry('hyper+a');
  bad.run = () => {
    throw new Error('boom');
  };
  manager.apply([bad], {acceleratorFor});
  assert.doesNotThrow(() => grabber.press('<Control><Alt><Shift><Super>a'));
  assert.equal(log.named('hotkeys.handler_failed')[0].data.message, 'boom');
});

test('accelerators compare by modifiers and key, Hyper counting as Super in xkb mode', () => {
  assert.equal(normalizeAccelerator('<Super><Shift>Left'), 'shift+super+left');
  assert.equal(normalizeAccelerator('<Shift><Super>left'), 'shift+super+left');
  assert.equal(normalizeAccelerator('<Primary><Alt>t'), 'alt+ctrl+t');
  assert.equal(normalizeAccelerator('<Hyper>a', {hyperIsSuper: true}), normalizeAccelerator('<Super>a'));
  assert.notEqual(normalizeAccelerator('<Hyper>a'), normalizeAccelerator('<Super>a'));
  assert.equal(normalizeAccelerator(''), null);
  assert.equal(normalizeAccelerator('<Super>'), null);
});

// --- Game automation: per-app bindings, mouse buttons, modifier keys, while-held -----------------

const realAccelerator = (combo) => realCore.toGnomeAccelerator(combo);
const realCombo = (text) => realCore.parseKeyCombo(text);

function appEntry(keys, apps, runs, extra = {}) {
  return {id: keys, keys: realCombo(keys), modal: null, repeats: false, source: 'test', apps, run: () => runs.push(keys), ...extra};
}

test('app-specific bindings are grabbed only while one of their apps has focus', () => {
  const grabber = new FakeGrabber();
  const log = new MemoryLog();
  const manager = new KeybindingManager({grabber, log});
  const runs = [];
  manager.setFocusedApp(appIdentity('firefox'));
  manager.apply(
    [
      appEntry('f', ['org.prismlauncher.PrismLauncher.desktop'], runs),
      appEntry('g', ['steam_app_1086940'], runs),
      appEntry('hyper+x', [], runs),
    ],
    {acceleratorFor: realAccelerator},
  );
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt><Shift><Super>x'], 'only the global binding while Firefox has focus');
  assert.deepEqual(manager.statuses, {f: 'active', g: 'active', 'hyper+x': 'active'}, 'app bindings count as ready');

  // The launcher's desktop id, written with ".desktop", matches without it too.
  assert.equal(manager.setFocusedApp(appIdentity('org.prismlauncher.PrismLauncher')), true);
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt><Shift><Super>x', 'f']);
  assert.ok(grabber.press('f'));
  assert.deepEqual(runs, ['f']);

  // A Proton game without a desktop file is known by its window's WM_CLASS.
  manager.setFocusedApp(appIdentity('window:12', ['steam_app_1086940']));
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt><Shift><Super>x', 'g'], 'f is let go, g grabbed');

  const deferred = grabber.deferred;
  assert.equal(manager.setFocusedApp(appIdentity('window:13', ['steam_app_1086940'])), false, 'same bindings: nothing to redo');
  assert.equal(grabber.deferred, deferred);
  manager.setFocusedApp(null);
  assert.deepEqual(grabber.accelerators(), ['<Control><Alt><Shift><Super>x'], 'the overview: no app bindings');
  assert.equal(log.named('hotkeys.registered').length, 1, 'app switches that change no problem aren’t logged as registrations');
});

test('an app binding duplicates a global one only while its app has focus', () => {
  const grabber = new FakeGrabber();
  const manager = new KeybindingManager({grabber});
  const runs = [];
  const entries = [appEntry('f', ['minecraft'], runs), appEntry('f', [], runs)];
  manager.apply(entries, {acceleratorFor: realAccelerator});
  assert.deepEqual(manager.statuses, {f: 'active'});
  assert.deepEqual(manager.duplicates, []);
  manager.setFocusedApp(appIdentity('Minecraft'));
  assert.deepEqual(manager.duplicates, ['f'], 'the app binding wins in its app');
  assert.equal(grabber.accelerators().length, 1);
});

test('mouse buttons and lone modifier keys fail with reasons, even for app bindings', () => {
  const grabber = new FakeGrabber();
  const manager = new KeybindingManager({grabber});
  manager.apply(
    [
      appEntry('mouse4', [], []),
      appEntry('ctrl+mouse5', [], []),
      appEntry('shift', [], []),
      appEntry('mouse3', ['minecraft'], []),
      appEntry('rightAlt', ['minecraft'], []),
    ],
    {acceleratorFor: realAccelerator},
  );
  assert.equal(manager.statuses.mouse4, `failed: ${MOUSE_BUTTON_REASON}`);
  assert.equal(manager.statuses['ctrl+mouse5'], `failed: ${MOUSE_BUTTON_REASON}`);
  assert.equal(manager.statuses.shift, `failed: ${MODIFIER_KEY_REASON}`);
  assert.equal(manager.statuses.mouse3, `failed: ${MOUSE_BUTTON_REASON}`, 'reported before the app is ever focused');
  assert.equal(manager.statuses.rightAlt, `failed: ${MODIFIER_KEY_REASON}`);
  assert.match(MOUSE_BUTTON_REASON, /keyd/);
  assert.deepEqual(grabber.accelerators(), []);
});

test('release timing follows GNOME’s keyboard repeat, with a floor for slow main loops', () => {
  assert.deepEqual(releaseTiming({delayMs: 500, intervalMs: 30}), {firstMs: 500 + MIN_RELEASE_MS, nextMs: MIN_RELEASE_MS});
  assert.deepEqual(releaseTiming({delayMs: 250, intervalMs: 80}), {firstMs: 410, nextMs: 160});
});

test('a holdable binding runs once per press; key repeats keep it held until they stop', () => {
  const grabber = new FakeGrabber();
  const releases = [];
  const runs = [];
  const manager = new KeybindingManager({grabber, onRelease: (entry) => releases.push(entry.id)});
  manager.apply([appEntry('f', [], runs, {holdable: true}), appEntry('g', [], runs)], {acceleratorFor: realAccelerator, holdTiming: releaseTiming({delayMs: 500, intervalMs: 30})});
  const flags = Object.fromEntries([...grabber.grabs.values()].map((g) => [g.accelerator, g.repeats]));
  assert.deepEqual(flags, {f: true, g: false}, 'the holdable grab listens to key repeat');

  grabber.press('f'); // press
  assert.deepEqual(runs, ['f']);
  grabber.timers.advance(500); // GNOME's repeat delay
  for (let i = 0; i < 10; i++) {
    grabber.press('f'); // a key-repeat activation every 30 ms
    grabber.timers.advance(30);
  }
  assert.deepEqual(runs, ['f'], 'repeats are heartbeats, not new presses');
  assert.deepEqual(manager.heldKeys, ['f']);
  grabber.timers.advance(MIN_RELEASE_MS - 31);
  assert.deepEqual(releases, [], 'still within the release window');
  grabber.timers.advance(2);
  assert.deepEqual(releases, ['f'], 'no repeat for ~2× the interval: released');
  assert.deepEqual(manager.heldKeys, []);

  grabber.press('f');
  assert.deepEqual(runs, ['f', 'f'], 'the next press runs again');
  grabber.timers.advance(600);
  assert.deepEqual(releases, ['f', 'f'], 'a quick tap is released after the delay plus the window');
});

test('without keyboard repeat nothing is holdable: while-held bindings work like toggles', () => {
  const grabber = new FakeGrabber();
  const releases = [];
  const runs = [];
  const manager = new KeybindingManager({grabber, onRelease: (entry) => releases.push(entry.id)});
  manager.apply([appEntry('f', [], runs, {holdable: true})], {acceleratorFor: realAccelerator, holdTiming: null});
  assert.equal([...grabber.grabs.values()][0].repeats, false, 'key repeat is ignored like any toggle');
  grabber.press('f');
  grabber.timers.advance(5000);
  grabber.press('f');
  assert.deepEqual(runs, ['f', 'f'], 'each press reaches the action, which toggles');
  assert.deepEqual(releases, []);
});

test('re-applying or switching apps lets go of held keys', () => {
  const grabber = new FakeGrabber();
  const releases = [];
  const manager = new KeybindingManager({grabber, onRelease: (entry) => releases.push(entry.id)});
  const timing = releaseTiming({delayMs: 500, intervalMs: 30});
  const entries = [appEntry('f', ['minecraft'], [], {holdable: true})];
  manager.setFocusedApp(appIdentity('minecraft'));
  manager.apply(entries, {acceleratorFor: realAccelerator, holdTiming: timing});
  grabber.press('f');
  manager.setFocusedApp(appIdentity('firefox'));
  assert.deepEqual(releases, ['f']);
  assert.equal(grabber.timers.pending, 0, 'its release timer is gone');
  manager.destroy();
});
