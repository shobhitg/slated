// The automation engine (lib/platform/automation.js): auto-repeat scheduling with jitter and times,
// toggles, while-held release, holding and pressing inputs, and the safety rails (stop all, app
// switches, the time limit), with virtual time and a recording synthesizer.

import assert from 'node:assert/strict';
import {test} from 'node:test';

import {
  AutomationEngine,
  automationShortcuts,
  indicatorText,
  inputLabel,
  repeatTitle,
  sendsKeys,
  whileHeldRepeat,
} from '../../gnome-extension/lib/platform/automation.js';
import {appIdentity, keyLabel, secondsLabel, shortcutLabel} from '../../gnome-extension/lib/platform/util.js';
import {RepeatSchedule} from '../../gnome-extension/lib/core/index.js';
import {FakeTimers, MemoryLog} from './fixtures.mjs';

/** Records what the virtual pointer and keyboard would send. */
class FakeSynth {
  constructor() {
    this.events = [];
    this.refuse = new Set();
  }
  mouse(button, down) {
    this.events.push(`${button} ${down ? 'down' : 'up'}`);
    return {ok: true};
  }
  key(combo, down) {
    if (this.refuse.has(combo.key)) return {ok: false, error: `${combo.key} isn't a key on this keyboard layout`};
    this.events.push(`${[...combo.modifiers, combo.key].join('+')} ${down ? 'down' : 'up'}`);
    return {ok: true};
  }
}

function setup({random = () => 0.5, focused = appIdentity('org.prismlauncher.PrismLauncher')} = {}) {
  const timers = new FakeTimers();
  const synth = new FakeSynth();
  const log = new MemoryLog();
  const state = {focused, performed: [], changes: 0};
  const engine = new AutomationEngine({timers, synth, log, now: () => timers.now, random, focusedApp: () => state.focused});
  engine.perform = (action) => {
    state.performed.push(timers.now);
    return action.fail !== true;
  };
  engine.onChange = () => state.changes++;
  return {timers, synth, log, state, engine};
}

const click = {op: 'click', button: 'left'};

test('a repeat runs right away, then every interval until toggled off', () => {
  const {timers, engine, state, log} = setup();
  engine.toggleRepeat(click, {interval: 0.1, id: 'hotkey f', trigger: 'hotkey f'});
  assert.deepEqual(state.performed, [0], 'the first run happens immediately');
  timers.advance(350);
  assert.deepEqual(state.performed, [0, 100, 200, 300]);
  assert.deepEqual(engine.active.map((a) => [a.title, a.repetitions]), [['Repeat click left every 100 ms', 4]]);
  engine.toggleRepeat(click, {interval: 0.1, id: 'hotkey f'});
  assert.equal(engine.isRunning, false);
  timers.advance(1000);
  assert.equal(state.performed.length, 4, 'nothing runs after toggling off');
  assert.equal(timers.pending, 0, 'no timeout left behind');
  const [started] = log.named('automation.started');
  assert.deepEqual(started.data, {id: 'hotkey f', title: 'Repeat click left every 100 ms', app: 'org.prismlauncher.PrismLauncher', interval: 0.1, mode: 'toggle', times: null, trigger: 'hotkey f'});
  const [stopped] = log.named('automation.stopped');
  assert.equal(stopped.data.reason, 'toggled off');
  assert.equal(stopped.data.repetitions, 4);
  assert.equal(stopped.data.seconds, 0.35);
});

test('times stops a repeat by itself; a single run never schedules a timeout', () => {
  const {timers, engine, state, log} = setup();
  engine.toggleRepeat(click, {interval: 0.1, times: 3, id: 'a'});
  timers.advance(1000);
  assert.deepEqual(state.performed, [0, 100, 200]);
  assert.equal(engine.isRunning, false);
  assert.equal(log.named('automation.stopped')[0].data.reason, 'finished');
  engine.toggleRepeat(click, {interval: 0.1, times: 1, id: 'b'});
  assert.equal(timers.pending, 0);
  assert.equal(state.performed.length, 4);
});

test('each interval gets its own jitter from the schedule', () => {
  const randoms = [0, 1, 0.25, 0.75];
  let i = 0;
  const {timers, engine, state} = setup({random: () => randoms[i++ % randoms.length]});
  engine.toggleRepeat(click, {interval: 1, jitter: 0.5, id: 'j'});
  timers.advance(10_000);
  const schedule = new RepeatSchedule({interval: 1, jitter: 0.5});
  const expected = [0];
  for (let k = 0; expected[expected.length - 1] + schedule.nextInterval(randoms[k % 4]) * 1000 <= 10_000; k++) {
    expected.push(expected[expected.length - 1] + schedule.nextInterval(randoms[k % 4]) * 1000);
  }
  assert.deepEqual(state.performed, expected);
  assert.deepEqual(state.performed.slice(0, 5), [0, 500, 2000, 2750, 4000], 'intervals of 0.5, 1.5, 0.75 and 1.25 s');
  engine.stopAll('test');
});

test('a while-held repeat stops on release; a toggle repeat ignores it', () => {
  const {timers, engine, state} = setup();
  engine.toggleRepeat(click, {interval: 0.05, mode: 'while-held', id: 'hotkey mouse'});
  timers.advance(120);
  engine.released('hotkey mouse');
  assert.equal(engine.isRunning, false);
  assert.equal(state.performed.length, 3);
  engine.toggleRepeat(click, {interval: 0.05, id: 'hotkey t'});
  engine.released('hotkey t');
  assert.equal(engine.isRunning, true, 'releasing a toggle repeat’s key does nothing');
  engine.stopAll('test');
});

test('a repeat whose action stops automations ends cleanly; failures are counted, not logged per run', () => {
  const {timers, engine, log} = setup();
  engine.perform = () => {
    engine.stopAll('stop shortcut');
    return true;
  };
  engine.toggleRepeat(click, {interval: 0.1, id: 's'});
  assert.equal(engine.isRunning, false);
  assert.equal(timers.pending, 0);
  const failing = setup();
  failing.engine.toggleRepeat({op: 'click', fail: true}, {interval: 0.1, times: 3, id: 'f'});
  failing.timers.advance(500);
  assert.equal(failing.log.named('automation.stopped')[0].data.failures, 3);
  assert.equal(log.named('automation.step_failed').length, 0);
});

test('holding toggles: the first press holds the input down, the next releases it', () => {
  const {engine, synth, log} = setup();
  engine.toggleHold('mouse:right', 'hotkey mouse4');
  engine.toggleHold('key:shift', 'hotkey hyper+r');
  assert.deepEqual(synth.events, ['right down', 'shift down']);
  assert.deepEqual(engine.active.map((a) => a.title), ['Hold Right Mouse Button', 'Hold Shift']);
  engine.toggleHold('mouse:right');
  assert.deepEqual(synth.events, ['right down', 'shift down', 'right up']);
  assert.equal(engine.isHeld('mouse:right'), false);
  assert.equal(log.named('automation.stopped')[0].data.reason, 'toggled off');
  engine.stopAll('test');
  assert.deepEqual(synth.events.slice(-1), ['shift up'], 'stopAll releases what is still held');
});

test('press down/up tracks what is held and never sends a release for something not pressed', () => {
  const {engine, synth, log} = setup();
  engine.press('key:w', 'up');
  assert.deepEqual(synth.events, [], 'nothing to release');
  assert.equal(log.named('automation.not_held').length, 1);
  engine.press('key:w', 'down');
  engine.press('key:w', 'down');
  assert.deepEqual(synth.events, ['w down'], 'a second press of a held key is dropped');
  engine.press('key:w', 'up');
  assert.deepEqual(synth.events, ['w down', 'w up']);
  assert.equal(log.named('automation.stopped')[0].data.reason, 'released by macro');
  engine.press('key:ctrl+shift+w', 'down');
  assert.deepEqual(synth.events.slice(-1), ['ctrl+shift+w down']);
  engine.stopAll('test');
});

test('an input the keyboard layout can’t produce fails and is logged', () => {
  const {engine, synth, log} = setup();
  synth.refuse.add('é');
  assert.equal(engine.press('key:é', 'down'), false);
  assert.equal(engine.isRunning, false);
  assert.match(log.named('automation.unknown_key')[0].data.message, /isn't a key/);
  assert.equal(engine.press('key:bogus', 'down'), false, 'not an input at all');
  assert.equal(log.named('automation.unknown_input').length, 1);
});

test('stopAll stops repeats and releases holds, logs once and tells the indicator', () => {
  const {timers, engine, synth, log, state} = setup();
  engine.toggleRepeat(click, {interval: 0.1, id: 'r'});
  engine.toggleHold('key:w');
  const changes = state.changes;
  engine.stopAll('stop shortcut');
  assert.equal(engine.isRunning, false);
  assert.equal(timers.pending, 0);
  assert.deepEqual(synth.events, ['w down', 'w up']);
  assert.deepEqual(log.named('automation.stopped_all').map((e) => [e.data.reason, e.level]), [['stop shortcut', 'notice']]);
  assert.equal(log.named('automation.stopped').length, 2);
  assert.equal(state.changes, changes + 1, 'one change notification for the whole stop');
  engine.stopAll('again');
  assert.equal(log.named('automation.stopped_all').length, 1, 'nothing running: nothing logged');
});

test('every stop asks for what automations left pending (macro steps, queued keys) to be dropped', () => {
  const {engine, timers} = setup();
  const dropped = [];
  engine.onStopAll = (reason) => dropped.push(reason);
  engine.toggleHold('key:w');
  engine.focusChanged(appIdentity('firefox'));
  assert.deepEqual(dropped, ['switched to another app']);
  engine.settings.maxRunMinutes = 0.01;
  engine.toggleRepeat(click, {interval: 0.1, id: 'r'});
  timers.advance(1000);
  assert.deepEqual(dropped, ['switched to another app', 'time limit reached']);
  engine.stopAll('nothing runs');
  assert.equal(dropped.length, 2, 'nothing running: nothing to drop');
  engine.onStopAll = () => {
    throw new Error('boom');
  };
  engine.toggleHold('key:w');
  assert.doesNotThrow(() => engine.stopAll('stop shortcut'), 'a failing hook never stops the release');
  assert.equal(engine.isRunning, false);
  engine.destroy();
  assert.equal(engine.onStopAll, null);
});

test('switching to another app stops everything; the same app and Slated’s settings don’t', () => {
  const {engine, state, log} = setup();
  engine.toggleRepeat(click, {interval: 0.1, id: 'r'});
  engine.focusChanged(appIdentity('org.prismlauncher.PrismLauncher', ['minecraft']));
  engine.focusChanged(appIdentity('org.gnome.Shell.Extensions'));
  assert.equal(engine.isRunning, true);
  engine.focusChanged(appIdentity('firefox'));
  assert.equal(engine.isRunning, false);
  assert.equal(log.named('automation.stopped_all')[0].data.reason, 'switched to another app');

  engine.toggleRepeat(click, {interval: 0.1, id: 'r'});
  engine.focusChanged(null);
  assert.equal(log.named('automation.stopped_all')[1].data.reason, 'left the app', 'the overview counts as leaving');

  state.focused = null; // started from the desktop: the next app is the one it's for
  engine.toggleRepeat(click, {interval: 0.1, id: 'r'});
  engine.focusChanged(appIdentity('steam_app_1086940'));
  assert.equal(engine.isRunning, true);
  engine.focusChanged(appIdentity('steam_app_1086940'));
  assert.equal(engine.isRunning, true);
  engine.focusChanged(appIdentity('firefox'));
  assert.equal(engine.isRunning, false);

  engine.settings.stopOnAppSwitch = false;
  engine.toggleHold('mouse:left');
  engine.focusChanged(appIdentity('firefox'));
  assert.equal(engine.isRunning, true, 'stopOnAppSwitch off');
  engine.stopAll('test');
});

test('a macro waiting on a wait counts for the safety stops, though the indicator doesn’t list it', () => {
  const {engine, timers, log, state} = setup();
  const dropped = [];
  engine.onStopAll = (reason) => dropped.push(reason);
  const first = engine.waitBegan();
  assert.deepEqual([engine.isRunning, engine.isBusy, engine.active], [false, true, []]);
  engine.focusChanged(appIdentity('org.prismlauncher.PrismLauncher'));
  engine.focusChanged(appIdentity('firefox'));
  assert.deepEqual(dropped, ['switched to another app'], 'leaving the app drops its steps');
  assert.equal(engine.isBusy, false);
  engine.waitEnded(first);

  // The steps after the wait run while Slated's settings window is in front: what they hold still
  // belongs to the game, so switching to Firefox stops it.
  const second = engine.waitBegan();
  state.focused = appIdentity('org.gnome.Shell.Extensions');
  engine.focusChanged(state.focused);
  engine.press('key:w', 'down');
  engine.waitEnded(second);
  assert.equal(log.named('automation.started')[0].data.app, 'org.prismlauncher.PrismLauncher');
  engine.focusChanged(appIdentity('firefox'));
  assert.equal(engine.isHeld('key:w'), false);
  assert.deepEqual(dropped, ['switched to another app', 'switched to another app']);

  state.focused = appIdentity('org.prismlauncher.PrismLauncher');
  engine.settings.maxRunMinutes = 0.01;
  engine.waitBegan();
  timers.advance(1000);
  assert.equal(dropped.at(-1), 'time limit reached');
  engine.waitBegan();
  engine.dropWaits();
  assert.deepEqual([engine.isBusy, timers.pending], [false, 0], 'dropped: no time limit left running');
});

test('maxRunMinutes stops everything after the limit, counted from the first start', () => {
  const {timers, engine, log} = setup();
  engine.settings.maxRunMinutes = 0.5;
  engine.toggleRepeat(click, {interval: 10, id: 'r'});
  timers.advance(20_000);
  engine.toggleHold('key:w');
  timers.advance(10_001);
  assert.equal(engine.isRunning, false);
  assert.equal(log.named('automation.stopped_all')[0].data.reason, 'time limit reached');
  assert.equal(timers.pending, 0);
  engine.settings.maxRunMinutes = 0;
  engine.toggleHold('key:w');
  timers.advance(3_600_000);
  assert.equal(engine.isRunning, true, 'no limit');
  engine.destroy();
  assert.equal(engine.isRunning, false);
  assert.equal(log.named('automation.stopped_all').at(-1).data.reason, 'disabled');
});

test('titles never contain typed text', () => {
  const {engine, log} = setup();
  engine.toggleRepeat({op: 'insert-text', text: 'my password'}, {interval: 2, times: 3, id: 'x'});
  const title = engine.active[0]?.title ?? log.named('automation.started')[0].data.title;
  assert.equal(title, "Repeat insert-text '(11 characters)' every 2 s, 3×");
  assert.ok(!JSON.stringify(log.events).includes('my password'));
  engine.stopAll('test');
});

test('labels: inputs, shortcuts, intervals and the indicator line', () => {
  assert.equal(inputLabel('mouse:middle'), 'Middle Mouse Button');
  assert.equal(inputLabel('key:rightCmd'), 'Right Super');
  assert.equal(inputLabel('key:ctrl+w'), 'Ctrl W');
  assert.equal(shortcutLabel({key: 'esc', modifiers: ['ctrl', 'alt', 'shift', 'cmd']}), '✦ Esc');
  assert.equal(shortcutLabel({key: 'v', modifiers: ['shift', 'cmd']}), 'Shift Super V');
  assert.equal(keyLabel('pad5'), 'Num 5');
  assert.deepEqual([secondsLabel(0.05), secondsLabel(1), secondsLabel(2.5), secondsLabel(0.0004)], ['50 ms', '1 s', '2.5 s', '0 ms']);
  assert.equal(repeatTitle({op: 'click', button: 'right', count: 2}, new RepeatSchedule({interval: 0.1, times: 50})), 'Repeat click right 2 every 100 ms, 50×');
  assert.equal(indicatorText([]), '');
  assert.equal(indicatorText([{title: 'Hold W'}]), 'Hold W');
  assert.equal(indicatorText([{title: 'a'}, {title: 'b'}]), '2 automations running');
});

test('while-held repeats are found in steps; key-sending actions are told apart', () => {
  const held = {op: 'repeat', action: click, interval: 0.1, mode: 'while-held'};
  assert.equal(whileHeldRepeat(held), held);
  assert.equal(whileHeldRepeat({op: 'repeat', action: click, interval: 0.1}), null, 'toggle mode');
  assert.equal(whileHeldRepeat({op: 'sequence', operations: [{op: 'undo'}, held]}), held);
  assert.equal(whileHeldRepeat({op: 'sequence', steps: [{action: held, keepWindow: true}]}), held);
  assert.equal(whileHeldRepeat({op: 'by-orientation', landscape: {op: 'undo'}, portrait: held}), held);
  assert.equal(whileHeldRepeat('repeat 0.1 while-held "click"'), null, 'canonical actions only');
  assert.equal(sendsKeys(click), false);
  assert.equal(sendsKeys({op: 'keystroke', keys: 'e'}), true);
  assert.equal(sendsKeys({op: 'press', input: 'key:w', phase: 'down'}), true);
  assert.equal(sendsKeys({op: 'hold', input: 'mouse:left'}), false);
  assert.equal(sendsKeys({op: 'sequence', operations: [click, {op: 'insert-text', text: 'x'}]}), true);
  assert.equal(sendsKeys({op: 'repeat', action: {op: 'hold', input: 'KEY:shift'}, interval: 1}), true);
});

test('status.json names the shortcuts that started running automations', () => {
  const active = [
    {title: 'Repeat click left every 100 ms', trigger: 'hotkey f6'},
    {title: 'Hold W', trigger: 'hotkey ctrl+alt+f4 1'},
    {title: 'Hold Shift', trigger: 'hotkey f6'},
    {title: 'Hold E', trigger: 'debug'},
    {title: 'Hold Q', trigger: null},
  ];
  assert.deepEqual(automationShortcuts(active), ['f6', 'ctrl+alt+f4 1']);
  assert.deepEqual(automationShortcuts([]), []);
});
