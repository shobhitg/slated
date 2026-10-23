// Key combos as the runtime handles them: tolerant of both config strings ("hyper+a") and decoded
// KeyCombo objects ({key, modifiers}), whichever form the core hands back.

import * as Core from '../core/index.js';

const MODIFIER_ORDER = ['fn', 'ctrl', 'alt', 'shift', 'cmd'];
const HYPER = ['ctrl', 'alt', 'shift', 'cmd'];

/** A KeyCombo object from a config string or KeyCombo, or null if it isn't one. */
export function comboOf(keys, core = Core) {
  if (!keys) return null;
  if (typeof keys === 'string') return core.parseKeyCombo(keys) ?? null;
  if (typeof keys === 'object' && typeof keys.key === 'string') {
    return {key: keys.key, modifiers: Array.isArray(keys.modifiers) ? [...keys.modifiers] : []};
  }
  return null;
}

/** "hyper+a" style text without the core (used when the core can't format, and in tests). */
export function fallbackComboText(combo) {
  const mods = new Set(combo.modifiers ?? []);
  const tokens = [];
  if (HYPER.every((m) => mods.has(m))) {
    if (mods.has('fn')) tokens.push('fn');
    tokens.push('hyper');
  } else {
    for (const m of MODIFIER_ORDER) if (mods.has(m)) tokens.push(m);
  }
  tokens.push(combo.key);
  return tokens.join('+');
}

/** Canonical config text for a combo, e.g. "hyper+a". */
export function comboText(keys, core = Core) {
  if (!keys) return '';
  const combo = typeof keys === 'string' ? safe(() => core.parseKeyCombo(keys)) : keys;
  if (!combo) return String(keys);
  return safe(() => core.formatKeyCombo(combo)) ?? fallbackComboText(combo);
}

/** A Slate modal key `{keys, toggle}` normalized, or null. */
export function modalOf(modal, core = Core) {
  if (!modal || typeof modal !== 'object') return null;
  const keys = comboOf(modal.keys, core);
  return keys ? {keys, toggle: !!modal.toggle} : null;
}

/**
 * The key a binding is known by in statuses and logs: the combo text, prefixed by the modal key's
 * text and a space for modal bindings ("ctrl+alt+f4 1"), as on macOS.
 */
export function bindingKey(keys, modal, core = Core) {
  const prefix = modal ? `${comboText(modal.keys, core)} ` : '';
  return `${prefix}${comboText(keys, core)}`;
}

function safe(body) {
  try {
    return body();
  } catch {
    return null;
  }
}
