import {suite, expect, expectEqual} from './harness.mjs';
import {
  parseStatus, emptyStatus, hotkeyState, hotkeyCounts, extensionState, runningSummary, bindingState, statePresentation,
  stateExplanation,
} from '../../gnome-extension/lib/prefs/status.js';
import {
  SAMPLE_SCREENS, sampleFrame, previews, place, screenMap, screenAt, describeFrame, layoutPlacements, orderedLeftToRight,
} from '../../gnome-extension/lib/prefs/placement.js';
import {implemented} from '../../gnome-extension/lib/prefs/engine.js';
import {presetById, defaultChain} from '../../gnome-extension/lib/prefs/presets.js';
import {slatedPaths} from '../../gnome-extension/lib/prefs/paths.js';

const paths = slatedPaths('/home/me', () => null);

/** The exact example from the status.json contract. */
const EXAMPLE = JSON.stringify({
  session: 'abcd1234', version: '0.1.0', running: true, updatedAt: '2026-10-22T18:00:00.000Z',
  hyper: {wanted: true, mode: 'xkb', active: true},
  hotstrings: {engine: 'espanso', espansoInstalled: true, matchFile: '/home/me/.config/espanso/match/slated.yml', count: 3},
  hotkeys: {'hyper+a': 'active', 'hyper+q': 'failed: already used by GNOME', 'hyper+w': 'duplicate', 'hyper+z': 'disabled'},
  sources: [{path: '~/.slate.js', kind: 'javascript', exists: true, loaded: true, bindings: 21, diagnostics: ['line 3: oops']}],
  lastAction: 'Left half · firefox', lastError: null,
});

const shellActive = extensionState({state: 1, error: ''});

export default suite('Status and placement', [
  ['parses status.json as specified', () => {
    const s = parseStatus(EXAMPLE);
    expect(s.present && s.running && !s.error);
    expectEqual(s.session, 'abcd1234');
    expectEqual(s.updatedAt.toISOString(), '2026-10-22T18:00:00.000Z');
    expectEqual(s.hyper, {wanted: true, mode: 'xkb', active: true});
    expectEqual(s.hotstrings.count, 3);
    expectEqual(s.hotkeys['hyper+q'], {state: 'failed', reason: 'already used by GNOME'});
    expectEqual(s.sources[0], {path: '~/.slate.js', kind: 'javascript', exists: true, loaded: true, bindings: 21, diagnostics: ['line 3: oops']});
    expectEqual(s.lastAction, 'Left half · firefox');
    expectEqual(s.screens, null);
    expectEqual(hotkeyCounts(s), {active: 1, failed: 1, duplicate: 1, disabled: 1, unknown: 0});
    // Fields an older extension doesn't write yet come back empty.
    expectEqual(s.automation, {running: [], shortcuts: [], stopShortcut: null, whileHeld: 'key-repeat'});
    expectEqual(s.clipboard, {enabled: false, items: 0});
    expectEqual(s.recentApps, []);
  }],
  ['parses automation, the clipboard and recent apps', () => {
    const s = parseStatus(JSON.stringify({
      ...JSON.parse(EXAMPLE),
      automation: {running: ['Repeat click left every 100 ms', 7], shortcuts: ['f6'], stopShortcut: 'hyper+esc', whileHeld: 'toggle'},
      clipboard: {enabled: true, items: 12.4},
      recentApps: [{id: 'steam_app_1', name: 'steam_app_1'}, {id: 'firefox'}, {name: 'no id'}, 'nonsense'],
    }));
    expectEqual(s.automation, {running: ['Repeat click left every 100 ms'], shortcuts: ['f6'], stopShortcut: 'hyper+esc', whileHeld: 'toggle'});
    expectEqual(s.clipboard, {enabled: true, items: 12});
    expectEqual(s.recentApps, [{id: 'steam_app_1', name: 'steam_app_1'}, {id: 'firefox', name: 'firefox'}]);
  }],
  ['a saved binding is up to date whatever order its fields are in', () => {
    const saved = {action: {op: 'undo'}, enabled: true, id: 'x', keys: 'hyper+u'};
    const made = {id: 'x', keys: 'hyper+u', action: {op: 'undo'}, enabled: true};
    const status = parseStatus(JSON.stringify({running: true, hotkeys: {'hyper+u': 'active'}}));
    expectEqual(bindingState({binding: made, key: 'hyper+u', saved, status, running: true}), {state: 'active'});
  }],
  ['tolerates missing, broken and odd status files', () => {
    expectEqual(parseStatus(null), emptyStatus());
    expect(parseStatus('{oops').error.startsWith("status.json isn't valid JSON"));
    expectEqual(parseStatus('[]').error, 'status.json must contain a JSON object');
    const odd = parseStatus(JSON.stringify({running: 'yes', hyper: {mode: 'magic'}, hotkeys: {a: 'failed'}, screens: [{frame: {x: 0, y: 0, width: 10, height: 10}}, {nope: 1}]}));
    expectEqual(odd.running, false);
    expectEqual(odd.hyper.mode, 'off');
    expectEqual(odd.hotkeys.a, {state: 'failed', reason: 'GNOME refused the shortcut.'});
    expectEqual(odd.screens.length, 1);
    expectEqual(odd.screens[0].visibleFrame, {x: 0, y: 0, width: 10, height: 10});
    expectEqual(hotkeyState('weird'), {state: 'unknown', reason: null});
  }],
  ['interprets GNOME Shell extension states', () => {
    expectEqual(extensionState(null).reachable, false);
    expectEqual(extensionState({}), {known: false, reachable: true, state: 'unknown', error: null, enabled: null});
    expectEqual(extensionState({state: 3, error: 'SyntaxError'}).state, 'error');
    expectEqual(extensionState({state: 2}).state, 'inactive');
    expectEqual(extensionState({state: 6}).state, 'initialized');
  }],
  ['the Overview headline covers every situation', () => {
    const status = parseStatus(EXAMPLE);
    const none = emptyStatus();
    expectEqual(runningSummary({status: none, shell: extensionState({})}).action, 'relogin');
    expectEqual(runningSummary({status: none, shell: extensionState({state: 3, error: 'boom'})}).title, 'Slated stopped with an error');
    expectEqual(runningSummary({status: none, shell: extensionState({state: 2})}).action, 'enable');
    expectEqual(runningSummary({status: none, shell: extensionState({state: 6})}).action, 'relogin');
    expectEqual(runningSummary({status: none, shell: extensionState(null)}).title, "Slated isn't running");
    expectEqual(runningSummary({status: none, shell: shellActive}).title, 'Slated is starting…');
    expectEqual(runningSummary({status: {...status, running: false}, shell: shellActive}).running, false);
    const update = runningSummary({status, shell: shellActive, build: {commit: 'bbb'}, runningCommit: 'aaa'});
    expectEqual([update.title, update.action, update.running], ['A newer build is installed', 'relogin', true]);
    const review = runningSummary({status, shell: shellActive, build: {commit: 'aaa'}, runningCommit: 'aaa'});
    expectEqual([review.level, review.detail], ['warning', '1 duplicate shortcut and 1 that GNOME refused']);
    const clean = parseStatus(JSON.stringify({running: true, hotkeys: {'hyper+a': 'active'}}));
    expectEqual(runningSummary({status: clean, shell: shellActive}).level, 'ok');
  }],
  ['binding states and their presentation', () => {
    const status = parseStatus(EXAMPLE);
    const binding = {id: '1', keys: 'hyper+q', action: {op: 'undo'}, enabled: true};
    const base = {binding, key: 'hyper+q', saved: binding, issues: [], status, running: true};
    expectEqual(bindingState(base), {state: 'failed', reason: 'already used by GNOME'});
    expectEqual(bindingState({...base, key: 'hyper+a'}).state, 'active');
    expectEqual(bindingState({...base, key: 'hyper+x'}).state, 'inactive');
    expectEqual(bindingState({...base, running: false}).state, 'not-running');
    expectEqual(bindingState({...base, binding: {...binding, keys: ''}, saved: undefined}).state, 'new');
    expectEqual(bindingState({...base, binding: {...binding, enabled: false}}).state, 'disabled');
    expectEqual(bindingState({...base, issues: [{severity: 'error', message: 'Bad.'}]}), {state: 'not-saved', message: 'Bad.', wasSaved: true});
    expectEqual(bindingState({...base, saved: {...binding, keys: 'hyper+w'}}).state, 'saving');
    expectEqual(bindingState({binding, key: 'hyper+w', status, running: true, isSource: true}).state, 'duplicate');
    expectEqual(bindingState({binding, key: 'hyper+w', status, running: true, isSource: true, slateLoading: false}).state, 'slate-off');
    // Imported while the file keeps loading: Slated's copy runs, this one is ignored.
    expectEqual(bindingState({binding, key: 'hyper+w', status, running: true, isSource: true, imported: true}).state, 'imported');
    expectEqual(statePresentation({state: 'imported'}).label, 'Imported');
    expect(stateExplanation({state: 'imported'}).includes('ignores this copy'));
    expectEqual(statePresentation({state: 'failed'}).row, "Couldn't register");
    expect(stateExplanation({state: 'not-saved', message: 'Bad.', wasSaved: true}).includes('last saved version'));
    expectEqual(stateExplanation({state: 'active'}), null);
  }],
  ['the sample window and preview math', () => {
    expectEqual(sampleFrame(SAMPLE_SCREENS), {x: 480, y: 242, width: 960, height: 629});
    expectEqual(sampleFrame(SAMPLE_SCREENS, SAMPLE_SCREENS[1]), {x: 2190, y: 384, width: 540, height: 1152});
    expectEqual(orderedLeftToRight([SAMPLE_SCREENS[1], SAMPLE_SCREENS[0]]).map(s => s.displayID), [1, 2]);
    const map = screenMap(SAMPLE_SCREENS, 316, 216, {padding: 8, labelHeight: 0});
    const canvas = map.toCanvas({x: 0, y: 0, width: 3000, height: 1920});
    expect(Math.abs(canvas.width - 300) < 0.01 || Math.abs(canvas.height - 200) < 0.01, 'fills the limiting dimension');
    const back = map.fromCanvas(canvas.x + 1, canvas.y + 1);
    expectEqual(screenAt(SAMPLE_SCREENS, back), 0);
    expectEqual(screenAt(SAMPLE_SCREENS, {x: 2500, y: 1500}), 1);
    expectEqual(screenAt(SAMPLE_SCREENS, {x: 100, y: 1500}), -1);
    expectEqual(describeFrame({x: 0.4, y: 32, width: 959.6, height: 1048}), '960 × 1048 at 0, 32');
  }],
  ['previews place windows with the engine, or say why they cannot', () => {
    expect(previews(presetById('left-half').action) && previews({op: 'chain', operations: []}));
    expect(!previews({op: 'undo'}) && !previews({op: 'focus', app: 'x'}));
    expectEqual(place({op: 'undo'}, {screens: []}), null);
    expectEqual(place({op: 'chain', operations: []}, {screens: SAMPLE_SCREENS}).state.kind, 'nothing');
    expectEqual(place({op: 'sequence', operations: [{op: 'undo'}]}, {screens: SAMPLE_SCREENS}).state.message,
      'None of these steps move the window.');
    expectEqual(place({op: 'hint'}, {screens: SAMPLE_SCREENS}).state.kind, 'nothing');
    const half = place(presetById('left-half').action, {screens: SAMPLE_SCREENS});
    if (implemented('targetFrame')) {
      expectEqual(half.state, {kind: 'placed', frame: {x: 0, y: 32, width: 960, height: 1048}});
      const portrait = place({op: 'by-orientation', landscape: presetById('left-third').action, portrait: presetById('top-half').action},
        {screens: SAMPLE_SCREENS, startScreen: 1});
      expectEqual(portrait.state.frame, {x: 1920, y: 0, width: 1080, height: 960});
      const third = place({op: 'chain', operations: defaultChain()}, {screens: SAMPLE_SCREENS, step: 4});
      expectEqual(third.state.frame, {x: 0, y: 32, width: 640, height: 1048});
    } else {
      expectEqual(half.state, {kind: 'unavailable', reason: null}, 'quiet "Preview unavailable" while the engine is a stub');
    }
    const layout = layoutPlacements({apps: [{app: 'Files', operations: [presetById('left-half').action]}, {app: 'X', operations: []}]},
      {screens: SAMPLE_SCREENS});
    expectEqual(layout.windows.length, implemented('targetFrame') ? 1 : 0);
  }],
  ['paths follow the XDG base directories', () => {
    expectEqual(paths.configFile, '/home/me/.config/slated/config.json');
    expectEqual(paths.statusFile, '/home/me/.local/state/slated/status.json');
    expectEqual(paths.logFile, '/home/me/.local/state/slated/slated.log');
    // The settings window's own state (Get Started finished), next to status.json: not shared with the Mac.
    expectEqual(paths.settingsWindowFile, '/home/me/.local/state/slated/settings-window.json');
    const custom = slatedPaths('/home/me/', name => ({XDG_CONFIG_HOME: '/cfg/', XDG_STATE_HOME: 'relative/ignored'})[name] ?? null);
    expectEqual([custom.configFile, custom.stateDir], ['/cfg/slated/config.json', '/home/me/.local/state/slated']);
    // Like the extension and the macOS app: SLATED_HOME replaces the home (XDG variables belong to the real one).
    const env = {SLATED_HOME: '/tmp/test-home/', XDG_CONFIG_HOME: '/cfg', XDG_STATE_HOME: '/state'};
    const test = slatedPaths('/home/me', name => env[name] ?? null);
    expectEqual([test.home, test.configFile, test.logFile],
      ['/tmp/test-home', '/tmp/test-home/.config/slated/config.json', '/tmp/test-home/.local/state/slated/slated.log']);
    const config = slatedPaths('/home/me', name => ({SLATED_CONFIG: '/elsewhere/slated.json'})[name] ?? null);
    expectEqual([config.configFile, config.configDir, config.statusFile],
      ['/elsewhere/slated.json', '/elsewhere', '/home/me/.local/state/slated/status.json']);
    // The keyd configuration linux/install.sh --hyper-keyd writes, moved by the same variable as there.
    expectEqual(paths.keydConfig, '/etc/keyd/slated.conf');
    expectEqual(slatedPaths('/home/me', name => ({SLATED_KEYD_CONF: '/tmp/keyd/slated.conf'})[name] ?? null).keydConfig, '/tmp/keyd/slated.conf');
  }],
]);
