// Handwritten tests for what the Swift golden vectors can't express: JavaScript-only API (GNOME
// accelerators, options objects, accepted input forms), the module contract, and engine purity.

import * as core from '../gnome-extension/lib/core/index.js';
import {SlatedError} from '../gnome-extension/lib/core/errors.js';
import {keysymName} from '../gnome-extension/lib/core/keys.js';
import {formatDate} from '../gnome-extension/lib/core/hotstrings.js';
import {characterCount, doubleDescription, graphemes} from '../gnome-extension/lib/core/text.js';
import {parseJSON5} from '../gnome-extension/lib/core/json.js';
import {expect, expectEqual, expectThrows, show, test} from './harness.mjs';

/** Every export the engine contract (index.js) promised the extension. */
const CONTRACT = [
  'SlatedError', 'evaluateExpression', 'parseOperation', 'formatOperation', 'parseKeystroke', 'parseSlateConfig',
  'targetFrame', 'targetOrigin', 'resolveScreen', 'decodeConfiguration', 'encodeConfiguration', 'starterConfiguration',
  'parseKeyCombo', 'formatKeyCombo', 'toGnomeAccelerator', 'HotstringMatcher', 'expandTemplate',
];

/** Exports added beyond the contract (documented in index.js). */
const ADDITIONS = [
  'validateExpression', 'shellArguments', 'describeDiagnostic', 'screenContaining', 'orderedLeftToRight',
  'decodeAction', 'isWindowGeometry', 'readSettings', 'displayKeyCombo',
];

const MODULES = [
  'index.js', 'errors.js', 'text.js', 'json.js', 'tokenizer.js', 'expression.js', 'keys.js', 'model.js', 'config.js',
  'slateSyntax.js', 'slateConfig.js', 'frame.js', 'hotstrings.js',
];

const hyper = ['ctrl', 'alt', 'shift', 'cmd'];
const screen = {
  displayID: 1, name: 'Main', frame: {x: 0, y: 0, width: 1920, height: 1080},
  visibleFrame: {x: 0, y: 32, width: 1920, height: 1048}, isMain: true, scale: 1,
};
const context = {frame: {x: 100, y: 100, width: 800, height: 600}, screens: [screen]};

export function registerUnitTests({root, readText}) {
  test('contract: index.js exports every promised function', () => {
    for (const name of [...CONTRACT, ...ADDITIONS]) expect(typeof core[name] === 'function', `${name} is ${typeof core[name]}`);
    expect(core.windowVariableNames.length === 10 && core.variableNames.length === 12, 'variable name lists');
    expect(core.isWindowGeometry({op: 'by-orientation', landscape: 'push up', portrait: 'corner top-left'}), 'by-orientation of geometry');
    expect(!core.isWindowGeometry({op: 'by-orientation', landscape: 'push up', portrait: 'focus left'}), 'by-orientation with focus');
    expect(core.isWindowGeometry('throw next') && !core.isWindowGeometry('undo'), 'Slate syntax');
    const error = new core.SlatedError('invalidSyntax', 'x');
    expect(error instanceof Error && error.kind === 'invalidSyntax' && error.message === 'x', 'SlatedError(kind, message)');
    expect(new core.HotstringMatcher([]).feed('a', null) === null, 'HotstringMatcher is constructible');
  });

  test('purity: the engine imports only its own modules and no platform APIs', () => {
    // Every module reachable from index.js (the runtime can't list directories, so follow imports).
    const seen = new Set();
    const queue = ['index.js'];
    while (queue.length > 0) {
      const file = queue.shift();
      if (seen.has(file)) continue;
      seen.add(file);
      const source = readText(`${root}/linux/gnome-extension/lib/core/${file}`);
      // Code only: drop comments (a line comment must follow whitespace, so "file://" survives).
      const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/.*$/gm, '$1');
      const imports = [...code.matchAll(/^\s*(?:import|export)\s[^;]*?from\s+['"]([^'"]+)['"]/gm)].map((m) => m[1]);
      for (const spec of imports) {
        if (/^\.\/[A-Za-z]+\.js$/.test(spec)) queue.push(spec.slice(2));
        else expect(false, `${file} imports ${spec}`);
      }
      expect(!/\bimport\s*\(/.test(code), `${file} uses dynamic import()`);
      const forbidden = [/['"]gi:\/\//, /['"]node:/, /\brequire\s*\(/, /\bdocument\./, /\bprocess\./, /\bimports\./, /\bwindow\.(?:document|location|navigator)/];
      for (const pattern of forbidden) expect(!pattern.test(code), `${file} uses ${pattern}`);
    }
    for (const file of MODULES) expect(seen.has(file), `${file} isn't reachable from index.js`);
  });

  test('toGnomeAccelerator: modifiers, Hyper and keysym names', () => {
    expectEqual(core.toGnomeAccelerator({key: 'a', modifiers: hyper}), '<Control><Alt><Shift><Super>a');
    expectEqual(core.toGnomeAccelerator({key: 'a', modifiers: hyper}, {hyperMode: 'xkb'}), '<Hyper>a');
    expectEqual(core.toGnomeAccelerator({key: 'a', modifiers: ['ctrl', 'alt']}, {hyperMode: 'xkb'}), '<Control><Alt>a');
    expectEqual(core.toGnomeAccelerator({key: 'a', modifiers: [...hyper, 'fn']}, {hyperMode: 'xkb'}), '<Hyper>a');
    expectEqual(core.toGnomeAccelerator({key: 'f1', modifiers: ['fn']}), 'F1', 'fn has no accelerator form');
    expectEqual(core.toGnomeAccelerator({key: '4', modifiers: ['cmd', 'shift']}), '<Shift><Super>4', 'canonical order');
    expectEqual(core.toGnomeAccelerator({key: 'A', modifiers: []}), 'a', 'letters are lowercase keysyms');
    expectEqual(core.toGnomeAccelerator('hyper+left'), '<Control><Alt><Shift><Super>Left', 'config strings work too');
    expectEqual(core.toGnomeAccelerator('meh+return', {hyperMode: 'xkb'}), '<Control><Alt><Shift>Return');
    expectEqual(core.toGnomeAccelerator('bogus+a'), null);
    expectEqual(core.toGnomeAccelerator({key: 'bogus', modifiers: []}), null, 'unknown key names have no keysym');
    expectEqual(core.toGnomeAccelerator({key: '', modifiers: ['ctrl']}), null);
    const keysyms = {
      left: 'Left', right: 'Right', up: 'Up', down: 'Down', return: 'Return', tab: 'Tab', space: 'space',
      delete: 'BackSpace', forwardDelete: 'Delete', esc: 'Escape', home: 'Home', end: 'End', pageUp: 'Page_Up',
      pageDown: 'Page_Down', help: 'Help', caps: 'Caps_Lock', mute: 'XF86AudioMute', volumeUp: 'XF86AudioRaiseVolume',
      volumeDown: 'XF86AudioLowerVolume', backslash: 'backslash', padClear: 'Num_Lock', padEnter: 'KP_Enter',
      'pad=': 'KP_Equal', 'pad*': 'KP_Multiply', 'pad+': 'KP_Add', 'pad-': 'KP_Subtract', 'pad.': 'KP_Decimal',
      'pad/': 'KP_Divide', pad0: 'KP_0', pad1: 'KP_1', pad9: 'KP_9', f1: 'F1', f13: 'F13', f20: 'F20', "'": 'apostrophe',
      ';': 'semicolon', ',': 'comma', '.': 'period', '/': 'slash', '\\': 'backslash', '[': 'bracketleft',
      ']': 'bracketright', '-': 'minus', '=': 'equal', '`': 'grave', '+': 'plus', '"': 'quotedbl', '#': 'numbersign',
      '~': 'asciitilde', 1: '1', z: 'z', é: 'eacute', ß: 'ssharp', '€': 'EuroSign', ж: 'U0436', '😀': 'U1F600',
      escape: 'Escape', Enter: 'Return', PageUp: 'Page_Up', f21: null, ab: null, 'é': null,
    };
    for (const [key, name] of Object.entries(keysyms)) expectEqual(keysymName(key), name, `keysym for ${show(key)}`);
  });

  test('toGnomeAccelerator: every Slate key name has a keysym', () => {
    const named = [
      'left', 'right', 'up', 'down', 'return', 'tab', 'space', 'delete', 'forwardDelete', 'esc', 'home', 'end',
      'pageUp', 'pageDown', 'help', 'caps', 'mute', 'volumeUp', 'volumeDown', 'backslash', 'padClear', 'padEnter',
      'pad=', 'pad*', 'pad+', 'pad-', 'pad.', 'pad/',
    ];
    for (let i = 0; i <= 9; i++) named.push(`pad${i}`);
    for (let i = 1; i <= 20; i++) named.push(`f${i}`);
    for (let c = 0x21; c < 0x7f; c++) named.push(String.fromCharCode(c));
    for (const key of named) expect(keysymName(key) !== null, `no keysym for ${show(key)}`);
  });

  test('keys: combos accept config strings and validate modifier names', () => {
    expectEqual(core.formatKeyCombo('ctrl+shift+alt+cmd+a'), 'hyper+a');
    expectEqual(core.displayKeyCombo('hyper+a'), '✦A');
    expectEqual(core.displayKeyCombo({key: 'a', modifiers: hyper}, {hyperGlyph: false}), '⌃⌥⇧⌘A');
    const error = expectThrows(() => core.formatKeyCombo({key: 'a', modifiers: ['super']}));
    expect(error instanceof SlatedError && error.kind === 'invalidSyntax', `got ${error}`);
    expectEqual(core.formatKeyCombo({key: 'a', modifiers: ['hyper']}), 'hyper+a', 'modifier aliases');
  });

  test('actions: every function accepts Slate syntax and JSON forms', () => {
    expectEqual(core.formatOperation('push top bar-resize:screenSizeY/2'), 'push up bar-resize:screenSizeY/2');
    expectEqual(core.formatOperation({op: 'push', direction: 'top'}), 'push up');
    expectEqual(core.targetFrame('push left bar-resize:screenSizeX/2', context), {x: 0, y: 32, width: 960, height: 1048});
    expectEqual(core.targetFrame({op: 'move', x: 0, y: 0, width: 10, height: 10}, context), {x: 0, y: 0, width: 10, height: 10});
    expectEqual(core.targetOrigin('corner bottom-right', context, {width: 500, height: 500}), {x: 1120, y: 480});
    const error = expectThrows(() => core.decodeAction({op: 'move', x: '0'}));
    expect(error instanceof SlatedError && error.kind === 'invalidConfiguration', 'decoding errors are SlatedErrors');
    expectEqual(error?.codingPath, ['y'], 'codingPath points at the problem');
    expectEqual(error?.message, '"move" needs "y"');
  });

  test('actions: a grid keeps its written order until it goes through JSON', () => {
    const grid = core.parseOperation('grid 1:6,6 0:4,4 10:2,2');
    expectEqual(core.formatOperation(grid), 'grid 1:6,6 0:4,4 10:2,2');
    expectEqual(Object.keys(grid.grids).sort(), ['0', '1', '10']);
    expectEqual(core.formatOperation(JSON.parse(JSON.stringify(grid))), 'grid 0:4,4 1:6,6 10:2,2');
    const chain = core.parseOperation('chain grid 2:1,1 1:1,1 | undo');
    expectEqual(core.formatOperation(chain), 'chain grid 2:1,1 1:1,1 | undo', 'nested grids too');
  });

  test('screens: resolveScreen takes text, numbers or null', () => {
    const right = {...screen, displayID: 2, name: 'Right', frame: {x: 1920, y: 0, width: 1920, height: 1080}, isMain: false};
    const ctx = {...context, screens: [screen, right]};
    expectEqual(core.resolveScreen(null, ctx)?.name, 'Main');
    expectEqual(core.resolveScreen(1, ctx)?.name, 'Right');
    expectEqual(core.resolveScreen('right', ctx)?.name, 'Right');
    expectEqual(core.resolveScreen('next', ctx)?.name, 'Right');
    expectEqual(core.resolveScreen(5, ctx), null);
    expectEqual(core.resolveScreen(5, {...ctx, settings: {defaultToCurrentScreen: true}})?.name, 'Main');
    const error = expectThrows(() => core.resolveScreen('sideways', ctx));
    expectEqual(error?.message, 'Invalid screen reference "sideways"');
    expectEqual(core.resolveScreen(null, {...ctx, screens: []}), null, 'no screens');
  });

  test('config: decode accepts objects; encode canonicalizes and refuses NaN', () => {
    const config = core.decodeConfiguration({bindings: [{keys: 'Hyper+A', action: 'push top'}]});
    expectEqual(config.bindings[0].keys, 'hyper+a');
    expectEqual(config.bindings[0].action, {op: 'push', direction: 'up'});
    expect(/^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/.test(config.bindings[0].id), 'random v4 id');
    expectEqual(core.encodeConfiguration({}), core.encodeConfiguration(core.decodeConfiguration('{}')));
    const error = expectThrows(() => core.encodeConfiguration({settings: {x: NaN}}));
    expect(error instanceof SlatedError && error.kind === 'invalidConfiguration', `got ${error}`);
    const bad = expectThrows(() => core.decodeConfiguration('{"bindings": [{"keys": "x+y", "action": "undo"}]}'));
    expectEqual(bad?.codingPath, ['bindings', 0, 'keys']);
    const broken = expectThrows(() => core.decodeConfiguration('{"bindings": ['));
    expect(broken instanceof SlatedError && broken.kind === 'invalidConfiguration', `broken JSON: ${broken}`);
  });

  test('config: readSettings applies Slate defaults', () => {
    const s = core.readSettings({});
    expectEqual([s.defaultToCurrentScreen, s.orderScreensLeftToRight, s.undoMaxStackSize, s.repeatOnHoldOps], [false, true, 10, ['resize', 'nudge']]);
    expectEqual(core.readSettings({secondsBeforeRepeat: '0.2'}).secondsBeforeRepeat, 0.2);
  });

  test('config: starter configuration matches docs/CONFIG.md', () => {
    const starter = core.starterConfiguration();
    expectEqual(starter.keyboard.capsLock, 'hyper');
    expectEqual(starter.bindings.length, 21);
    expect(starter.bindings.every((b) => b.keys.startsWith('hyper+')), 'all on Hyper');
    const keys = starter.bindings.map((b) => b.keys.slice('hyper+'.length)).sort().join(' ');
    expectEqual(keys, "' a b c d down e f g h left q return right s tab up v w x z");
    expect(core.starterConfiguration().bindings[0].id !== starter.bindings[0].id, 'fresh ids each time');
  });

  test('slate config: default options and diagnostics', () => {
    const result = core.parseSlateConfig('bind a:ctrl push up\nsource ~/other.slate\nbogus');
    expectEqual(result.bindings.length, 1);
    expectEqual(result.diagnostics.map((d) => [d.line, d.file]), [[2, undefined], [3, undefined]]);
    expectEqual(core.describeDiagnostic({severity: 'error', message: 'm', file: '/a/b/.slate', line: 3}), '.slate, line 3: m');
    expectEqual(core.describeDiagnostic({severity: 'warning', message: 'm'}), 'm');
    const sourced = core.parseSlateConfig('source extra.slate', {path: '/home/u/.slate', homeDirectory: '/home/u', readFile: (p) => (p === '/home/u/extra.slate' ? 'bind b:ctrl undo' : null)});
    expectEqual(sourced.bindings.map((b) => b.keys), ['ctrl+b']);
  });

  test('hotstrings: matcher API with partial hotstrings', () => {
    const m = new core.HotstringMatcher([{trigger: ';sig'}, {trigger: 'off', enabled: false}, {trigger: ''}]);
    expectEqual(m.hotstrings.map((h) => h.trigger), [';sig'], 'only enabled hotstrings with a trigger');
    let match = null;
    for (const c of 'x;sig') match = m.feed(c) ?? match;
    expectEqual(match && [match.hotstring.trigger, match.deleteCount, match.delimiter], [';sig', 3, null]);
    m.update([{trigger: 'brb', fire: 'afterDelimiter', onlyInApps: ['org.gnome.TextEditor']}]);
    expectEqual(m.feed('brb ', null), null, 'onlyInApps needs an app');
    const hit = m.feed('brb ', 'org.gnome.TextEditor');
    expectEqual(hit && [hit.deleteCount, hit.delimiter], [3, ' ']);
    expect(core.HotstringMatcher.isDelimiter('.') && !core.HotstringMatcher.isDelimiter('_'), 'isDelimiter');
  });

  test('templates: dates, time zones and options', () => {
    const now = Date.UTC(2026, 9, 22, 15, 4, 5, 678);
    expectEqual(core.expandTemplate('{date:yyyy-MM-dd HH:mm}', {now, timeZone: 'UTC'}), '2026-10-22 15:04');
    expectEqual(core.expandTemplate('{date:HH:mm XXX}', {now, timeZone: 330}), '20:34 +05:30', 'fixed offsets');
    expectEqual(core.expandTemplate('{date:HH:mm xx O}', {now, timeZone: -420}), '08:04 -0700 GMT-7');
    expectEqual(core.expandTemplate('{date:ZZZZ X}', {now, timeZone: -150}), 'GMT-02:30 -0230');
    expectEqual(core.expandTemplate('{date:yyyy}', {now: new Date(now), timeZone: 'UTC'}), '2026', 'Date objects work too');
    expectEqual(core.expandTemplate('{time}', {now, timeZone: 'UTC'}), '3:04\u202FPM', 'en_US_POSIX by default');
    expectEqual(core.expandTemplate('{clipboard}'), '', 'no clipboard');
    expect(/^\d{4}$/.test(core.expandTemplate('{date:yyyy}')), 'defaults to now, local time');
    expectEqual(formatDate(new Date(now), "h 'o''clock' a", {timeZone: 'UTC'}), "3 o'clock PM");
  });

  test('text: Swift characters and number descriptions', () => {
    expectEqual(graphemes('é👍🏽🇺🇸👨\u200D👩\u200D👧\r\nक'), ['é', '👍🏽', '🇺🇸', '👨\u200D👩\u200D👧', '\r\n', 'क']);
    expectEqual(graphemes('한국어'), ['한', '국', '어']);
    expectEqual(characterCount('각'), 1, 'Hangul jamo form one character');
    const descriptions = [
      [0.1, '0.1'], [1e15, '1000000000000000.0'], [2 ** 53, '9007199254740992.0'], [2 ** 53 + 2, '9.007199254740994e+15'],
      [1e-4, '0.0001'], [1.5e-5, '1.5e-05'], [-0, '-0.0'], [1e300, '1e+300'], [5e-324, '5e-324'], [-2.5, '-2.5'],
    ];
    for (const [d, text] of descriptions) expectEqual(doubleDescription(d), text, `description of ${d}`);
  });

  test('json: JSON5 parser keeps numbers as written', () => {
    const value = parseJSON5("{a: 0x10, 'b': [1, 2,], /* c */ c: 'x'}");
    expectEqual(value.a.raw, '0x10');
    expectEqual(value.b.map((n) => n.raw), ['1', '2']);
    expectEqual(value.c, 'x');
    const proto = parseJSON5('{"__proto__": {"x": 1}}');
    expect(Object.prototype.hasOwnProperty.call(proto, '__proto__') && proto.x === undefined, 'no prototype pollution');
    const settings = core.decodeConfiguration('{"settings": {"__proto__": 1}}').settings;
    expect(Object.prototype.hasOwnProperty.call(settings, '__proto__'), '__proto__ is kept as a setting');
  });

  test('expressions: variables come only from the given object', () => {
    const error = expectThrows(() => core.evaluateExpression('constructor', {}));
    expect(error?.message?.startsWith('Unknown variable "constructor"'), `got ${error?.message}`);
    expectEqual(core.evaluateExpression('a*2', {a: 21}), 42);
    expectThrows(() => core.validateExpression('windowHintsWidth'));
    core.validateExpression('windowHintsWidth', core.variableNames);
  });
}
