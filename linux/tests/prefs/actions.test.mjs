import {suite, expect, expectEqual} from './harness.mjs';
import {
  PRESETS, PRESET_GROUPS, ORIENTATION_PRESETS, presetById, matchingPreset, starterBindings, defaultChain, defaultSequence,
} from '../../gnome-extension/lib/prefs/presets.js';
import {
  KINDS, CATEGORIES, kindOf, kindById, formFromAction, actionFromForm, convertAction, updateAction, actionTitle,
  actionDetail, localDetail, bindingTitle, bindingSubtitle, isWindowGeometry, screenName, appsPhrase, isAutomation,
  containsAutomation, containsWindowGeometry, isInputStep, INPUT_STEPS, defaultForm,
} from '../../gnome-extension/lib/prefs/actions.js';
import {actionProblems} from '../../gnome-extension/lib/prefs/validator.js';
import {canonicalActionLocal} from '../../gnome-extension/lib/prefs/canonical.js';
import {canonicalAction, implemented} from '../../gnome-extension/lib/prefs/engine.js';

const half = () => JSON.parse(JSON.stringify(presetById('left-half').action));

/** One example of every kind, in canonical form. */
const EXAMPLES = {
  move: {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/3', height: 'screenSizeY', screen: 'next'},
  resize: {op: 'resize', width: '+10%', height: '-5%', anchor: 'bottom-right'},
  push: {op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/3', screen: '1'},
  nudge: {op: 'nudge', x: '+10', y: '-10'},
  throw: {op: 'throw', screen: 'left', width: 'screenSizeX', height: 'screenSizeY'},
  corner: {op: 'corner', direction: 'bottom-left', width: 'screenSizeX/2', height: 'screenSizeY/2'},
  chain: {op: 'chain', operations: [{op: 'undo'}, {op: 'relaunch'}]},
  sequence: {op: 'sequence', steps: [{action: {op: 'undo'}, keepWindow: false}, {action: {op: 'relaunch'}, keepWindow: true}]},
  layout: {op: 'layout', name: 'Coding'},
  'by-orientation': {op: 'by-orientation', landscape: {op: 'push', direction: 'left'}, portrait: {op: 'push', direction: 'up'}},
  focus: {op: 'focus', direction: 'behind'},
  'focus-app': {op: 'focus', app: 'Firefox'},
  hint: {op: 'hint', characters: 'asdf'},
  grid: {op: 'grid', padding: 4, grids: {0: {width: 6, height: 6}}},
  hide: {op: 'hide', app: 'all-but:Terminal'},
  show: {op: 'show', app: ['Firefox', 'Files']},
  toggle: {op: 'toggle', app: 'current'},
  switch: {op: 'switch'},
  snapshot: {op: 'snapshot', name: 'work', save: true, stack: true},
  'activate-snapshot': {op: 'activate-snapshot', name: 'work', delete: true},
  'delete-snapshot': {op: 'delete-snapshot', name: 'work', all: true},
  undo: {op: 'undo'},
  'insert-text': {op: 'insert-text', text: 'Hello\nworld', method: 'paste'},
  keystroke: {op: 'keystroke', keys: 'ctrl+shift+t'},
  'open-url': {op: 'open-url', url: 'https://example.com/a?b'},
  shell: {op: 'shell', command: 'notify-send hi', wait: true, path: '~/src'},
  relaunch: {op: 'relaunch'},
  'clipboard-history': {op: 'clipboard-history'},
  click: {op: 'click', button: 'right', count: 2},
  press: {op: 'press', input: 'key:w', phase: 'up'},
  hold: {op: 'hold', input: 'mouse:left'},
  repeat: {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05, mode: 'while-held', times: 20, jitter: 0.15},
  wait: {op: 'wait', seconds: 1.5},
  'stop-automations': {op: 'stop-automations'},
};

/** Kinds the engine writes differently from the editor's local forms (none: every example is canonical). */
const ENGINE_CANONICAL = Object.keys(EXAMPLES);

export default suite('Presets and actions', [
  ['presets mirror the macOS set', () => {
    expectEqual(PRESETS.length, 20);
    expectEqual(new Set(PRESETS.map(p => p.id)).size, 20, 'ids are unique');
    expectEqual(PRESET_GROUPS.map(g => g.id), ['halves', 'quarters', 'thirds', 'center', 'screens']);
    for (const p of PRESETS) {
      expectEqual(canonicalActionLocal(p.action), p.action, `${p.id} is canonical`);
      for (const alias of p.aliases) expectEqual(canonicalActionLocal(alias), alias, `${p.id} alias is canonical`);
      expect(p.region !== null || p.icon !== null, `${p.id} has a glyph`);
      expectEqual(matchingPreset(p.action)?.id, p.id, `${p.id} matches itself`);
    }
  }],
  ['presets recognize other spellings of the same placement', () => {
    expectEqual(matchingPreset({op: 'push', direction: 'left', style: 'bar-resize:screenSizeX/2'})?.id, 'left-half');
    expectEqual(matchingPreset({op: 'push', direction: 'top', style: 'bar-resize:screenSizeY/2'})?.id, 'top-half');
    expectEqual(matchingPreset({op: 'push', direction: 'bottom', style: 'bar-resize:screenSizeY/2'})?.id, 'bottom-half');
    expectEqual(matchingPreset({op: 'corner', direction: 'top-left', width: 'screenSizeX', height: 'screenSizeY'})?.id, 'maximize');
    expectEqual(matchingPreset({op: 'throw', screen: 'next'})?.id, 'throw-next');
    expectEqual(matchingPreset({op: 'move', x: '0', y: '0', width: '10', height: '10'}), null);
    expectEqual(matchingPreset('undo'), null);
  }],
  ['starter bindings, default chain and sequence', () => {
    let n = 0;
    const starter = starterBindings(() => `id${n++}`);
    expectEqual(starter.map(b => b.keys), ['hyper+left', 'hyper+right', 'hyper+up', 'hyper+down', 'hyper+return', 'hyper+c', 'hyper+n', 'hyper+z']);
    expectEqual(starter.map(b => b.name), ['Left Half', 'Right Half', 'Top Half', 'Bottom Half', 'Maximize', 'Center', 'Next Display', 'Undo']);
    expectEqual(new Set(starter.map(b => b.id)).size, 8);
    expectEqual(defaultChain().map(a => matchingPreset(a).id), ['left-half', 'left-third', 'left-two-thirds']);
    expectEqual(defaultSequence().map(a => matchingPreset(a).id), ['throw-next', 'maximize']);
    expectEqual(presetById('maximize').title, 'Maximize');
  }],
  ['every action kind has an entry in the picker', () => {
    expectEqual(KINDS.length, 34);
    expectEqual(CATEGORIES.map(c => c.title), ['Window', 'Combine', 'Focus', 'Apps', 'Snapshots', 'Utilities', 'Mouse & Keys']);
    expectEqual(KINDS.filter(k => k.category === 'input').map(k => k.id), ['click', 'press', 'hold', 'repeat', 'wait', 'stop-automations']);
    for (const k of KINDS) {
      expect(CATEGORIES.some(c => c.id === k.category), `${k.id} has a category`);
      expect(k.icon.endsWith('-symbolic') && k.title && k.explanation, `${k.id} is described`);
    }
    for (const [id, action] of Object.entries(EXAMPLES)) expectEqual(kindOf(action), id, id);
    expectEqual(Object.keys(EXAMPLES).length, KINDS.length, 'the examples cover every kind');
    expectEqual(kindOf('push left'), 'syntax');
    expectEqual(kindOf({op: 'teleport'}), 'unknown');
    expectEqual(kindById('syntax').title, 'Slate Operation');
  }],
  ['forms round-trip every kind', () => {
    for (const [id, action] of Object.entries(EXAMPLES)) {
      expectEqual(actionFromForm(formFromAction(action)), action, id);
    }
    // The examples are what the engine (Swift's Codable) writes, key order included, so an edited
    // binding compares equal to the saved one.
    for (const id of ENGINE_CANONICAL) {
      expectEqual(JSON.stringify(canonicalAction(EXAMPLES[id])), JSON.stringify(EXAMPLES[id]), `${id} is canonical, in Swift's key order`);
    }
    expectEqual(actionFromForm(formFromAction('push left')), 'push left');
    expectEqual(actionFromForm(formFromAction({op: 'teleport', to: 'mars'})), {op: 'teleport', to: 'mars'});
  }],
  ['field updates rebuild a canonical action', () => {
    expectEqual(updateAction(EXAMPLES.push, 'pushStyle', 'none'), {op: 'push', direction: 'up', screen: '1'});
    expectEqual(updateAction(EXAMPLES.resize, 'anchor', 'top-left'), {op: 'resize', width: '+10%', height: '-5%'});
    expectEqual(updateAction(EXAMPLES.throw, 'resizes', false), {op: 'throw', screen: 'left'});
    expectEqual(updateAction({op: 'hint'}, 'hintCharacters', 'ab'), {op: 'hint', characters: 'ab'});
    expectEqual(updateAction(EXAMPLES.sequence, 'steps', [{action: {op: 'undo'}, keepWindow: false}]), {op: 'sequence', operations: [{op: 'undo'}]});
  }],
  ['switching kinds keeps compatible parameters', () => {
    const half = presetById('left-half').action;
    expectEqual(convertAction(half, 'corner'), {op: 'corner', direction: 'top-left', width: 'screenSizeX/2', height: 'screenSizeY'});
    expectEqual(convertAction(half, 'throw'), {op: 'throw', screen: 'next'});
    expectEqual(convertAction(half, 'by-orientation'), {op: 'by-orientation', landscape: half, portrait: half});
    expectEqual(convertAction({op: 'undo'}, 'layout', {knownLayouts: ['Writing', 'Coding']}), {op: 'layout', name: 'Coding'});
    expectEqual(convertAction({op: 'undo'}, 'chain').operations.length, 3);
    expectEqual(convertAction({op: 'snapshot', name: 'x'}, 'activate-snapshot'), {op: 'activate-snapshot', name: 'x'});
    expectEqual(convertAction('push left', 'undo'), {op: 'undo'});
  }],
  ['titles read like the macOS app', () => {
    expectEqual(actionTitle({op: 'push', direction: 'left', style: 'bar-resize:screenSizeX/2'}), 'Left Half');
    expectEqual(actionTitle({op: 'push', direction: 'right', style: 'bar'}), 'Push Right, Full Height');
    expectEqual(actionTitle({op: 'push', direction: 'down', style: 'center'}), 'Push Down, Centered');
    expectEqual(actionTitle({op: 'chain', operations: defaultChain()}), 'Cycle Left Half → Left Third → Left Two Thirds');
    expectEqual(actionTitle({op: 'throw', screen: '1', width: 'screenSizeX', height: 'screenSizeY'}), 'Throw to Display 2, Resized');
    expectEqual(actionTitle(EXAMPLES['by-orientation']), 'Push Left / Push Up');
    expectEqual(actionTitle(EXAMPLES['focus-app']), 'Focus Firefox');
    expectEqual(actionTitle(EXAMPLES.focus), 'Focus Window Behind');
    expectEqual(actionTitle(EXAMPLES.hide), 'Hide All but Terminal');
    expectEqual(actionTitle(EXAMPLES.show), 'Show Firefox & Files');
    expectEqual(actionTitle(EXAMPLES['insert-text']), 'Insert “Hello ⏎ world”');
    expectEqual(actionTitle(EXAMPLES['open-url']), 'Open example.com');
    expectEqual(actionTitle(EXAMPLES.keystroke), 'Press Ctrl Shift T');
    expectEqual(actionTitle({op: 'layout', name: ''}), 'Apply Layout');
    expectEqual(screenName('ordered:0'), 'Display 1 (left to right)');
    expectEqual(appsPhrase(['a', 'b', 'c']), 'a & 2 more');
  }],
  ['thirds that turn with the display, displays and centered moves are named as on the Mac', () => {
    const third = presetById('left-third').action;
    const stacked = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX', height: 'screenSizeY/3'};
    expectEqual(matchingPreset({op: 'by-orientation', landscape: third, portrait: stacked})?.id, 'first-third');
    expectEqual(actionTitle({op: 'by-orientation', landscape: third, portrait: stacked}), 'First Third');
    expectEqual(ORIENTATION_PRESETS.map(p => p.title), ['First Third', 'Middle Third', 'Last Third', 'First Two Thirds', 'Last Two Thirds']);
    expect(ORIENTATION_PRESETS.every(p => !PRESETS.includes(p)), 'the pickers offer only the plain presets');
    // Slate's "*1/3" spelling of a two-thirds offset, side by side and turned.
    const twoThirds = {op: 'move', x: 'screenOriginX+screenSizeX*1/3', y: 'screenOriginY', width: 'screenSizeX*2/3', height: 'screenSizeY'};
    expectEqual(matchingPreset(twoThirds)?.id, 'right-two-thirds');
    expectEqual(actionTitle({op: 'by-orientation', landscape: twoThirds,
      portrait: {op: 'move', x: 'screenOriginX', y: 'screenOriginY+screenSizeY*1/3', width: 'screenSizeX', height: 'screenSizeY*2/3'}}), 'Last Two Thirds');
    // Other pairs name both sides, once when they're the same.
    expectEqual(actionTitle({op: 'by-orientation', landscape: presetById('maximize').action, portrait: presetById('maximize').action}), 'Maximize');
    expectEqual(screenName('left'), 'Left Display');
    expectEqual(actionTitle({op: 'throw', screen: 'right', width: 'screenSizeX', height: 'screenSizeY'}), 'Throw to Right Display, Resized');
    if (implemented('targetFrame')) {
      const centered = (w, h) => ({op: 'move', x: `screenOriginX+(screenSizeX-screenSizeX*${w})/2`, y: `screenOriginY+(screenSizeY-screenSizeY*${h})/2`,
        width: `screenSizeX*${w}`, height: `screenSizeY*${h}`});
      expectEqual(actionTitle(centered(0.5, 0.5)), 'Center, 50%');
      expectEqual(actionTitle(centered(0.6, 0.8)), 'Center, 60% × 80%');
      expectEqual(actionTitle({op: 'move', x: 'screenOriginX+10', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'}), 'Move & Resize');
    }
  }],
  ['details fall back to Slate-like syntax without the engine', () => {
    expectEqual(localDetail(EXAMPLES.push), 'push up bar-resize:screenSizeY/3 1');
    expectEqual(localDetail(EXAMPLES.grid), 'grid padding:4 0:6,6');
    expectEqual(localDetail(EXAMPLES.sequence), 'undo > relaunch');
    expectEqual(localDetail(EXAMPLES.hide), "hide all-but:'Terminal'");
    expect(typeof actionDetail(EXAMPLES.move) === 'string' && actionDetail(EXAMPLES.move).startsWith('move'));
  }],
  ['binding titles and subtitles', () => {
    expectEqual(bindingTitle({name: '  ', action: presetById('maximize').action}), 'Maximize');
    expectEqual(bindingTitle({name: 'Big', action: presetById('maximize').action}), 'Big');
    expectEqual(bindingSubtitle({name: 'Big', action: presetById('maximize').action}), 'Maximize');
    expectEqual(bindingSubtitle({action: presetById('maximize').action}), 'Move & Resize');
    expectEqual(bindingSubtitle({action: {op: 'undo'}}), 'Snapshots');
  }],
  ['window geometry', () => {
    expect(isWindowGeometry(EXAMPLES.move) && isWindowGeometry(EXAMPLES['by-orientation']));
    expect(!isWindowGeometry(EXAMPLES.chain) && !isWindowGeometry(EXAMPLES.undo));
    expect(!isWindowGeometry({op: 'by-orientation', landscape: {op: 'undo'}, portrait: {op: 'push', direction: 'left'}}));
  }],
  ['Mouse & Keys actions are titled like the Mac app', () => {
    expectEqual(actionTitle({op: 'click', button: 'right', count: 2}), 'Double-Click Right');
    expectEqual(actionTitle({op: 'click', count: 3}), '3× Click Left');
    expectEqual(actionTitle({op: 'press', input: 'mouse:left', phase: 'down'}), 'Press Left Button');
    expectEqual(actionTitle({op: 'press', input: 'key:shift+w', phase: 'up'}), 'Release Shift W');
    expectEqual(actionTitle({op: 'hold', input: 'key:w'}), 'Hold W');
    expectEqual(actionTitle({op: 'hold', input: 'key:rightShift'}), 'Hold Right Shift');
    expectEqual(actionTitle({op: 'repeat', action: {op: 'click'}, interval: 0.1, mode: 'while-held'}),
      'Repeat Click Left every 100 ms while held');
    expectEqual(actionTitle(EXAMPLES.repeat), 'Repeat Press E every 50 ms while held, 20×');
    expectEqual(actionTitle({op: 'wait', seconds: 1.5}), 'Wait 1.5 s');
    expectEqual(actionTitle({op: 'wait', seconds: 2}), 'Wait 2 s');
    expectEqual(actionTitle({op: 'stop-automations'}), 'Stop Automations');
    expectEqual(actionTitle({op: 'clipboard-history'}), 'Clipboard History');
    expectEqual(actionProblems({op: 'teleport'})[0].severity, 'error');
    expectEqual(kindOf({op: 'teleport'}), 'unknown');
  }],
  ['Mouse & Keys forms keep the Mac editor\'s defaults and limits', () => {
    const form = defaultForm();
    expectEqual([form.mouseButton, form.clickCount, form.input, form.phase, form.interval, form.repeatMode, form.repeatTimes, form.jitter, form.seconds],
      ['left', 1, 'mouse:right', 'down', 0.1, 'toggle', null, 0, 0.5]);
    expectEqual(convertAction({op: 'undo'}, 'click'), {op: 'click', button: 'left'});
    expectEqual(convertAction({op: 'undo'}, 'press'), {op: 'press', input: 'mouse:right', phase: 'down'});
    expectEqual(convertAction({op: 'press', input: 'key:w', phase: 'up'}, 'hold'), {op: 'hold', input: 'key:w'}, 'the input carries over');
    expectEqual(convertAction({op: 'undo'}, 'repeat'), {op: 'repeat', action: {op: 'click', button: 'left'}, interval: 0.1});
    expectEqual(convertAction({op: 'undo'}, 'wait'), {op: 'wait', seconds: 0.5});
    expectEqual(updateAction({op: 'click', button: 'left', count: 2}, 'clickCount', 1), {op: 'click', button: 'left'}, 'count 1 left out');
    expectEqual(updateAction(EXAMPLES.repeat, 'interval', 0.001).interval, 0.01, 'at most 100 runs a second');
    expectEqual(updateAction(EXAMPLES.repeat, 'jitter', 0.9).jitter, 0.5);
    expectEqual(updateAction(EXAMPLES.repeat, 'jitter', 0).jitter, undefined, 'no jitter left out');
    expectEqual(updateAction(EXAMPLES.repeat, 'repeatTimes', null).times, undefined, 'until stopped');
    expectEqual(updateAction(EXAMPLES.repeat, 'repeatTimes', 0).times, 1, 'at least one run');
    expectEqual(updateAction(EXAMPLES.repeat, 'repeatMode', 'toggle').mode, undefined, 'toggle is the default');
    expectEqual(updateAction({op: 'wait', seconds: 1}, 'seconds', -2), {op: 'wait', seconds: 0});
    expectEqual(localDetail(EXAMPLES.repeat), "repeat 0.05 while-held times:20 jitter:0.15 'keystroke e'");
    expectEqual(localDetail(EXAMPLES.click), 'click right 2');
    expectEqual(actionDetail(EXAMPLES.press), 'press key:w up');
  }],
  ['automation is found in steps, and macros know which steps act on windows', () => {
    expect(isAutomation(EXAMPLES.click) && isAutomation('wait 1') && !isAutomation(EXAMPLES['clipboard-history']));
    expect(containsAutomation({op: 'sequence', operations: [half(), EXAMPLES.wait]}));
    expect(containsAutomation({op: 'by-orientation', landscape: {op: 'undo'}, portrait: EXAMPLES.hold}));
    expect(!containsAutomation(EXAMPLES.chain) && !containsAutomation(EXAMPLES['insert-text']));
    expect(containsWindowGeometry({op: 'sequence', operations: [EXAMPLES.click, half()]}));
    expect(!containsWindowGeometry({op: 'sequence', operations: [EXAMPLES.click, EXAMPLES.wait]}));
    expect(isInputStep(EXAMPLES.keystroke) && isInputStep(EXAMPLES.wait) && !isInputStep(half()));
    expectEqual(INPUT_STEPS.map(s => s.action.op), ['click', 'click', 'press', 'press', 'keystroke', 'wait', 'wait']);
    for (const step of INPUT_STEPS) expectEqual(canonicalAction(step.action), step.action, `${step.title} is canonical`);
  }],
]);
