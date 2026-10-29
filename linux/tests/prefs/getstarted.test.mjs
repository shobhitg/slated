import {suite, expect, expectEqual} from './harness.mjs';
import {
  STEPS, parseWindowState, windowStateText, startingPane, primaryTitle, hyperSubtitle, tapSubtitle, keydAdvice,
  hotstringsStep, slateStep, starterAdded, doneChecklist, tryItTip,
} from '../../gnome-extension/lib/prefs/getstarted.js';
import {memoryIO, WINDOW} from './memoryio.mjs';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {emptyStatus} from '../../gnome-extension/lib/prefs/status.js';
import {presetById, starterBindings} from '../../gnome-extension/lib/prefs/presets.js';

const config = (json = {}) => decodeConfiguration(JSON.stringify(json));
const status = (fields = {}) => ({...emptyStatus(), present: true, running: true, ...fields});
const slateFile = (displayPath = '~/.slate.js') => ({path: displayPath, file: `/home/me/${displayPath.slice(2)}`, displayPath, kind: 'javascript'});

/** A model on a first run, with the window state file in memory. */
function model(windowState = null) {
  const files = windowState === null ? {} : {[WINDOW]: windowState};
  const io = memoryIO(files);
  const disk = {
    get windowState() {
      return files[WINDOW] ?? null;
    },
    set fail(on) {
      io.writeWindowState = on ? () => {
        throw new Error('read-only file system');
      } : memoryIO(files).writeWindowState;
    },
  };
  const logged = [];
  const m = new PrefsModel({io, log: (event, data, level) => logged.push({event, data, level})});
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
    expectEqual(hyperSubtitle({bindings, hyperOn: false}),
      '2 of your shortcuts use ✦ (Ctrl+Alt+Shift+Super). Turn this on to press them with Caps Lock.');
    expectEqual(hyperSubtitle({bindings: bindings.slice(1), hyperOn: false}),
      '1 of your shortcuts uses ✦ (Ctrl+Alt+Shift+Super). Turn this on to press it with Caps Lock.');
    expectEqual(hyperSubtitle({bindings, hyperOn: true}), 'You can change this any time under Keyboard.');
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
  ['the Slate config step says what was imported, or offers the import', () => {
    const none = slateStep({record: null, slateFiles: [], bindings: [{}]});
    expectEqual([none.state, none.offerImport, none.offerStarter], ['none', false, true], 'no Slate file: offer the starter set');
    const found = slateStep({record: null, slateFiles: [slateFile()], bindings: [{}]});
    expectEqual([found.state, found.title, found.offerImport, found.offerStarter], ['found', 'Your Slate config is here', true, false]);
    expect(found.subtitle.includes('~/.slate.js') && found.subtitle.includes("doesn't read Slate files"), found.subtitle);
    expect(slateStep({record: null, slateFiles: [slateFile()], bindings: []}).offerStarter, 'no shortcuts of its own: the starter set too');
    const record = {kind: 'first-run', slate: {files: ['~/.slate.js'], imported: 20, skipped: 1,
      unconvertible: [{keys: 'hyper+x', modal: null, reason: 'runs several operations at once, which needs the script'}]}};
    const imported = slateStep({record, slateFiles: [slateFile()], bindings: [{}]});
    expectEqual([imported.state, imported.title, imported.offerImport], ['imported', 'Your Slate shortcuts are in Slated', false]);
    expectEqual(imported.subtitle, "Slated imported 20 shortcuts from ~/.slate.js. 1 shortcut Slated already had was left alone. "
      + "1 couldn't be converted: ✦ X. Edit them under Windows. Slated doesn't read Slate files any more.");
    const here = slateStep({record: null, slateFiles: [slateFile()], importedHere: true, bindings: [{}]});
    expectEqual([here.state, here.offerImport], ['imported', true], 'imported in this window: it can be run again');
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
    expectEqual(tryItTip({bindings: c.bindings})?.text, 'to snap this window to the left half');
    expectEqual(tryItTip({bindings: []}), null);
  }],
]);
