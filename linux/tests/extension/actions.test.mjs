import assert from 'node:assert/strict';
import {test} from 'node:test';

import {ActionRunner, redactForLog} from '../../gnome-extension/lib/platform/actions.js';
import {AutomationEngine} from '../../gnome-extension/lib/platform/automation.js';
import * as realCore from '../../gnome-extension/lib/core/index.js';
import {fakeCore} from './fake-core.mjs';
import {FakePlatform, FakeWindow} from './fake-platform.mjs';
import {FakeTimers, MemoryLog, leftHalf, rightHalf, topHalf} from './fixtures.mjs';

const apps = [
  {id: 'firefox', name: 'Firefox'},
  {id: 'org.gnome.Terminal', name: 'Terminal'},
  {id: 'org.gnome.Nautilus', name: 'Files'},
];

function setup({windows, overlays = null, snapshots = null} = {}) {
  const platform = new FakePlatform({
    apps,
    windows: windows ?? [
      new FakeWindow({id: 1, app: 'firefox', title: 'Mail', frame: {x: 100, y: 100, width: 800, height: 600}}),
      new FakeWindow({id: 2, app: 'org.gnome.Terminal', title: 'Shell', frame: {x: 1000, y: 150, width: 700, height: 500}}),
      new FakeWindow({id: 3, app: 'org.gnome.Nautilus', title: 'Home', frame: {x: 2000, y: 300, width: 800, height: 900}}),
    ],
  });
  const log = new MemoryLog();
  const runner = new ActionRunner({platform, core: fakeCore, log, overlays, snapshots});
  const performed = [];
  const errors = [];
  runner.onPerformed = (message) => performed.push(message);
  runner.onError = (message) => errors.push(message);
  return {platform, log, runner, performed, errors};
}

test('a move lands on the work area and logs action.done', () => {
  const {platform, log, runner, performed} = setup();
  assert.equal(runner.run(leftHalf, {label: 'Left half', trigger: 'hotkey hyper+a', source: 'Slated'}), true);
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048});
  assert.deepEqual(performed, ['Left half · Firefox']);
  const [event] = log.named('action.done');
  assert.equal(event.level, 'info');
  assert.equal(event.data.trigger, 'hotkey hyper+a');
  assert.equal(event.data.app, 'firefox');
  assert.equal(event.data.label, 'Left half');
  assert.equal(event.data.source, 'Slated');
  assert.equal(event.data.action, 'move screenOriginX;screenOriginY screenSizeX/2;screenSizeY');
  assert.equal(typeof event.data.ms, 'number');
  assert.equal(event.data.error, null);
});

test('undo puts the window back', () => {
  const {platform, runner} = setup();
  runner.run(leftHalf, {trigger: 't'});
  runner.run(topHalf, {trigger: 't'});
  runner.run({op: 'undo'}, {trigger: 't'});
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048});
  runner.run({op: 'undo'}, {trigger: 't'});
  assert.deepEqual(platform.windows[0].frame, {x: 100, y: 100, width: 800, height: 600});
  assert.equal(runner.run({op: 'undo'}, {trigger: 't'}), false);
});

test('undo skips windows that have closed', () => {
  const {platform, runner} = setup();
  runner.run(leftHalf, {trigger: 't'});
  platform.focused = platform.windows[1];
  runner.run(leftHalf, {trigger: 't'});
  platform.windows[1].closed = true;
  runner.run({op: 'undo'}, {trigger: 't'});
  assert.deepEqual(platform.windows[0].frame, {x: 100, y: 100, width: 800, height: 600});
});

test('apps with a minimum size end up flush with the edge after settling', () => {
  const window = new FakeWindow({id: 1, app: 'firefox', frame: {x: 100, y: 100, width: 800, height: 600}, minSize: {width: 1000, height: 100}});
  const {platform, runner} = setup({windows: [window]});
  runner.run(rightHalf, {trigger: 't'});
  assert.deepEqual(window.frame, {x: 960, y: 32, width: 1000, height: 1048});
  platform.settle();
  assert.deepEqual(window.frame, {x: 960, y: 32, width: 1000, height: 1048}, 'move x is an expression of the screen, not the size');
  const push = {op: 'push', direction: 'right', style: 'bar-resize:screenSizeX/2'};
  runner.run(push, {trigger: 't'});
  platform.settle();
  assert.deepEqual(window.frame, {x: 920, y: 32, width: 1000, height: 1048});
});

test('a move the window didn’t take is retried once it settled', () => {
  const {platform, runner} = setup();
  runner.run(leftHalf, {trigger: 't'});
  platform.windows[0].frame = {x: 300, y: 300, width: 960, height: 1048}; // e.g. unmaximize restored it
  platform.settle();
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048});
});

test('a refused move fails with the app name', () => {
  const {platform, log, runner, errors} = setup();
  platform.refuseMoves.add(1);
  assert.equal(runner.run(leftHalf, {trigger: 't'}), false);
  assert.deepEqual(errors, ["Firefox didn't allow moving that window"]);
  assert.equal(log.named('action.failed')[0].data.error, "Firefox didn't allow moving that window");
  assert.equal(log.named('action.failed')[0].level, 'error');
});

test('no focused window fails clearly', () => {
  const {platform, log, runner} = setup();
  platform.focused = null;
  assert.equal(runner.run(leftHalf, {trigger: 't'}), false);
  assert.equal(log.named('action.failed')[0].data.error, 'No focused window to move');
});

test('chains cycle per binding and start over on another window', () => {
  const {platform, runner} = setup();
  const chain = {op: 'chain', operations: [leftHalf, rightHalf]};
  const frames = [];
  for (let i = 0; i < 3; i++) {
    runner.run(chain, {chainKey: 'b1', trigger: 't'});
    frames.push(platform.windows[0].frame.x);
  }
  assert.deepEqual(frames, [0, 960, 0]);
  // Another binding with the same chain has its own position.
  runner.run(chain, {chainKey: 'b2', trigger: 't'});
  assert.equal(platform.windows[0].frame.x, 0);
  runner.run(chain, {chainKey: 'b1', trigger: 't'}); // b1 continues
  assert.equal(platform.windows[0].frame.x, 960);
  platform.focused = platform.windows[1];
  runner.run(chain, {chainKey: 'b1', trigger: 't'});
  assert.equal(platform.windows[1].frame.x, 0, 'a different window starts at the first step');
});

test('sequence steps act on the focused window, keepWindow steps on the starting one', () => {
  const {platform, runner} = setup();
  const focusRight = {op: 'focus', direction: 'right'};
  runner.run({op: 'sequence', operations: [focusRight, leftHalf]}, {trigger: 't'});
  assert.equal(platform.focused.id, 2);
  assert.deepEqual(platform.windows[1].frame, {x: 0, y: 32, width: 960, height: 1048});

  const second = setup();
  second.runner.run(
    {
      op: 'sequence',
      steps: [
        {action: focusRight, keepWindow: false},
        {action: leftHalf, keepWindow: true},
      ],
    },
    {trigger: 't'},
  );
  assert.equal(second.platform.focused.id, 2);
  assert.deepEqual(second.platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048}, 'moved the window the run started on');
});

test('by-orientation picks the action for the window’s screen shape', () => {
  const {platform, runner} = setup();
  const thirds = {
    op: 'by-orientation',
    landscape: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'},
    portrait: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX', height: 'screenSizeY/3'},
  };
  runner.run(thirds, {trigger: 't'});
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 640, height: 1048});
  platform.focused = platform.windows[2];
  runner.run(thirds, {trigger: 't'});
  assert.deepEqual(platform.windows[2].frame, {x: 1920, y: 0, width: 1080, height: 640});
});

test('by-orientation treats a square screen as portrait, like the Mac', () => {
  const square = {displayID: 0, name: 'Square', frame: {x: 0, y: 0, width: 1200, height: 1200}, visibleFrame: {x: 0, y: 0, width: 1200, height: 1200}, isMain: true, scale: 1};
  const platform = new FakePlatform({apps, screens: [square], windows: [new FakeWindow({id: 1, app: 'firefox', frame: {x: 100, y: 100, width: 400, height: 400}})]});
  const runner = new ActionRunner({platform, core: realCore, log: new MemoryLog()});
  const thirds = {
    op: 'by-orientation',
    landscape: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'},
    portrait: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX', height: 'screenSizeY/3'},
  };
  assert.equal(runner.run(thirds, {trigger: 't'}), true);
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 0, width: 1200, height: 400});
  // The core agrees when it resolves by-orientation itself (the settings window's previews).
  assert.deepEqual(realCore.targetFrame(thirds, {frame: {x: 100, y: 100, width: 400, height: 400}, screens: [square]}), {x: 0, y: 0, width: 1200, height: 400});
});

test('layouts apply operations to each app’s windows with Slate’s options', () => {
  const windows = [
    new FakeWindow({id: 1, app: 'org.gnome.Terminal', title: 'c', frame: {x: 10, y: 50, width: 400, height: 300}}),
    new FakeWindow({id: 2, app: 'org.gnome.Terminal', title: 'a', frame: {x: 20, y: 60, width: 400, height: 300}}),
    new FakeWindow({id: 3, app: 'org.gnome.Terminal', title: 'b', frame: {x: 30, y: 70, width: 400, height: 300}}),
  ];
  const {platform, runner} = setup({windows});
  runner.setLayouts([
    {name: 'repeat', apps: [{app: 'Terminal', operations: [leftHalf, rightHalf], options: {repeat: true}}]},
    {name: 'last', apps: [{app: 'Terminal', operations: [leftHalf, rightHalf], options: {repeatLast: true}}]},
    {name: 'plain', apps: [{app: 'Terminal', operations: [rightHalf], options: {}}]},
    {name: 'titles', apps: [{app: 'Terminal', operations: [leftHalf, rightHalf], options: {titleOrder: ['b', 'a']}}]},
    {name: 'sorted', apps: [{app: 'Terminal', operations: [leftHalf, rightHalf, topHalf], options: {sortTitle: true}}]},
  ]);
  const xs = () => windows.map((w) => w.frame.x);

  runner.run({op: 'layout', name: 'repeat'}, {trigger: 't'});
  assert.deepEqual(xs(), [0, 960, 0]);
  runner.run({op: 'layout', name: 'last'}, {trigger: 't'});
  assert.deepEqual(xs(), [0, 960, 960]);
  windows.forEach((w) => (w.frame.x = 5));
  runner.run({op: 'layout', name: 'plain'}, {trigger: 't'});
  assert.deepEqual(xs(), [960, 5, 5]);
  runner.run({op: 'layout', name: 'titles'}, {trigger: 't'});
  assert.deepEqual(xs(), [960, 960, 0], 'b first, then a');
  runner.run({op: 'layout', name: 'sorted'}, {trigger: 't'});
  assert.deepEqual(windows.map((w) => [w.title, w.frame.x, w.frame.width]), [
    ['c', 0, 1920],
    ['a', 0, 960],
    ['b', 960, 960],
  ]);
  assert.equal(platform.calls.filter((c) => c[0] === 'activate').length, 0);
});

test('a failing layout step stops that app unless IGNORE_FAIL', () => {
  const windows = [
    new FakeWindow({id: 1, app: 'firefox', frame: {x: 10, y: 50, width: 400, height: 300}}),
    new FakeWindow({id: 2, app: 'firefox', frame: {x: 20, y: 60, width: 400, height: 300}}),
  ];
  const {platform, runner} = setup({windows});
  platform.refuseMoves.add(1);
  runner.setLayouts([
    {name: 'strict', apps: [{app: 'Firefox', operations: [leftHalf, rightHalf]}]},
    {name: 'lenient', apps: [{app: 'Firefox', operations: [leftHalf, rightHalf], options: {ignoreFail: true}}]},
  ]);
  runner.run({op: 'layout', name: 'strict'}, {trigger: 't'});
  assert.equal(windows[1].frame.x, 20);
  runner.run({op: 'layout', name: 'lenient'}, {trigger: 't'});
  assert.equal(windows[1].frame.x, 960);
});

test('layouts focus their first app with layoutFocusOnActivate, and unknown names fail', () => {
  const {platform, runner, log} = setup();
  runner.settings = {layoutFocusOnActivate: true};
  runner.setLayouts([{name: 'work', apps: [{app: 'Terminal', operations: [leftHalf]}], before: [{op: 'shell', command: 'true'}]}]);
  runner.run({op: 'layout', name: 'work'}, {trigger: 't'});
  assert.deepEqual(platform.calls.find((c) => c[0] === 'activate'), ['activate', 'org.gnome.Terminal']);
  assert.ok(platform.calls.some((c) => c[0] === 'shell'));
  assert.equal(runner.run({op: 'layout', name: 'nope'}, {trigger: 't'}), false);
  assert.equal(log.named('action.failed')[0].data.error, 'No layout named "nope"');
});

test('directional focus finds the nearest overlapping window; behind follows the stack', () => {
  const {platform, runner} = setup();
  runner.run({op: 'focus', direction: 'right'}, {trigger: 't'});
  assert.equal(platform.focused.id, 2);
  runner.run({op: 'focus', direction: 'left'}, {trigger: 't'});
  assert.equal(platform.focused.id, 1);
  assert.equal(runner.run({op: 'focus', direction: 'up'}, {trigger: 't'}), false);
  runner.run({op: 'focus', direction: 'behind'}, {trigger: 't'});
  assert.equal(platform.focused.id, 2);
  runner.run({op: 'focus', direction: 'top'}, {trigger: 't'});
  assert.equal(platform.focused.id, 2, 'top is up; nothing above');
});

test('focus app activates it, or fails when it isn’t running', () => {
  const {platform, runner, log} = setup();
  runner.run({op: 'focus', app: 'Terminal'}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['activate', 'org.gnome.Terminal']);
  assert.equal(runner.run({op: 'focus', app: 'Xcode'}, {trigger: 't'}), false);
  assert.equal(log.named('action.failed')[0].data.error, "Xcode isn't running");
});

test('hide, show and toggle understand app selectors', () => {
  const {platform, runner} = setup();
  runner.run({op: 'hide', app: 'all-but:Firefox'}, {trigger: 't'});
  assert.deepEqual(platform.calls.map((c) => c.join(':')), ['hide:org.gnome.Terminal', 'hide:org.gnome.Nautilus']);
  platform.calls = [];
  runner.run({op: 'toggle', app: ['Terminal', 'Firefox']}, {trigger: 't'});
  assert.deepEqual(platform.calls.map((c) => c.join(':')), ['hide:firefox', 'show:org.gnome.Terminal']);
  platform.calls = [];
  runner.run({op: 'show', app: 'current'}, {trigger: 't'});
  assert.deepEqual(platform.calls.map((c) => c.join(':')), ['show:firefox']);
});

test('shell, URLs, text and keystrokes go to the platform', () => {
  const {platform, runner, log} = setup();
  runner.run({op: 'shell', command: 'notify-send hi', wait: true, path: '~/src'}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['shell', 'notify-send hi', {wait: true, path: '~/src'}]);
  assert.equal(runner.run({op: 'shell', command: 'false'}, {trigger: 't'}), false);
  assert.equal(log.named('action.failed')[0].data.error, "Couldn't run false: exit status 1");
  runner.run({op: 'open-url', url: 'https://example.com'}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['openURL', 'https://example.com']);
  runner.run({op: 'insert-text', text: 'hello', method: 'type'}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['insertText', 'hello', 'type']);
  runner.run({op: 'keystroke', keys: 'cmd+shift+4'}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['pressKeys', {key: '4', modifiers: ['shift', 'cmd']}]);
  runner.run({op: 'keystroke', keys: {key: 'v', modifiers: ['ctrl']}}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['pressKeys', {key: 'v', modifiers: ['ctrl']}]);
});

test('inserted text never reaches the log, even inside a sequence', () => {
  const {log, runner} = setup();
  runner.core = {...fakeCore, formatOperation: (action) => JSON.stringify(action)};
  runner.run({op: 'insert-text', text: 'my secret phrase'}, {trigger: 't'});
  runner.run({op: 'sequence', operations: [{op: 'insert-text', text: 'another secret'}]}, {trigger: 't'});
  const logged = JSON.stringify(log.events);
  assert.ok(!logged.includes('secret'), logged);
  assert.deepEqual(redactForLog({op: 'sequence', steps: [{action: {op: 'insert-text', text: 'héllo'}, keepWindow: false}]}), {
    op: 'sequence',
    steps: [{action: {op: 'insert-text', text: '(5 characters)'}, keepWindow: false}],
  });
  assert.deepEqual(redactForLog({op: 'shell', command: 'echo', text: 'kept'}), {op: 'shell', command: 'echo', text: 'kept'});
});

test('hints and the grid open overlays; the grid needs a window', () => {
  const shown = [];
  const overlays = {showHints: (chars) => shown.push(['hints', chars]), showGrid: (options) => shown.push(['grid', options])};
  const {platform, runner, log} = setup({overlays});
  runner.settings = {windowHintsCharacters: 'ASDF'};
  runner.run({op: 'hint'}, {trigger: 't'});
  runner.run({op: 'hint', characters: 'QWER'}, {trigger: 't'});
  runner.run({op: 'grid', padding: 4, grids: {0: {width: 6, height: 6}}}, {trigger: 't'});
  assert.deepEqual(shown[0], ['hints', 'ASDF']);
  assert.deepEqual(shown[1], ['hints', 'QWER']);
  assert.equal(shown[2][1].padding, 4);
  assert.deepEqual(shown[2][1].grids, [{screen: '0', width: 6, height: 6}]);
  assert.equal(shown[2][1].window, platform.windows[0]);
  platform.focused = null;
  assert.equal(runner.run({op: 'grid'}, {trigger: 't'}), false);
  assert.equal(log.named('action.failed').at(-1).data.error, 'No focused window to place');
});

test('snapshots, relaunch, switch and unknown operations', () => {
  const calls = [];
  const snapshots = {
    take: (name, options) => calls.push(['take', name, options]),
    activate: (name) => name === 'saved',
    delete: (name, options) => calls.push(['delete', name, options]),
  };
  const {runner, log} = setup({snapshots});
  let relaunched = false;
  runner.onRelaunch = () => (relaunched = true);
  runner.run({op: 'snapshot', name: 'a', save: true}, {trigger: 't'});
  assert.deepEqual(calls[0], ['take', 'a', {save: true, stack: false}]);
  assert.equal(runner.run({op: 'activate-snapshot', name: 'saved'}, {trigger: 't'}), true);
  assert.equal(runner.run({op: 'activate-snapshot', name: 'missing'}, {trigger: 't'}), false);
  runner.run({op: 'delete-snapshot', name: 'a', all: true}, {trigger: 't'});
  assert.deepEqual(calls[1], ['delete', 'a', {all: true}]);
  runner.run({op: 'relaunch'}, {trigger: 't'});
  assert.ok(relaunched);
  assert.equal(runner.run({op: 'switch'}, {trigger: 't'}), false);
  assert.equal(runner.run({op: 'teleport'}, {trigger: 't'}), false);
  assert.deepEqual(
    log.named('action.failed').map((e) => e.data.error),
    ['No snapshot named "missing"', "Slate's app switcher (switch) isn't supported yet", 'Unknown operation "teleport"'],
  );
});

test('Slate syntax strings are parsed with the core', () => {
  const {platform, runner} = setup();
  runner.run('push left bar-resize:screenSizeX/3', {trigger: 'debug'});
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 640, height: 1048});
});

test('a core that throws becomes action.failed, never an exception', () => {
  const {log, runner} = setup();
  const broken = new ActionRunner({
    platform: runner.platform,
    log,
    core: {
      targetFrame() {
        throw new Error('Not implemented yet: targetFrame');
      },
      formatOperation() {
        throw new Error('Not implemented yet: formatOperation');
      },
    },
  });
  assert.equal(broken.run(leftHalf, {trigger: 't'}), false);
  const [event] = log.named('action.failed');
  assert.equal(event.data.error, 'Not implemented yet: targetFrame');
  assert.match(event.data.action, /^\{"height":"screenSizeY","op":"move"/);
});

test('the undo stack honours undoMaxStackSize', () => {
  const {platform, runner} = setup();
  runner.settings = {undoMaxStackSize: 2};
  runner.run(leftHalf, {trigger: 't'});
  runner.run(rightHalf, {trigger: 't'});
  runner.run(topHalf, {trigger: 't'});
  runner.run({op: 'undo'}, {trigger: 't'});
  runner.run({op: 'undo'}, {trigger: 't'});
  assert.equal(runner.run({op: 'undo'}, {trigger: 't'}), false);
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048});
});

test('a waiting shell step holds the rest of a sequence until the command exits, without blocking', async () => {
  const {platform, log, runner} = setup();
  const sequence = {
    op: 'sequence',
    steps: [
      {action: {op: 'shell', command: 'make', wait: true}, keepWindow: false},
      {action: leftHalf, keepWindow: true},
    ],
  };
  assert.equal(runner.run(sequence, {trigger: 'hotkey hyper+m', source: 'Slated'}), true);
  assert.deepEqual(platform.windows[0].frame, {x: 100, y: 100, width: 800, height: 600}, 'nothing moved yet');
  assert.equal(log.named('action.done').length, 1);
  platform.focused = platform.windows[1]; // focus moves while the command runs; keepWindow keeps the first
  await platform.finishShells();
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048});
  const [, after] = log.named('action.done');
  assert.equal(after.data.trigger, 'hotkey hyper+m (after shell)');
  assert.equal(after.data.source, 'Slated');
});

test('a waiting shell at the end, or with nothing after it, holds nothing', async () => {
  const {platform, runner, log} = setup();
  runner.run({op: 'shell', command: 'sleep 1', wait: true}, {trigger: 't'});
  runner.run(leftHalf, {trigger: 't'});
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 960, height: 1048});
  await platform.finishShells();
  assert.equal(log.named('action.done').length, 2, 'no continuation event');
});

test('a layout waits for its BEFORE shell command, and nothing runs after destroy', async () => {
  const {platform, runner} = setup();
  runner.setLayouts([{name: 'work', before: [{op: 'shell', command: 'gnome-terminal', wait: true}], apps: [{app: 'Terminal', operations: [leftHalf]}]}]);
  runner.run({op: 'layout', name: 'work'}, {trigger: 't'});
  assert.equal(platform.windows[1].frame.x, 1000);
  await platform.finishShells();
  assert.equal(platform.windows[1].frame.x, 0);

  runner.run({op: 'layout', name: 'work'}, {trigger: 't'});
  platform.windows[1].frame.x = 500;
  runner.destroy();
  await platform.finishShells();
  assert.equal(platform.windows[1].frame.x, 500);
});

test('a maximized window that first settles at its old size gets the size asked again', () => {
  const window = new FakeWindow({id: 1, app: 'firefox', frame: {x: 0, y: 32, width: 1920, height: 1048}, maximized: true, restoreSize: {width: 800, height: 600}});
  const {platform, runner} = setup({windows: [window]});
  runner.run(leftHalf, {trigger: 't'});
  assert.deepEqual(window.frame, {x: 0, y: 32, width: 800, height: 600}, 'the restored size first');
  platform.settle();
  assert.deepEqual(window.frame, {x: 0, y: 32, width: 960, height: 1048});
  platform.settle();
  assert.equal(platform.calls.filter((c) => c[0] === 'setFrame').length, 2, 'asked once more, then left alone');
});

test('undoMaxStackSize is read as on the Mac: infinity keeps everything, text that isn\u2019t a number is the default', () => {
  // 12 moves, then undo until it fails: how many undos were kept (SlateSettings.undoMaxStackSize, at least 1).
  const kept = (undoMaxStackSize) => {
    const {runner} = setup();
    runner.settings = {undoMaxStackSize};
    for (let i = 0; i < 12; i++) runner.run(i % 2 ? leftHalf : rightHalf, {trigger: 't'});
    let undos = 0;
    while (runner.run({op: 'undo'}, {trigger: 't'})) undos++;
    return undos;
  };
  assert.deepEqual(
    [Infinity, -Infinity, NaN, '', ' 12', '1e20', '3', 2.9, 0, -5].map(kept),
    [12, 1, 10, 10, 10, 12, 3, 2, 1, 1],
  );
});

test('the grid places windows with undo', () => {
  const {platform, runner, performed} = setup();
  runner.place(platform.windows[0], {x: 0, y: 32, width: 640.4, height: 524}, 'Grid');
  assert.deepEqual(platform.windows[0].frame, {x: 0, y: 32, width: 641, height: 524});
  assert.deepEqual(performed, ['Grid · Firefox']);
  runner.run({op: 'undo'}, {trigger: 't'});
  assert.deepEqual(platform.windows[0].frame, {x: 100, y: 100, width: 800, height: 600});
});

// --- Game automation and clipboard history ---------------------------------------------------------

/** The runner with the real core and automation engine, recording what the synthesizer sends. */
function automationSetup() {
  const ctx = setup();
  const runner = new ActionRunner({platform: ctx.platform, core: realCore, log: ctx.log});
  runner.onError = (message) => ctx.errors.push(message);
  const timers = new FakeTimers();
  const sent = [];
  const synth = {
    mouse: (button, down) => sent.push(`${button} ${down ? 'down' : 'up'}`) && {ok: true},
    key: (combo, down) => sent.push(`${[...combo.modifiers, combo.key].join('+')} ${down ? 'down' : 'up'}`) && {ok: true},
  };
  const engine = new AutomationEngine({timers, synth, log: ctx.log, now: () => timers.now, random: () => 0.5});
  engine.perform = (action) => runner.performStep(action);
  runner.automation = engine;
  return {...ctx, runner, timers, sent, engine};
}

test('click goes to the platform; press and hold go through the automation engine', () => {
  const {platform, runner, sent, engine, log} = automationSetup();
  assert.equal(runner.run('click right 2', {trigger: 'hotkey hyper+1'}), true);
  assert.deepEqual(platform.calls.at(-1), ['click', 'right', 2]);
  runner.run({op: 'click'}, {trigger: 't'});
  assert.deepEqual(platform.calls.at(-1), ['click', 'left', 1]);
  runner.run('hold mouse:right', {trigger: 'hotkey mouse4'});
  runner.run('press key:w down', {trigger: 't'});
  assert.deepEqual(sent, ['right down', 'w down']);
  assert.equal(engine.active[0].trigger, 'hotkey mouse4');
  runner.run('hold mouse:right', {trigger: 'hotkey mouse4'});
  runner.run('press key:w up', {trigger: 't'});
  assert.deepEqual(sent, ['right down', 'w down', 'right up', 'w up']);
  assert.equal(log.named('action.done').length, 6);
});

test('a repeat is identified by its trigger: the same shortcut toggles it', () => {
  const {platform, runner, timers, engine} = automationSetup();
  runner.run({op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1}, {trigger: 'hotkey f'});
  timers.advance(250);
  assert.equal(platform.calls.filter((c) => c[0] === 'click').length, 3);
  assert.equal(engine.isRepeating('hotkey f'), true);
  runner.run({op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1}, {trigger: 'hotkey f'});
  assert.equal(engine.isRunning, false);
  timers.advance(1000);
  assert.equal(platform.calls.filter((c) => c[0] === 'click').length, 3);
});

test('a repeat can’t repeat a repeat, and repetitions aren’t logged one by one', () => {
  const {runner, errors, log, timers, engine} = automationSetup();
  assert.equal(runner.run("repeat 1 \"repeat 0.1 'click'\"", {trigger: 't'}), false);
  assert.deepEqual(errors, ["An auto-repeat can't repeat another auto-repeat"]);
  runner.run('repeat 0.1 times:5 "click"', {trigger: 'hotkey x'});
  timers.advance(1000);
  assert.equal(engine.isRunning, false);
  assert.equal(log.named('action.done').length, 1, 'one event for the shortcut, none per click');
});

test('wait schedules the rest of a macro without blocking; stop-automations drops it', () => {
  const {platform, runner, sent, engine, log} = automationSetup();
  assert.equal(runner.run('sequence press key:w down | wait 2 | press key:w up | click left', {trigger: 'hotkey hyper+d'}), true);
  assert.deepEqual(sent, ['w down'], 'the steps before the wait run now');
  assert.equal(engine.isHeld('key:w'), true);
  platform.advance(1999);
  assert.deepEqual(sent, ['w down']);
  platform.advance(1);
  assert.deepEqual(sent, ['w down', 'w up']);
  assert.deepEqual(platform.calls.at(-1), ['click', 'left', 1], 'then the rest');
  assert.equal(log.named('action.done').length, 1, 'continuations that work aren’t logged');

  runner.run('sequence press key:w down | wait 2 | click left', {trigger: 'hotkey hyper+d'});
  runner.run('stop-automations', {trigger: 'hotkey hyper+esc'});
  assert.deepEqual(sent.slice(-2), ['w down', 'w up'], 'stop releases W at once');
  const clicks = platform.calls.filter((c) => c[0] === 'click').length;
  platform.advance(5000);
  assert.equal(platform.calls.filter((c) => c[0] === 'click').length, clicks, 'and the rest of the macro never runs');
});

test('a macro step that fails after a wait is logged; reloads and destroy drop waiting steps', () => {
  const {platform, runner, log} = automationSetup();
  platform.focused = null;
  runner.run('sequence wait 0.5 | push left', {trigger: 'hotkey hyper+p'});
  platform.advance(500);
  const [failed] = log.named('action.failed');
  assert.equal(failed.data.trigger, 'hotkey hyper+p (after wait)');
  assert.equal(failed.data.error, 'No focused window to move');
  runner.run('sequence wait 1 | click', {trigger: 't'});
  runner.cancelPendingSteps();
  platform.advance(1000);
  runner.run('sequence wait 1 | click', {trigger: 't'});
  runner.destroy();
  platform.advance(1000);
  assert.equal(platform.calls.filter((c) => c[0] === 'click').length, 0);
  assert.equal(runner.run('wait 1', {trigger: 't'}), true, 'a wait on its own does nothing');
});

test('steps waiting on a shell command are dropped by stop-automations and reloads, like steps after a wait', async () => {
  const {platform, runner, sent} = automationSetup();
  const macro = {op: 'sequence', operations: [
    {op: 'press', input: 'key:w', phase: 'down'}, {op: 'shell', command: 'sleep 1', wait: true},
    {op: 'press', input: 'key:w', phase: 'up'}, {op: 'press', input: 'mouse:left', phase: 'down'},
  ]};
  runner.run(macro, {trigger: 'hotkey f6'});
  runner.run('stop-automations', {trigger: 'hotkey hyper+esc'});
  assert.deepEqual(sent, ['w down', 'w up'], 'the stop releases W');
  await platform.finishShells();
  assert.deepEqual(sent, ['w down', 'w up'], 'and the left button never goes down once the command exits');

  runner.setLayouts([{name: 'work', before: [{op: 'shell', command: 'gnome-terminal', wait: true}], apps: [{app: 'Terminal', operations: [leftHalf]}]}]);
  runner.run({op: 'layout', name: 'work'}, {trigger: 't'});
  runner.cancelPendingSteps(); // a config reload
  await platform.finishShells();
  assert.equal(platform.windows[1].frame.x, 1000, 'a reload drops the arrangement waiting on its command');
});

test('keys and text say who sends them; stop-automations drops what automations left, even with nothing running', () => {
  const {platform, runner} = automationSetup();
  const from = [];
  let dropped = 0;
  platform.pressKeys = (combo, options) => from.push(`keys ${options?.from}`) && {ok: true};
  platform.insertText = (text, method, options) => from.push(`text ${options?.from}`) && {ok: true};
  platform.cancelPendingInput = () => dropped++;
  const macro = {op: 'sequence', operations: [{op: 'keystroke', keys: 'e'}, {op: 'wait', seconds: 1}, {op: 'insert-text', text: 'x'}]};
  runner.run(macro, {trigger: 'hotkey f6'});
  platform.advance(1000);
  runner.run({op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.1, times: 1}, {trigger: 'hotkey f7'});
  assert.deepEqual(from, ['keys binding', 'text macro', 'keys repeat']);
  runner.run('stop-automations', {trigger: 'hotkey hyper+esc'});
  assert.equal(dropped, 1);
});

test('while automations can’t start, only shortcuts that would start one are ignored', () => {
  const {runner, sent, log} = automationSetup();
  let blocked = 'the overview is open';
  runner.automationBlocked = () => blocked;
  assert.equal(runner.run('click left', {trigger: 't'}), true, 'one click isn’t an automation');
  assert.equal(runner.run('press key:w up', {trigger: 't'}), true);
  assert.equal(runner.run('stop-automations', {trigger: 't'}), true);
  assert.equal(runner.run('sequence click left | wait 1', {trigger: 't'}), true, 'a wait at the end holds nothing up');
  assert.equal(runner.run({op: 'chain', operations: ['click left', 'hold key:w']}, {trigger: 't'}), false);
  assert.equal(runner.lastFailure, "Automations don't start while the overview is open");
  assert.equal(runner.run({op: 'by-orientation', landscape: 'click left', portrait: 'repeat 0.1 "click left"'}, {trigger: 't'}), false);
  assert.equal(runner.run({op: 'sequence', operations: ['click left', 'wait 1', 'click left']}, {trigger: 't'}), false);
  blocked = null;
  runner.run('hold key:w', {trigger: 'hotkey hyper+w'});
  blocked = 'the overview is open';
  assert.equal(runner.run('hold key:w', {trigger: 'hotkey hyper+w'}), true, 'a second press still lets go');
  assert.deepEqual(sent, ['w down', 'w up']);
  assert.deepEqual(log.named('automation.start_ignored').map((e) => e.data), Array(3).fill({reason: 'the overview is open', trigger: 't', source: null}));
});

test('clipboard-history opens the switcher, or fails with the reason', () => {
  const {runner, errors} = automationSetup();
  let result = {ok: true};
  let opened = 0;
  runner.clipboard = {
    showSwitcher: () => {
      opened++;
      return result;
    },
  };
  assert.equal(runner.run({op: 'clipboard-history'}, {trigger: 'hotkey shift+cmd+v'}), true);
  result = {ok: false, error: 'Clipboard history is turned off (clipboard.enabled)'};
  assert.equal(runner.run('clipboard-history', {trigger: 't'}), false);
  assert.equal(opened, 2);
  assert.deepEqual(errors, ['Clipboard history is turned off (clipboard.enabled)']);
  runner.clipboard = null;
  runner.automation = null;
  assert.equal(runner.run('clipboard-history', {trigger: 't'}), false);
  assert.equal(runner.run('hold key:w', {trigger: 't'}), false);
  assert.equal(runner.run('stop-automations', {trigger: 't'}), true, 'stopping with nothing to stop is fine');
});
