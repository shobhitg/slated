import assert from 'node:assert/strict';
import {test} from 'node:test';

import {buildStatus, hotkeyStatusText, statusText} from '../../gnome-extension/lib/platform/status.js';

const state = {
  session: 'abcd1234',
  version: '0.1.0',
  running: true,
  paused: true,
  now: new Date('2026-10-22T10:00:00.000Z'),
  hyper: {wanted: true, mode: 'xkb', active: true, keyd: 'stopped'},
  keyRepeat: {state: 'applied', delay: 200, interval: 17},
  hotstrings: {engine: 'espanso', espansoInstalled: true, matchFile: '/home/me/.config/espanso/match/slated.yml', count: 3},
  hotkeys: {'hyper+z': 'disabled', 'hyper+a': 'active', 'hyper+q': 'failed: taken', 'hyper+w': 'duplicate'},
  automation: {running: ['Repeat click left every 100 ms', 'Hold Shift'], shortcuts: ['f6'], stopShortcut: 'hyper+esc', whileHeld: 'key-repeat'},
  clipboard: {enabled: true, items: 12, secrets: 1},
  recentApps: [{id: 'steam_app_1086940', name: 'steam_app_1086940'}, {id: 'firefox', name: 'Firefox'}],
  lastAction: 'Left half · Firefox',
  lastError: null,
};

test('status.json has exactly the schema the preferences app reads', () => {
  const status = buildStatus(state);
  assert.deepEqual(Object.keys(status), [
    'session',
    'version',
    'running',
    'paused',
    'updatedAt',
    'hyper',
    'keyRepeat',
    'hotstrings',
    'hotkeys',
    'automation',
    'clipboard',
    'recentApps',
    'lastAction',
    'lastError',
  ]);
  assert.deepEqual(status, {
    session: 'abcd1234',
    version: '0.1.0',
    running: true,
    paused: true,
    updatedAt: '2026-10-22T10:00:00.000Z',
    hyper: {wanted: true, mode: 'xkb', active: true, keyd: 'stopped'},
    keyRepeat: {state: 'applied', delay: 200, interval: 17},
    hotstrings: {engine: 'espanso', espansoInstalled: true, matchFile: '/home/me/.config/espanso/match/slated.yml', count: 3},
    hotkeys: {'hyper+a': 'active', 'hyper+q': 'failed: taken', 'hyper+w': 'duplicate', 'hyper+z': 'disabled'},
    automation: {running: ['Repeat click left every 100 ms', 'Hold Shift'], shortcuts: ['f6'], stopShortcut: 'hyper+esc', whileHeld: 'key-repeat'},
    clipboard: {enabled: true, items: 12, secrets: 1},
    recentApps: [{id: 'steam_app_1086940', name: 'steam_app_1086940'}, {id: 'firefox', name: 'Firefox'}],
    lastAction: 'Left half · Firefox',
    lastError: null,
  });
});

test('missing parts get safe defaults', () => {
  const status = buildStatus({session: 's', version: '0.1.0', running: false});
  assert.equal(status.paused, false);
  assert.deepEqual(status.hyper, {wanted: false, mode: 'off', active: false, keyd: 'none'});
  assert.deepEqual(status.keyRepeat, {state: 'off', delay: null, interval: null});
  assert.deepEqual(status.hotstrings, {engine: 'none', espansoInstalled: false, matchFile: null, count: 0});
  assert.deepEqual(status.hotkeys, {});
  assert.deepEqual(status.automation, {running: [], shortcuts: [], stopShortcut: null, whileHeld: 'key-repeat'});
  assert.deepEqual(status.clipboard, {enabled: true, items: 0, secrets: 0});
  assert.deepEqual(status.recentApps, []);
  assert.equal(status.lastAction, null);
  assert.equal(status.lastError, null);
  assert.match(status.updatedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
});

test('hyper.mode only ever takes the schema’s values', () => {
  assert.equal(buildStatus({hyper: {wanted: true, mode: 'pending'}}).hyper.mode, 'off');
  assert.equal(buildStatus({hyper: {wanted: true, mode: 'keyd', active: true}}).hyper.mode, 'keyd');
  assert.equal(buildStatus({hyper: {keyd: 'maybe'}}).hyper.keyd, 'none');
});

test('automation.whileHeld is "key-repeat" or "toggle"; clipboard items are a count', () => {
  assert.equal(buildStatus({automation: {whileHeld: 'toggle'}}).automation.whileHeld, 'toggle');
  assert.equal(buildStatus({automation: {whileHeld: 'bogus'}}).automation.whileHeld, 'key-repeat');
  assert.deepEqual(buildStatus({clipboard: {enabled: false, items: NaN}}).clipboard, {enabled: false, items: 0, secrets: 0});
  assert.deepEqual(buildStatus({clipboard: {items: 3, secrets: 2}}).clipboard, {enabled: true, items: 3, secrets: 2}, 'secrets: a count');
  assert.deepEqual(buildStatus({recentApps: [{id: 'a'}, {name: 'no id'}]}).recentApps, [{id: 'a', name: 'a'}]);
});

test('keyRepeat is applied, failed or off, with its numbers only when set', () => {
  assert.deepEqual(buildStatus({keyRepeat: {state: 'failed', delay: 500, interval: 30}}).keyRepeat, {state: 'failed', delay: 500, interval: 30});
  assert.deepEqual(buildStatus({keyRepeat: {state: 'off', delay: 500, interval: 30}}).keyRepeat, {state: 'off', delay: null, interval: null});
  assert.deepEqual(buildStatus({keyRepeat: {state: 'bogus', delay: 500, interval: 30}}).keyRepeat, {state: 'off', delay: null, interval: null});
  assert.deepEqual(buildStatus({keyRepeat: {state: 'applied', delay: '500'}}).keyRepeat, {state: 'off', delay: null, interval: null});
});

test('hotkey statuses are plain strings', () => {
  assert.equal(hotkeyStatusText('active'), 'active');
  assert.equal(hotkeyStatusText({failed: 'Super+A is GNOME’s'}), 'failed: Super+A is GNOME’s');
});

test('the file is pretty JSON ending in a newline', () => {
  const text = statusText(state);
  assert.ok(text.endsWith('}\n'));
  assert.deepEqual(JSON.parse(text).hotkeys['hyper+a'], 'active');
});
