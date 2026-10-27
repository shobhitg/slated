import {suite, expect, expectEqual, readText} from './harness.mjs';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {decodeConfiguration, implemented, starterConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {presetById} from '../../gnome-extension/lib/prefs/presets.js';
import {recipeById} from '../../gnome-extension/lib/prefs/automation.js';

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

/** A Slate file with a layout named "Code" and a shortcut that applies it. */
const SLATE_CODE = 'slate.layout("Code", {"Terminal": {"operations": [slate.operation("move", '
  + '{"x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX", "height": "screenSizeY"})]}});\n'
  + 'slate.bind("c:ctrl,alt", slate.operation("layout", {"name": "Code"}));\n';

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
  ['a broken config.json that\'s deleted no longer blocks saving: the next change creates it', () => {
    // Broken from the start, then deleted and reloaded.
    let {model, disk, tick} = harness({[CONFIG]: '{"bindings": ['});
    model.load();
    expect(model.loadError !== null, 'blocked');
    delete disk[CONFIG];
    model.reload();
    expectEqual([model.loadError, model.saveState, model.firstRun], [null, {kind: 'saved'}, true], 'as on a first run');
    model.update(config => {
      config.general.showActionHUD = true;
    });
    tick();
    expectEqual(decodeConfiguration(disk[CONFIG]).general.showActionHUD, true, 'created again');
    // Broken by a hand edit after it was read, with an edit waiting, then deleted: the edit is saved.
    ({model, disk, tick} = harness({[CONFIG]: '{"general": {"showActionHUD": true}}'}));
    model.load();
    disk[CONFIG] = '{"general": ';
    model.syncFromDisk();
    model.update(config => {
      config.keyboard.capsLock = 'hyper';
    });
    expectEqual(model.saveState, {kind: 'blocked'});
    delete disk[CONFIG];
    model.syncFromDisk();
    expectEqual(model.loadError, null);
    tick();
    const saved = decodeConfiguration(disk[CONFIG]);
    expectEqual([saved.general.showActionHUD, saved.keyboard.capsLock], [true, 'hyper'], 'what the window showed, with the edit');
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
  ['a binding or hotstring copied in config.json with its id gets one of its own: editing or deleting the copy spares the original', () => {
    const {model, disk, tick, writes} = harness({[CONFIG]: JSON.stringify({
      bindings: [{id: A, name: 'Left', keys: 'hyper+a', action: half}, {id: A, name: 'Right', keys: 'hyper+d', action: half}],
      hotstrings: [{id: H, trigger: ';a', replacement: 'a'}, {id: H, trigger: ';b', replacement: 'b'}],
    })});
    model.load();
    const [left, right] = model.configuration.bindings;
    expectEqual(left.id, A);
    expect(right.id !== A, 'the copy has its own id');
    expectEqual(model.binding(right.id).name, 'Right');
    expectEqual(writes.length, 0, 'nothing is written until something changes');
    // An unrelated hand edit: the copy keeps the id the window gave it, so its open editor stays.
    disk[CONFIG] = disk[CONFIG].replace('"hyper+a"', '"hyper+q"');
    model.syncFromDisk();
    expectEqual(model.configuration.bindings.map(b => [b.id, b.keys]), [[A, 'hyper+q'], [right.id, 'hyper+d']]);
    model.deleteBinding(right.id);
    const copy = model.configuration.hotstrings[1].id;
    expect(copy !== H, 'hotstrings too');
    model.setHotstring(copy, h => {
      h.replacement = 'B';
    });
    tick();
    const saved = decodeConfiguration(disk[CONFIG]);
    expectEqual(saved.bindings.map(b => b.name), ['Left']);
    expectEqual(saved.hotstrings.map(h => [h.trigger, h.replacement]), [[';a', 'a'], [';b', 'B']]);
    expect(saved.hotstrings[0].id !== saved.hotstrings[1].id, 'saved with ids of their own');
  }],
  ['typing another layout\'s name (or none) over a layout\'s name moves no shortcut and renames no other layout', () => {
    const {model, disk, tick} = harness({[CONFIG]: JSON.stringify({
      layouts: [{name: 'A', apps: [{app: 'Firefox'}]}, {name: 'B', apps: [{app: 'Terminal'}]}],
      bindings: [{id: A, keys: 'hyper+1', action: {op: 'layout', name: 'A'}}, {id: B, keys: 'hyper+2', action: {op: 'layout', name: 'B'}}],
    })});
    model.load();
    expectEqual(model.layoutNameProblem('B', 'A'), 'Another layout already has this name.');
    expectEqual(model.layoutNameProblem('B', '  '), 'Name the layout.');
    expectEqual(model.layoutNameProblem('B', 'B'), null);
    // The editor tracks its layout by name while "B" becomes "AB": select all, type A, then B.
    let name = model.setLayout('B', l => {
      l.name = 'A';
    });
    expectEqual(name, 'B');
    expectEqual(model.binding(B).action.name, 'B');
    expectEqual(model.setLayout(name, l => {
      l.name = '';
    }), 'B');
    tick();
    expectEqual(decodeConfiguration(disk[CONFIG]).bindings.map(b => b.action.name), ['A', 'B']);
    name = model.setLayout(name, l => {
      l.name = 'AB';
    });
    expectEqual(name, 'AB');
    expectEqual(model.configuration.layouts.map(l => `${l.name}: ${l.apps[0].app}`), ['A: Firefox', 'AB: Terminal']);
    expectEqual(model.configuration.bindings.map(b => b.action.name), ['A', 'AB']);
    // The rest of a change still applies.
    model.setLayout('AB', l => {
      l.name = 'A';
      l.apps.push({app: 'Files', operations: [], options: l.apps[0].options});
    });
    expectEqual(model.configuration.layouts.map(l => `${l.name}: ${l.apps.length}`), ['A: 1', 'AB: 2']);
  }],
  ['a Slate file\'s layout name is taken, as when adding a layout', () => {
    const {model} = harness({[CONFIG]: JSON.stringify({layouts: [{name: 'New Layout', apps: []}]}), [`${HOME}/.slate.js`]: SLATE_CODE});
    model.load();
    expectEqual(model.layoutNameProblem('New Layout', 'Code'), 'Another layout already has this name.');
    expectEqual(model.setLayout('New Layout', l => {
      l.name = 'Code';
    }), 'New Layout');
    expectEqual(model.layoutNameProblem('New Layout', 'Code 2'), null);
  }],
  ['a rename keeps what named the new name before (a Slate layout, or none yet) where it was', () => {
    const {model} = harness({[CONFIG]: JSON.stringify({
      layouts: [{name: 'Terminals', apps: []}],
      bindings: [{id: A, keys: 'hyper+t', action: {op: 'layout', name: 'Terminals'}}, {id: B, keys: 'hyper+g', action: {op: 'layout', name: 'Gaming'}}],
    })});
    model.load();
    expectEqual([...model.layoutReferences('Gaming')], [`binding:${B}`]);
    // As the layout editor types "Gaming 2" over "Terminals": "Gaming" arrives with hyper+g on it.
    let name = model.setLayout('Terminals', l => {
      l.name = 'Gaming';
    });
    expectEqual(model.configuration.bindings.map(b => b.action.name), ['Gaming', 'Gaming']);
    name = model.setLayout(name, l => {
      l.name = 'Gaming 2';
    }, {keep: new Set([`binding:${B}`])});
    expectEqual(name, 'Gaming 2');
    expectEqual(model.configuration.bindings.map(b => b.action.name), ['Gaming 2', 'Gaming']);
  }],
  ['a rename re-points every step, hotstring and display default that applies the layout', () => {
    const layout = name => ({op: 'layout', name});
    const {model} = harness({[CONFIG]: JSON.stringify({
      layouts: [{name: 'Code', apps: []}],
      bindings: [
        {id: A, keys: 'hyper+1', action: layout('Code')},
        {id: B, keys: 'hyper+2', action: {op: 'chain', operations: [layout('Code'), half]}},
        {id: testId(0xc), keys: 'hyper+3', action: {op: 'by-orientation', landscape: layout('Code'), portrait: half}},
        {id: testId(0xd), keys: 'hyper+4', action: {op: 'sequence', operations: [layout('Code'), {op: 'wait', seconds: 1}]}},
        {id: testId(0xe), keys: 'hyper+5', action: 'layout Code'},
      ],
      hotstrings: [{id: H, trigger: ';code', replacement: '', action: layout('Code')}],
      defaults: [{target: 'Code', condition: {count: {_0: 2}}}],
    })});
    model.load();
    model.setLayout('Code', l => {
      l.name = 'Coding';
    });
    const config = model.configuration;
    expectEqual(config.bindings[0].action, layout('Coding'));
    expectEqual(config.bindings[1].action.operations[0], layout('Coding'));
    expectEqual(config.bindings[2].action.landscape, layout('Coding'));
    expectEqual(config.bindings[3].action.operations[0], layout('Coding'));
    if (implemented('parseOperation')) expectEqual(config.bindings[4].action, layout('Coding'), 'Slate syntax too');
    expectEqual(config.hotstrings[0].action, layout('Coding'));
    expectEqual(config.defaults.map(d => d.target), ['Coding']);
    expectEqual(model.issues.filter(i => /no layout named/.test(i.message)), [], 'nothing still names the old layout');
  }],
  ['a layout copied in config.json is its own: editing or deleting the copy spares the original', () => {
    const copied = () => harness({[CONFIG]: JSON.stringify({
      layouts: [{name: 'Code', apps: [{app: 'Firefox'}]}, {name: 'Code', apps: [{app: 'Terminal'}]}],
      bindings: [{id: A, keys: 'hyper+1', action: {op: 'layout', name: 'Code'}}],
    })});
    let {model, disk, tick} = copied();
    model.load();
    expectEqual(model.layoutIndex('Code', 1), 1);
    expectEqual(model.layoutNameProblem('Code', 'Code 2', 1), null);
    expectEqual(model.setLayout('Code', l => {
      l.name = 'Code 2';
    }, {index: 1}), 'Code 2');
    expectEqual(model.configuration.layouts.map(l => `${l.name}: ${l.apps[0].app}`), ['Code: Firefox', 'Code 2: Terminal']);
    expectEqual(model.binding(A).action.name, 'Code', 'the original still has the name, so its shortcut stays');
    ({model, disk, tick} = copied());
    model.load();
    model.deleteLayout('Code', 1);
    tick();
    expectEqual(decodeConfiguration(disk[CONFIG]).layouts.map(l => `${l.name}: ${l.apps[0].app}`), ['Code: Firefox']);
  }],
  ['a rename waits with its shortcuts while another layout can\'t be saved', () => {
    const bad = {op: 'move', x: 'screenOriginX+', y: '0', width: '10', height: '10'};
    const start = (chat, code = {name: 'Code', apps: []}) => harness({[CONFIG]: JSON.stringify({
      layouts: [code, {name: 'Chat', apps: [{app: 'Slack', operations: [chat]}]}],
      bindings: [{id: A, keys: 'hyper+1', action: {op: 'layout', name: 'Code'}}],
      defaults: [{target: 'Code', condition: {count: {_0: 2}}}],
    })});
    const onDisk = disk => {
      const saved = decodeConfiguration(disk[CONFIG]);
      return [saved.layouts.map(l => l.name), saved.bindings[0].action.name, saved.defaults[0].target];
    };
    // An operation half-typed in another layout while this one is renamed.
    let {model, disk, tick} = start(half);
    model.load();
    model.setLayout('Chat', l => {
      l.apps[0].operations = [bad];
    });
    model.setLayout('Code', l => {
      l.name = 'Coding';
    });
    tick();
    expectEqual(onDisk(disk), [['Code', 'Chat'], 'Code', 'Code'], 'the shortcut keeps the name config.json has');
    // A typo already in the file, in another layout.
    ({model, disk, tick} = start(bad));
    model.load();
    model.setLayout('Code', l => {
      l.name = 'Coding';
    });
    tick();
    expectEqual(onDisk(disk), [['Code', 'Chat'], 'Code', 'Code']);
    // An error in the renamed layout itself, saved as the window closes.
    ({model, disk} = start(half));
    model.load();
    model.setLayout('Code', l => {
      l.name = 'Coding';
      l.apps.push({app: 'Terminal', operations: [{...bad, x: '0', width: 'screenSizeX/'}]});
    });
    model.saveNow();
    expectEqual(onDisk(disk), [['Code', 'Chat'], 'Code', 'Code']);
    // Fixed: the rename and its shortcuts save together.
    model.setLayout('Coding', l => {
      l.apps.pop();
    });
    model.saveNow();
    expectEqual(onDisk(disk), [['Coding', 'Chat'], 'Coding', 'Coding']);
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
  ['recipes add named automation bindings, and shared keys respect the apps they work in', () => {
    const {model, logged, writes, tick} = harness({[CONFIG]: JSON.stringify({
      bindings: [
        {id: A, name: 'Minecraft', keys: 'f', action: {op: 'hold', input: 'key:w'}, onlyInApps: ['org.prismlauncher.PrismLauncher']},
        {id: B, name: 'Clipboard too', keys: 'shift+cmd+v', action: half},
      ],
    })});
    model.load();
    const id = model.addRecipe(recipeById('click-times'), {keys: 'f', apps: ['steam_app_1']});
    const added = model.binding(id);
    expectEqual([added.name, added.keys, added.onlyInApps, added.action.times], ['Click 50 Times', 'f', ['steam_app_1'], 50]);
    expectEqual(model.otherUses('f', null, id), [], 'Minecraft\'s F is another app\'s');
    model.setBinding(id, b => {
      b.onlyInApps = ['org.prismlauncher.PrismLauncher.desktop'];
    });
    expectEqual(model.otherUses('f', null, id), ['“Minecraft”'], 'the same app: they clash');
    const waiting = model.addRecipe(recipeById('hold-w'));
    expectEqual([model.binding(waiting).keys, model.binding(waiting).name], ['', 'Hold W (Auto-Run)'], 'no keys yet: recorded next');
    expectEqual(logged.filter(e => e.event === 'ui.recipe_added').map(e => e.data), [
      {recipe: 'click-times', keys: true, apps: 1}, {recipe: 'hold-w', keys: false, apps: 0}]);
    expectEqual(model.otherUsesOfBuiltIn('clipboard'), ['“Clipboard too”']);
    expectEqual(model.otherUsesOfBuiltIn('stopAutomations'), []);
    tick();
    const written = JSON.parse(writes[writes.length - 1]);
    expectEqual(written.bindings.find(b => b.id === id).onlyInApps, ['org.prismlauncher.PrismLauncher.desktop']);
    expectEqual(model.bindingState(model.binding(id)), {state: 'not-running'}, 'saved: no longer "saving"');
  }],
  ['the built-in shortcuts\' state comes from the running extension', () => {
    const {model} = harness({[CONFIG]: '{}'});
    model.load();
    model.setShellInfo({state: 1, error: ''});
    model.setStatusText(JSON.stringify({running: true, hotkeys: {'shift+cmd+v': 'failed: taken by GNOME', 'hyper+esc': 'active'}}));
    expectEqual(model.builtInState('clipboard'), {state: 'failed', reason: 'taken by GNOME'});
    expectEqual(model.builtInState('stopAutomations'), {state: 'active', reason: null});
    model.update(config => {
      config.clipboard.enabled = false;
    });
    expectEqual(model.builtInState('clipboard'), null, 'off: nothing to report');
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
