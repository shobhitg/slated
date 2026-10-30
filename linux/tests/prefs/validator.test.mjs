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

/** Each hotstring's validation messages, in order. */
function hotstringWarnings(hotstrings) {
  const issues = validate(config({hotstrings}));
  return hotstrings.map(h => issues.filter(i => i.target === target.hotstring(h.id)).map(i => i.message));
}

const HIGHER_IN_THE_LIST = 'Another hotstring with the same trigger is higher in the list, so this one never fires.';

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
    // What the Mac's check makes of them, as probed on macOS 26: macOS 14's URL(string:) percent-encodes
    // what doesn't belong in a path, query, fragment or user name, but a host or port must be RFC 3986's
    // (with IDNA for other characters in a host). SettingsUITests.swift checks the same URLs.
    const urls = {
      ok: ['https://www.google.com/search?q=hello world', 'https://example.com/a b', 'https://example.com/a\tb',
        'https://example.com/a\nb', 'https://example.com/ ', 'mailto:me @example.com', 'https://example.com/#a b',
        'https://user name@example.com/', 'file:///home/me/a b.txt', 'https://example.com?q=a b',
        'obsidian://open?vault=My Notes', 'https://example.com/\u00a0x', 'slack://open',
        'http://localhost:3000/', 'https://[::1]:8080/', 'https://example.com:/x', 'https://exa%41mple.com',
        'https://m\u00fcnchen.de/', 'https://\u4f8b\u3048.\u30c6\u30b9\u30c8/', 'https://exa\ufeffmple.com', 'https://exa\u200bmple.com'],
      bad: ['https://example.com ', ' https://example.com', 'https://exa mple.com', 'https://a\nb', 'https://', 'https:',
        'https:// example.com', 'ht tp://example.com', 'https://example.com:80 /x', 'https://exa\u00a0mple.com',
        'https://{host}/path', 'https://localhost:port/', 'https://example.com:8o8o/', 'https://[::1/', 'https://[::1]x/',
        'https://exa|mple.com/', 'https://exa%mple.com', 'https://exa\u0085mple.com', 'https://exa\u3000mple.com',
        'https://exa\uff1ample.com', 'https://exa\u200emple.com'],
    };
    for (const url of urls.ok) expectEqual(actionProblems({op: 'open-url', url}), [], JSON.stringify(url));
    for (const url of urls.bad) expectEqual(actionProblems({op: 'open-url', url}).length, 1, JSON.stringify(url));
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
        // Swift's Character.isNewline: also vertical tab, form feed, NEL and the Unicode separators.
        ...['\v', '\f', '\r', '\u0085', '\u2028', '\u2029'].map((c, i) => ({id: `nl${i}`, trigger: `;n${i}${c}x`, replacement: 'x'})),
      ],
    }));
    const messages = id => issues.filter(i => i.target === target.hotstring(id)).map(i => i.message);
    expectEqual(messages('1'), ['Type a trigger.']);
    expectEqual(messages('2'), ["A trigger can't contain a line break."]);
    for (let i = 0; i < 6; i++) expectEqual(messages(`nl${i}`), ["A trigger can't contain a line break."], `newline ${i}`);
    // “;sig” wins when typed so, and “;SIG” (any case) gets the rest: both fire.
    expectEqual(messages('3'), ['The replacement is empty, so the trigger will just be deleted.']);
    expectEqual(messages('4'), []);
    expectEqual(messages('6'), ['“;br” fires as soon as it\'s typed, so this one never gets the chance.']);
  }],
  ['of two hotstrings with the same trigger the first wins, only where both work', () => {
    // As in SettingsUITests.swift, without the Mac's “Drag this one above it”: this list can't be reordered.
    const mail = 'com.apple.mail';
    const mailOnly = {id: 'mailOnly', trigger: ';sig', replacement: 'Best, S', onlyInApps: [mail]};
    const global = {id: 'global', trigger: ';sig', replacement: 'S.'};
    // A per-app override: Mail gets its own, every other app the global one.
    expectEqual(hotstringWarnings([mailOnly, global]), [[], []]);
    // Below the global one, the Mail one never fires.
    expectEqual(hotstringWarnings([global, mailOnly]), [[], [HIGHER_IN_THE_LIST]]);
    // Each still fires somewhere: Mail gets the first, Notes the second.
    const mailAndNotes = {id: 'mailAndNotes', trigger: ';sig', replacement: 'S', onlyInApps: [mail, 'com.apple.Notes']};
    expectEqual(hotstringWarnings([mailOnly, mailAndNotes]), [[], []]);
    expectEqual(hotstringWarnings([mailAndNotes, mailOnly]), [[], [HIGHER_IN_THE_LIST]]);
    // Firing as soon as it's typed beats waiting for a delimiter, whatever the order.
    const waits = {id: 'waits', trigger: ';sig', replacement: 'W', fire: 'afterDelimiter'};
    const firesFirst = 'Another hotstring with the same trigger fires as soon as it\'s typed, so this one never gets the chance.';
    expectEqual(hotstringWarnings([waits, global]), [[firesFirst], []]);
    expectEqual(hotstringWarnings([global, waits]), [[], [firesFirst]]);
    // A case-sensitive “BTW” first leaves “btw” and “Btw” to the other.
    const upper = {id: 'upper', trigger: 'BTW', replacement: 'By the way'};
    const anyCase = {id: 'anyCase', trigger: 'btw', replacement: 'by the way', caseSensitive: false};
    expectEqual(hotstringWarnings([upper, anyCase]), [[], []]);
    expectEqual(hotstringWarnings([anyCase, upper]), [[], [HIGHER_IN_THE_LIST]]);
    // A whole-word one first leaves typing inside a word to the other.
    const word = {id: 'word', trigger: 'teh', replacement: 'the', wordBoundary: true};
    const inWords = {id: 'inWords', trigger: 'teh', replacement: 'the'};
    expectEqual(hotstringWarnings([word, inWords]), [[], []]);
    expectEqual(hotstringWarnings([inWords, word]), [[], [HIGHER_IN_THE_LIST]]);
    // One that's off shadows nothing.
    expectEqual(hotstringWarnings([{...global, enabled: false}, mailOnly]), [[], []]);
  }],
  ['a trigger that fires first says where, when that\'s only some of this one\'s apps', () => {
    // App filters hold Mac bundle ids, which the GNOME settings show as they are.
    const email = {id: 'email', trigger: ';email', replacement: 'a@b.c'};
    // Everywhere but Mail, “;e” fires first; in Mail “;email” works.
    const notInMail = {id: 'notInMail', trigger: ';e', replacement: 'e', exceptInApps: ['com.apple.mail']};
    expectEqual(hotstringWarnings([notInMail, email]),
      [[], ['“;e” fires as soon as it\'s typed, so this one only works in com.apple.mail.']]);
    // Only in Mail and TextEdit does “;e” fire first.
    const twoApps = {id: 'twoApps', trigger: ';e', replacement: 'e', onlyInApps: ['com.apple.mail', 'com.apple.TextEdit']};
    expectEqual(hotstringWarnings([twoApps, email])[1],
      ['In com.apple.TextEdit and com.apple.mail, “;e” fires as soon as it\'s typed, so this one never gets the chance there.']);
    // Where “;e” works in all of “;email”'s apps, “;email” never fires.
    const mailEmail = {id: 'mailEmail', trigger: ';email', replacement: 'a@b.c', onlyInApps: ['com.apple.mail']};
    expectEqual(hotstringWarnings([twoApps, mailEmail])[1],
      ['“;e” fires as soon as it\'s typed, so this one never gets the chance.']);
  }],
  ['a trigger typed on the way to another one fires first', () => {
    const shrug = {id: 'shrug', trigger: ';shrug', replacement: '¯\\_(ツ)_/¯'};
    const warnings = (other, longer = shrug) => hotstringWarnings([{id: 'other', replacement: 'x', ...other}, longer])[1];
    const sh = '“sh” fires as soon as it\'s typed, so this one never gets the chance.';
    expectEqual(warnings({trigger: 'sh'}), [sh]);
    expectEqual(warnings({trigger: 'SH', caseSensitive: false}), ['“SH” fires as soon as it\'s typed, so this one never gets the chance.']);
    // A whole-word trigger fires after the “;” but not after a letter.
    expectEqual(warnings({trigger: 'sh', wordBoundary: true}), [sh]);
    expectEqual(warnings({trigger: 'hr', wordBoundary: true}), []);
    // Waiting for a delimiter, or ending where this one does (the longer trigger wins), is fine.
    expectEqual(warnings({trigger: 'sh', fire: 'afterDelimiter'}), []);
    expectEqual(warnings({trigger: 'rug'}), []);
    // Kept to different apps, they never meet.
    expectEqual(warnings({trigger: 'sh', onlyInApps: ['com.apple.mail']},
      {id: 'notesShrug', trigger: ';shrug', replacement: 'x', onlyInApps: ['com.apple.Notes']}), []);
    // The one typed first is named: “;s” fires before “hr” is complete.
    expectEqual(hotstringWarnings([{id: 'hr', trigger: 'hr', replacement: 'x'}, {id: 's', trigger: ';s', replacement: 'x'}, shrug])[2],
      ['“;s” fires as soon as it\'s typed, so this one never gets the chance.']);
  }],
  ['hotstrings kept to different apps don\'t clash; overlapping ones do', () => {
    // The Mac's case (SettingsUITests.swift): its matcher only considers the hotstrings available in
    // the app in front, so each of these fires in its own app. GNOME expands none of the Mac-only ones.
    const mail = 'com.apple.mail';
    const messages = 'com.apple.MobileSMS';
    const hotstrings = [
      {id: 'mailSignature', trigger: ';sig', replacement: 'Best, S', onlyInApps: [mail]},
      {id: 'chatSignature', trigger: ';sig', replacement: 'cheers', onlyInApps: [messages]},
      {id: 'notInMail', trigger: ';e', replacement: 'e', exceptInApps: [mail]},
      {id: 'mailOnlyEmail', trigger: ';email', replacement: 'a@b.c', onlyInApps: [mail]},
    ];
    expectEqual(validate(config({hotstrings})), []);
    const issues = validate(config({hotstrings: [...hotstrings,
      {id: 'everywhere', trigger: ';sig', replacement: 'S.'},
      {id: 'chatEmail', trigger: ';email', replacement: 'a@b.c', onlyInApps: [messages]},
    ]}));
    const about = id => issues.filter(i => i.target === target.hotstring(id)).map(i => i.message);
    // Listed first, the app-limited ones win in their apps, and the global one fires everywhere else.
    for (const signature of ['mailSignature', 'chatSignature', 'everywhere']) expectEqual(about(signature), [], signature);
    expect(about('chatEmail').some(m => m.includes('“;e”')), '“;e” works in Messages, where ;email is');
    expectEqual(about('mailOnlyEmail'), [], 'not in Mail, where “;e” isn\'t');
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
    after.windows.undoMaxStackSize = 20;
    const changes = configChanges(before, after);
    expect(changes.includes('binding changed: Left (hyper+s)'), changes.join(' | '));
    expect(changes.some(c => c.startsWith('binding added: ') && c.endsWith('(hyper+b)')), 'added binding');
    expect(changes.includes('hotstring changed: ;sig'), 'hotstring by trigger');
    expect(changes.includes('keyboard: capsLock hyper, alone nothing, modifiers Ctrl+Alt+Shift+Super'));
    expect(changes.includes('setting undoMaxStackSize: 20'));
    expect(!changes.join(' ').includes('secret'), 'replacements stay out of the log');
    // Settings → Hotstrings' Expansion switch, named as on the Mac (ConfigDiff.swift).
    const off = JSON.parse(JSON.stringify(before));
    off.general.hotstringsEnabled = false;
    expectEqual(configChanges(before, off),
      ['general: launchAtLogin false, showActionHUD false, hotstringsEnabled false']);
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
