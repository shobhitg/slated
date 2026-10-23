import {suite, expect, expectEqual} from './harness.mjs';
import {
  PRESETS, PRESET_GROUPS, presetById, matchingPreset, starterBindings, defaultChain, defaultSequence,
} from '../../gnome-extension/lib/prefs/presets.js';
import {
  KINDS, CATEGORIES, kindOf, kindById, formFromAction, actionFromForm, convertAction, updateAction, actionTitle,
  actionDetail, localDetail, bindingTitle, bindingSubtitle, isWindowGeometry, screenName, appsPhrase,
} from '../../gnome-extension/lib/prefs/actions.js';
import {canonicalActionLocal} from '../../gnome-extension/lib/prefs/canonical.js';

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
};

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
    expectEqual(KINDS.length, 27);
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
]);
