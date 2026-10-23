// Game automation (AutoHotkey-style): auto-repeats and held mouse buttons or keys, with the macOS
// app's safety rails. A port of Sources/Slated/Engine/AutomationEngine.swift.
//
// - `repeat` runs its action right away, then on GLib timeouts rescheduled after every run, so each
//   interval gets its own jitter (RepeatSchedule in the core holds the timing rules).
// - `hold` and `press` go through a synthesizer (synth.js: Clutter virtual pointer and keyboard).
//   Everything pressed is tracked, so it can always be released, and nothing is released that
//   Slated didn't press.
// - Safety: the stop shortcut (`stopAll`), stopping when you switch away from the app an automation
//   started in, a time limit (`maxRunMinutes`), and releasing everything on disable, screen lock and
//   config reload (the runtime calls `stopAll`). Every start and stop is logged; the log never holds
//   typed text (insert-text is redacted, like action.done).
//
// No GNOME imports: timers, the synthesizer, the clock and the focused app are passed in, so the
// Node tests drive it with fakes.

import * as Core from '../core/index.js';

import {redactForLog} from './actions.js';
import {appMatchesAny, secondsLabel, shortcutLabel} from './util.js';

/** Apps that are Slated itself: starting from its settings window, the next app is the one it's for. */
export const OWN_APPS = Object.freeze(['org.gnome.Shell.Extensions', 'org.gnome.Extensions']);

const MOUSE_LABELS = {left: 'Left Mouse Button', right: 'Right Mouse Button', middle: 'Middle Mouse Button'};

/** "Left Mouse Button", "W", "Shift", "Ctrl W" for an input like "mouse:left" or "key:ctrl+w". */
export function inputLabel(input) {
  const parsed = typeof input === 'string' ? Core.parseSyntheticInput(input) : input;
  if (!parsed) return String(input);
  return parsed.kind === 'mouse' ? MOUSE_LABELS[parsed.button] : shortcutLabel(parsed.combo);
}

/** What the indicator and status.json call a repeat: "Repeat click left every 100 ms, 50×". */
export function repeatTitle(action, schedule) {
  let description;
  try {
    description = Core.formatOperation(redactForLog(action));
  } catch {
    description = String(action?.op ?? 'action');
  }
  let title = `Repeat ${description} every ${secondsLabel(schedule.interval)}`;
  if (schedule.times !== null) title += `, ${schedule.times}×`;
  return title;
}

/** The indicator's line: the one automation's title, or how many run. */
export function indicatorText(active) {
  if (active.length === 0) return '';
  return active.length === 1 ? active[0].title : `${active.length} automations running`;
}

/** The parts of an action that run as steps: a sequence's steps, a chain's operations, both orientations. */
function children(action) {
  if (!action || typeof action !== 'object') return [];
  switch (action.op) {
    case 'sequence':
      return (action.steps ?? []).map((s) => s?.action).concat(action.operations ?? []);
    case 'chain':
      return action.operations ?? [];
    case 'by-orientation':
      return [action.landscape, action.portrait];
    default:
      return [];
  }
}

/** The first while-held `repeat` a binding's action runs (itself, or a step of it), or null. */
export function whileHeldRepeat(action) {
  if (!action || typeof action !== 'object') return null;
  if (action.op === 'repeat') return action.mode === 'while-held' ? action : null;
  for (const child of children(action)) {
    const found = whileHeldRepeat(child);
    if (found) return found;
  }
  return null;
}

/**
 * Whether an action types or presses keys. On GNOME, any key press or release stops the keyboard's
 * repeat, which is how Slated notices a while-held shortcut is still down, so such repeats can't be
 * while-held there.
 */
export function sendsKeys(action) {
  if (!action || typeof action !== 'object') return false;
  switch (action.op) {
    case 'keystroke':
    case 'insert-text':
      return true;
    case 'press':
    case 'hold':
      return String(action.input ?? '').toLowerCase().startsWith('key:');
    case 'repeat':
      return sendsKeys(action.action);
    default:
      return children(action).some(sendsKeys);
  }
}

export class AutomationEngine {
  /**
   * @param {object} options
   * @param {object} options.timers  `timeout(ms, callback)` → id and `clear(id)` (timers.js).
   * @param {object} options.synth   `mouse(button, down)`, `key(combo, down)` → {ok, error?} (synth.js).
   * @param {object} [options.log]
   * @param {() => number} [options.now]  Milliseconds, for durations.
   * @param {() => number} [options.random]  Uniform in 0…1, for jitter.
   * @param {() => object|null} [options.focusedApp]  The focused app's identity (util.appIdentity).
   */
  constructor({timers, synth, log = null, now = () => Date.now(), random = Math.random, focusedApp = () => null}) {
    this._timers = timers;
    this._synth = synth;
    this._log = log;
    this._now = now;
    this._random = random;
    this._focusedApp = focusedApp;
    this.settings = {stopShortcut: 'hyper+esc', stopOnAppSwitch: true, maxRunMinutes: 0, showIndicator: true};
    /** Performs one repetition; returns false when it failed (wired to the action runner). */
    this.perform = null;
    /** Something started or stopped (the indicator and status.json refresh). */
    this.onChange = null;
    this._repeaters = new Map();
    this._held = new Map();
    /**
     * The app in front when the first automation started (for stopOnAppSwitch). Null while nothing
     * runs, and while something runs that started with no app (or Slated's own window) in front: then
     * the next app focused is the one it's for.
     */
    this._startedIn = null;
    this._limitTimer = 0;
  }

  get isRunning() {
    return this._repeaters.size > 0 || this._held.size > 0;
  }

  /** Running automations, oldest first: {id, title, trigger, startedAt, repetitions}. */
  get active() {
    return [...[...this._repeaters.values()].map((r) => r.info), ...this._held.values()].sort((a, b) => a.startedAt - b.startedAt);
  }

  // --- Auto-repeat ---------------------------------------------------------------------------------

  /**
   * Starts an auto-repeat identified by `id` (its trigger), or stops it if it's already running
   * (toggle mode, or a second press in while-held mode). The first run happens right away.
   */
  toggleRepeat(action, {interval, mode = 'toggle', times = null, jitter = 0, id, trigger = null}) {
    if (this._repeaters.has(id)) {
      this._stopRepeat(id, 'toggled off');
      return;
    }
    const schedule = new Core.RepeatSchedule({interval, times, jitter});
    const info = {id, title: repeatTitle(action, schedule), trigger, startedAt: this._now(), repetitions: 1, failures: 0};
    this._repeaters.set(id, {timer: 0, info, action, schedule, mode});
    const extra = {interval: schedule.interval, mode, times: schedule.times};
    if (schedule.jitter > 0) extra.jitter = schedule.jitter;
    this._began(info, extra);
    this._run(id);
    if (!this._repeaters.has(id)) return; // the action stopped automations itself
    if (schedule.shouldRunAgain(1)) this._scheduleNext(id);
    else this._stopRepeat(id, 'finished');
  }

  /** The trigger's key was let go: stops the while-held repeat it started. */
  released(id) {
    const repeater = this._repeaters.get(id);
    if (repeater?.mode === 'while-held') this._stopRepeat(id, 'released');
  }

  /** Whether a repeat for this trigger is running. */
  isRepeating(id) {
    return this._repeaters.has(id);
  }

  _run(id) {
    const repeater = this._repeaters.get(id);
    if (!repeater) return;
    let ok = false;
    try {
      ok = this.perform?.(repeater.action) !== false;
    } catch (e) {
      ok = false;
      this._log?.error('automation.step_failed', e?.message ?? String(e), {id});
    }
    if (!ok) repeater.info.failures += 1;
  }

  /** One-shot timeouts rescheduled after each run, so every interval can get its own jitter. */
  _scheduleNext(id) {
    const repeater = this._repeaters.get(id);
    if (!repeater) return;
    const wait = repeater.schedule.nextInterval(this._random());
    repeater.timer = this._timers.timeout(wait * 1000, () => this._tick(id));
  }

  _tick(id) {
    const repeater = this._repeaters.get(id);
    if (!repeater) return;
    repeater.timer = 0;
    repeater.info.repetitions += 1;
    this._run(id);
    if (this._repeaters.get(id) !== repeater) return; // stopped by its own action
    if (repeater.schedule.shouldRunAgain(repeater.info.repetitions)) this._scheduleNext(id);
    else this._stopRepeat(id, 'finished');
  }

  _stopRepeat(id, reason, notify = true) {
    const repeater = this._repeaters.get(id);
    if (!repeater) return;
    this._repeaters.delete(id);
    if (repeater.timer) this._timers.clear(repeater.timer);
    this._ended(repeater.info, reason, notify);
  }

  // --- Holding inputs ------------------------------------------------------------------------------

  /** Holds `input` ("mouse:right", "key:w") down, or releases it if it's already held. */
  toggleHold(input, trigger = null) {
    if (this._held.has(input)) this._release(input, 'toggled off');
    else this.press(input, 'down', trigger);
  }

  /** Presses or releases `input` (macro steps). Returns false when the input can't be sent. */
  press(input, phase, trigger = null) {
    if (phase === 'up') {
      // Only what Slated pressed is released: GNOME warns about releasing keys that aren't down.
      if (!this._held.has(input)) {
        this._log?.record('automation.not_held', {input}, 'debug');
        return true;
      }
      this._release(input, 'released by macro');
      return true;
    }
    // Pressing something already held would send a second press without a release.
    if (this._held.has(input)) return true;
    if (!this._send(input, true)) return false;
    const info = {id: `hold:${input}`, title: `Hold ${inputLabel(input)}`, trigger, startedAt: this._now(), repetitions: 1, failures: 0};
    this._held.set(input, info);
    this._began(info, {input});
    return true;
  }

  /** Whether Slated is holding `input` down. */
  isHeld(input) {
    return this._held.has(input);
  }

  _release(input, reason, notify = true) {
    this._send(input, false);
    const info = this._held.get(input);
    if (!info) return;
    this._held.delete(input);
    this._ended(info, reason, notify);
  }

  _send(input, down) {
    const parsed = Core.parseSyntheticInput(input);
    if (!parsed) {
      this._log?.error('automation.unknown_input', `${input} isn't a mouse button or key Slated knows`, {input});
      return false;
    }
    let result;
    try {
      result = parsed.kind === 'mouse' ? this._synth.mouse(parsed.button, down) : this._synth.key(parsed.combo, down);
    } catch (e) {
      result = {ok: false, error: e?.message ?? String(e)};
    }
    if (result?.ok === false) {
      this._log?.error('automation.unknown_key', result.error ?? `Couldn't send ${input}`, {input});
      return false;
    }
    return true;
  }

  // --- Stopping ------------------------------------------------------------------------------------

  /** Stops every repeat and releases everything held. */
  stopAll(reason) {
    if (!this.isRunning) return;
    for (const id of [...this._repeaters.keys()]) this._stopRepeat(id, reason, false);
    for (const input of [...this._held.keys()]) this._release(input, reason, false);
    this._log?.record('automation.stopped_all', {reason}, 'notice');
    this.onChange?.();
  }

  /**
   * The focused app changed (an `appIdentity`, or null for the overview or an empty desktop): stops
   * everything when you leave the app an automation started in, so clicks don't land elsewhere.
   */
  focusChanged(app) {
    if (!this.settings.stopOnAppSwitch || !this.isRunning) return;
    if (app && appMatchesAny(app, OWN_APPS)) return; // Slated's own settings window doesn't count
    if (this._startedIn === null) {
      this._startedIn = app;
      return;
    }
    if (app && app.id === this._startedIn.id) return;
    this.stopAll(app ? 'switched to another app' : 'left the app');
  }

  destroy(reason = 'disabled') {
    this.stopAll(reason);
    this._limitTimer = this._timers.clear(this._limitTimer);
    this.perform = this.onChange = null;
  }

  _began(info, extra) {
    // The first automation (it's already counted) remembers the app it's for.
    if (this._repeaters.size + this._held.size === 1) {
      const app = this._focusedApp();
      this._startedIn = app && !appMatchesAny(app, OWN_APPS) ? app : null;
    }
    const minutes = Number(this.settings.maxRunMinutes) || 0;
    if (minutes > 0 && !this._limitTimer) {
      this._limitTimer = this._timers.timeout(minutes * 60_000, () => {
        this._limitTimer = 0;
        this.stopAll('time limit reached');
      });
    }
    const data = {id: info.id, title: info.title, app: this._startedIn?.id ?? 'unknown', ...extra};
    if (info.trigger) data.trigger = info.trigger;
    this._log?.record('automation.started', data);
    this.onChange?.();
  }

  _ended(info, reason, notify) {
    const data = {id: info.id, title: info.title, reason, repetitions: info.repetitions, seconds: (this._now() - info.startedAt) / 1000};
    if (info.failures) data.failures = info.failures;
    this._log?.record('automation.stopped', data);
    if (!this.isRunning) {
      this._startedIn = null;
      this._limitTimer = this._timers.clear(this._limitTimer);
    }
    if (notify) this.onChange?.();
  }
}
