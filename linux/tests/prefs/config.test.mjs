import {suite, expect, expectEqual, expectThrows} from './harness.mjs';
import {canonicalActionLocal, screenRef, pushStyle, coerceParameter} from '../../gnome-extension/lib/prefs/canonical.js';
import {json5ToJSON, parseLenientJSON, fillDefaults, encodeLocal} from '../../gnome-extension/lib/prefs/config.js';
import {
  decodeConfiguration, encodeConfiguration, canonicalAction, isNotImplemented, implemented,
} from '../../gnome-extension/lib/prefs/engine.js';
import {stableStringify} from '../../gnome-extension/lib/prefs/util.js';

export default suite('Config and canonical actions', [
  ['canonical actions match Swift Action Codable', () => {
    expectEqual(canonicalActionLocal({op: 'push', direction: 'top', style: 'bar-resize:screenSizeY/2'}),
      {op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/2'});
    expectEqual(canonicalActionLocal({op: 'push', direction: 'Bottom', style: 'none'}), {op: 'push', direction: 'down'});
    expectEqual(canonicalActionLocal({op: 'move', x: 0, y: 'screenOriginY', width: 100.5, height: 'h', screen: 1}),
      {op: 'move', x: '0', y: 'screenOriginY', width: '100.5', height: 'h', screen: '1'});
    expectEqual(canonicalActionLocal({op: 'resize', width: '+10%'}), {op: 'resize', width: '+10%', height: '+0'});
    expectEqual(canonicalActionLocal({op: 'resize', anchor: 'top-left'}), {op: 'resize', width: '+0', height: '+0'});
    expectEqual(canonicalActionLocal({op: 'corner', direction: 'Top-Left'}), {op: 'corner', direction: 'top-left'});
    expectEqual(canonicalActionLocal({op: 'throw', screen: 'prev'}), {op: 'throw', screen: 'previous'});
    expectEqual(canonicalActionLocal({op: 'throw', screen: 'ordered:01', width: 'screenSizeX'}),
      {op: 'throw', screen: 'ordered:1', width: 'screenSizeX'});
    expectEqual(canonicalActionLocal({op: 'sequence', steps: [{action: {op: 'undo'}}, {action: {op: 'relaunch'}, keepWindow: false}]}),
      {op: 'sequence', operations: [{op: 'undo'}, {op: 'relaunch'}]});
    expectEqual(canonicalActionLocal({op: 'sequence', steps: [{action: {op: 'undo'}}, {action: {op: 'relaunch'}, keepWindow: true}]}),
      {op: 'sequence', steps: [{action: {op: 'undo'}, keepWindow: false}, {action: {op: 'relaunch'}, keepWindow: true}]});
    expectEqual(canonicalActionLocal({op: 'focus', direction: 'above'}), {op: 'focus', direction: 'up'});
    expectEqual(canonicalActionLocal({op: 'focus', app: 'Firefox', direction: 'left'}), {op: 'focus', app: 'Firefox'});
    expectEqual(canonicalActionLocal({op: 'hide', app: 'Firefox'}), {op: 'hide', app: ['Firefox']});
    expectEqual(canonicalActionLocal({op: 'hide', app: 'ALL-BUT:Files'}), {op: 'hide', app: 'all-but:Files'});
    expectEqual(canonicalActionLocal({op: 'snapshot', name: 'a', save: false, stack: true}), {op: 'snapshot', name: 'a', stack: true});
    expectEqual(canonicalActionLocal({op: 'grid', padding: 4, grids: {1: {width: 6, height: 6}, 0: {width: 2, height: 3}}}),
      {op: 'grid', padding: 4, grids: {0: {width: 2, height: 3}, 1: {width: 6, height: 6}}});
    expectEqual(canonicalActionLocal({op: 'insert-text', text: 'hi', method: 'auto'}), {op: 'insert-text', text: 'hi'});
    expectEqual(canonicalActionLocal({op: 'keystroke', keys: 'cmd+ctrl+alt+shift+a'}), {op: 'keystroke', keys: 'hyper+a'});
    expectEqual(canonicalActionLocal({op: 'by-orientation', landscape: {op: 'push', direction: 'left'}, portrait: {op: 'push', direction: 'top'}}),
      {op: 'by-orientation', landscape: {op: 'push', direction: 'left'}, portrait: {op: 'push', direction: 'up'}});
    expectEqual(canonicalActionLocal('push left'), 'push left', 'Slate syntax is left for the engine');
  }],
  ['invalid actions are reported like Swift decoding errors', () => {
    expectThrows(() => canonicalActionLocal({op: 'push'}), /needs "direction"/);
    expectThrows(() => canonicalActionLocal({op: 'push', direction: 'sideways'}), /Invalid direction/);
    expectThrows(() => canonicalActionLocal({op: 'corner', direction: 'middle'}), /Invalid corner/);
    expectThrows(() => canonicalActionLocal({op: 'teleport'}), /Unknown operation/);
    expectThrows(() => canonicalActionLocal({op: 'throw'}), /needs "screen"/);
    expectThrows(() => canonicalActionLocal({op: 'snapshot', name: 'x', save: 'yes'}), /true or false/);
  }],
  ['screen references, push styles and coercions', () => {
    expectEqual(screenRef(0), '0');
    expectEqual(screenRef('1680X1050'), '1680x1050');
    expectEqual(screenRef('below'), 'down');
    expectEqual(screenRef('nowhere'), null);
    expectEqual(pushStyle('BAR-RESIZE:screenSizeX/3'), 'bar-resize:screenSizeX/3');
    expectEqual(pushStyle('sideways'), null);
    expectEqual(coerceParameter('wait', 'false'), false);
    expectEqual(coerceParameter('save', 'yes'), true);
    expectEqual(coerceParameter('padding', ' 4 '), 4);
    expectEqual(coerceParameter('grids', {0: {width: '6', height: 6}}), {0: {width: 6, height: 6}});
  }],
  ['reads hand-edited JSON5 config files', () => {
    const text = `{
      // Caps Lock becomes Hyper
      "keyboard": { "capsLock": "hyper", },
      /* bindings */
      bindings: [
        { 'name': 'Left half', "keys": "hyper+a", "action": "push left bar-resize:screenSizeX/2" },
      ],
      "general": { "showActionHUD": true, "note": "it's // not a comment" },
    }`;
    const raw = parseLenientJSON(text);
    expectEqual(raw.keyboard.capsLock, 'hyper');
    expectEqual(raw.bindings[0].name, 'Left half');
    expectEqual(raw.general.note, "it's // not a comment");
    expectEqual(JSON.parse(json5ToJSON("{'a': 'it\\'s'}")), {a: "it's"});
    expectThrows(() => parseLenientJSON('{"a": }'), /isn't valid JSON/);
  }],
  ['fills Swift defaults', () => {
    const config = fillDefaults({bindings: [{keys: 'hyper+a', action: {op: 'undo'}}]}, () => 'ID');
    expectEqual(config.version, 1);
    expectEqual(config.general, {launchAtLogin: false, loadSlateConfigs: true, slateConfigPaths: ['~/.slate.js', '~/.slate'], showActionHUD: false, hotstringsEnabled: true});
    expectEqual(config.keyboard, {capsLock: 'off', capsLockAlone: 'nothing', hyperModifiers: ['ctrl', 'alt', 'shift', 'cmd']});
    expectEqual(config.bindings, [{id: 'ID', keys: 'hyper+a', action: {op: 'undo'}, enabled: true}]);
    const hs = fillDefaults({hotstrings: [{trigger: ';x'}]}, () => 'H').hotstrings[0];
    expectEqual(hs, {id: 'H', trigger: ';x', replacement: '', enabled: true, caseSensitive: true, fire: 'immediately',
      wordBoundary: false, method: 'auto', onlyInApps: [], exceptInApps: []});
    expectThrows(() => fillDefaults([]), /JSON object/);
  }],
  ['the engine facade decodes, encodes and round-trips (engine or fallback)', () => {
    const config = decodeConfiguration('{ "keyboard": {"capsLock": "hyper"}, "hotstrings": [{"id": "A", "trigger": ";s", "replacement": "x"}], }');
    expectEqual(config.keyboard.capsLock, 'hyper');
    expectEqual(config.general.loadSlateConfigs, true);
    expectEqual(config.hotstrings[0].trigger, ';s');
    const again = decodeConfiguration(encodeConfiguration(config));
    expectEqual(again, config, 'encode → decode keeps every value');
    expect(encodeLocal({b: 1, a: 2}).indexOf('"a"') < encodeLocal({b: 1, a: 2}).indexOf('"b"'), 'keys are sorted');
  }],
  ['canonicalAction agrees with the local rules', () => {
    const samples = [
      {op: 'push', direction: 'top', style: 'bar-resize:screenSizeY/2'},
      {op: 'corner', direction: 'bottom-right', width: 'screenSizeX/2', height: 'screenSizeY/2'},
      {op: 'throw', screen: 1, width: 'screenSizeX', height: 'screenSizeY'},
      {op: 'grid', padding: 4, grids: {0: {width: 6, height: 6}}},
    ];
    for (const action of samples) {
      expectEqual(stableStringify(canonicalAction(action)), stableStringify(canonicalActionLocal(action)), action.op);
    }
  }],
  ['notImplemented errors are recognized; probes report engine progress', () => {
    expect(isNotImplemented({kind: 'notImplemented'}));
    expect(!isNotImplemented(new Error('x')));
    for (const name of ['evaluateExpression', 'parseOperation', 'targetFrame', 'decodeConfiguration', 'parseSlateConfig']) {
      expect(typeof implemented(name) === 'boolean', name);
    }
  }],
]);
