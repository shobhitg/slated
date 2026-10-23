import assert from 'node:assert/strict';
import {test} from 'node:test';

import {KeybindingManager, normalizeAccelerator} from '../../gnome-extension/lib/platform/keybindings.js';
import {fakeCore} from './fake-core.mjs';
import {MemoryLog} from './fixtures.mjs';

/** Mutter's accelerator grabs in miniature: refuses taken accelerators, records repeat flags. */
class FakeGrabber {
  constructor({taken = []} = {}) {
    this.taken = new Set(taken);
    this.grabs = new Map();
    this.next = 1;
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
