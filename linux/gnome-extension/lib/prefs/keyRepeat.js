// Settings → Keyboard → Key repeat: what the page shows and changes (ui/keyboard.js draws it). Port of
// the Mac's Key repeat group. config.json's keyboard.keyRepeat holds milliseconds; the running
// extension applies them to GNOME (lib/platform/keyRepeat.js) and reports back in status.json.
//
// Pure ES module.

import {KEY_REPEAT_RANGES, clampKeyRepeat} from '../core/index.js';

export {KEY_REPEAT_RANGES};

/** GNOME's default, for turning the switch on when this computer's setting can't be read. */
export const GNOME_DEFAULT_KEY_REPEAT = Object.freeze({delay: 500, interval: 30});

/** The repeat rate slider runs in repeats per second (faster to the right): 2 to 66. */
export const RATE_RANGE = Object.freeze([
  Math.ceil(1000 / KEY_REPEAT_RANGES.interval[1]),
  Math.floor(1000 / KEY_REPEAT_RANGES.interval[0]),
]);

/** Repeats per second at `interval` ms, rounded. */
export function repeatsPerSecond(interval) {
  return Math.round(1000 / interval);
}

/** The interval for a position of the rate slider (repeats per second). */
export function intervalForRate(rate) {
  return clampKeyRepeat({delay: KEY_REPEAT_RANGES.delay[0], interval: 1000 / Math.max(1, rate)}).interval;
}

/** "200 ms" */
export function delayLabel(delay) {
  return `${delay} ms`;
}

/** "59 per second (17 ms)" */
export function rateLabel(interval) {
  return `${repeatsPerSecond(interval)} per second (${interval} ms)`;
}

/** `config` with keyRepeat set (clamped), or removed when `value` is null (GNOME's own setting). */
export function withKeyRepeat(config, value) {
  const keyboard = {...config.keyboard};
  const clamped = value ? clampKeyRepeat(value) : null;
  if (clamped) keyboard.keyRepeat = clamped;
  else delete keyboard.keyRepeat;
  return {...config, keyboard};
}

/**
 * The page's status line: {label, detail, style}, a short pill (pill styles) and a sentence.
 * `configured` is the saved keyRepeat (or null), `status` what the extension reports.
 */
export function keyRepeatStatusLine(configured, status) {
  if (!configured) return {label: 'Off', detail: 'GNOME’s own setting is left as it is.', style: 'dim'};
  if (!status?.running) {
    return {label: 'Saved', detail: 'Slated applies it once it’s on: turn it on in the Extensions app.', style: 'warning'};
  }
  const reported = status.keyRepeat ?? {};
  const same = reported.delay === configured.delay && reported.interval === configured.interval;
  if (same && reported.state === 'applied') return {label: 'Applied', detail: 'GNOME repeats keys this way now. Hold a key below to try it.', style: 'success'};
  if (same && reported.state === 'failed') return {label: 'Not applied', detail: 'GNOME didn’t take the change: Show Log in Slated’s menu says why.', style: 'error'};
  return {label: 'Applying', detail: 'Slated is passing the change to GNOME.', style: 'dim'};
}
