import {suite, expect, expectEqual} from './harness.mjs';
import {
  GNOME_DEFAULT_KEY_REPEAT, RATE_RANGE, delayLabel, intervalForRate, keyRepeatStatusLine, rateLabel, repeatsPerSecond,
  withKeyRepeat,
} from '../../gnome-extension/lib/prefs/keyRepeat.js';
import {parseStatus} from '../../gnome-extension/lib/prefs/status.js';
import {configChanges} from '../../gnome-extension/lib/prefs/validator.js';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {decodeConfigurationFiles} from '../../gnome-extension/lib/core/index.js';
import {memoryIO, CONFIG, SETTINGS} from './memoryio.mjs';

function harness(files) {
  const disk = {...files};
  const logged = [];
  let pending = null;
  const scheduler = {setTimeout: fn => (pending = fn, 1), clearTimeout: () => (pending = null)};
  const model = new PrefsModel({io: memoryIO(disk), scheduler, log: (event, data) => logged.push({event, data})});
  model.load();
  const tick = () => {
    const fn = pending;
    pending = null;
    fn?.();
  };
  return {model, disk, logged, tick};
}

const running = keyRepeat => ({running: true, keyRepeat});

export default suite('Key repeat', [
  ['labels: milliseconds, and the rate as repeats per second with its interval', () => {
    expectEqual(delayLabel(200), '200 ms');
    expectEqual(rateLabel(17), '59 per second (17 ms)');
    expectEqual(rateLabel(30), '33 per second (30 ms)');
    expectEqual(repeatsPerSecond(500), 2);
  }],
  ['the rate slider runs 2 to 66 per second and maps to whole, clamped milliseconds', () => {
    expectEqual(RATE_RANGE, [2, 66]);
    expectEqual(intervalForRate(59), 17);
    expectEqual(intervalForRate(60), 17);
    expectEqual(intervalForRate(66), 15);
    expectEqual(intervalForRate(2), 500);
    expectEqual(intervalForRate(1), 500, 'clamped');
    expectEqual(intervalForRate(1000), 15, 'clamped');
  }],
  ['the switch sets or removes keyRepeat, clamped, leaving the rest of keyboard alone', () => {
    const config = decodeConfiguration('{"keyboard": {"capsLock": "hyper"}}');
    const on = withKeyRepeat(config, {delay: 5, interval: 17.2});
    expectEqual(on.keyboard.keyRepeat, {delay: 100, interval: 17});
    expectEqual(on.keyboard.capsLock, 'hyper');
    const off = withKeyRepeat(on, null);
    expect(!('keyRepeat' in off.keyboard), 'removed');
    expectEqual(config.keyboard.keyRepeat, undefined, 'the original is untouched');
    expectEqual(withKeyRepeat(config, GNOME_DEFAULT_KEY_REPEAT).keyboard.keyRepeat, {delay: 500, interval: 30});
  }],
  ['status.json’s keyRepeat is read strictly', () => {
    expectEqual(parseStatus(null).keyRepeat, {state: 'off', delay: null, interval: null});
    expectEqual(parseStatus('{"keyRepeat": {"state": "applied", "delay": 200, "interval": 17}}').keyRepeat, {state: 'applied', delay: 200, interval: 17});
    expectEqual(parseStatus('{"keyRepeat": {"state": "applied", "delay": "200", "interval": 17}}').keyRepeat, {state: 'off', delay: null, interval: null});
    expectEqual(parseStatus('{"keyRepeat": {"state": "maybe", "delay": 200, "interval": 17}}').keyRepeat.state, 'off');
  }],
  ['the status line: off, not running, applied, failed, or still applying', () => {
    const want = {delay: 200, interval: 17};
    expectEqual(keyRepeatStatusLine(null, running({state: 'off'})).style, 'dim');
    expectEqual(keyRepeatStatusLine(want, {running: false}).style, 'warning');
    expectEqual(keyRepeatStatusLine(want, running({state: 'applied', delay: 200, interval: 17})).style, 'success');
    expectEqual(keyRepeatStatusLine(want, running({state: 'failed', delay: 200, interval: 17})).style, 'error');
    expectEqual(keyRepeatStatusLine(want, running({state: 'applied', delay: 500, interval: 30})).label, 'Applying');
  }],
  ['changes are logged like the Mac’s', () => {
    const before = decodeConfiguration('{}');
    const after = decodeConfiguration('{"keyboard": {"keyRepeat": {"delay": 200, "interval": 17}}}');
    expectEqual(configChanges(before, after), ['keyboard: capsLock off, alone nothing, modifiers Ctrl+Alt+Shift+Super, keyRepeat 200/17 ms']);
  }],
  ['edits save to config.json and read back the same; a hand-set keyRepeat isn’t an unsaved change', () => {
    const {model, disk, logged, tick} = harness({[CONFIG]: '{"version": 2, "keyboard": {"keyRepeat": {"delay": 250, "interval": 25}}}',
      [SETTINGS]: '{"version": 2}'});
    expectEqual(model.configuration.keyboard.keyRepeat, {delay: 250, interval: 25});
    expectEqual(model.saveState.kind, 'saved');
    model.update(config => Object.assign(config, withKeyRepeat(config, {delay: 200, interval: 17})));
    tick();
    expectEqual(JSON.parse(disk[CONFIG]).keyboard.keyRepeat, {delay: 200, interval: 17});
    expectEqual(decodeConfigurationFiles(disk[CONFIG], disk[SETTINGS]).configuration, model.configuration, 'the files decode to what is shown');
    expectEqual(logged.map(e => e.event), ['config.saved']);
    model.update(config => Object.assign(config, withKeyRepeat(config, null)));
    tick();
    expect(!('keyRepeat' in JSON.parse(disk[CONFIG]).keyboard), 'the switch off removes it from config.json');
  }],
]);
