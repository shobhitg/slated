// Keys and key combinations: Slate's key vocabulary, config strings like "hyper+a", keycap labels,
// and the mapping from GDK key names to Slate key names used by the shortcut recorder.
//
// Pure ES module (no gi:// imports). Parsing and formatting prefer the engine (lib/core) and fall
// back to the local implementation below while the engine is still a stub; the two follow the same
// rules as Swift's KeyCombo (Sources/SlatedCore/Model/KeyCombo.swift).

import * as core from '../core/index.js';

/** Modifier tokens in canonical order. "cmd" is the Super key on Linux. */
export const MODIFIERS = ['ctrl', 'alt', 'shift', 'cmd'];
export const HYPER = ['ctrl', 'alt', 'shift', 'cmd'];
export const MEH = ['ctrl', 'alt', 'shift'];

/**
 * Modifier keys as keys of their own: held by automations ("key:shift" to hold Shift for sprint),
 * never shortcuts on their own. "cmd" is the Super key.
 */
export const MODIFIER_KEY_NAMES = ['shift', 'ctrl', 'alt', 'cmd', 'rightShift', 'rightCtrl', 'rightAlt', 'rightCmd'];

/** Extra mouse buttons, shortcuts on the Mac only: GNOME can't grab mouse buttons. */
export const MOUSE_BUTTON_KEYS = ['mouse3', 'mouse4', 'mouse5'];

const NAMED = (() => {
  const map = new Map();
  const names = [
    'left', 'right', 'up', 'down', 'return', 'tab', 'space', 'delete', 'forwardDelete', 'esc',
    'home', 'end', 'pageUp', 'pageDown', 'help', 'caps', 'mute', 'volumeUp', 'volumeDown',
    'backslash', 'padClear', 'padEnter', 'pad=', 'pad*', 'pad+', 'pad-', 'pad.', 'pad/',
    ...MODIFIER_KEY_NAMES, ...MOUSE_BUTTON_KEYS,
  ];
  for (const name of names) map.set(name.toLowerCase(), name);
  for (let i = 0; i <= 9; i++) map.set(`pad${i}`, `pad${i}`);
  for (let i = 1; i <= 20; i++) map.set(`f${i}`, `f${i}`);
  map.set('escape', 'esc');
  map.set('enter', 'return');
  map.set('backspace', 'delete');
  return map;
})();

/** Normalizes a key name: named keys get their canonical spelling, single characters are lowercased. */
export function canonicalKey(key) {
  const named = NAMED.get(String(key).toLowerCase());
  if (named) return named;
  return [...String(key)].length === 1 ? String(key).toLowerCase() : String(key);
}

export function isValidKey(key) {
  return NAMED.has(String(key).toLowerCase()) || [...String(key)].length === 1;
}

export function isFunctionKey(key) {
  return /^f\d+$/.test(key);
}

/** Shift, Ctrl, Alt, Super (cmd) and their right-hand twins, as key names. */
export function isModifierKey(key) {
  return MODIFIER_KEY_NAMES.includes(key);
}

/** mouse3 (middle), mouse4 and mouse5. */
export function isMouseButton(key) {
  return MOUSE_BUTTON_KEYS.includes(key);
}

/** Parses one modifier token, returning a list (hyper and meh expand). */
export function modifierToken(raw) {
  switch (String(raw).toLowerCase()) {
  case 'ctrl': case 'control': case '⌃': return ['ctrl'];
  case 'alt': case 'opt': case 'option': case '⌥': return ['alt'];
  case 'shift': case '⇧': return ['shift'];
  case 'cmd': case 'command': case '⌘': return ['cmd'];
  case 'fn': case 'function': return ['fn'];
  case 'hyper': case '✦': return [...HYPER];
  case 'meh': return [...MEH];
  default: return null;
  }
}

function orderModifiers(list) {
  const set = new Set(list);
  return ['fn', ...MODIFIERS].filter(m => set.has(m));
}

export function isHyper(modifiers) {
  return HYPER.every(m => modifiers.includes(m));
}

/** Local parser for "hyper+a", "ctrl+cmd+left", "cmd++" (⌘ and the + key), "pad+". */
export function parseKeyComboLocal(string) {
  const trimmed = String(string ?? '').trim();
  if (!trimmed) return null;
  let parts = trimmed.split('+');
  let key;
  if (trimmed.endsWith('+')) {
    // "cmd++" → ["cmd", "", ""]; "pad+" → ["pad", ""]: the last two parts are the key either way.
    parts = parts.slice(0, -2);
    key = trimmed.toLowerCase().endsWith('pad+') ? 'pad+' : '+';
  } else {
    key = parts.pop();
  }
  const modifiers = [];
  for (const part of parts) {
    if (!part.trim()) continue;
    const tokens = modifierToken(part.trim());
    if (!tokens) return null;
    modifiers.push(...tokens);
  }
  key = key.trim();
  if (!key) return null;
  return {key: canonicalKey(key), modifiers: orderModifiers(modifiers)};
}

/** Local formatter: KeyCombo → canonical config string ("hyper+a", "ctrl+alt+left"). */
export function formatKeyComboLocal(combo) {
  const mods = orderModifiers(combo.modifiers ?? []);
  let tokens;
  if (isHyper(mods)) {
    tokens = mods.includes('fn') ? ['fn', 'hyper'] : ['hyper'];
  } else {
    tokens = mods;
  }
  return [...tokens, combo.key].join('+');
}

function notImplemented(error) {
  return error?.kind === 'notImplemented';
}

/** "hyper+a" → {key, modifiers} | null. Uses the engine when it is implemented. */
export function parseKeyCombo(string) {
  try {
    const combo = core.parseKeyCombo(string);
    return combo ? {key: combo.key, modifiers: orderModifiers(combo.modifiers ?? [])} : null;
  } catch (error) {
    if (notImplemented(error)) return parseKeyComboLocal(string);
    return null;
  }
}

/** {key, modifiers} → "hyper+a". Uses the engine when it is implemented. */
export function formatKeyCombo(combo) {
  try {
    return core.formatKeyCombo(combo);
  } catch (error) {
    if (notImplemented(error)) return formatKeyComboLocal(combo);
    throw error;
  }
}

/**
 * Accepts a config `keys` value in either shape (the config string, or a KeyCombo object as the
 * engine may return it) and gives back the canonical config string, or '' for an empty combo.
 */
export function keysString(keys) {
  if (keys === undefined || keys === null) return '';
  if (typeof keys === 'string') {
    if (!keys.trim()) return '';
    const parsed = parseKeyCombo(keys);
    return parsed ? formatKeyCombo(parsed) : keys;
  }
  if (typeof keys === 'object') {
    if (!keys.key) return '';
    return formatKeyCombo({key: keys.key, modifiers: keys.modifiers ?? []});
  }
  return '';
}

/** The KeyCombo object for a config `keys` value (string or object); empty key when unset. */
export function keysCombo(keys) {
  if (keys && typeof keys === 'object') return {key: keys.key ?? '', modifiers: orderModifiers(keys.modifiers ?? [])};
  return parseKeyCombo(keys ?? '') ?? {key: '', modifiers: []};
}

/** The key of RuntimeStatus.hotkeys / status.json "hotkeys": modal key and a space, then the keys. */
export function statusKey(keys, modal) {
  const prefix = modal?.keys ? `${keysString(modal.keys)} ` : '';
  return prefix + keysString(keys);
}

// --- Display --------------------------------------------------------------------------------------

const DISPLAY = {
  left: '←', right: '→', up: '↑', down: '↓', return: 'Return', tab: 'Tab', space: 'Space',
  delete: 'Backspace', forwardDelete: 'Delete', esc: 'Esc', home: 'Home', end: 'End',
  pageUp: 'Page Up', pageDown: 'Page Down', padEnter: 'Enter', backslash: '\\', caps: 'Caps Lock',
  help: 'Help', mute: 'Mute', volumeUp: 'Volume Up', volumeDown: 'Volume Down', padClear: 'Num Lock',
  shift: 'Shift', ctrl: 'Ctrl', alt: 'Alt', cmd: 'Super', rightShift: 'Right Shift', rightCtrl: 'Right Ctrl',
  rightAlt: 'Right Alt', rightCmd: 'Right Super', mouse3: 'Middle Click', mouse4: 'Mouse 4', mouse5: 'Mouse 5',
};

/** How a Slate key name is labeled on a keycap on Linux: "A", "←", "Return", "F5", "Num 1". */
export function keyLabel(key) {
  if (DISPLAY[key]) return DISPLAY[key];
  if (/^pad/.test(key)) return `Num ${key.slice(3)}`;
  if (isFunctionKey(key)) return key.toUpperCase();
  return String(key).toUpperCase();
}

const MODIFIER_LABELS = {fn: 'Fn', ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', cmd: 'Super'};

/**
 * Keycaps for a combo, in order: [{label, hyper}]. All four of Ctrl, Alt, Shift and Super show as a
 * single ✦ (Hyper) cap, as on macOS.
 */
export function keycaps(combo) {
  const mods = orderModifiers(combo?.modifiers ?? []);
  const caps = [];
  if (mods.includes('fn')) caps.push({label: 'Fn', hyper: false});
  if (isHyper(mods)) {
    caps.push({label: '✦', hyper: true});
  } else {
    for (const m of MODIFIERS) if (mods.includes(m)) caps.push({label: MODIFIER_LABELS[m], hyper: false});
  }
  if (combo?.key) caps.push({label: keyLabel(combo.key), hyper: false});
  return caps;
}

/** A one-line label: "✦ A", "Ctrl Alt ←", or "Ctrl F4 → 1" with a modal key. */
export function comboLabel(keys, modal) {
  const text = combo => keycaps(keysCombo(combo)).map(c => c.label).join(' ');
  const main = text(keys);
  return modal?.keys ? `${text(modal.keys)} → ${main}` : main;
}

/** "Hyper Left Arrow", "Control Super K", for screen readers and tooltips. */
export function spokenCombo(combo) {
  const mods = orderModifiers(combo?.modifiers ?? []);
  const words = [];
  if (mods.includes('fn')) words.push('Function');
  if (isHyper(mods)) words.push('Hyper');
  else for (const [m, w] of [['ctrl', 'Control'], ['alt', 'Alt'], ['shift', 'Shift'], ['cmd', 'Super']]) if (mods.includes(m)) words.push(w);
  const names = {left: 'Left Arrow', right: 'Right Arrow', up: 'Up Arrow', down: 'Down Arrow', esc: 'Escape'};
  if (combo?.key) words.push(names[combo.key] ?? keyLabel(combo.key));
  return words.join(' ');
}

// --- Recording (GDK key names → Slate key names) ---------------------------------------------------

const GDK_NAMES = {
  apostrophe: "'", semicolon: ';', comma: ',', period: '.', slash: '/', minus: '-', equal: '=',
  bracketleft: '[', bracketright: ']', backslash: 'backslash', grave: '`',
  Left: 'left', Right: 'right', Up: 'up', Down: 'down', Return: 'return', KP_Enter: 'padEnter',
  ISO_Enter: 'return', Tab: 'tab', ISO_Left_Tab: 'tab', space: 'space', BackSpace: 'delete',
  Delete: 'forwardDelete', Escape: 'esc', Home: 'home', End: 'end', Page_Up: 'pageUp', Prior: 'pageUp',
  Page_Down: 'pageDown', Next: 'pageDown', Help: 'help', Num_Lock: 'padClear',
  KP_Decimal: 'pad.', KP_Separator: 'pad.', KP_Multiply: 'pad*', KP_Add: 'pad+', KP_Divide: 'pad/',
  KP_Subtract: 'pad-', KP_Equal: 'pad=',
  // Keypad keys with Num Lock off report their navigation names.
  KP_Insert: 'pad0', KP_End: 'pad1', KP_Down: 'pad2', KP_Next: 'pad3', KP_Page_Down: 'pad3',
  KP_Left: 'pad4', KP_Begin: 'pad5', KP_Right: 'pad6', KP_Home: 'pad7', KP_Up: 'pad8', KP_Prior: 'pad9',
  KP_Page_Up: 'pad9', KP_Delete: 'pad.',
  XF86AudioMute: 'mute', XF86AudioRaiseVolume: 'volumeUp', XF86AudioLowerVolume: 'volumeDown',
};

const MODIFIER_KEYS = new Set([
  'Control_L', 'Control_R', 'Shift_L', 'Shift_R', 'Alt_L', 'Alt_R', 'Super_L', 'Super_R', 'Hyper_L',
  'Hyper_R', 'Meta_L', 'Meta_R', 'ISO_Level3_Shift', 'ISO_Level5_Shift', 'Caps_Lock', 'Shift_Lock',
  'ISO_Next_Group', 'Mode_switch',
]);

/** True for keys that only modify others (Ctrl, Shift, Super, Hyper, Caps Lock…). */
export function isModifierKeyName(gdkName) {
  return MODIFIER_KEYS.has(gdkName);
}

/**
 * The Slate key name for a pressed key, from its GDK key name (`Gdk.keyval_name`) at level 0 (no
 * Shift), plus the character it types (`Gdk.keyval_to_unicode`) for layout-specific keys. Returns
 * null for keys that can't be part of a shortcut.
 */
export function keyNameFromGdk(gdkName, character = '') {
  if (!gdkName) return null;
  if (MODIFIER_KEYS.has(gdkName)) return null;
  if (GDK_NAMES[gdkName]) return GDK_NAMES[gdkName];
  if (/^F([1-9]|1\d|20)$/.test(gdkName)) return gdkName.toLowerCase();
  if (/^KP_\d$/.test(gdkName)) return `pad${gdkName.slice(3)}`;
  if (/^[a-zA-Z0-9]$/.test(gdkName)) return gdkName.toLowerCase();
  const ch = String(character ?? '');
  if ([...ch].length === 1 && ch.trim() && ch !== '\u0000' && ch.codePointAt(0) >= 0x20) {
    if (ch === '\\') return 'backslash';
    return canonicalKey(ch);
  }
  return null;
}

/**
 * Modifier tokens from a GDK modifier state. `masks` holds the Gdk.ModifierType values (passed in
 * so this stays free of gi:// imports): {SHIFT, CONTROL, ALT, SUPER, HYPER, META}.
 *
 * Caps Lock as Hyper reports HYPER (GNOME's caps:hyper option) or all four of Ctrl, Alt, Shift and
 * Super (keyd); both record as ✦.
 *
 * `held` (optional) is the set of modifier keys being held, by GDK key name. In many layouts
 * caps:hyper puts Hyper on the same modifier as Super (Mod4), and GTK may then report both masks,
 * or only SUPER, whichever of the two keys is down. The key actually held tells them apart:
 * Hyper_L is Caps Lock, Super_L/R the Super keys.
 */
export function modifiersFromState(state, masks, held = null) {
  const mods = new Set();
  if (state & masks.CONTROL) mods.add('ctrl');
  if (state & masks.ALT) mods.add('alt');
  if (state & masks.SHIFT) mods.add('shift');
  const superMask = Boolean(state & masks.SUPER);
  let hyper = Boolean(masks.HYPER && (state & masks.HYPER));
  if (held && (superMask || hyper)) {
    if (held.has('Hyper_L') || held.has('Hyper_R')) hyper = true;
    else if (held.has('Super_L') || held.has('Super_R')) hyper = false;
  }
  if (superMask) mods.add('cmd');
  if (hyper) for (const m of HYPER) mods.add(m);
  if (masks.META && (state & masks.META) && !mods.has('alt') && !mods.has('cmd')) mods.add('alt');
  return orderModifiers([...mods]);
}

const HELD_KEY_MODIFIERS = {
  Control_L: ['ctrl'], Control_R: ['ctrl'], Shift_L: ['shift'], Shift_R: ['shift'], Alt_L: ['alt'], Alt_R: ['alt'],
  Meta_L: ['alt'], Meta_R: ['alt'], Super_L: ['cmd'], Super_R: ['cmd'], Hyper_L: HYPER, Hyper_R: HYPER,
};

/**
 * The modifiers that the held modifier keys stand for, for showing them live while recording (a
 * key event's state lags behind the modifier keys: it's the state from before the event).
 */
export function modifiersFromHeldKeys(held) {
  const mods = new Set();
  for (const name of held ?? []) for (const m of HELD_KEY_MODIFIERS[name] ?? []) mods.add(m);
  return orderModifiers([...mods]);
}

/** Global shortcuts need Ctrl, Alt or Super unless they're on a function key; else they'd swallow typing. */
export function isAcceptableGlobalShortcut(combo) {
  return isFunctionKey(combo.key) || (combo.modifiers ?? []).some(m => m === 'ctrl' || m === 'alt' || m === 'cmd');
}
