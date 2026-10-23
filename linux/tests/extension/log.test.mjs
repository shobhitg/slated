import assert from 'node:assert/strict';
import {test} from 'node:test';

import {EventLog, formatEvent, newSessionId, rotationPlan, sanitize, summarizeEvent} from '../../gnome-extension/lib/platform/log.js';

test('log lines use the macOS schema with sorted keys', () => {
  const line = formatEvent({
    ts: '2026-10-22T18:21:03.123Z',
    level: 'info',
    event: 'action.done',
    session: '1a2b3c4d',
    data: {trigger: 'hotkey hyper+a', ms: 12.345, app: 'firefox', label: undefined, error: null},
  });
  assert.equal(
    line,
    '{"data":{"app":"firefox","ms":12.3,"trigger":"hotkey hyper+a"},"event":"action.done","level":"info","session":"1a2b3c4d","ts":"2026-10-22T18:21:03.123Z"}',
  );
  assert.deepEqual(Object.keys(JSON.parse(line)), ['data', 'event', 'level', 'session', 'ts']);
});

test('empty data is left out, like the Swift EventLog', () => {
  const line = formatEvent({ts: 't', level: 'notice', event: 'modal.exited', session: 's', data: {}});
  assert.equal(line, '{"event":"modal.exited","level":"notice","session":"s","ts":"t"}');
});

test('sanitize keeps JSON shapes and rounds fractions to one decimal', () => {
  assert.deepEqual(sanitize({a: 1, b: 2.26, c: [1.04, 'x', null], d: {e: undefined, f: true}, g: Infinity}), {
    a: 1,
    b: 2.3,
    c: [1, 'x', null],
    d: {f: true},
    g: 'Infinity',
  });
  assert.equal(sanitize(new Error('boom')), 'boom');
  assert.deepEqual(sanitize(new Set(['x'])), ['x']);
});

test('slashes and unicode are written as-is, and each line is valid JSON', () => {
  const line = formatEvent({ts: 't', event: 'config.loaded', session: 's', data: {path: '/home/me/.config/slated/config.json', name: 'Größe'}});
  assert.ok(line.includes('/home/me/.config/slated/config.json'));
  assert.ok(line.includes('Größe'));
  assert.doesNotThrow(() => JSON.parse(line));
  assert.ok(!line.includes('\n'));
});

test('session ids are 8 lowercase hex characters', () => {
  for (let i = 0; i < 20; i++) assert.match(newSessionId(), /^[0-9a-f]{8}$/);
  assert.equal(newSessionId(() => 0.99999), 'ffffffff');
});

test('EventLog writes one line per event to its sink and mirrors a summary', () => {
  const lines = [];
  const mirrored = [];
  const log = new EventLog({
    sink: {write: (text) => lines.push(text), close() {}},
    session: 'abcd1234',
    now: () => new Date('2026-10-22T10:00:00.000Z'),
    mirror: (level, message) => mirrored.push([level, message]),
  });
  log.record('app.start', {version: '0.1.0', mode: 'gnome-extension'}, 'notice');
  log.error('config.error', "Couldn't read config.json", {path: '/x'});
  assert.equal(lines.length, 2);
  assert.ok(lines.every((l) => l.endsWith('\n')));
  const first = JSON.parse(lines[0]);
  assert.equal(first.session, 'abcd1234');
  assert.equal(first.level, 'notice');
  assert.equal(first.ts, '2026-10-22T10:00:00.000Z');
  const second = JSON.parse(lines[1]);
  assert.equal(second.level, 'error');
  assert.equal(second.data.message, "Couldn't read config.json");
  assert.deepEqual(mirrored[1], ['error', "config.error message=Couldn't read config.json path=/x"]);
});

test('an unknown level falls back to info, and a failing sink is reported, not thrown', () => {
  const mirrored = [];
  const log = new EventLog({
    sink: {
      write() {
        throw new Error('disk full');
      },
      close() {},
    },
    mirror: (level, message) => mirrored.push([level, message]),
  });
  assert.doesNotThrow(() => log.record('x.y', {}, 'shouting'));
  assert.equal(mirrored[0][0], 'error');
  assert.match(mirrored[0][1], /disk full/);
});

test('rotation keeps three old files like the macOS log', () => {
  assert.deepEqual(rotationPlan('/s/slated.log'), {
    remove: '/s/slated.3.log',
    moves: [
      ['/s/slated.2.log', '/s/slated.3.log'],
      ['/s/slated.1.log', '/s/slated.2.log'],
      ['/s/slated.log', '/s/slated.1.log'],
    ],
  });
});

test('summaries list data keys in order', () => {
  assert.equal(summarizeEvent('action.done', {b: 1, a: 'x'}), 'action.done a=x b=1');
  assert.equal(summarizeEvent('modal.exited'), 'modal.exited');
});
