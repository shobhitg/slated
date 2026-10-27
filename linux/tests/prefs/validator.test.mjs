import {suite, expect, expectEqual} from './harness.mjs';
import {checkExpression, lint, isRelativeAmount} from '../../gnome-extension/lib/prefs/expressions.js';
import {
  validate, keyProblem, typingWarning, actionProblems, savable, configChanges, target, MODIFIER_KEY_PROBLEM,
} from '../../gnome-extension/lib/prefs/validator.js';
import {GNOME_NOTES} from '../../gnome-extension/lib/prefs/automation.js';
import {decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {fillDefaults} from '../../gnome-extension/lib/prefs/config.js';
import {presetById} from '../../gnome-extension/lib/prefs/presets.js';

const half = presetById('left-half').action;
const config = fields => fillDefaults(fields, () => 'X');

export default suite('Validation', [
  ['the local expression lint catches typos with suggestions', () => {
    expectEqual(lint('screenOriginX+screenSizeX/2'), {status: 'valid', value: null});
    expectEqual(lint('min({screenSizeX, 800})'), {status: 'valid', value: null});
    expectEqual(lint('screnSizeX/2').message, 'Unknown name “screnSizeX”. Did you mean screenSizeX?');
    expectEqual(lint('banana').message, 'Unknown name “banana”');
    expectEqual(lint('floor + 1').message, '“floor” is a function — write floor(…)');
    expectEqual(lint('(screenSizeX/2').message, 'Missing “)”');
    expectEqual(lint('screenSizeX)').message, 'There\'s a “)” without a matching “(”');
    expectEqual(lint('screenSizeX/').message, 'The expression ends too early');
    expectEqual(lint('screenSizeX % 2').message, '“%” can\'t be used in an expression');
  }],
  ['expression checks agree with the engine on clear cases', () => {
    expectEqual(checkExpression('').status, 'empty');
    expectEqual(checkExpression('   ').status, 'empty');
    expectEqual(checkExpression('screenSizeX/2').status, 'valid');
    expectEqual(checkExpression('screnSizeX/2').status, 'invalid');
    expectEqual(checkExpression('+10%', {relative: true}), {status: 'valid', value: null});
    expect(isRelativeAmount('-100') && isRelativeAmount('+ 10.5%') && !isRelativeAmount('10%'));
  }],
  ['shortcut problems', () => {
    expectEqual(keyProblem(''), 'Record a shortcut.');
    expectEqual(keyProblem('hyper+banana'), '“banana” isn\'t a key Slated knows.');
    expectEqual(keyProblem('hyper+a'), null);
    expectEqual(typingWarning('shift+a', null), 'Without Ctrl, Alt or Super this shortcut takes over typing A everywhere.');
    expectEqual(typingWarning('f5', null), null);
    expectEqual(typingWarning('a', {keys: 'ctrl+f4'}), null, 'modal keys are fine bare');
  }],
  ['action problems', () => {
    expectEqual(actionProblems({op: 'move', x: '', y: 'y', width: 'screenSizeX', height: 'screenSizeY'}).map(p => p.message)[0], 'X is empty.');
    expectEqual(actionProblems({op: 'chain', operations: []})[0].message, 'Add at least one operation to the chain.');
    expectEqual(actionProblems({op: 'chain', operations: [{op: 'focus', app: ''}]})[0].message, 'Step 1: Choose an app to focus.');
    expectEqual(actionProblems({op: 'by-orientation', landscape: half, portrait: {op: 'shell', command: ' '}})[0].message,
      'Portrait: Enter a command to run.');
    expectEqual(actionProblems({op: 'layout', name: 'Nope'}, new Set(['Coding']))[0], {severity: 'warning', message: 'There\'s no layout named “Nope” yet.'});
    expectEqual(actionProblems({op: 'layout', name: 'Coding'}, new Set(['Coding'])), []);
    expectEqual(actionProblems({op: 'open-url', url: 'https://'})[0].message, 'Enter a full URL, like https://example.com.');
    expectEqual(actionProblems({op: 'open-url', url: 'mailto:me@example.com'}), []);
    expectEqual(actionProblems({op: 'keystroke', keys: 'ctrl+wat'})[0].message, '“wat” isn\'t a key Slated knows.');
    expectEqual(actionProblems({op: 'grid', grids: {0: {width: 0, height: 2}}})[0].message, 'Grid sizes must be at least 1 × 1.');
    expectEqual(actionProblems({op: 'hide', app: []})[0].message, 'Choose at least one app.');
    expectEqual(actionProblems({op: 'switch'})[0].severity, 'warning');
    expectEqual(actionProblems({op: 'teleport'})[0].message, 'Slated doesn\'t know the operation “teleport”.');
    expectEqual(actionProblems(half), []);
  }],
  ['bindings with the same keys warn each other', () => {
    const issues = validate(config({
      bindings: [
        {id: 'a', name: 'One', keys: 'hyper+a', action: half},
        {id: 'b', name: 'Two', keys: 'hyper+a', action: half},
        {id: 'c', name: 'Off', keys: 'hyper+a', action: half, enabled: false},
      ],
    }));
    expectEqual(issues.filter(i => i.target === target.binding('a')).map(i => i.message), ['Same shortcut as “Two”. Only one of them can run.']);
    expectEqual(issues.filter(i => i.target === target.binding('c')), [], 'disabled bindings never clash');
  }],
  ['bindings limited to different apps never clash', () => {
    const issues = validate(config({
      bindings: [
        {id: 'a', name: 'Minecraft', keys: 'f', action: half, onlyInApps: ['org.prismlauncher.PrismLauncher']},
        {id: 'b', name: 'Proton game', keys: 'f', action: half, onlyInApps: ['steam_app_1']},
        {id: 'c', name: 'Also Minecraft', keys: 'f', action: half, onlyInApps: ['org.prismlauncher.PrismLauncher.desktop']},
        {id: 'd', name: 'Everywhere', keys: 'hyper+g', action: half},
        {id: 'e', name: 'In a game', keys: 'hyper+g', action: half, onlyInApps: ['steam_app_1']},
      ],
    }));
    const keys = id => issues.filter(i => i.target === target.binding(id) && i.field === 'keys').map(i => i.message);
    expectEqual(keys('a'), ['Same shortcut as “Also Minecraft”. Only one of them can run.']);
    expectEqual(keys('b'), [], 'another game: no clash, and a plain key is fine there');
    expectEqual(keys('d'), ['Same shortcut as “In a game”. Only one of them can run.'], 'everywhere overlaps every app');
  }],
  ['modifier keys, mouse buttons and the built-in shortcuts', () => {
    // The engine's config: the built-in shortcuts' defaults filled in, ids in Swift's upper case.
    const decoded = decodeConfiguration(JSON.stringify({
      bindings: [
        {keys: 'shift', action: half},
        {keys: 'mouse4', action: {op: 'hold', input: 'mouse:right'}},
        {keys: 'shift+cmd+v', action: half},
        {keys: 'hyper+esc', action: {op: 'stop-automations'}},
        {keys: 'f8', action: {op: 'wait', seconds: 1}},
      ],
    }));
    const issues = validate(decoded);
    const at = letter => {
      const id = decoded.bindings['abcde'.indexOf(letter)].id;
      return issues.filter(i => i.target === target.binding(id)).map(i => [i.severity, i.message]);
    };
    expectEqual(at('a'), [['error', MODIFIER_KEY_PROBLEM]]);
    expectEqual(at('b'), [['warning', GNOME_NOTES.mouseTrigger]], 'kept for the Mac, with the keyd hint');
    expectEqual(at('c'), [['warning', 'Same keys as the clipboard history shortcut. This shortcut wins, so Shift Super V won\'t open the clipboard history.']]);
    expectEqual(at('d'), [], 'running the same action is harmless');
    expectEqual(at('e'), [['warning', 'A wait on its own does nothing. Use it as a step in a sequence, between other steps.']]);
  }],
  ['automation action problems, as on the Mac', () => {
    const repeat = (action, extra = {}) => ({op: 'repeat', action, interval: 0.1, ...extra});
    expectEqual(actionProblems(repeat({op: 'click', button: 'left'})), []);
    expectEqual(actionProblems(repeat({op: 'click', button: 'left'}, {interval: 0.005})).map(p => p.message),
      ['Repeat at most 100 times a second (an interval of 10 ms or more).']);
    expectEqual(actionProblems(repeat(repeat({op: 'click'}))).map(p => p.message), ["An auto-repeat can't repeat another auto-repeat."]);
    expectEqual(actionProblems(repeat({op: 'wait', seconds: 1})), [{severity: 'warning', message: 'Repeating a wait does nothing. Repeat a click or a key.'}]);
    expectEqual(actionProblems(repeat({op: 'stop-automations'}))[0].message, 'This would stop itself the first time it runs.');
    expectEqual(actionProblems(repeat({op: 'keystroke', keys: 'ctrl+wat'}))[0].message, 'Repeated: “wat” isn\'t a key Slated knows.');
    expectEqual(actionProblems({op: 'hold', input: 'key:wat'})[0].message, '“wat” isn\'t a key Slated knows.');
    expectEqual(actionProblems({op: 'press', input: 'mouse:back', phase: 'down'})[0].message, 'Choose a mouse button or a key.');
    expectEqual(actionProblems({op: 'hold', input: 'key:rightShift'}), []);
    expectEqual(actionProblems({op: 'wait', seconds: 900})[0], {severity: 'warning', message: "That's a wait of over 10 minutes."});
    expectEqual(actionProblems({op: 'sequence', operations: [{op: 'press', input: 'key:w', phase: 'down'}, {op: 'click', button: 'left'}]}),
      [{severity: 'warning', message: 'W stays down after the last step. Add a Release step, or press the stop shortcut to let go.'}]);
    for (const op of ['click', 'stop-automations', 'clipboard-history']) expectEqual(actionProblems({op}), [], op);
  }],
  ['hotstring issues', () => {
    const issues = validate(config({
      hotstrings: [
        {id: '1', trigger: '', replacement: 'x'},
        {id: '2', trigger: ';a\nb', replacement: 'x'},
        {id: '3', trigger: ';sig', replacement: ''},
        {id: '4', trigger: ';SIG', replacement: 'y', caseSensitive: false},
        {id: '5', trigger: ';br', replacement: 'z'},
        {id: '6', trigger: ';brb', replacement: 'be right back'},
      ],
    }));
    const messages = id => issues.filter(i => i.target === target.hotstring(id)).map(i => i.message);
    expectEqual(messages('1'), ['Type a trigger.']);
    expectEqual(messages('2'), ["A trigger can't contain a line break."]);
    expectEqual(messages('3'), ['The replacement is empty, so the trigger will just be deleted.',
      'Another hotstring uses the same trigger. Only one of them will fire.']);
    expectEqual(messages('6'), ['“;br” fires as soon as it\'s typed, so this one never gets the chance.']);
  }],
  ['layout issues', () => {
    const issues = validate(config({
      layouts: [
        {name: '', apps: []},
        {name: 'Dup', apps: [{app: 'Files', operations: [{op: 'move', x: '(', y: '0', width: '1', height: '1'}]}]},
        {name: 'Dup', apps: []},
      ],
    }));
    expectEqual(issues.filter(i => i.target === target.layout('')).map(i => i.message), ['Name the layout.']);
    const dup = issues.filter(i => i.target === target.layout('Dup')).map(i => i.message);
    expect(dup.includes('Another layout already has this name.'), 'duplicate name');
    expect(dup.some(m => m.startsWith('Files: X')), 'operation errors name the app');
  }],
  ['items with errors keep their last saved version', () => {
    const saved = config({bindings: [{id: 'a', keys: 'hyper+a', action: half}], layouts: [{name: 'L', apps: []}]});
    const draft = config({
      bindings: [
        {id: 'a', keys: 'hyper+banana', action: half},
        {id: 'new', keys: '', action: half},
        {id: 'ok', keys: 'hyper+b', action: half},
      ],
      layouts: [{name: '', apps: []}],
    });
    const output = savable(draft, saved, validate(draft));
    expectEqual(output.bindings.map(b => [b.id, b.keys]), [['a', 'hyper+a'], ['ok', 'hyper+b']]);
    expectEqual(output.layouts, saved.layouts);
    const clean = config({bindings: [{id: 'ok', keys: 'hyper+b', action: half}]});
    expect(savable(clean, saved, validate(clean)) === clean, 'nothing to hold back: the draft itself');
  }],
  ['change descriptions for the log never include replacements', () => {
    const before = config({
      bindings: [{id: 'a', name: 'Left', keys: 'hyper+a', action: half}],
      hotstrings: [{id: 'h', trigger: ';sig', replacement: 'secret'}],
    });
    const after = JSON.parse(JSON.stringify(before));
    after.bindings[0].keys = 'hyper+s';
    after.bindings.push({id: 'b', keys: 'hyper+b', action: {op: 'undo'}, enabled: true});
    after.hotstrings[0].replacement = 'more secret';
    after.keyboard.capsLock = 'hyper';
    after.settings.undoMaxStackSize = 20;
    const changes = configChanges(before, after);
    expect(changes.includes('binding changed: Left (hyper+s)'), changes.join(' | '));
    expect(changes.some(c => c.startsWith('binding added: ') && c.endsWith('(hyper+b)')), 'added binding');
    expect(changes.includes('hotstring changed: ;sig'), 'hotstring by trigger');
    expect(changes.includes('keyboard: capsLock hyper, alone nothing, modifiers Ctrl+Alt+Shift+Super'));
    expect(changes.includes('setting undoMaxStackSize: 20'));
    expect(!changes.join(' ').includes('secret'), 'replacements stay out of the log');
  }],
  ['clipboard and automation settings changes are logged, app ids only counted', () => {
    const before = decodeConfiguration('{}');
    const after = JSON.parse(JSON.stringify(before));
    after.clipboard.shortcut = null;
    after.clipboard.excludedApps.push('org.keepassxc.KeePassXC');
    after.automation.maxRunMinutes = 5;
    const changes = configChanges(before, after);
    expectEqual(changes, [
      'clipboard: enabled true, shortcut none, maxItems 200, persist true, retentionDays 30, ignoreConcealed true, excludedApps 8, pasteAfterSelecting true',
      'automation: stopShortcut hyper+esc, stopOnAppSwitch true, maxRunMinutes 5, showIndicator true',
    ]);
    expect(!changes.join(' ').includes('keepassxc'), 'which apps is nobody else\'s business');
  }],
]);
