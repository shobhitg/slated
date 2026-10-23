import {suite, expect, expectEqual, readText} from './harness.mjs';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {decodeConfiguration, implemented, starterConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {presetById} from '../../gnome-extension/lib/prefs/presets.js';

const HOME = '/home/me';
const CONFIG = `${HOME}/.config/slated/config.json`;
const author = await readText('./fixtures/slate-author-like.js', import.meta.url);

/** In-memory files plus a manual clock, so saving can be tested without waiting. */
function harness(files = {}) {
  const disk = {...files};
  const writes = [];
  const logged = [];
  const timers = new Map();
  let nextTimer = 1;
  let n = 0;
  const io = {
    home: HOME,
    readConfig: () => (CONFIG in disk ? disk[CONFIG] : null),
    writeConfig: text => {
      if (disk.__failWrites) throw new Error('disk full');
      disk[CONFIG] = text;
      writes.push(text);
    },
    readFile: path => (path in disk ? disk[path] : null),
  };
  const scheduler = {
    setTimeout: (fn, ms) => {
      const id = nextTimer++;
      timers.set(id, {fn, ms});
      return id;
    },
    clearTimeout: id => timers.delete(id),
  };
  const model = new PrefsModel({io, scheduler, log: (event, data, level) => logged.push({event, data, level}), makeId: () => testId(1000 + n++)});
  const tick = () => {
    for (const [id, timer] of [...timers]) {
      timers.delete(id);
      timer.fn();
    }
  };
  return {model, disk, writes, logged, tick, timers};
}

const half = presetById('left-half').action;

/** config.json ids must be UUIDs, as in Swift: deterministic ones for the tests. */
const testId = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const A = testId(0xa);
const B = testId(0xb);
const H = testId(0x100);

export default suite('Preferences model', [
  ['first run without config.json or Slate files starts from the starter set, and writes nothing yet', () => {
    const {model, writes} = harness();
    model.load();
    expect(model.firstRun);
    const starter = starterConfiguration();
    expectEqual(model.configuration.bindings.length, starter ? starter.bindings.length : 0);
    expectEqual(writes.length, 0);
    expectEqual(model.saveState, {kind: 'saved'});
  }],
  ['first run with a Slate config starts empty, like macOS', () => {
    const {model} = harness({[`${HOME}/.slate.js`]: author});
    model.load();
    expectEqual(model.configuration.bindings, []);
    expectEqual(model.sources[0].bindings.length, 21);
    expectEqual(model.sources[0].displayPath, '~/.slate.js');
    expectEqual(model.sources[1].exists, false);
  }],
  ['edits save after a pause, with the changes in the log', () => {
    const {model, writes, logged, tick, timers} = harness({[CONFIG]: '{}'});
    model.load();
    model.update(config => {
      config.keyboard.capsLock = 'hyper';
    });
    expectEqual(model.saveState, {kind: 'pending'});
    expectEqual([...timers.values()][0].ms, 450);
    expectEqual(writes.length, 0, 'nothing written before the pause');
    tick();
    expectEqual(writes.length, 1);
    expectEqual(decodeConfiguration(writes[0]).keyboard.capsLock, 'hyper');
    expectEqual(model.saveState, {kind: 'saved'});
    expectEqual(logged.map(e => e.event), ['config.saved']);
    expect(logged[0].data.changes[0].startsWith('keyboard: capsLock hyper'));
    model.update(config => config);
    expectEqual(model.saveState, {kind: 'saved'}, 'no-op edits change nothing');
  }],
  ['config edits round-trip through the file', async () => {
    const text = await readText('./fixtures/config-handwritten.jsonc', import.meta.url);
    const {model, writes} = harness({[CONFIG]: text});
    model.load();
    expectEqual(model.loadError, null);
    const id = model.configuration.bindings[0].id;
    model.setBinding(id, b => {
      b.name = 'Renamed';
    });
    const hs = model.addHotstring({trigger: ';x', replacement: 'y'});
    model.saveNow();
    const written = decodeConfiguration(writes[writes.length - 1]);
    expectEqual(written, model.configuration, 'what was written decodes to the draft');
    expectEqual(written.bindings[0].name, 'Renamed');
    expect(written.hotstrings.some(h => h.id === hs && h.trigger === ';x'));
    expectEqual(written.settings, {nudgePercentOf: 'screenSize'}, 'hand-set values survive');
  }],
  ['items with errors are held back; a new binding waiting for keys is not an error', () => {
    const {model, disk, tick} = harness({[CONFIG]: JSON.stringify({bindings: [{id: A, keys: 'hyper+a', action: half}]})});
    model.load();
    model.addBinding();
    tick();
    expectEqual(model.saveState, {kind: 'saved'});
    expectEqual(decodeConfiguration(disk[CONFIG]).bindings.map(b => b.id), [A], 'the empty binding is not written');
    model.setBinding(A, b => {
      b.action = {...half, width: 'screnSizeX/2'};
    });
    tick();
    expectEqual(model.saveState, {kind: 'partial', count: 1});
    expectEqual(decodeConfiguration(disk[CONFIG]).bindings[0].action, half, 'the last saved version stays on disk');
    expectEqual(model.bindingState(model.binding(A)).state, 'not-saved');
  }],
  ['hand edits on disk are adopted unless there are unsaved edits', () => {
    const {model, disk} = harness({[CONFIG]: '{}'});
    model.load();
    disk[CONFIG] = '{"general": {"showActionHUD": true}}';
    model.syncFromDisk();
    expectEqual(model.configuration.general.showActionHUD, true);
    model.update(config => {
      config.general.showActionHUD = false;
    });
    disk[CONFIG] = '{"general": {"showActionHUD": true}, "keyboard": {"capsLock": "hyper"}}';
    model.syncFromDisk();
    expectEqual(model.configuration.keyboard.capsLock, 'off', 'pending edits win');
  }],
  ['a broken config.json pauses saving until it is fixed', () => {
    const {model, disk, writes, tick} = harness({[CONFIG]: '{ "bindings": [ }'});
    model.load();
    expect(model.loadError !== null);
    expectEqual(model.saveState, {kind: 'blocked'});
    model.update(config => {
      config.general.showActionHUD = true;
    });
    tick();
    model.saveNow();
    expectEqual(writes.length, 0, "never overwrite a file the user is editing");
    disk[CONFIG] = '{}';
    model.syncFromDisk();
    expectEqual(model.loadError, null);
    expectEqual(model.saveState, {kind: 'saved'});
  }],
  ['write failures are reported and logged', () => {
    const {model, disk, logged} = harness({[CONFIG]: '{}'});
    model.load();
    disk.__failWrites = true;
    model.update(config => {
      config.general.showActionHUD = true;
    });
    model.saveNow();
    expectEqual(model.saveState, {kind: 'failed', message: 'disk full'});
    expectEqual(logged.map(e => [e.event, e.level]), [['config.save_failed', 'error']]);
  }],
  ['status drives binding states', () => {
    const {model} = harness({[CONFIG]: JSON.stringify({bindings: [{id: A, keys: 'hyper+a', action: half}]})});
    model.load();
    model.setShellInfo({state: 1});
    model.setStatusText(JSON.stringify({running: true, hotkeys: {'hyper+a': 'failed: taken'}}));
    expectEqual(model.bindingState(model.binding(A)), {state: 'failed', reason: 'taken'});
    model.setStatusText(null);
    expectEqual(model.bindingState(model.binding(A)).state, 'not-running');
  }],
  ['binding helpers: starter set, duplicate, delete, copy from Slate', () => {
    const {model} = harness({[CONFIG]: JSON.stringify({bindings: [{id: A, keys: 'hyper+left', action: half, name: 'Mine'}]}),
      [`${HOME}/.slate.js`]: author});
    model.load();
    expectEqual(model.addStarterBindings(), 7, 'hyper+left is taken already');
    expectEqual(model.addStarterBindings(), 0);
    const copy = model.duplicateBinding(A);
    expectEqual([model.binding(copy).name, model.binding(copy).keys], ['Mine Copy', '']);
    expectEqual(model.deleteBinding(copy), 'Mine Copy');
    const source = model.sources[0].bindings.find(b => b.keys === 'hyper+a');
    expect(!model.isCopied(source));
    const id = model.copyIntoSlated(source);
    expectEqual(model.binding(id).action, half, 'functions are copied as their probed operation');
    expect(model.isCopied(source));
    expectEqual(model.otherUses('hyper+a', null, null), ['“Left Half”', '“JavaScript function” in ~/.slate.js']);
  }],
  ['renaming a layout keeps the shortcuts that apply it', () => {
    const {model} = harness({[CONFIG]: JSON.stringify({
      layouts: [{name: 'Coding', apps: []}],
      bindings: [{id: A, keys: 'hyper+1', action: {op: 'layout', name: 'Coding'}}],
    })});
    model.load();
    expectEqual(model.addLayout(), 'New Layout');
    expectEqual(model.setLayout('Coding', l => {
      l.name = 'Writing';
    }), 'Writing');
    expectEqual(model.binding(A).action, {op: 'layout', name: 'Writing'});
    expectEqual(model.triggersForLayout('Writing'), [{keys: 'hyper+1', modal: null}]);
  }],
  ['moving, deleting and duplicating', () => {
    const {model} = harness({[CONFIG]: JSON.stringify({
      bindings: [{id: A, keys: 'hyper+a', action: half}, {id: B, keys: 'hyper+b', action: half}],
      hotstrings: [{id: H, trigger: ';x', replacement: 'y'}],
      layouts: [{name: 'L'}],
    })});
    model.load();
    model.moveBinding(A, 1);
    expectEqual(model.configuration.bindings.map(b => b.id), [B, A]);
    model.moveBinding(A, 1);
    expectEqual(model.configuration.bindings.map(b => b.id), [B, A], 'moving past the end does nothing');
    const copy = model.duplicateHotstring(H);
    expectEqual(model.hotstring(copy).trigger, ';x2');
    expectEqual(model.deleteHotstring(H), ';x');
    expectEqual(model.deleteHotstring('nope'), null);
    model.deleteLayout('L');
    expectEqual(model.configuration.layouts, []);
  }],
  ['reload saves pending edits and re-reads everything', () => {
    const {model, disk, writes} = harness({[CONFIG]: '{}', [`${HOME}/.slate.js`]: author});
    model.load();
    model.update(config => {
      config.general.showActionHUD = true;
    });
    disk[`${HOME}/.slate.js`] = 'S.bnd("a:ctrl", {"op": "undo"});';
    model.reload();
    expectEqual(writes.length, 1, 'the pending edit was saved first');
    expectEqual(model.sources[0].bindings.length, 1, 'the Slate file was re-read');
  }],
  ['sections the window doesn\'t edit (clipboard, automation) survive saving', () => {
    const {model, writes} = harness({[CONFIG]: JSON.stringify({
      bindings: [{id: A, keys: 'hyper+a', action: half}],
      clipboard: {enabled: false, shortcut: null, maxItems: 50, excludedApps: ['org.keepassxc.KeePassXC']},
      automation: {stopShortcut: 'ctrl+alt+esc', maxRunMinutes: 2.5},
    })});
    model.load();
    model.setBinding(A, b => {
      b.name = 'Renamed';
    });
    model.saveNow();
    const written = JSON.parse(writes[writes.length - 1]);
    expectEqual(written.bindings[0].name, 'Renamed');
    expectEqual([written.clipboard.enabled, written.clipboard.shortcut, written.clipboard.maxItems, written.clipboard.excludedApps],
      [false, null, 50, ['org.keepassxc.KeePassXC']], 'clipboard settings kept, null shortcut included');
    expectEqual([written.automation.stopShortcut, written.automation.maxRunMinutes], ['ctrl+alt+esc', 2.5]);
    expectEqual(decodeConfiguration(writes[writes.length - 1]), model.configuration, 'and the file decodes to what is shown');
  }],
  ['a config.json the engine can\'t read is never overwritten', () => {
    // E.g. a newer action from the Mac app that this engine doesn't know yet, or an id that isn't a UUID.
    for (const text of [
      JSON.stringify({bindings: [{id: A, keys: 'hyper+c', action: {op: 'teleport'}}]}),
      JSON.stringify({bindings: [{id: 'not-a-uuid', keys: 'hyper+c', action: half}]}),
    ]) {
      const {model, disk, writes, tick} = harness({[CONFIG]: text});
      model.load();
      expect(model.loadError !== null, 'reported');
      model.update(config => {
        config.general.showActionHUD = true;
      });
      tick();
      model.saveNow();
      expectEqual(writes.length, 0, 'nothing written');
      expectEqual(disk[CONFIG], text, 'the file is untouched');
    }
    const {model} = harness({[CONFIG]: JSON.stringify({bindings: [{id: 'not-a-uuid', keys: 'hyper+c', action: half}]})});
    model.load();
    expectEqual(model.loadError, 'bindings[0].id: Attempted to decode UUID from invalid UUID string.', 'says where');
  }],
  ['entries written without ids keep theirs when the file is read again', () => {
    // Hand-written files often leave ids out; each decode invents new ones, as in Swift.
    const text = JSON.stringify({bindings: [{keys: 'hyper+a', action: half}, {keys: 'hyper+b', action: {op: 'undo'}}],
      hotstrings: [{trigger: ';x', replacement: 'y'}]});
    const {model, disk, writes} = harness({[CONFIG]: text});
    model.load();
    const ids = () => [...model.configuration.bindings.map(b => b.id), ...model.configuration.hotstrings.map(h => h.id)];
    const before = ids();
    expect(before.every(id => /^[0-9A-F-]{36}$/.test(id)), 'generated ids are UUIDs');
    model.syncFromDisk();
    expectEqual(ids(), before, 'the same text: nothing changes');
    // A hand edit to one entry keeps the other entries' ids, so their open editors stay open.
    disk[CONFIG] = JSON.stringify({bindings: [{keys: 'hyper+a', action: half}, {keys: 'hyper+b', action: {op: 'hint'}}],
      hotstrings: [{trigger: ';x', replacement: 'y'}]});
    model.syncFromDisk();
    expectEqual(model.configuration.bindings[0].id, before[0]);
    expectEqual(model.configuration.bindings[1].action, {op: 'hint'}, 'the edit was adopted');
    expectEqual(model.configuration.hotstrings[0].id, before[2]);
    expectEqual(writes.length, 0, 'reading never writes');
  }],
  ['importing the Slate config adds its bindings and logs it', () => {
    const {model, logged, tick} = harness({[CONFIG]: '{}', [`${HOME}/.slate.js`]: author});
    model.load();
    const plan = model.planSlateImport();
    const converted = implemented('parseOperation') ? 21 : 15;
    expectEqual(plan.added.length, converted);
    expectEqual(plan.stopsLoading, converted === 21);
    model.applySlateImport(plan);
    tick();
    expectEqual(model.configuration.bindings.length, converted);
    const event = logged.find(e => e.event === 'slate.imported');
    expectEqual(event.data.imported, converted);
  }],
]);
