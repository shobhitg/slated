import {suite, expect, expectEqual} from './harness.mjs';
import {
  defaultIslandSettings, islandSettings, CHEAT_SHEET_DELAYS, cheatSheetDelayItems, islandRowsSensitive, cheatSheetDelayText,
} from '../../gnome-extension/lib/prefs/island.js';
import {configChanges} from '../../gnome-extension/lib/prefs/validator.js';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';

const CONFIG = '/home/me/.config/slated/config.json';

/** A model on an in-memory config.json whose saves run when `tick()` says. */
function harness(text) {
  const disk = {[CONFIG]: text};
  const logged = [];
  let pending = null;
  const io = {
    home: '/home/me',
    readConfig: () => disk[CONFIG] ?? null,
    writeConfig: written => {
      disk[CONFIG] = written;
    },
    readFile: path => disk[path] ?? null,
  };
  const scheduler = {setTimeout: fn => (pending = fn, 1), clearTimeout: () => (pending = null)};
  const model = new PrefsModel({io, scheduler, log: (event, data) => logged.push({event, data}), makeId: () => '00000000-0000-4000-8000-000000000001'});
  model.load();
  const tick = () => {
    const fn = pending;
    pending = null;
    fn?.();
  };
  return {model, disk, logged, tick};
}

export default suite('Island settings', [
  ['defaults are the Mac\'s, and hand-set values win', () => {
    expectEqual(defaultIslandSettings(), {enabled: true, cheatSheet: true, cheatSheetDelay: 0.5, showFailures: true});
    expectEqual(islandSettings({}), defaultIslandSettings());
    expectEqual(islandSettings({island: {enabled: false, cheatSheetDelay: 0.8}}),
      {enabled: false, cheatSheet: true, cheatSheetDelay: 0.8, showFailures: true});
    expectEqual(islandSettings(decodeConfiguration('{}')), defaultIslandSettings(), 'the engine fills the same defaults');
  }],
  ['the delays are the Mac\'s, and a hand-set one is offered too', () => {
    expectEqual(CHEAT_SHEET_DELAYS.map(i => `${i.label} ${i.id}`), ['Short 0.3', 'Medium 0.5', 'Long 0.8']);
    expectEqual(cheatSheetDelayItems(0.5), [...CHEAT_SHEET_DELAYS]);
    expectEqual(cheatSheetDelayItems(1.25).map(i => i.label), ['Short', 'Medium', 'Long', '1.25 seconds']);
    expectEqual(cheatSheetDelayItems(1.25)[3].id, 1.25);
  }],
  ['rows are disabled while the island (or, for the delay, the cheat sheet) is off', () => {
    const rows = (enabled, cheatSheet) => islandRowsSensitive({...defaultIslandSettings(), enabled, cheatSheet});
    expectEqual(rows(true, true), {cheatSheet: true, cheatSheetDelay: true, showFailures: true});
    expectEqual(rows(true, false), {cheatSheet: true, cheatSheetDelay: false, showFailures: true});
    expectEqual(rows(false, true), {cheatSheet: false, cheatSheetDelay: false, showFailures: false});
  }],
  ['with keyd\'s tap for Escape, the delay row says keyd follows it after the installer runs again', () => {
    expectEqual(cheatSheetDelayText(false), 'How long to hold before the shortcuts appear. Quick taps never show them.');
    const keyd = cheatSheetDelayText(true);
    expect(keyd.startsWith(cheatSheetDelayText(false)), keyd);
    expect(/doesn't send Escape/.test(keyd) && keyd.includes('linux/install.sh --hyper-keyd again'), keyd);
  }],
  ['changes are logged like the Mac\'s', () => {
    const before = decodeConfiguration('{}');
    const after = decodeConfiguration('{"island": {"cheatSheetDelay": 0.8, "showFailures": false}}');
    expectEqual(configChanges(before, after), ['island: enabled true, cheatSheet true, cheatSheetDelay 0.8, showFailures false']);
    expectEqual(configChanges(after, after), []);
  }],
  ['edits save to config.json and read back the same, keeping a hand-set delay', () => {
    const {model, disk, logged, tick} = harness('{"island": {"cheatSheetDelay": 1.25}, "keyboard": {"capsLock": "hyper"}}');
    expectEqual(model.configuration.island.cheatSheetDelay, 1.25);
    model.update(config => {
      config.island = {...islandSettings(config), showFailures: false};
    });
    tick();
    const saved = JSON.parse(disk[CONFIG]);
    expectEqual(saved.island, {enabled: true, cheatSheet: true, cheatSheetDelay: 1.25, showFailures: false});
    expectEqual(saved.keyboard.capsLock, 'hyper', 'the rest of the file is kept');
    expectEqual(decodeConfiguration(disk[CONFIG]), model.configuration, 'the file decodes to what is shown');
    expectEqual(logged.map(e => e.event), ['config.saved']);
    expectEqual(logged[0].data.changes, ['island: enabled true, cheatSheet true, cheatSheetDelay 1.25, showFailures false']);
    model.update(config => {
      config.island = {...islandSettings(config), enabled: false, cheatSheetDelay: 0.3};
    });
    tick();
    expectEqual(JSON.parse(disk[CONFIG]).island, {enabled: false, cheatSheet: true, cheatSheetDelay: 0.3, showFailures: false});
  }],
]);
