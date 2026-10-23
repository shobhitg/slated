import assert from 'node:assert/strict';
import {test} from 'node:test';

import {SnapshotStore, matchSnapshot} from '../../gnome-extension/lib/platform/snapshots.js';
import {FakePlatform, FakeWindow} from './fake-platform.mjs';

test('windows match saved states by app and title, then by order', () => {
  const states = [
    {app: 'term', title: 'build', frame: {x: 1, y: 1, width: 1, height: 1}},
    {app: 'term', title: 'logs', frame: {x: 2, y: 2, width: 2, height: 2}},
    {app: 'term', title: 'gone', frame: {x: 3, y: 3, width: 3, height: 3}},
    {app: 'web', title: 'x', frame: {x: 4, y: 4, width: 4, height: 4}},
  ];
  const windows = [
    {window: 'A', app: 'term', title: 'logs'},
    {window: 'B', app: 'term', title: 'new'},
    {window: 'C', app: 'web', title: 'other'},
    {window: 'D', app: 'mail', title: 'inbox'},
  ];
  assert.deepEqual(matchSnapshot(states, windows), [
    {window: 'A', frame: {x: 2, y: 2, width: 2, height: 2}},
    {window: 'B', frame: {x: 1, y: 1, width: 1, height: 1}},
    {window: 'C', frame: {x: 4, y: 4, width: 4, height: 4}},
  ]);
});

test('snapshots take, restore, stack and delete', () => {
  const window = new FakeWindow({id: 1, app: 'term', title: 't', frame: {x: 10, y: 10, width: 100, height: 100}});
  const platform = new FakePlatform({windows: [window], apps: [{id: 'term', name: 'Terminal'}]});
  const store = new SnapshotStore({path: null, platform});
  store.take('a');
  window.frame = {x: 50, y: 50, width: 100, height: 100};
  store.take('a', {stack: true});
  window.frame = {x: 90, y: 90, width: 100, height: 100};
  assert.equal(store.activate('a'), true);
  assert.deepEqual(window.frame, {x: 50, y: 50, width: 100, height: 100});
  store.delete('a');
  assert.equal(store.activate('a'), true);
  assert.deepEqual(window.frame, {x: 10, y: 10, width: 100, height: 100});
  assert.equal(store.activate('a', {delete: true}), true);
  assert.equal(store.activate('a'), false);
  assert.equal(store.activate('missing'), false);
});
