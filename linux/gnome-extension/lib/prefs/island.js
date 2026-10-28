// Settings → General's island group without the GTK parts (port of GeneralPane.swift's IslandCard):
// config.json's `island` section with its defaults, the cheat-sheet delays on offer, which rows apply,
// and what the delay row says when keyd's tap for Escape follows the delay.
//
// Pure ES module.

import {isObject} from './util.js';

/** Swift's IslandSettings defaults. */
export function defaultIslandSettings() {
  return {enabled: true, cheatSheet: true, cheatSheetDelay: 0.5, showFailures: true};
}

/** The configuration's island settings with every default filled in. */
export function islandSettings(config) {
  return {...defaultIslandSettings(), ...(isObject(config?.island) ? config.island : {})};
}

/** The Mac's cheat-sheet delays, in seconds. */
export const CHEAT_SHEET_DELAYS = Object.freeze([
  Object.freeze({id: 0.3, label: 'Short'}), Object.freeze({id: 0.5, label: 'Medium'}), Object.freeze({id: 0.8, label: 'Long'}),
]);

/** The delay choices, plus the current value when a hand edit set another one (as on the Mac). */
export function cheatSheetDelayItems(value) {
  return CHEAT_SHEET_DELAYS.some(i => i.id === value) ? [...CHEAT_SHEET_DELAYS] : [...CHEAT_SHEET_DELAYS, {id: value, label: `${value} seconds`}];
}

/** Which rows can be changed: the others need the island on, and the delay needs the cheat sheet too. */
export function islandRowsSensitive(island) {
  return {cheatSheet: island.enabled, cheatSheetDelay: island.enabled && island.cheatSheet, showFailures: island.enabled};
}

const DELAY_TEXT = 'How long to hold before the shortcuts appear. Quick taps never show them.';

/**
 * The delay row's subtitle. With keyd's tap for Escape, the delay is also the longest hold that still
 * sends Escape, and keyd's file is root's: linux/install.sh writes it from config.json.
 */
export function cheatSheetDelayText(keydTap) {
  if (!keydTap) return DELAY_TEXT;
  return `${DELAY_TEXT} Letting go after a longer hold doesn't send Escape. keyd applies it: run linux/install.sh --hyper-keyd again after changing this.`;
}
