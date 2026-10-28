import {suite, expect, expectEqual} from './harness.mjs';
import {
  STEPS, parseWindowState, windowStateText, startingPane, primaryTitle, hyperSubtitle, tapSubtitle, keydAdvice,
  hotstringsStep, slateStep, sourceSummary, starterAdded, doneChecklist, tryItTip, loadedSourceBindings,
} from '../../gnome-extension/lib/prefs/getstarted.js';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {emptyStatus} from '../../gnome-extension/lib/prefs/status.js';
import {presetById, starterBindings} from '../../gnome-extension/lib/prefs/presets.js';

const config = (json = {}) => decodeConfiguration(JSON.stringify(json));
const status = (fields = {}) => ({...emptyStatus(), present: true, running: true, ...fields});
const source = (fields = {}) => ({path: '~/.slate.js', displayPath: '~/.slate.js', kind: 'javascript', exists: true, bindings: [], layouts: [], error: null, ...fields});

/** A model on a first run, with the window state file in memory. */
function model(windowState = null) {
  const disk = {windowState};
  const logged = [];
  const m = new PrefsModel({
    io: {
      home: '/home/me', readConfig: () => null, writeConfig: () => {}, readFile: () => null,
      readWindowState: () => disk.windowState,
      writeWindowState: text => {
        if (disk.fail) throw new Error('read-only file system');
        disk.windowState = text;
      },
    },
    log: (event, data, level) => logged.push({event, data, level}),
  });
  m.load();
  return {model: m, disk, logged};
}

export default suite('Get Started', [
  ['the window keeps "finished" in its own state file', () => {
    expectEqual(parseWindowState(null), {setupFinished: false}, 'no file: a first run');
    expectEqual(parseWindowState('{"setupFinished": tru'), {setupFinished: false}, 'unreadable: a first run');
    expectEqual(parseWindowState('[true]'), {setupFinished: false});
    expectEqual(parseWindowState('{"setupFinished": true, "later": 1}'), {setupFinished: true, later: 1}, 'other keys are kept');
    expectEqual(parseWindowState(windowStateText({setupFinished: true})), {setupFinished: true});
  }],
  ['the window opens on Get Started until it is finished, then on Overview', () => {
    expectEqual([startingPane(false), startingPane(true)], ['getStarted', 'overview']);
    const {model: m, disk, logged} = model();
    expect(m.needsSetup && m.startingPane() === 'getStarted', 'a first open');
    let emitted = 0;
    m.on('setup', () => emitted++);
    m.setGetStartedStep('slateConfig');
    m.setGetStartedStep('nonsense');
    m.restartGetStarted();
    expectEqual(m.getStartedStep, 'slateConfig', 'during setup, Get Started picks up where it was');
    expectEqual(m.finishSetup(), null);
    expect(!m.needsSetup && m.startingPane() === 'overview', 'finished');
    expectEqual(JSON.parse(disk.windowState), {setupFinished: true});
    expect(logged.some(e => e.event === 'ui.get_started_finished'), 'logged');
    m.restartGetStarted();
    expectEqual(m.getStartedStep, 'welcome', 'after setup, it starts over');
    expectEqual(emitted, 3);
    expectEqual(model(disk.windowState).model.startingPane(), 'overview', 'the next window opens on Overview');
    const failing = model();
    failing.disk.fail = true;
    expect(/read-only/.test(failing.model.finishSetup()), 'a failed write is reported');
    expect(!failing.model.needsSetup, 'setup still counts as done for this window');
  }],
  ['the steps and their buttons follow the Mac', () => {
    expectEqual(STEPS, ['welcome', 'hyperKey', 'hotstrings', 'slateConfig', 'done']);
    expectEqual(STEPS.map(step => primaryTitle(step)), ['Set Up Slated', 'Continue', 'Continue', 'Continue', 'Start Using Slated']);
    expectEqual(primaryTitle('hotstrings', {hotstringsReady: false}), 'Skip for Now', 'espanso missing: skip, as the Mac skips its permission');
  }],
  ['the Hyper key step counts Hyper shortcuts and recommends keyd', () => {
    const bindings = [{keys: 'hyper+a'}, {keys: 'ctrl+alt+shift+cmd+b'}, {keys: 'ctrl+alt+c'}];
    expectEqual(hyperSubtitle({bindings, sourceBindings: [{keys: 'hyper+d'}], hyperOn: false}),
      '3 of your shortcuts use ✦ (Ctrl+Alt+Shift+Super). Turn this on to press them with Caps Lock.');
    expectEqual(hyperSubtitle({bindings: bindings.slice(1), sourceBindings: [], hyperOn: false}),
      '1 of your shortcuts uses ✦ (Ctrl+Alt+Shift+Super). Turn this on to press it with Caps Lock.');
    expectEqual(hyperSubtitle({bindings, sourceBindings: [], hyperOn: true}), 'You can change this any time under Keyboard.');
    expect(tapSubtitle({running: true, hyper: {mode: 'xkb'}}).startsWith('Needs keyd'));
    expect(tapSubtitle({running: false, hyper: {mode: 'off'}}).endsWith('On GNOME this needs keyd.'));
    const advice = (mode, keydConfigured, running = true) => keydAdvice({running, hyper: {mode, active: true}, keydConfigured});
    expectEqual([advice('keyd', true).level, advice('keyd', true).offerSetup], ['ok', false]);
    expectEqual([advice('xkb', false).title, advice('xkb', false).offerSetup], ['Recommended: keyd', true]);
    expectEqual(advice('xkb', true).title, "keyd is set up but isn't running");
    expectEqual(advice('off', true, false).title, 'keyd is set up');
  }],
  ['the hotstrings step checks espanso', () => {
    const withHotstrings = config({hotstrings: [{trigger: ';s', replacement: 'x'}, {trigger: ';m', replacement: 'y', onlyInApps: ['com.apple.mail']}]});
    const missing = hotstringsStep({config: withHotstrings, status: status(), running: true});
    expectEqual([missing.guidance.level, missing.ready, missing.installLink], ['warning', false, 'https://espanso.org/install/linux/']);
    expectEqual([missing.summary, missing.first], ['1 hotstring to expand · 1 Mac only', ';s']);
    const synced = hotstringsStep({config: withHotstrings, running: true,
      status: status({hotstrings: {engine: 'espanso', espansoInstalled: true, matchFile: null, count: 1}})});
    expectEqual([synced.guidance.level, synced.ready, synced.installLink], ['ok', true, null]);
    const off = hotstringsStep({config: config({general: {hotstringsEnabled: false}}), status: status(), running: true});
    expectEqual([off.guidance.title, off.ready, off.summary], ['Text expansion is turned off', true, 'None yet. Add them under Hotstrings.']);
  }],
  ['the Slate config step works as on the Mac', () => {
    const half = presetById('left-half').action;
    const found = [source({bindings: [{keys: 'hyper+a', action: half}], layouts: [{name: 'Code'}]})];
    expectEqual(slateStep({sources: [source({exists: false})], slateLoading: true, bindings: [{}]}).state, 'none');
    expect(slateStep({sources: [], slateLoading: true, bindings: [{}]}).offerStarter, 'no Slate file: offer the starter set');
    expectEqual(slateStep({sources: found, slateLoading: false, bindings: [{}]}).title, 'Your Slate config is here');
    const loaded = slateStep({sources: found, slateLoading: true, bindings: []});
    expectEqual([loaded.title, loaded.subtitle.startsWith('Slated found 1 binding and'), loaded.offerStarter],
      ['Your Slate config works as-is', true, true]);
    expectEqual([sourceSummary(found[0], true), sourceSummary(found[0], false)], ['1 binding · 1 layout', 'Not loaded']);
    expectEqual(loadedSourceBindings(found, false), []);
    expect(!starterAdded([]) && starterAdded(starterBindings()), 'the starter set is added once its keys are taken');
  }],
  ['the done step says what works and what to try', () => {
    const half = presetById('left-half').action;
    const c = config({keyboard: {capsLock: 'hyper'}, bindings: [{id: '00000000-0000-4000-8000-000000000001', keys: 'hyper+a', name: 'Left Half', action: half}]});
    const running = {running: true, title: "Everything's running", action: null};
    const items = doneChecklist({summary: running, config: c, status: status({hyper: {wanted: true, mode: 'keyd', active: true}}), running: true, totalShortcuts: 1});
    expectEqual(items.map(i => [i.title, i.done, i.detail]), [
      ['Slated is running', true, 'In GNOME Shell'], ['Hyper key', true, 'Caps Lock is ✦ · keyd'],
      ['Hotstrings', false, 'Needs espanso'], ['Shortcuts', true, '1 ready'],
    ]);
    const off = doneChecklist({summary: {running: false, title: 'Slated is turned off', action: 'enable'}, config: config(), status: emptyStatus(), running: false, totalShortcuts: 0});
    expectEqual([off[0].detail, off[0].action, off[1].detail, off[2].detail, off[3].done], ['Slated is turned off', 'enable', 'Off', 'Once Slated runs', false]);
    expectEqual(tryItTip({bindings: c.bindings, sourceBindings: []})?.text, 'to snap this window to the left half');
    const third = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY'};
    expectEqual(tryItTip({bindings: [], sourceBindings: [{keys: 'hyper+f', isFunction: true, probe: () => ({action: third})}]})?.text, 'for left third');
    expectEqual(tryItTip({bindings: [], sourceBindings: [{keys: 'hyper+f', probe: () => ({reason: 'x'})}]}), null);
  }],
]);
