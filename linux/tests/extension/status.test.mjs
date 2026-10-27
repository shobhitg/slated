import assert from 'node:assert/strict';
import {test} from 'node:test';

import {buildStatus, hotkeyStatusText, statusText} from '../../gnome-extension/lib/platform/status.js';

const state = {
  session: 'abcd1234',
  version: '0.1.0',
  running: true,
  now: new Date('2026-10-22T10:00:00.000Z'),
  hyper: {wanted: true, mode: 'xkb', active: true},
  hotstrings: {engine: 'espanso', espansoInstalled: true, matchFile: '/home/me/.config/espanso/match/slated.yml', count: 3},
  hotkeys: {'hyper+z': 'disabled', 'hyper+a': 'active', 'hyper+q': 'failed: taken', 'hyper+w': 'duplicate'},
  sources: [
    {
      path: '~/.slate.js',
      kind: 'javascript',
      exists: true,
      loaded: true,
      bindings: new Array(21).fill({}),
      diagnostics: [{severity: 'warning', message: 'Hmm', file: '/home/me/.slate.js', line: 4}],
    },
  ],
  automation: {running: ['Repeat click left every 100 ms', 'Hold Shift'], shortcuts: ['f6'], stopShortcut: 'hyper+esc', whileHeld: 'key-repeat'},
  clipboard: {enabled: true, items: 12},
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
    'updatedAt',
    'hyper',
    'hotstrings',
    'hotkeys',
    'sources',
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
    updatedAt: '2026-10-22T10:00:00.000Z',
    hyper: {wanted: true, mode: 'xkb', active: true},
    hotstrings: {engine: 'espanso', espansoInstalled: true, matchFile: '/home/me/.config/espanso/match/slated.yml', count: 3},
    hotkeys: {'hyper+a': 'active', 'hyper+q': 'failed: taken', 'hyper+w': 'duplicate', 'hyper+z': 'disabled'},
    sources: [
      {path: '~/.slate.js', kind: 'javascript', exists: true, loaded: true, bindings: 21, diagnostics: ['.slate.js, line 4: Hmm']},
    ],
    automation: {running: ['Repeat click left every 100 ms', 'Hold Shift'], shortcuts: ['f6'], stopShortcut: 'hyper+esc', whileHeld: 'key-repeat'},
    clipboard: {enabled: true, items: 12},
    recentApps: [{id: 'steam_app_1086940', name: 'steam_app_1086940'}, {id: 'firefox', name: 'Firefox'}],
    lastAction: 'Left half · Firefox',
    lastError: null,
  });
});

test('missing parts get safe defaults', () => {
  const status = buildStatus({session: 's', version: '0.1.0', running: false});
  assert.deepEqual(status.hyper, {wanted: false, mode: 'off', active: false});
  assert.deepEqual(status.hotstrings, {engine: 'none', espansoInstalled: false, matchFile: null, count: 0});
  assert.deepEqual(status.hotkeys, {});
  assert.deepEqual(status.sources, []);
  assert.deepEqual(status.automation, {running: [], shortcuts: [], stopShortcut: null, whileHeld: 'key-repeat'});
  assert.deepEqual(status.clipboard, {enabled: true, items: 0});
  assert.deepEqual(status.recentApps, []);
  assert.equal(status.lastAction, null);
  assert.equal(status.lastError, null);
  assert.match(status.updatedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
});

test('hyper.mode only ever takes the schema’s values', () => {
  assert.equal(buildStatus({hyper: {wanted: true, mode: 'pending'}}).hyper.mode, 'off');
  assert.equal(buildStatus({hyper: {wanted: true, mode: 'keyd', active: true}}).hyper.mode, 'keyd');
});

test('automation.whileHeld is "key-repeat" or "toggle"; clipboard items are a count', () => {
  assert.equal(buildStatus({automation: {whileHeld: 'toggle'}}).automation.whileHeld, 'toggle');
  assert.equal(buildStatus({automation: {whileHeld: 'bogus'}}).automation.whileHeld, 'key-repeat');
  assert.deepEqual(buildStatus({clipboard: {enabled: false, items: NaN}}).clipboard, {enabled: false, items: 0});
  assert.deepEqual(buildStatus({recentApps: [{id: 'a'}, {name: 'no id'}]}).recentApps, [{id: 'a', name: 'a'}]);
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
