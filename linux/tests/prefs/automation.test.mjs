import {suite, expect, expectEqual} from './harness.mjs';
import {
  RECIPES, recipeById, recipeBindingName, recipeMatches, recipeBadge, recipeChip, rate, shortRate, modeTitle, jitterText,
  inputName, parseInput, sentence, facts, macroDuration, TIME_LIMITS, timeLimitTitle, MAX_ITEMS, RETENTION_DAYS,
  retentionTitle, withCurrent, automationBindings, bindingForRecipe, suggestedAutomationKeys, usedShortcutKeys,
  BUILT_IN_SHORTCUTS, builtInShortcut, sharesApps, normalizeAppId, appDisplayName, passwordManagerApps,
  whileHeldRepeat, sendsKeys, unreleasedPresses, whileHeldBehavior, whileHeldNote, GNOME_NOTES, clipboardSettings,
  automationSettings, defaultClipboardSettings, defaultAutomationSettings, MODIFIER_KEY_CHOICES, COMMON_GAME_KEYS,
} from '../../gnome-extension/lib/prefs/automation.js';
import {canonicalAction, decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {isValidKey} from '../../gnome-extension/lib/prefs/keys.js';
// The extension's own rules for while-held repeats: pure, so the preferences' copy is held to them.
import * as platform from '../../gnome-extension/lib/platform/automation.js';

const click = {op: 'click', button: 'left'};
const repeatClick = (extra = {}) => ({op: 'repeat', action: click, interval: 0.1, ...extra});

export default suite('Automation and clipboard settings', [
  ['the eleven recipes mirror the Mac app and are canonical actions', () => {
    expectEqual(RECIPES.map(r => r.id), ['auto-click-left', 'auto-click-right', 'double-click', 'click-times', 'hold-left', 'hold-right',
      'hold-w', 'toggle-sprint', 'toggle-crouch', 'spam-key', 'macro']);
    for (const r of RECIPES) {
      expectEqual(JSON.stringify(canonicalAction(r.action)), JSON.stringify(r.action), `${r.id} is written as config.json holds it`);
      expect(r.title && r.summary && r.detail && r.icon.endsWith('-symbolic'), `${r.id} is described`);
      expect(recipeMatches(r, r.action), `${r.id} matches its own action`);
      expectEqual(recipeBindingName(r, r.action), r.title, `${r.id} is named after itself`);
      expectEqual(recipeById(r.id), r);
    }
  }],
  ['recipes recognize adjusted versions and tell each other apart', () => {
    const r = id => recipeById(id);
    expect(recipeMatches(r('auto-click-left'), repeatClick({interval: 0.25, jitter: 0.2})), 'another speed still counts');
    expect(!recipeMatches(r('auto-click-left'), repeatClick({times: 5})), 'a counted burst is click-times');
    expect(recipeMatches(r('click-times'), repeatClick({times: 5})));
    expect(!recipeMatches(r('auto-click-left'), repeatClick({mode: 'while-held'})));
    expect(recipeMatches(r('auto-click-right'), {op: 'repeat', action: {op: 'click', button: 'right'}, interval: 0.5}));
    expect(recipeMatches(r('spam-key'), {op: 'repeat', action: {op: 'keystroke', keys: 'f'}, interval: 0.1, mode: 'while-held'}));
    expect(recipeMatches(r('hold-w'), {op: 'hold', input: 'key:space'}) && !recipeMatches(r('hold-w'), {op: 'hold', input: 'key:shift'}));
    expect(recipeMatches(r('toggle-sprint'), {op: 'hold', input: 'key:rightShift'}));
    expect(recipeMatches(r('toggle-crouch'), {op: 'hold', input: 'key:ctrl'}) && !recipeMatches(r('toggle-crouch'), {op: 'hold', input: 'key:shift'}));
    expect(recipeMatches(r('double-click'), {op: 'click', button: 'right', count: 2}));
    expect(recipeMatches(r('hold-left'), {op: 'hold', input: 'mouse:left'}) && !recipeMatches(r('hold-left'), {op: 'hold', input: 'mouse:right'}));
    expect(!recipeMatches(r('macro'), {op: 'sequence', operations: [click]}));
    expectEqual(recipeBindingName(r('click-times'), repeatClick({times: 25})), 'Click 25 Times');
    expectEqual(recipeBindingName(r('click-times'), repeatClick({times: 1})), 'Click 1 Time');
    expectEqual(recipeBindingName(r('spam-key'), {op: 'repeat', action: {op: 'keystroke', keys: 'f'}, interval: 0.05, mode: 'while-held'}), 'Spam F');
    expectEqual(recipeBindingName(r('hold-w'), {op: 'hold', input: 'key:space'}), 'Hold Space');
    expectEqual([recipeBadge(r('auto-click-left').action), recipeBadge(r('click-times').action), recipeBadge(r('double-click').action), recipeBadge(r('hold-w').action)],
      ['10/s', '×50', '2×', null]);
    expectEqual(RECIPES.map(x => recipeChip(x.action)), ['Toggle', 'Toggle', 'Instant', 'Auto-stops', 'Toggle', 'Toggle', 'Toggle', 'Toggle', 'Toggle',
      'While held', '4 steps']);
  }],
  ['automations are described in plain words', () => {
    expectEqual([rate(0.1), rate(0.05), rate(0.4), rate(2), rate(2.5), rate(0), rate(NaN)],
      ['10 per second', '20 per second', '2.5 per second', 'once every 2 seconds', 'once every 2.5 seconds', '—', '—']);
    expectEqual([shortRate(0.1), shortRate(0.4), shortRate(2)], ['10/s', '2.5/s', '1 per 2 s']);
    expectEqual([modeTitle('toggle'), modeTitle('while-held'), jitterText(0.15)], ['Toggle', 'While held', '±15%']);
    expectEqual([inputName('mouse:left'), inputName('key:w'), inputName('key:shift'), inputName('key:rightCmd'), inputName('key:ctrl+w'), inputName('nonsense')],
      ['Left Button', 'W', 'Shift', 'Right Super', 'Ctrl W', 'a key']);
    expectEqual(parseInput('MOUSE:Right'), {kind: 'mouse', button: 'right'});
    expectEqual(parseInput('key:Shift+W'), {kind: 'key', keys: 'shift+w'});
    expectEqual([parseInput('mouse:back'), parseInput('key:'), parseInput('w')], [null, null, null]);
    expectEqual(sentence(repeatClick()), 'Clicks the left button 10 times a second until pressed again');
    expectEqual(sentence(repeatClick({times: 50})), 'Clicks the left button 50 times, 10 times a second');
    expectEqual(sentence({op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05, mode: 'while-held', jitter: 0.2}),
      'Presses E 20 times a second while held, timing varied ±20%');
    expectEqual(sentence({op: 'repeat', action: {op: 'click', button: 'right', count: 2}, interval: 2}), 'Double-clicks the right button once every 2 seconds until pressed again');
    expectEqual(sentence({op: 'hold', input: 'mouse:right'}), 'Holds the right button down until pressed again');
    expectEqual(sentence({op: 'hold', input: 'key:shift'}), 'Holds Shift down until pressed again');
    expectEqual(sentence({op: 'click', button: 'middle', count: 3}), 'Clicks the middle button 3 times');
    expectEqual(sentence({op: 'press', input: 'key:w', phase: 'up'}), 'Releases W');
    expectEqual(sentence({op: 'wait', seconds: 0.25}), 'Waits 250 ms');
    expectEqual(sentence({op: 'stop-automations'}), 'Stops every automation and lets go of anything held');
    expectEqual(sentence(recipeById('macro').action), '4 steps: Press W → Wait 2 s → Release W → Click Left');
    expectEqual(facts(repeatClick({jitter: 0.1})), ['10/s', 'Toggle', '±10%']);
    expectEqual(facts(recipeById('macro').action), ['4 steps', '2 s']);
    expectEqual(macroDuration([{op: 'wait', seconds: 1}, click, {op: 'wait', seconds: 0.5}, 'wait 2']), 3.5);
  }],
  ['choices for time limits and clipboard history keep hand-edited values', () => {
    expectEqual(TIME_LIMITS.map(timeLimitTitle), ['No limit', '1 min', '5 min', '15 min', '30 min', '1 hour']);
    expectEqual(timeLimitTitle(2.5), '2.5 min');
    expectEqual(withCurrent(TIME_LIMITS, 10), [0, 1, 5, 10, 15, 30, 60]);
    expectEqual(withCurrent(TIME_LIMITS, 5), [...TIME_LIMITS]);
    expectEqual(RETENTION_DAYS.map(retentionTitle), ['1 day', '1 week', '30 days', '90 days', 'Forever']);
    expectEqual(withCurrent(RETENTION_DAYS, 14), [1, 7, 14, 30, 90, 0], 'forever stays last');
    expectEqual(withCurrent(MAX_ITEMS, 42), [42, 50, 100, 200, 500, 1000]);
  }],
  ['the settings defaults are the engine\'s', () => {
    const config = decodeConfiguration('{}');
    expectEqual(defaultClipboardSettings(), config.clipboard);
    expectEqual(defaultAutomationSettings(), config.automation);
    expectEqual(clipboardSettings({}), config.clipboard, 'a missing section is the defaults');
    expectEqual(automationSettings({automation: {maxRunMinutes: 5}}).maxRunMinutes, 5);
  }],
  ['the built-in shortcuts, and which keys are free for a new automation', () => {
    const config = decodeConfiguration(JSON.stringify({
      keyboard: {capsLock: 'hyper'},
      bindings: [
        {keys: 'f6', action: repeatClick()},
        {keys: 'hyper+1', action: {op: 'hold', input: 'key:w'}},
        {keys: 'f7', action: click, enabled: false},
      ],
    }));
    expectEqual(BUILT_IN_SHORTCUTS.map(b => [b.id, b.keys(config)]), [['clipboard', 'shift+cmd+v'], ['stopAutomations', 'hyper+esc']]);
    expectEqual(builtInShortcut('clipboard').keys({...config, clipboard: {...config.clipboard, enabled: false}}), null, 'off: no keys');
    expectEqual(builtInShortcut('stopAutomations').keys({...config, automation: {...config.automation, stopShortcut: null}}), null);
    const used = usedShortcutKeys(config);
    expect(used.has('f6') && used.has('hyper+1') && used.has('hyper+esc') && !used.has('f7'), [...used].join(' '));
    expectEqual(suggestedAutomationKeys(config, used), ['f7', 'hyper+2'], 'a free function key, then a free ✦ digit');
    expectEqual(suggestedAutomationKeys({...config, keyboard: {capsLock: 'off'}}, used), ['f7', 'f8']);
    expectEqual(automationBindings(config).length, 3);
    expectEqual(bindingForRecipe(config, recipeById('auto-click-left'))?.keys, 'f6');
    expectEqual(bindingForRecipe(config, recipeById('macro')), null);
  }],
  ['which apps a binding works in', () => {
    expect(sharesApps({}, {onlyInApps: ['steam_app_1']}), 'everywhere overlaps everything');
    expect(sharesApps({onlyInApps: ['org.prismlauncher.PrismLauncher.desktop']}, {onlyInApps: ['ORG.PRISMLAUNCHER.PRISMLAUNCHER']}));
    expect(!sharesApps({onlyInApps: ['steam_app_1']}, {onlyInApps: ['steam_app_2']}));
    expectEqual(normalizeAppId(' Firefox.desktop '), 'firefox');
    const names = {installed: [{id: 'org.mozilla.firefox', name: 'Firefox'}], recent: [{id: 'steam_app_1', name: 'steam_app_1'}]};
    expectEqual(appDisplayName('org.mozilla.firefox.desktop', names), 'Firefox');
    expectEqual(appDisplayName('steam_app_1', names), 'steam_app_1');
    expectEqual(appDisplayName('com.apple.keychainaccess', names), 'Keychain Access (Mac)');
    expectEqual(appDisplayName('unknown.app', names), 'unknown.app');
    const installed = [{id: 'org.keepassxc.KeePassXC', name: 'KeePassXC'}, {id: 'org.gnome.TextEditor', name: 'Text Editor'},
      {id: 'com.example.Vault', name: 'Password Vault'}];
    expectEqual(passwordManagerApps(installed).map(a => a.name), ['KeePassXC', 'Password Vault']);
  }],
  ['GNOME runs while-held repeats through key repeat, with the extension\'s rules', () => {
    const held = {op: 'repeat', action: click, interval: 0.1, mode: 'while-held'};
    const keyed = {op: 'repeat', action: {op: 'keystroke', keys: 'e'}, interval: 0.05, mode: 'while-held'};
    expectEqual(whileHeldRepeat({op: 'sequence', steps: [{action: held, keepWindow: false}]}), held);
    expectEqual(whileHeldBehavior({action: held}), 'key-repeat');
    expectEqual(whileHeldBehavior({action: keyed}), 'sends-keys');
    expectEqual(whileHeldBehavior({action: held, modal: {keys: 'ctrl+f4', toggle: false}}), 'modal');
    expectEqual(whileHeldBehavior({action: held}, 'toggle'), 'repeat-off');
    expectEqual(whileHeldBehavior({action: repeatClick()}), null);
    expectEqual(whileHeldNote({action: keyed}), GNOME_NOTES.sendsKeys);
    expectEqual(whileHeldNote({action: held}), GNOME_NOTES.whileHeld);
    expect(/keyd/.test(GNOME_NOTES.mouseTrigger) && /f13/.test(GNOME_NOTES.mouseTrigger));
    const samples = [click, held, keyed, {op: 'hold', input: 'KEY:shift'}, {op: 'hold', input: 'mouse:left'},
      {op: 'sequence', operations: [click, {op: 'insert-text', text: 'x'}]}, {op: 'by-orientation', landscape: {op: 'undo'}, portrait: held},
      {op: 'chain', operations: [keyed]}, {op: 'press', input: 'key:w', phase: 'down'}, {op: 'sequence', steps: [{action: keyed, keepWindow: true}]}];
    for (const action of samples) {
      expectEqual(sendsKeys(action), platform.sendsKeys(action), `sendsKeys ${JSON.stringify(action)}`);
      expectEqual(whileHeldRepeat(action), platform.whileHeldRepeat(action), `whileHeldRepeat ${JSON.stringify(action)}`);
    }
  }],
  ['macros warn about inputs left pressed', () => {
    expectEqual(unreleasedPresses(recipeById('macro').action.operations), []);
    expectEqual(unreleasedPresses([{op: 'press', input: 'key:w', phase: 'down'}, {op: 'press', input: 'mouse:left', phase: 'down'},
      {op: 'press', input: 'KEY:W', phase: 'up'}, {op: 'hold', input: 'key:e'}]), ['mouse:left']);
  }],
  ['key choices are keys Slated knows', () => {
    for (const {key} of MODIFIER_KEY_CHOICES) expect(isValidKey(key), key);
    for (const key of COMMON_GAME_KEYS) expect(isValidKey(key), key);
  }],
]);
