import {suite, expect, expectEqual} from './harness.mjs';
import {
  parseKeyComboLocal, formatKeyComboLocal, parseKeyCombo, formatKeyCombo, keysString, keysCombo, keycaps, comboLabel,
  keyLabel, keyNameFromGdk, modifiersFromState, modifiersFromHeldKeys, isAcceptableGlobalShortcut, statusKey, isModifierKeyName,
  spokenCombo,
} from '../../gnome-extension/lib/prefs/keys.js';

// Gdk.ModifierType values (GTK 4): passed in so keys.js stays free of gi:// imports.
const MASKS = {SHIFT: 1, CONTROL: 4, ALT: 8, SUPER: 1 << 26, HYPER: 1 << 27, META: 1 << 28};

export default suite('Keys', [
  ['parses config key strings like Swift KeyCombo', () => {
    expectEqual(parseKeyComboLocal('hyper+a'), {key: 'a', modifiers: ['ctrl', 'alt', 'shift', 'cmd']});
    expectEqual(parseKeyComboLocal('cmd+ctrl+left'), {key: 'left', modifiers: ['ctrl', 'cmd']});
    expectEqual(parseKeyComboLocal('cmd++'), {key: '+', modifiers: ['cmd']});
    expectEqual(parseKeyComboLocal('pad+'), {key: 'pad+', modifiers: []});
    expectEqual(parseKeyComboLocal('ctrl+pad+'), {key: 'pad+', modifiers: ['ctrl']});
    expectEqual(parseKeyComboLocal('meh+Escape'), {key: 'esc', modifiers: ['ctrl', 'alt', 'shift']});
    expectEqual(parseKeyComboLocal("cmd+shift+'"), {key: "'", modifiers: ['shift', 'cmd']});
    expectEqual(parseKeyComboLocal('super+a'), null, '"super" isn\'t a Slate modifier');
    expectEqual(parseKeyComboLocal(''), null);
  }],
  ['formats canonical config strings', () => {
    expectEqual(formatKeyComboLocal({key: 'a', modifiers: ['cmd', 'shift', 'alt', 'ctrl']}), 'hyper+a');
    expectEqual(formatKeyComboLocal({key: 'a', modifiers: ['fn', 'ctrl', 'alt', 'shift', 'cmd']}), 'fn+hyper+a');
    expectEqual(formatKeyComboLocal({key: 'left', modifiers: ['cmd', 'ctrl']}), 'ctrl+cmd+left');
    // Through the engine facade (the engine when implemented, else the local rules): same results.
    expectEqual(formatKeyCombo(parseKeyCombo('ctrl+alt+shift+cmd+return')), 'hyper+return');
  }],
  ['normalizes keys given as strings or objects', () => {
    expectEqual(keysString('ctrl+alt+shift+cmd+A'), 'hyper+a');
    expectEqual(keysString({key: 'f4', modifiers: ['ctrl']}), 'ctrl+f4');
    expectEqual(keysString(''), '');
    expectEqual(keysString(undefined), '');
    expectEqual(keysCombo('hyper+tab'), {key: 'tab', modifiers: ['ctrl', 'alt', 'shift', 'cmd']});
    expectEqual(keysCombo(''), {key: '', modifiers: []});
    expectEqual(statusKey('hyper+1', {keys: 'ctrl+f4', toggle: false}), 'ctrl+f4 hyper+1');
    expectEqual(statusKey('hyper+1', null), 'hyper+1');
  }],
  ['labels keycaps the GNOME way, with ✦ for Hyper', () => {
    expectEqual(keycaps(keysCombo('hyper+a')), [{label: '✦', hyper: true}, {label: 'A', hyper: false}]);
    expectEqual(keycaps(keysCombo('ctrl+cmd+left')).map(c => c.label), ['Ctrl', 'Super', '←']);
    expectEqual(keycaps(keysCombo('meh+pageDown')).map(c => c.label), ['Ctrl', 'Alt', 'Shift', 'Page Down']);
    expectEqual(comboLabel('hyper+1', {keys: 'ctrl+f4'}), 'Ctrl F4 → ✦ 1');
    expectEqual(keyLabel('delete'), 'Backspace');
    expectEqual(keyLabel('forwardDelete'), 'Delete');
    expectEqual(keyLabel('pad5'), 'Num 5');
    expectEqual(spokenCombo(keysCombo('hyper+left')), 'Hyper Left Arrow');
  }],
  ['maps GDK key names to Slate key names', () => {
    const cases = {
      a: 'a', A: 'a', 7: '7', apostrophe: "'", semicolon: ';', bracketleft: '[', backslash: 'backslash',
      Left: 'left', Return: 'return', KP_Enter: 'padEnter', Tab: 'tab', ISO_Left_Tab: 'tab', space: 'space',
      BackSpace: 'delete', Delete: 'forwardDelete', Escape: 'esc', Page_Up: 'pageUp', Next: 'pageDown',
      F5: 'f5', F20: 'f20', KP_1: 'pad1', KP_End: 'pad1', KP_Add: 'pad+', XF86AudioMute: 'mute',
    };
    for (const [gdk, slate] of Object.entries(cases)) expectEqual(keyNameFromGdk(gdk), slate, gdk);
    expectEqual(keyNameFromGdk('eacute', 'é'), 'é', 'layout characters come from the keyval\'s character');
    expectEqual(keyNameFromGdk('Control_L'), null);
    expectEqual(keyNameFromGdk('Hyper_L'), null);
    expectEqual(keyNameFromGdk('F25'), null);
    expect(isModifierKeyName('Super_R') && isModifierKeyName('Caps_Lock') && !isModifierKeyName('a'));
  }],
  ['reads modifiers from a GDK state; Caps Lock as Hyper records ✦ in both modes', () => {
    expectEqual(modifiersFromState(MASKS.CONTROL | MASKS.SHIFT, MASKS), ['ctrl', 'shift']);
    expectEqual(modifiersFromState(MASKS.SUPER, MASKS), ['cmd']);
    // xkb mode (caps:hyper): the Hyper modifier.
    expectEqual(modifiersFromState(MASKS.HYPER, MASKS), ['ctrl', 'alt', 'shift', 'cmd']);
    // keyd mode: all four real modifiers.
    expectEqual(modifiersFromState(MASKS.CONTROL | MASKS.ALT | MASKS.SHIFT | MASKS.SUPER, MASKS), ['ctrl', 'alt', 'shift', 'cmd']);
    expectEqual(modifiersFromState(MASKS.META, MASKS), ['alt'], 'Meta alone counts as Alt');
  }],
  ['tells Caps Lock from Super by the key held when Hyper shares Super\'s modifier', () => {
    const shared = MASKS.SUPER | MASKS.HYPER;
    // GTK reports both masks for either key: the held key decides.
    expectEqual(modifiersFromState(shared, MASKS, new Set(['Super_L'])), ['cmd'], 'Super, not ✦');
    expectEqual(modifiersFromState(shared | MASKS.SHIFT, MASKS, new Set(['Super_R', 'Shift_L'])), ['shift', 'cmd']);
    expectEqual(modifiersFromState(shared, MASKS, new Set(['Hyper_L'])), ['ctrl', 'alt', 'shift', 'cmd'], 'Caps Lock');
    // GTK reports only SUPER for Caps Lock: still ✦.
    expectEqual(modifiersFromState(MASKS.SUPER, MASKS, new Set(['Hyper_L'])), ['ctrl', 'alt', 'shift', 'cmd']);
    // Both keys down: ✦ (which includes Super).
    expectEqual(modifiersFromState(shared, MASKS, new Set(['Hyper_L', 'Super_L'])), ['ctrl', 'alt', 'shift', 'cmd']);
    // A stale held key doesn't add modifiers the state doesn't have.
    expectEqual(modifiersFromState(MASKS.CONTROL, MASKS, new Set(['Hyper_L'])), ['ctrl']);
    // No key seen (held before recording started): the masks as reported.
    expectEqual(modifiersFromState(shared, MASKS, new Set()), ['ctrl', 'alt', 'shift', 'cmd']);
    // keyd sends four real modifier keys.
    expectEqual(modifiersFromHeldKeys(new Set(['Control_L', 'Alt_L', 'Shift_L', 'Super_L'])), ['ctrl', 'alt', 'shift', 'cmd']);
    expectEqual(modifiersFromHeldKeys(new Set(['Hyper_L'])), ['ctrl', 'alt', 'shift', 'cmd']);
    expectEqual(modifiersFromHeldKeys(new Set(['Meta_L', 'Caps_Lock'])), ['alt']);
    expectEqual(modifiersFromHeldKeys(null), []);
  }],
  ['global shortcuts need Ctrl, Alt or Super unless they are function keys', () => {
    expect(isAcceptableGlobalShortcut({key: 'a', modifiers: ['ctrl']}));
    expect(isAcceptableGlobalShortcut({key: 'f5', modifiers: []}));
    expect(!isAcceptableGlobalShortcut({key: 'a', modifiers: ['shift']}));
  }],
]);
