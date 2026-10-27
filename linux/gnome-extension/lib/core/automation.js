// Game automation's pure parts (port of Automation.swift and RepeatSchedule.swift).
//
// A synthetic input is what `press` and `hold` act on: a mouse button or a key combo, written
// "mouse:right", "key:w" or "key:shift+w" in config.json. A repeat schedule holds the timing rules of
// an auto-repeat (`repeat`): how long until the next run, and whether there is one.

import {formatKeyCombo, isValidKey, parseKeyCombo} from './keys.js';
import {dropFirst} from './model.js';
import {hasPrefix, lowercased, trimWhitespace} from './text.js';

/** Mouse buttons Slated can click, press or hold (MouseButton). */
export const MOUSE_BUTTONS = Object.freeze(['left', 'right', 'middle']);
/** How an auto-repeat runs (RepeatMode): the trigger toggles it, or it runs while the trigger is held. */
export const REPEAT_MODES = Object.freeze(['toggle', 'while-held']);
/** Press or release, for macros (PressPhase). */
export const PRESS_PHASES = Object.freeze(['down', 'up']);

/**
 * Parses an input like "mouse:right", "key:w" or "key:shift+w" (SyntheticInput(string:)). The prefix
 * is case-insensitive; the key must be one Slate knows.
 * @returns {{kind: "mouse", button: string} | {kind: "key", combo: {key: string, modifiers: string[]}} | null}
 */
export function parseSyntheticInput(raw) {
  if (typeof raw !== 'string') return null;
  const s = trimWhitespace(raw);
  const lower = lowercased(s);
  if (hasPrefix(lower, 'mouse:')) {
    const button = dropFirst(lower, 'mouse:'.length);
    return MOUSE_BUTTONS.includes(button) ? {kind: 'mouse', button} : null;
  }
  if (hasPrefix(lower, 'key:')) {
    const combo = parseKeyCombo(dropFirst(s, 'key:'.length));
    if (combo === null || !isValidKey(combo.key)) return null;
    return {kind: 'key', combo};
  }
  return null;
}

/** The canonical text of a parsed input: "mouse:right", "key:shift+w". */
export function formatSyntheticInput(input) {
  return input.kind === 'mouse' ? `mouse:${input.button}` : `key:${formatKeyCombo(input.combo)}`;
}

// Swift's max/min: with a NaN they return whichever argument the comparison picks, unlike Math.max.
const swiftMax = (x, y) => (y >= x ? y : x);
const swiftMin = (x, y) => (y < x ? y : x);

/**
 * The timing rules of an auto-repeat (RepeatSchedule). Pure, so the GNOME timer code stays trivial.
 * - `interval`: seconds between runs, at least 0.01 (100 runs a second); not finite means 0.1.
 * - `times`: total runs before it stops by itself (at least 1), or null to run until stopped.
 * - `jitter`: each interval varies randomly by up to this fraction, clamped to 0…0.5.
 */
export class RepeatSchedule {
  constructor({interval, times = null, jitter = 0} = {}) {
    this.interval = swiftMax(Number.isFinite(interval) ? interval : 0.1, 0.01);
    this.times = times === null || times === undefined ? null : swiftMax(Number(times), 1);
    this.jitter = swiftMin(swiftMax(Number.isFinite(jitter) ? jitter : 0, 0), 0.5);
  }

  /** Whether another run should follow after `runs` runs so far. */
  shouldRunAgain(runs) {
    return this.times === null ? true : runs < this.times;
  }

  /** Seconds to wait before the next run. `random` is uniform in 0…1 (injected for tests). */
  nextInterval(random) {
    const r = swiftMin(swiftMax(random, 0), 1);
    return swiftMax(0.01, this.interval * (1 - this.jitter + 2 * this.jitter * r));
  }
}
