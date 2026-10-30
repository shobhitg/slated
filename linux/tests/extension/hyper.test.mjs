import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

import {createFakeGnome} from './fake-gnome.mjs';
import {MemoryLog} from './fixtures.mjs';

const gnome = createFakeGnome();
globalThis.__slatedGnomeFakes = gnome.modules;
globalThis.global = gnome.global;
const {HyperManager, acceleratorOptions, chooseHyperMode, mapsCapsLock, withCapsHyper, withoutCapsHyper} = await import(
  '../../gnome-extension/lib/platform/hyper.js'
);

test('adding caps:hyper keeps the other options and sets conflicting caps options aside', () => {
  assert.deepEqual(withCapsHyper(['compose:ralt', 'caps:escape', 'lv3:ralt_switch']), {
    options: ['compose:ralt', 'lv3:ralt_switch', 'caps:hyper'],
    removed: ['caps:escape'],
    added: true,
    changed: true,
  });
  assert.deepEqual(withCapsHyper([]), {options: ['caps:hyper'], removed: [], added: true, changed: true});
});

test('an existing caps:hyper is left alone and never counted as Slated’s', () => {
  const result = withCapsHyper(['compose:ralt', 'caps:hyper']);
  assert.equal(result.changed, false);
  assert.equal(result.added, false);
  assert.deepEqual(result.options, ['compose:ralt', 'caps:hyper']);
});

test('removing caps:hyper restores what was set aside, without duplicates', () => {
  assert.deepEqual(withoutCapsHyper(['compose:ralt', 'caps:hyper'], ['caps:escape']), ['compose:ralt', 'caps:escape']);
  assert.deepEqual(withoutCapsHyper(['caps:escape', 'caps:hyper'], ['caps:escape']), ['caps:escape']);
  assert.deepEqual(withoutCapsHyper(['compose:ralt']), ['compose:ralt']);
});

test('round trip leaves the user’s options as they were (order aside)', () => {
  const original = ['compose:ralt', 'caps:ctrl_modifier'];
  const added = withCapsHyper(original);
  assert.deepEqual(withoutCapsHyper(added.options, added.removed).sort(), [...original].sort());
});

test('mode choice: off, keyd when it runs, otherwise xkb', () => {
  assert.equal(chooseHyperMode({wanted: false, keyd: true}), 'off');
  assert.equal(chooseHyperMode({wanted: true, keyd: true}), 'keyd');
  assert.equal(chooseHyperMode({wanted: true, keyd: false}), 'xkb');
  assert.deepEqual(acceleratorOptions('xkb'), {hyperMode: 'xkb'});
  assert.deepEqual(acceleratorOptions('keyd'), {});
  assert.deepEqual(acceleratorOptions('off'), {});
});

const XKB = 'org.gnome.desktop.input-sources:xkb-options';
const xkbOptions = () => gnome.state.settings[XKB];
const MAPS_CAPS = '[ids]\n*\n\n[main]\ncapslock = layer(hyper)\n';
// The docs' example: keyd only for a mouse's side buttons.
const SIDE_BUTTONS = '[ids]\nm:046d:c52b\n\n[main]\nmouse1 = f13\nmouse2 = f14\n';

/** A throwaway /etc/keyd and keyd socket, and a HyperManager looking there. */
function keydWorld() {
  const dir = mkdtempSync(join(tmpdir(), 'slated-hyper-'));
  const etc = join(dir, 'etc/keyd');
  mkdirSync(etc, {recursive: true});
  const world = {dir, etc, config: join(etc, 'slated.conf'), socket: join(dir, 'keyd.socket'), detected: 0};
  world.manager = new HyperManager({
    log: new MemoryLog(), statePath: join(dir, 'hyper.json'), socketPath: world.socket, keydConfigPath: world.config,
    onDetected: () => world.detected++,
  });
  world.cleanup = () => rmSync(dir, {recursive: true, force: true});
  return world;
}

const unitChanged = (properties) => gnome.systemSignal('org.freedesktop.DBus.Properties.PropertiesChanged', ['org.freedesktop.systemd1.Unit', properties, []]);

test('keyd maps Caps Lock only with a capslock line in its [main] section', () => {
  assert.equal(mapsCapsLock(MAPS_CAPS), true);
  assert.equal(mapsCapsLock('[main]\n  capslock=overload(control, esc)  # tap for Esc\n'), true);
  assert.equal(mapsCapsLock('[ids]\n*\n\n[global]\noverload_tap_timeout = 500\n\n[main]\ncapslock = overload(hyper, esc)\n'), true,
    'after a [global] section, as linux/install.sh writes it for the tap');
  assert.equal(mapsCapsLock(SIDE_BUTTONS), false);
  assert.equal(mapsCapsLock('[main]\n# capslock = esc\n\n[nav]\ncapslock = esc\n'), false, 'a comment, or another layer');
  assert.equal(mapsCapsLock(''), false);
});

test('without systemd, keyd is the Hyper key when its socket exists and a keyd config maps Caps Lock', () => {
  const world = keydWorld();
  const {manager} = world;
  gnome.state.settings[XKB] = ['compose:ralt'];
  writeFileSync(world.socket, ''); // keyd runs, but only for the side buttons
  writeFileSync(join(world.etc, 'mouse.conf'), SIDE_BUTTONS);
  manager.detect();
  assert.equal(manager.keyd, false, 'keyd leaves Caps Lock alone');
  assert.deepEqual(manager.apply({wanted: true}), {wanted: true, mode: 'xkb', active: true, hyperIsSuper: true, pending: false, keyd: 'none'});
  assert.deepEqual(xkbOptions(), ['compose:ralt', 'caps:hyper']);

  writeFileSync(join(world.etc, 'mouse.conf'), `${SIDE_BUTTONS}capslock = layer(hyper)\n`); // you map it there
  gnome.fileChanged(world.etc);
  assert.equal(world.detected, 1, 'the runtime is told to apply again');
  assert.deepEqual(manager.apply({wanted: true}), {wanted: true, mode: 'keyd', active: true, hyperIsSuper: false, pending: false, keyd: 'running'});
  assert.deepEqual(xkbOptions(), ['compose:ralt'], 'caps:hyper is taken back');
  gnome.fileChanged(world.socket);
  assert.equal(world.detected, 1, 'only changes count');

  writeFileSync(join(world.etc, 'mouse.conf'), SIDE_BUTTONS); // and take it out again; keyd keeps running
  gnome.fileChanged(world.etc);
  assert.equal(world.detected, 2);
  assert.equal(manager.apply({wanted: true}).mode, 'xkb', 'GNOME’s option is back');
  assert.deepEqual(xkbOptions(), ['compose:ralt', 'caps:hyper']);

  manager.destroy();
  assert.equal(gnome.state.monitors.get(world.socket)?.size ?? 0, 0, 'the watches end with the extension');
  assert.equal(gnome.state.monitors.get(world.etc)?.size ?? 0, 0);
  assert.deepEqual(xkbOptions(), ['compose:ralt']);
  world.cleanup();
});

test('linux/install.sh --hyper-keyd and --remove switch modes while Slated runs', () => {
  const world = keydWorld();
  const {manager} = world;
  writeFileSync(world.socket, '');
  manager.detect();
  assert.equal(manager.keyd, false, 'keyd runs with no config yet');
  writeFileSync(world.config, MAPS_CAPS);
  gnome.fileChanged(world.etc);
  assert.deepEqual([manager.keyd, world.detected], [true, 1]);
  rmSync(world.config);
  gnome.fileChanged(world.etc);
  assert.deepEqual([manager.keyd, world.detected], [false, 2], 'keyd still runs, but no longer maps Caps Lock');
  rmSync(world.socket);
  writeFileSync(world.config, MAPS_CAPS);
  gnome.fileChanged(world.etc);
  assert.deepEqual([manager.keyd, world.detected], [false, 2], 'mapped, but keyd isn’t running');
  manager.destroy();
  world.cleanup();
});

test('with systemd, keyd is the Hyper key only while keyd.service is active: it leaves its socket behind when it stops', () => {
  const world = keydWorld();
  const {manager} = world;
  Object.assign(gnome.state, {programs: {systemctl: '/usr/bin/systemctl'}, subprocesses: [], dbusCalls: []});
  const asked = () => gnome.state.subprocesses;
  writeFileSync(world.config, MAPS_CAPS);
  writeFileSync(world.socket, '');
  manager.detect();
  assert.equal(manager.keyd, null, 'systemd is asked, although the socket exists');
  assert.equal(manager.apply({wanted: true}).pending, true);
  assert.deepEqual(asked().map((p) => p.argv), [['/usr/bin/systemctl', 'is-active', '--quiet', 'keyd']]);
  asked()[0].exit(true);
  assert.deepEqual([manager.keyd, world.detected], [true, 1]);
  gnome.loop.run();
  assert.deepEqual(gnome.state.dbusCalls, ['org.freedesktop.systemd1.Manager.Subscribe'], 'systemd announces keyd.service’s changes');

  unitChanged({ActiveState: 'deactivating'}); // sudo systemctl disable --now keyd
  assert.deepEqual([manager.keyd, world.detected], [true, 1], 'no news until systemd answers');
  asked()[1].exit(false);
  assert.deepEqual([manager.keyd, world.detected], [false, 2]);
  assert.equal(manager.apply({wanted: true}).mode, 'xkb', 'Caps Lock is Hyper through GNOME again');
  unitChanged({SubState: 'dead'});
  assert.equal(asked().length, 2, 'other properties don’t matter');

  unitChanged({ActiveState: 'activating'}); // keyd starts again
  gnome.fileChanged(world.socket); // ...and makes its socket
  asked()[3].exit(true);
  asked()[2].exit(false); // the older answer, from before keyd was up, comes last
  assert.deepEqual([manager.keyd, world.detected], [true, 3], 'the newest answer wins');

  gnome.fileChanged(world.socket);
  manager.destroy();
  assert.doesNotThrow(() => asked()[4].exit(false), 'an answer after disable is dropped');
  assert.equal(world.detected, 3);
  assert.equal(gnome.signals.systemBus.size, 0, 'the D-Bus subscription ends with the extension');
  assert.ok(gnome.state.dbusCalls.includes('org.freedesktop.systemd1.Manager.Unsubscribe'));
  Object.assign(gnome.state, {programs: {}, subprocesses: undefined});
  world.cleanup();
});

test('without a keyd config that maps Caps Lock, systemd isn’t even asked', () => {
  const world = keydWorld();
  Object.assign(gnome.state, {programs: {systemctl: '/usr/bin/systemctl'}, subprocesses: [], dbusCalls: []});
  writeFileSync(join(world.etc, 'mouse.conf'), SIDE_BUTTONS);
  world.manager.detect();
  assert.equal(world.manager.keyd, false);
  assert.deepEqual([gnome.state.subprocesses.length, gnome.state.dbusCalls.length], [0, 0]);
  world.manager.destroy();
  Object.assign(gnome.state, {programs: {}, subprocesses: undefined});
  world.cleanup();
});
