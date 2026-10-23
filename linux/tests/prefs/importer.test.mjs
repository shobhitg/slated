import {suite, expect, expectEqual, readText} from './harness.mjs';
import {
  loadSlateScript, importSlateScript, planImport, parseKeystrokeLocal, keystrokeToConfig,
} from '../../gnome-extension/lib/prefs/importer.js';
import {implemented, starterConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {matchingPreset} from '../../gnome-extension/lib/prefs/presets.js';
import {fillDefaults} from '../../gnome-extension/lib/prefs/config.js';
import {keysString} from '../../gnome-extension/lib/prefs/keys.js';

const author = await readText('./fixtures/slate-author-like.js', import.meta.url);
const edges = await readText('./fixtures/slate-edge-cases.js', import.meta.url);
const surface = await readText('./fixtures/slate-api-surface.js', import.meta.url);
const EXTRA = '// sourced by slate-api-surface.js\nS.bnd("2:ctrl,alt", {"op": "undo"});\nslate.source("~/.slate.extra.js"); // MARK:loop\n';

const move = (x, y, width, height) => ({op: 'move', x, y, width, height});
const X = 'screenOriginX';
const Y = 'screenOriginY';
const W = 'screenSizeX';
const H = 'screenSizeY';

function ids() {
  let n = 0;
  return () => `id-${n++}`;
}

/** The line of the fixture that contains `MARK:<name>`. */
function markLine(text, name) {
  return text.split('\n').findIndex(line => line.includes(`MARK:${name}`)) + 1;
}

/** keys → action, keeping the first binding for keys bound twice (as the import plan does). */
const byKeys = bindings => Object.fromEntries([...bindings].reverse().map(b => [b.keys, b.action]));

export default suite('Slate importer', [
  ['parses Slate keystrokes like SlateSyntax.parseKeystroke', () => {
    expectEqual(parseKeystrokeLocal('a:ctrl,shift,alt,cmd'), {keys: {key: 'a', modifiers: ['ctrl', 'alt', 'shift', 'cmd']}, modal: null});
    expectEqual(parseKeystrokeLocal("':ctrl,shift,alt,cmd").keys.key, "'");
    expectEqual(parseKeystrokeLocal('left:ctrl;cmd').keys, {key: 'left', modifiers: ['ctrl', 'cmd']});
    expectEqual(parseKeystrokeLocal('1:f4,ctrl,alt'), {keys: {key: '1', modifiers: []}, modal: {keys: {key: 'f4', modifiers: ['ctrl', 'alt']}, toggle: false}});
    expectEqual(parseKeystrokeLocal('1:ctrl,f4:toggle').modal.toggle, true);
    expectEqual(keystrokeToConfig('return:ctrl,shift,alt,cmd'), {keys: 'hyper+return', modal: null});
    expectEqual(keystrokeToConfig('m:f6,ctrl,alt'), {keys: 'm', modal: {keys: 'ctrl+alt+f6', toggle: false}});
    let threw = false;
    try {
      parseKeystrokeLocal('a:ctrl:toggle');
    } catch {
      threw = true;
    }
    expect(threw, ':toggle needs a modal key');
  }],
  ['loads the author-like config: 21 Hyper bindings, all JavaScript functions', () => {
    const loaded = loadSlateScript(author, {path: '/home/me/.slate.js'});
    expectEqual(loaded.diagnostics, []);
    expectEqual(loaded.bindings.length, 21);
    expect(loaded.bindings.every(b => b.action === null && b.summary === 'JavaScript function'));
    expect(loaded.bindings.every(b => b.keys.startsWith('hyper+')));
    expectEqual(loaded.bindings[0].keys, "hyper+'");
  }],
  ['probes functions on a landscape and a portrait screen', () => {
    const result = importSlateScript(author, {makeId: ids()});
    const actions = byKeys(result.bindings);
    expectEqual(actions['hyper+a'], move(X, Y, `${W}/2`, H));
    expectEqual(matchingPreset(actions['hyper+a']).id, 'left-half');
    expectEqual(actions['hyper+x'], {op: 'push', direction: 'down', style: `bar-resize:${H}/2`});
    expectEqual(matchingPreset(actions['hyper+x']).id, 'bottom-half');
    expectEqual(actions['hyper+q'], {op: 'corner', direction: 'top-left', width: `${W}/2`, height: `${H}/2`});
    expectEqual(actions['hyper+f'], {op: 'by-orientation', landscape: move(X, Y, `${W}/3`, H), portrait: move(X, Y, W, `${H}/3`)});
    expectEqual(actions['hyper+b'], {op: 'by-orientation', landscape: move(`${X}+${W}*1/3`, Y, `${W}*2/3`, H),
      portrait: move(X, `${Y}+${H}*1/3`, W, `${H}*2/3`)});
    expectEqual(actions['hyper+return'], move(`${X}+${W}/8`, `${Y}+${H}/8`, `${W}/1.3`, `${H}/1.3`));
    expectEqual(result.diagnostics, []);
  }],
  ['bindings built from Slate syntax convert once the engine parses it', () => {
    const result = importSlateScript(author, {makeId: ids()});
    const syntaxKeys = ['hyper+w', 'hyper+tab', 'hyper+right', 'hyper+left', 'hyper+up', 'hyper+down'];
    if (implemented('parseOperation')) {
      expectEqual(result.skipped, []);
      const actions = byKeys(result.bindings);
      expectEqual(actions['hyper+w'], {op: 'push', direction: 'up', style: `bar-resize:${H}/2`});
      expectEqual(actions['hyper+left'], {op: 'throw', screen: 'left', width: W, height: H});
      expectEqual(actions['hyper+down'], {op: 'throw', screen: '1', width: W, height: H});
      expectEqual(actions['hyper+tab'], {op: 'grid', padding: 4, grids: {0: {width: 6, height: 6}, 1: {width: 6, height: 6}, 2: {width: 6, height: 6}}});
    } else {
      expectEqual(result.skipped.map(s => keysString(keystrokeToConfig(s.keystroke).keys)).sort(), [...syntaxKeys].sort());
      expect(result.skipped.every(s => s.reason.includes('newer Slated engine')), result.skipped.map(s => s.reason).join('; '));
      expectEqual(result.bindings.length, 15);
    }
  }],
  ['the author-like config imports into exactly the starter bindings (when the engine has them)', () => {
    if (!implemented('parseOperation') || !starterConfiguration()) return;
    const starter = starterConfiguration();
    const result = importSlateScript(author, {makeId: ids()});
    expectEqual(byKeys(result.bindings), Object.fromEntries(starter.bindings.map(b => [keysString(b.keys), b.action])));
  }],
  ['edge cases: aliases, bindAll, dynamic parameters, modal keys, layouts and settings', () => {
    const loaded = loadSlateScript(edges, {path: '/home/me/.slate.js'});
    const keys = loaded.bindings.map(b => b.keys);
    expect(keys.includes('ctrl+alt+1') && keys.includes('shift+cmd+k') && keys.includes('shift+cmd+l'), keys.join(' '));
    expectEqual(loaded.bindings.find(b => b.keys === 'ctrl+alt+2').repeats, true);
    expectEqual(loaded.bindings.find(b => b.keys === 'm').modal, {keys: 'ctrl+alt+f6', toggle: false});
    expectEqual(loaded.bindings.find(b => b.keys === 'n').modal, {keys: 'ctrl+alt+f6', toggle: true});
    expectEqual(loaded.bindings.find(b => b.keys === 'ctrl+cmd+space').action,
      {op: 'corner', direction: 'top-left', width: W, height: H});
    expectEqual(loaded.settings, {
      defaultToCurrentScreen: true, secondsBetweenRepeat: 0.1, orderScreensLeftToRight: true,
      nudgePercentOf: 'screenSize', windowHintsIgnoreHiddenWindows: 'a;b',
    });
    const coding = loaded.layouts.find(l => l.name === 'coding');
    expectEqual(coding.before, [{op: 'hide', app: 'all-but:Terminal'}]);
    expectEqual(coding.apps.map(a => a.app), ['Firefox', 'Terminal']);
    expectEqual(coding.apps[0].options.ignoreFail && coding.apps[0].options.repeat, true);
    expectEqual(coding.apps[1].options.titleOrder, ['one', 'two']);
    expectEqual(loaded.defaults, [{target: 'coding', condition: {count: {_0: 2}}}]);
  }],
  ['edge cases: mistakes are reported with their lines and the rest still loads', () => {
    const loaded = loadSlateScript(edges, {path: '/home/me/.slate.js'});
    const at = name => loaded.diagnostics.filter(d => d.line === markLine(edges, name));
    expectEqual(at('unknown-op').map(d => [d.severity, d.message]), [['error', 'Unknown operation "teleport".']]);
    expect(at('invalid-op').some(d => d.severity === 'error' && d.message.startsWith('Invalid "push" operation')),
      JSON.stringify(loaded.diagnostics));
    expectEqual(at('unknown-param').map(d => d.message), ['"move" has no parameter "depth", so it was ignored.']);
    expect(at('duplicate').some(d => d.severity === 'warning' && d.message.startsWith('"1:ctrl,alt" is bound more than once')));
    expect(loaded.bindings.some(b => b.keys === 'ctrl+cmd+space'), 'bindings after the mistakes still load');
  }],
  ['edge cases: what imports and what needs the script', () => {
    const result = importSlateScript(edges, {makeId: ids()});
    const actions = byKeys(result.bindings);
    const reasons = Object.fromEntries(result.skipped.map(s => [s.keystroke, s.reason]));
    const left = {op: 'push', direction: 'left', style: `bar-resize:${W}/2`};
    const right = {op: 'push', direction: 'right', style: `bar-resize:${W}/2`};
    const full = {op: 'corner', direction: 'top-left', width: W, height: H};
    expectEqual(actions['ctrl+alt+1'], left, 'static operation');
    expectEqual(actions['ctrl+alt+3'], {op: 'chain', operations: [left, right]}, 'static chain');
    expectEqual(actions['ctrl+alt+4'], {op: 'nudge', x: '+10%', y: '0'}, 'object with op');
    expectEqual(actions['ctrl+alt+5'], {op: 'sequence', steps: [
      {action: left, keepWindow: false}, {action: full, keepWindow: true}, {action: right, keepWindow: false}]}, 'sequence with > groups');
    expectEqual(actions['ctrl+alt+6'], {op: 'by-orientation', landscape: move(X, Y, `${W}/3`, H), portrait: move(X, Y, `${W}/2`, H)},
      'function parameters are evaluated per screen');
    expectEqual(actions['ctrl+f2'], {op: 'focus', direction: 'left'});
    expectEqual(actions['ctrl+f3'], full);
    expectEqual(actions['ctrl+f4'], {op: 'by-orientation', landscape: left, portrait: right}, 'S.window().screen() picks the branch');
    expect(reasons['7:ctrl,alt'].includes('win.move'), reasons['7:ctrl,alt']);
    expect(reasons['8:ctrl,alt'].includes('several operations'), reasons['8:ctrl,alt']);
    expect(reasons['9:ctrl,alt'].includes("doesn't run an operation"), reasons['9:ctrl,alt']);
    expect(reasons['0:ctrl,alt'].includes('boom'), reasons['0:ctrl,alt']);
    expect(reasons['f1:ctrl'].includes('slate.shell'), reasons['f1:ctrl']);
    expect(reasons['layout "scripted"'].includes('JavaScript'));
    expectEqual(result.layouts.map(l => l.name), ['coding']);
    expectEqual(result.defaults, [], 'display defaults stay in the script, as on macOS');
  }],
  ['the fake slate API answers window, screen, app and underscore queries like Slate', () => {
    const files = {'/home/me/.slate.extra.js': EXTRA};
    const loaded = loadSlateScript(surface, {path: '/home/me/.slate.js', home: '/home/me', readFile: p => files[p] ?? null});
    const probe = loaded.probe(loaded.bindings[0]);
    expectEqual(probe.reason, undefined, `the probe ran cleanly: ${probe.reason}`);
    expectEqual(probe.action, {op: 'by-orientation', landscape: move(X, Y, `${W}/3`, H), portrait: move(X, Y, `${W}/2`, H)});
  }],
  ['loading-time side effects are reported, and slate.source reads other files', () => {
    const files = {'/home/me/.slate.extra.js': EXTRA};
    const loaded = loadSlateScript(surface, {path: '/home/me/.slate.js', home: '/home/me', readFile: p => files[p] ?? null});
    const messageAt = (text, name) => loaded.diagnostics.filter(d => d.line === markLine(text, name)).map(d => d.message);
    expect(messageAt(surface, 'shell').some(m => m.includes('slate.shell')), JSON.stringify(loaded.diagnostics));
    expect(messageAt(surface, 'doop').some(m => m.startsWith('Operations only run when a shortcut is pressed')));
    expect(messageAt(surface, 'missing').some(m => m.startsWith("Couldn't read missing.js")));
    expect(loaded.diagnostics.some(d => d.severity === 'error' && d.message.includes('already loading')), 'a file sourcing itself is stopped');
    expect(loaded.bindings.some(b => b.keys === 'ctrl+alt+2'), 'bindings from the sourced file are loaded');
  }],
  ['the import plan skips keys Slated already uses and keeps Slate loading when something was skipped', () => {
    const config = fillDefaults({
      bindings: [{id: 'mine', keys: 'ctrl+alt+1', action: {op: 'undo'}}],
      settings: {orderScreensLeftToRight: false},
    });
    const result = importSlateScript(edges, {makeId: ids()});
    const plan = planImport(config, [{path: '~/.slate.js', result}]);
    expect(plan.duplicates.includes('ctrl+alt+1'), 'existing keys win');
    expectEqual(plan.config.bindings[0].id, 'mine');
    expectEqual(plan.config.settings.orderScreensLeftToRight, false, "config.json's settings win");
    expectEqual(plan.config.settings.nudgePercentOf, 'screenSize', 'script settings fill the gaps');
    expectEqual(plan.config.layouts.map(l => l.name), ['coding']);
    expect(!plan.stopsLoading && plan.config.general.loadSlateConfigs, 'something was skipped: keep loading the script');
    const clean = planImport(fillDefaults({}), [{path: '~/.slate.js', result: {...result, skipped: []}}]);
    expect(clean.stopsLoading && clean.config.general.loadSlateConfigs === false, 'everything converted: stop loading');
  }],
]);
