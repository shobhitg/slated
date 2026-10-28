// The island on GNOME: what it shows and when, a port of the macOS IslandModel and IslandPresenter
// (Sources/SlatedUI/Island/IslandModel.swift, Sources/Slated/Overlays/IslandPresenter.swift). The
// runtime feeds it; islandView.js draws it at the top center of a monitor.
//
// Highest priority first: the Hyper cheat sheet while Caps Lock is held past the delay, the active
// modal key (then its keys after the delay), a brief banner (what a shortcut did, or why it couldn't),
// running automations (hover to open them up and stop them), else nothing.

import {IslandView} from './islandView.js';

export const ISLAND_DEFAULTS = Object.freeze({enabled: true, cheatSheet: true, cheatSheetDelay: 0.5, showFailures: true});
const BANNER_MS = 1300;
const FAILURE_MS = 2400;
const HIGHLIGHT_MS = 700;
/**
 * A shortcut this recent still counts for a hold that's only now noticed: Caps Lock's hold is read
 * every 150 ms, so a quick combo can fire before the hold is seen.
 */
const USED_WINDOW_MS = 250;
/** How often running automations' timers and counts refresh. */
const TICK_MS = 1000;

/** config.json's `island` section with every default filled in (the fake core in tests has none). */
export function islandSettings(raw) {
  const s = {...ISLAND_DEFAULTS};
  if (raw && typeof raw === 'object') {
    for (const key of ['enabled', 'cheatSheet', 'showFailures']) if (typeof raw[key] === 'boolean') s[key] = raw[key];
    if (typeof raw.cheatSheetDelay === 'number' && Number.isFinite(raw.cheatSheetDelay)) s.cheatSheetDelay = raw.cheatSheetDelay;
  }
  return s;
}

/** How long Caps Lock must be held (or a modal key stay active) before its shortcuts show: 0.15–3 s. */
export function cheatSheetDelayMs(settings) {
  return Math.round(Math.min(Math.max(settings.cheatSheetDelay, 0.15), 3) * 1000);
}

const isEmpty = (sheet) => !sheet || sheet.sections.every((s) => s.items.length === 0);

export class IslandPresenter {
  /**
   * @param {object} options
   * @param {object} options.timers  timers.js `Timers`.
   * @param {object} [options.log]
   * @param {() => number} [options.now]  Milliseconds (what automations' `startedAt` count from).
   * @param {object} [options.view]  Draws the island (islandView.js; tests pass a stand-in).
   */
  constructor({timers, log = null, now = () => Date.now(), view = null}) {
    this._timers = timers;
    this._log = log;
    this._now = now;
    this._view = view ?? new IslandView({onStop: () => this._stop(), onHover: (hovering) => this._hover(hovering)});
    this.settings = {...ISLAND_DEFAULTS};
    /** Builds the Hyper cheat sheet when it's about to appear (bindings can change at any time). */
    this.hyperSheet = null;
    /** The running automations, read for live counts while the island shows them. */
    this.currentAutomations = null;
    /** The Stop button was clicked. */
    this.onStop = null;
    /** KeyCombo for "hotkey hyper+r" triggers ("hyper+r" → combo), to label automations. */
    this.comboOf = () => null;

    this.banner = null;
    this._bannerId = 0;
    this.automations = [];
    this.stopLabel = null;
    this.cheatSheet = null;
    this.modal = null;
    this.modalExpanded = false;
    this.hovering = false;
    this.highlighted = null;

    this._bannerTimer = 0;
    this._sheetTimer = 0;
    this._modalTimer = 0;
    this._highlightTimer = 0;
    this._tickTimer = 0;
    this._usedAt = -Infinity;
    this._destroyed = false;
  }

  /** What the island shows now: {kind: "hidden"|"cheatSheet"|"modal"|"banner"|"automations", …}. */
  get presentation() {
    if (this.cheatSheet && !isEmpty(this.cheatSheet)) return {kind: 'cheatSheet', sheet: this.cheatSheet};
    if (this.modal) return {kind: 'modal', sheet: this.modal, expanded: this.modalExpanded && !isEmpty(this.modal)};
    if (this.banner) return {kind: 'banner', banner: this.banner, id: this._bannerId};
    if (this.automations.length) return {kind: 'automations', expanded: this.hovering};
    return {kind: 'hidden'};
  }

  /** The island's view (tests). */
  get view() {
    return this._view;
  }

  apply(settings) {
    this.settings = islandSettings(settings);
    if (!this.settings.enabled) {
      this._sheetTimer = this._timers.clear(this._sheetTimer);
      this._modalTimer = this._timers.clear(this._modalTimer);
      this.cheatSheet = null;
      this.modal = null;
      this.modalExpanded = false;
      this.automations = [];
      this.hovering = false;
      this.banner = null;
    } else if (!this.settings.cheatSheet) {
      this._sheetTimer = this._timers.clear(this._sheetTimer);
      this.cheatSheet = null;
      this.modalExpanded = false;
    }
    this._refresh();
  }

  // --- Banners -------------------------------------------------------------------------------------

  /**
   * Briefly shows what a shortcut did: {title, app, region, symbol}, on `monitor` (the window's) when
   * known.
   */
  flash(feedback, {monitor = null} = {}) {
    if (!this.settings.enabled) return;
    this._showBanner({kind: 'done', ...feedback}, BANNER_MS, monitor);
  }

  /** Briefly shows why a shortcut didn't work. */
  flashFailure(message) {
    if (!this.settings.enabled || !this.settings.showFailures) return;
    this._showBanner({kind: 'failed', message: String(message)}, FAILURE_MS, null);
  }

  _showBanner(banner, ms, monitor) {
    this.banner = banner;
    const id = ++this._bannerId;
    this._timers.clear(this._bannerTimer);
    this._bannerTimer = this._timers.timeout(ms, () => {
      this._bannerTimer = 0;
      if (id !== this._bannerId) return;
      this.banner = null;
      this._refresh();
    });
    this._refresh({monitor});
  }

  // --- Automations ---------------------------------------------------------------------------------

  /** What runs ({id, title, trigger, startedAt, repetitions}), and the stop shortcut as keycaps. */
  automationsChanged(active, {stopLabel = null} = {}) {
    this.stopLabel = stopLabel;
    this.automations = this.settings.enabled ? [...(active ?? [])] : [];
    if (this.automations.length === 0) this.hovering = false;
    this._refresh();
  }

  _hover(hovering) {
    if (hovering === this.hovering) return;
    this.hovering = hovering && this.automations.length > 0;
    this._refresh();
  }

  _stop() {
    this._log?.record('island.stop_clicked', {running: this.automations.length}, 'notice');
    try {
      this.onStop?.();
    } catch (e) {
      this._log?.error('island.stop_failed', e?.message ?? String(e));
    }
  }

  // --- The cheat sheet -----------------------------------------------------------------------------

  /** All of Hyper went down: the cheat sheet shows if it stays down for the delay, without a shortcut. */
  hyperPressed() {
    if (!this.settings.enabled || !this.settings.cheatSheet) return;
    // A combo fired before the hold was noticed: it's a quick one.
    if (this._now() - this._usedAt < USED_WINDOW_MS) return;
    this._timers.clear(this._sheetTimer);
    this._sheetTimer = this._timers.timeout(cheatSheetDelayMs(this.settings), () => {
      this._sheetTimer = 0;
      this._showCheatSheet();
    });
  }

  /** A shortcut fired: a quick Hyper combo never shows the sheet. Once it's up, it stays while you try shortcuts. */
  hyperUsed() {
    this._usedAt = this._now();
    if (!this.cheatSheet) this._sheetTimer = this._timers.clear(this._sheetTimer);
  }

  /** Hyper was let go. */
  hyperReleased() {
    this._sheetTimer = this._timers.clear(this._sheetTimer);
    if (!this.cheatSheet) return;
    this.cheatSheet = null;
    this._refresh();
  }

  /** The Hyper key stopped working (turned off, keyd stopped): don't leave the sheet up. */
  hyperUnavailable() {
    this.hyperReleased();
  }

  _showCheatSheet() {
    let sheet = null;
    try {
      sheet = this.hyperSheet?.() ?? null;
    } catch (e) {
      this._log?.error('island.cheat_sheet_failed', e?.message ?? String(e));
    }
    const items = sheet ? sheet.sections.reduce((n, s) => n + s.items.length, 0) : 0;
    this._log?.record('island.cheat_sheet', {items}, 'debug');
    if (items === 0) return;
    this.cheatSheet = sheet;
    this._refresh({focused: true});
  }

  /** A modal key was pressed (its sheet) or modal mode ended (null). */
  modalChanged(sheet) {
    this._modalTimer = this._timers.clear(this._modalTimer);
    this.modalExpanded = false;
    this.modal = this.settings.enabled ? (sheet ?? null) : null;
    if (this.modal && this.settings.cheatSheet && !isEmpty(this.modal)) {
      this._modalTimer = this._timers.timeout(cheatSheetDelayMs(this.settings), () => {
        this._modalTimer = 0;
        if (!this.modal) return;
        this.modalExpanded = true;
        this._refresh();
      });
    }
    this._refresh({focused: !!this.modal});
  }

  /** A shortcut fired: if the visible sheet lists it, light it up for a moment. */
  shortcutFired(id) {
    if (this._destroyed) return;
    const visible = this.cheatSheet ?? (this.modalExpanded ? this.modal : null);
    if (!visible || !visible.sections.some((s) => s.items.some((item) => item.id === id))) return;
    this.highlighted = id;
    this._timers.clear(this._highlightTimer);
    this._highlightTimer = this._timers.timeout(HIGHLIGHT_MS, () => {
      this._highlightTimer = 0;
      this.highlighted = null;
      this._view.tick(this._state());
    });
    this._view.tick(this._state());
  }

  // --- Showing -------------------------------------------------------------------------------------

  _state() {
    return {automations: this.automations, stopLabel: this.stopLabel, highlighted: this.highlighted, now: this._now(), comboOf: this.comboOf};
  }

  /**
   * Brings the view in line: on `monitor` when given, else where it is, else the focused window's
   * (`focused`: the sheet goes where you're working).
   */
  _refresh({monitor = null, focused = false} = {}) {
    if (this._destroyed) return;
    const presentation = this.presentation;
    // Something else took over: the pointer has to come back for the automations to open up again.
    if (presentation.kind !== 'automations') this.hovering = false;
    try {
      this._view.render(presentation, this._state(), {monitor, focused});
    } catch (e) {
      this._log?.error('island.render_failed', e?.message ?? String(e), {kind: presentation.kind});
    }
    this._updateTicker(presentation);
  }

  /** While automations show, their timers count up and their counts follow. */
  _updateTicker(presentation) {
    if (presentation.kind !== 'automations') {
      this._tickTimer = this._timers.clear(this._tickTimer);
      return;
    }
    if (this._tickTimer) return;
    this._tickTimer = this._timers.interval(TICK_MS, () => {
      if (this._destroyed || this.presentation.kind !== 'automations') {
        this._tickTimer = 0;
        return false;
      }
      try {
        const current = this.currentAutomations?.();
        if (current) this.automations = [...current];
        this._view.tick(this._state());
      } catch (e) {
        this._log?.error('island.tick_failed', e?.message ?? String(e));
      }
      return true;
    });
  }

  destroy() {
    this._destroyed = true;
    for (const timer of [this._bannerTimer, this._sheetTimer, this._modalTimer, this._highlightTimer, this._tickTimer]) this._timers?.clear(timer);
    this._bannerTimer = this._sheetTimer = this._modalTimer = this._highlightTimer = this._tickTimer = 0;
    this._view?.destroy();
    this._view = null;
    this.hyperSheet = this.currentAutomations = this.onStop = null;
    this.cheatSheet = this.modal = this.banner = null;
    this.automations = [];
  }
}
