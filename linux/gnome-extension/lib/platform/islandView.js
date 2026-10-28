// The island's actors: a black shape hanging from the top center of a monitor (from the top bar on the
// primary one) that grows and shrinks between what the presenter (island.js) shows. GNOME's version of
// SlatedUI's IslandView. Styled by stylesheet.css (.slated-island-*).
//
// It never takes keyboard focus. It takes pointer input only while it shows running automations, so
// hovering can open it to the Stop button; otherwise it's not reactive and clicks go to the window
// below. The holder spans the work area without being reactive or part of the input region, so only
// the island itself (and only then) can catch the pointer, on Wayland and X11 alike.

import Clutter from 'gi://Clutter';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {keyLabel, shortcutLabel} from './util.js';

const SHAPE_MS = 320;
const HIDE_MS = 220;
const CONTENT_IN_MS = 200;
const CONTENT_IN_DELAY_MS = 90;
const CONTENT_OUT_MS = 90;
/** The pill the island grows from and shrinks back into. */
const SEED = {width: 96, height: 6};
const MAX_BANNER_WIDTH = 560;
const MAX_AUTOMATION_ROWS = 4;
const SCREEN_MARGIN = 24;

/** SF Symbol names (the core's, as on the Mac) → GNOME symbolic icons, as the settings window uses them. */
const ICONS = {
  'arrow.up.and.down.and.arrow.left.and.right': 'view-fullscreen-symbolic',
  'arrow.up.left.and.arrow.down.right': 'zoom-fit-best-symbolic',
  'arrow.left.to.line': 'go-first-symbolic',
  'arrow.right.circle': 'go-next-symbolic',
  'rectangle.portrait.and.arrow.right': 'send-to-symbolic',
  'arrow.up.left.square': 'view-restore-symbolic',
  link: 'insert-link-symbolic',
  'list.number': 'view-list-ordered-symbolic',
  'rectangle.3.group': 'view-dual-symbolic',
  'rectangle.portrait.rotate': 'object-rotate-right-symbolic',
  scope: 'find-location-symbolic',
  'app.badge.checkmark': 'view-app-grid-symbolic',
  'character.cursor.ibeam': 'edit-find-symbolic',
  'square.grid.3x3': 'view-grid-symbolic',
  'eye.slash': 'view-conceal-symbolic',
  eye: 'view-reveal-symbolic',
  'eye.trianglebadge.exclamationmark': 'object-flip-horizontal-symbolic',
  'square.stack.3d.forward.dottedline': 'application-x-executable-symbolic',
  'camera.viewfinder': 'camera-photo-symbolic',
  'clock.arrow.circlepath': 'document-revert-symbolic',
  trash: 'user-trash-symbolic',
  'arrow.uturn.backward': 'edit-undo-symbolic',
  'text.insert': 'insert-text-symbolic',
  keyboard: 'input-keyboard-symbolic',
  'link.circle': 'web-browser-symbolic',
  terminal: 'utilities-terminal-symbolic',
  'arrow.clockwise': 'view-refresh-symbolic',
  'list.clipboard': 'edit-paste-symbolic',
  'cursorarrow.click': 'input-mouse-symbolic',
  'hand.point.up.left': 'go-bottom-symbolic',
  'hand.tap': 'changes-prevent-symbolic',
  repeat: 'media-playlist-repeat-symbolic',
  hourglass: 'preferences-system-time-symbolic',
  'stop.circle': 'media-playback-stop-symbolic',
  'arrow.right.to.line.compact': 'go-next-symbolic',
  'arrow.left.to.line.compact': 'go-previous-symbolic',
  curlybraces: 'text-x-generic-symbolic',
};

/** The GNOME icon for an SF Symbol name from the core. */
export const iconFor = (symbol) => ICONS[symbol] ?? 'object-select-symbolic';

/** "0:42", "12:05", "1:02:03". */
export function elapsedText(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor(total / 60) % 60;
  const s = total % 60;
  const two = (n) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

/** How a running automation is described under its title: "✦ R · 12 times · 0:42". */
export function automationDetail(automation, now, comboOf = () => null) {
  const parts = [];
  if (automation.trigger) {
    const keys = automation.trigger.startsWith('hotkey ') ? comboOf(automation.trigger.slice(7)) : null;
    parts.push(keys ? shortcutLabel(keys) : automation.trigger);
  }
  if (!String(automation.id ?? '').startsWith('hold:')) {
    parts.push(automation.repetitions === 1 ? '1 time' : `${automation.repetitions ?? 0} times`);
  }
  parts.push(elapsedText(now - automation.startedAt));
  return parts.join(' · ');
}

/** The icon for a running automation: a mouse for clicks and held buttons, a keyboard for held keys. */
export function automationIcon(automation) {
  if (!automation) return 'media-playlist-repeat-symbolic';
  const id = String(automation.id ?? '');
  if (id.startsWith('hold:mouse')) return 'input-mouse-symbolic';
  if (id.startsWith('hold:')) return 'input-keyboard-symbolic';
  return String(automation.title ?? '').includes('Click') ? 'input-mouse-symbolic' : 'media-playlist-repeat-symbolic';
}

/** A cheat sheet item's keycap in GNOME's words: the modifiers beyond Hyper ("Shift H"), or the whole shortcut. */
export function itemKeycap(item, sheet) {
  if (!item.keys) return item.label;
  if (!sheet.isHyper) return shortcutLabel(item.keys);
  const names = {fn: 'Fn', ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', cmd: 'Super'};
  const extra = ['fn', 'ctrl', 'alt', 'shift', 'cmd'].filter((m) => (item.extraModifiers ?? []).includes(m)).map((m) => names[m]);
  return [...extra, keyLabel(item.keys.key)].join(' ');
}

/** Columns for a sheet, as on the Mac: two for a few shortcuts, three up to 36, then four. */
export function sheetColumns(count) {
  return count <= 6 ? 2 : count <= 36 ? 3 : 4;
}

function column(props = {}) {
  const box = new St.BoxLayout(props);
  // `vertical` is deprecated from GNOME 48 on, `orientation` doesn't exist before it: the layout
  // manager's orientation works on every version.
  box.layout_manager.orientation = Clutter.Orientation.VERTICAL;
  return box;
}

const label = (text, style_class, props = {}) => new St.Label({text, style_class, y_align: Clutter.ActorAlign.CENTER, ...props});
const icon = (symbolic, style_class) => new St.Icon({icon_name: symbolic, style_class, y_align: Clutter.ActorAlign.CENTER});
const spacer = () => new St.Widget({x_expand: true});

/** A screen outline with the region a window goes to filled in (the Mac's RegionGlyph). */
function regionGlyph(region, width, height) {
  const glyph = new St.Widget({style_class: 'slated-island-region', width, height, y_align: Clutter.ActorAlign.CENTER});
  const inner = {w: width - 4, h: height - 4};
  const fill = new St.Widget({style_class: 'slated-island-region-fill'});
  fill.set_position(2 + Math.round(region.x * inner.w), 2 + Math.round(region.y * inner.h));
  fill.width = Math.max(2, Math.round(region.width * inner.w));
  fill.height = Math.max(2, Math.round(region.height * inner.h));
  glyph.add_child(fill);
  return glyph;
}

export class IslandView {
  /**
   * @param {object} callbacks
   * @param {() => void} callbacks.onStop  The Stop button was clicked.
   * @param {(hovering: boolean) => void} callbacks.onHover  The pointer entered or left the island.
   */
  constructor({onStop, onHover}) {
    this._onStop = onStop;
    this._onHover = onHover;
    this._holder = null;
    this._island = null;
    this._content = null;
    this._contentKey = 'hidden';
    this._monitor = -1;
    this._shown = false;
    this._interactive = false;
    this._tracked = false;
    this._hoverId = 0;
    this._cells = new Map();
    this._dynamic = [];
    /** Contents fading out, destroyed when they're gone. */
    this._leaving = new Set();
    this._hiding = false;
    this._destroying = false;
    /** Hover changes while drawing are passed on once the drawing is done (no re-entrant renders). */
    this._rendering = false;
    this._pendingHover = null;
  }

  /** Whether the island is on screen (tests and status). */
  get visible() {
    return this._shown;
  }

  /** The island actor (tests). */
  get actor() {
    return this._island;
  }

  /** The monitor it's on, or -1. */
  get monitor() {
    return this._shown ? this._monitor : -1;
  }

  /**
   * Shows `presentation` ({kind, …} from the presenter) with `state` ({automations, stopLabel,
   * highlighted, now, comboOf}), on `monitor` when given.
   */
  render(presentation, state, options = {}) {
    this._rendering = true;
    try {
      this._render(presentation, state, options);
    } finally {
      this._rendering = false;
    }
    const hover = this._pendingHover;
    this._pendingHover = null;
    if (hover !== null && this._interactive) this._onHover?.(hover);
  }

  _render(presentation, state, {monitor = null, focused = false}) {
    if (presentation.kind === 'hidden') {
      this._hide();
      return;
    }
    this._ensureActors();
    const target = this._chooseMonitor(monitor, focused);
    const area = this._areaOf(target);
    const moved = target !== this._monitor;
    this._monitor = target;
    this._holder.set_position(area.x, area.y);
    this._holder.width = area.width;
    this._holder.height = area.height;

    // Coming back (even mid-hide) builds fresh content, which fades in as the shape grows.
    const key = this._keyOf(presentation, state);
    const rebuilt = !this._shown || key !== this._contentKey || !this._content;
    if (rebuilt) {
      this._replaceContent(this._build(presentation, state, area));
      this._contentKey = key;
    }
    this._updateDynamic(state);
    this._setInteractive(presentation.kind === 'automations');
    if (rebuilt || moved) this._place(area, moved);
  }

  /** Refreshes what changes without a new layout: timers, counts and the highlighted shortcut. */
  tick(state) {
    if (this._shown) this._updateDynamic(state);
  }

  destroy() {
    this._destroying = true;
    if (this._hoverId && this._island) this._island.disconnect(this._hoverId);
    this._hoverId = 0;
    if (this._tracked && this._island) {
      try {
        Main.layoutManager.untrackChrome(this._island);
      } catch {
        // Already untracked with its parent.
      }
    }
    this._tracked = false;
    this._stopTransitions();
    // Their fade-outs end without destroying them: the holder takes them along.
    for (const leaving of this._leaving) leaving.remove_all_transitions();
    this._leaving.clear();
    if (this._holder) {
      Main.layoutManager.removeChrome(this._holder);
      this._holder.destroy();
    }
    this._holder = this._island = this._content = null;
    this._cells.clear();
    this._dynamic = [];
    this._shown = false;
    this._contentKey = 'hidden';
    this._onStop = this._onHover = null;
  }

  // --- Actors ------------------------------------------------------------------------------------

  _ensureActors() {
    if (this._holder) return;
    this._holder = new St.Widget({name: 'slatedIslandHolder', reactive: false, can_focus: false, track_hover: false, visible: false});
    this._island = new St.Widget({
      name: 'slatedIsland',
      style_class: 'slated-island',
      reactive: false,
      can_focus: false,
      track_hover: false,
      clip_to_allocation: true,
      opacity: 0,
    });
    this._holder.add_child(this._island);
    this._hoverId = this._island.connect('notify::hover', () => {
      if (!this._interactive || !this._island) return;
      if (this._rendering) {
        this._pendingHover = !!this._island.hover;
        return;
      }
      try {
        this._onHover?.(!!this._island.hover);
      } catch (e) {
        console.error(`Slated: island hover: ${e}\n${e?.stack ?? ''}`);
      }
    });
    // Above windows, fullscreen ones too (a game's automation stays visible), but out of the input
    // region: only the island catches the pointer, and only while it shows automations.
    Main.layoutManager.addTopChrome(this._holder, {affectsInputRegion: false});
  }

  /** `hint` (a window's monitor), else the focused window's when asked, else where it is, else the focused window's, else the primary. */
  _chooseMonitor(hint, preferFocused) {
    const count = global.display.get_n_monitors();
    const valid = (i) => Number.isInteger(i) && i >= 0 && i < count;
    if (valid(hint)) return hint;
    const focused = global.display.get_focus_window()?.get_monitor?.();
    if (preferFocused && valid(focused)) return focused;
    if (this._shown && valid(this._monitor)) return this._monitor;
    if (valid(focused)) return focused;
    return valid(Main.layoutManager.primaryIndex) ? Main.layoutManager.primaryIndex : 0;
  }

  /**
   * Where the island hangs: the work area's top (below the top bar), or the monitor's top edge while
   * a fullscreen window covers it and the top bar is gone.
   */
  _areaOf(index) {
    if (Main.layoutManager.monitors?.[index]?.inFullscreen) {
      const g = global.display.get_monitor_geometry(index);
      return {x: g.x, y: g.y, width: g.width, height: g.height};
    }
    return Main.layoutManager.getWorkAreaForMonitor(index);
  }

  _setInteractive(interactive) {
    if (interactive === this._interactive) return;
    this._interactive = interactive;
    this._island.reactive = interactive;
    this._island.track_hover = interactive;
    if (interactive && !this._tracked) {
      Main.layoutManager.trackChrome(this._island, {affectsInputRegion: true});
      this._tracked = true;
    } else if (!interactive && this._tracked) {
      Main.layoutManager.untrackChrome(this._island);
      this._tracked = false;
    }
  }

  /** Sizes the island to its content, centered at the top of the work area, growing from a seed when it appears. */
  _place(area, moved) {
    const content = this._content;
    const maxWidth = Math.max(SEED.width, area.width - 2 * SCREEN_MARGIN);
    const maxHeight = Math.max(SEED.height, area.height - SCREEN_MARGIN);
    const [, naturalWidth] = content.get_preferred_width(-1);
    const width = Math.min(Math.ceil(naturalWidth), maxWidth, this._maxWidth ?? Infinity);
    const [, naturalHeight] = content.get_preferred_height(width);
    const height = Math.min(Math.ceil(naturalHeight), maxHeight);
    // A fixed size for the content: labels ellipsize instead of overflowing, and it doesn't reflow
    // while the shape grows around it.
    content.width = width;
    content.height = height;
    const x = Math.round((area.width - width) / 2);
    const island = this._island;
    island.remove_all_transitions();
    // From the seed when it appears (or changes monitor); from wherever it is when it was shrinking away.
    if ((!this._shown && !this._hiding) || moved) {
      island.set_position(Math.round((area.width - SEED.width) / 2), 0);
      island.width = SEED.width;
      island.height = SEED.height;
      island.opacity = 0;
    }
    this._holder.show();
    island.show();
    this._shown = true;
    this._hiding = false;
    island.ease({x, y: 0, width, height, opacity: 255, duration: SHAPE_MS, mode: Clutter.AnimationMode.EASE_OUT_QUINT});
  }

  _hide() {
    if (!this._shown || !this._island) return;
    this._shown = false;
    this._hiding = true;
    this._setInteractive(false);
    const island = this._island;
    const area = {width: this._holder.width};
    island.remove_all_transitions();
    this._content?.remove_all_transitions();
    this._content?.ease({opacity: 0, duration: CONTENT_OUT_MS, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
    island.ease({
      x: Math.round((area.width - SEED.width) / 2),
      width: SEED.width,
      height: SEED.height,
      opacity: 0,
      duration: HIDE_MS,
      mode: Clutter.AnimationMode.EASE_IN_QUAD,
      onStopped: (finished) => {
        // Shown again meanwhile (or destroyed): leave it be.
        if (!finished || this._shown || !this._holder || this._destroying) return;
        this._hiding = false;
        this._holder.hide();
        this._replaceContent(null);
        this._contentKey = 'hidden';
      },
    });
  }

  _stopTransitions() {
    this._island?.remove_all_transitions();
    this._content?.remove_all_transitions();
    for (const actor of this._dynamic.filter((d) => d.pulse).map((d) => d.actor)) actor.remove_all_transitions();
  }

  _replaceContent(next) {
    const old = this._content;
    for (const d of this._dynamic) if (d.pulse) d.actor.remove_all_transitions();
    this._dynamic = [];
    this._cells.clear();
    if (old) {
      old.remove_all_transitions();
      this._leaving.add(old);
      // Out quickly, before the shape changes much.
      old.ease({
        opacity: 0,
        duration: CONTENT_OUT_MS,
        mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        onStopped: () => {
          this._leaving.delete(old);
          if (!this._destroying) old.destroy();
        },
      });
    }
    this._content = next?.actor ?? null;
    if (!next) return;
    this._dynamic = next.dynamic;
    this._cells = next.cells;
    this._maxWidth = next.maxWidth ?? null;
    const content = next.actor;
    content.opacity = 0;
    content.set_position(0, 0);
    this._island.add_child(content);
    content.ease({opacity: 255, delay: CONTENT_IN_DELAY_MS, duration: CONTENT_IN_MS, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
    for (const d of this._dynamic) {
      if (d.pulse) d.actor.ease({opacity: 70, duration: 800, mode: Clutter.AnimationMode.EASE_IN_OUT_QUAD, repeatCount: -1, autoReverse: true});
    }
  }

  // --- Content -----------------------------------------------------------------------------------

  /** What identifies a layout: a change rebuilds the content, anything else updates it in place. */
  _keyOf(presentation, state) {
    switch (presentation.kind) {
      case 'banner':
        return `banner:${presentation.id}`;
      case 'automations':
        return `automations:${presentation.expanded}:${state.automations.map((a) => a.id).join('|')}:${state.stopLabel ?? ''}`;
      case 'modal':
        return `modal:${presentation.expanded}:${presentation.sheet.title}:${sheetSignature(presentation.sheet)}`;
      case 'cheatSheet':
        return `sheet:${sheetSignature(presentation.sheet)}`;
      default:
        return 'hidden';
    }
  }

  _build(presentation, state, area) {
    switch (presentation.kind) {
      case 'banner':
        return this._banner(presentation.banner);
      case 'automations':
        return presentation.expanded ? this._automationDetail(state) : this._automationCompact(state);
      case 'modal':
        return presentation.expanded ? this._sheet(presentation.sheet, state, area) : this._modalCompact(presentation.sheet);
      default:
        return this._sheet(presentation.sheet, state, area);
    }
  }

  _banner(banner) {
    const row = new St.BoxLayout({style_class: 'slated-island-banner'});
    if (banner.kind === 'failed') {
      row.add_child(icon('dialog-warning-symbolic', 'slated-island-warning'));
      row.add_child(label(banner.message, 'slated-island-banner-title'));
    } else {
      row.add_child(banner.region ? regionGlyph(banner.region, 26, 17) : icon(iconFor(banner.symbol), 'slated-island-banner-icon'));
      row.add_child(label(banner.title, 'slated-island-banner-title'));
      if (banner.app) {
        row.add_child(label('·', 'slated-island-dim'));
        row.add_child(label(banner.app, 'slated-island-banner-app'));
      }
    }
    return {actor: row, dynamic: [], cells: new Map(), maxWidth: MAX_BANNER_WIDTH};
  }

  _automationCompact(state) {
    const automations = state.automations;
    const row = new St.BoxLayout({style_class: 'slated-island-compact'});
    const dot = new St.Widget({style_class: 'slated-island-dot', y_align: Clutter.ActorAlign.CENTER});
    row.add_child(dot);
    row.add_child(automations.length > 1 ? label(String(automations.length), 'slated-island-count') : icon(automationIcon(automations[0]), 'slated-island-compact-icon'));
    row.add_child(spacer());
    const elapsed = label('', 'slated-island-elapsed');
    row.add_child(elapsed);
    const oldest = automations.reduce((a, b) => (b.startedAt < a.startedAt ? b : a), automations[0]);
    const dynamic = [
      {pulse: true, actor: dot},
      {actor: elapsed, text: (s) => elapsedText(s.now - oldest.startedAt)},
    ];
    return {actor: row, dynamic, cells: new Map()};
  }

  _automationDetail(state) {
    const automations = [...state.automations].sort((a, b) => a.startedAt - b.startedAt);
    const box = column({style_class: 'slated-island-automations'});
    const dynamic = [];
    for (const automation of automations.slice(0, MAX_AUTOMATION_ROWS)) {
      const row = new St.BoxLayout({style_class: 'slated-island-automation-row'});
      row.add_child(new St.Bin({style_class: 'slated-island-automation-icon', y_align: Clutter.ActorAlign.CENTER, child: icon(automationIcon(automation), 'slated-island-automation-glyph')}));
      const texts = column({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
      texts.add_child(label(automation.title, 'slated-island-automation-title'));
      const detail = label('', 'slated-island-automation-detail');
      texts.add_child(detail);
      row.add_child(texts);
      box.add_child(row);
      dynamic.push({actor: detail, text: (s) => automationDetail(s.automations.find((a) => a.id === automation.id) ?? automation, s.now, s.comboOf)});
    }
    if (automations.length > MAX_AUTOMATION_ROWS) {
      box.add_child(label(`+${automations.length - MAX_AUTOMATION_ROWS} more`, 'slated-island-more'));
    }
    const footer = new St.BoxLayout({style_class: 'slated-island-footer'});
    const stop = new St.Button({
      style_class: 'slated-island-stop',
      label: automations.length > 1 ? 'Stop All' : 'Stop',
      can_focus: false,
      reactive: true,
      y_align: Clutter.ActorAlign.CENTER,
    });
    stop.connect('clicked', () => {
      try {
        this._onStop?.();
      } catch (e) {
        console.error(`Slated: island Stop: ${e}\n${e?.stack ?? ''}`);
      }
    });
    footer.add_child(stop);
    if (state.stopLabel) {
      footer.add_child(label('or press', 'slated-island-dim'));
      footer.add_child(label(state.stopLabel, 'slated-island-keycap'));
    }
    box.add_child(footer);
    return {actor: box, dynamic, cells: new Map(), stop};
  }

  _modalCompact(sheet) {
    const row = new St.BoxLayout({style_class: 'slated-island-compact'});
    row.add_child(icon('input-keyboard-symbolic', 'slated-island-accent-icon'));
    row.add_child(spacer());
    row.add_child(label(sheet.modalLabel ?? sheet.title, 'slated-island-modal-title'));
    return {actor: row, dynamic: [], cells: new Map()};
  }

  _sheet(sheet, state, area) {
    const items = sheet.sections.flatMap((s) => s.items);
    let columns = sheetColumns(items.length);
    // A narrow monitor (a portrait one) takes fewer columns.
    while (columns > 1 && columns * 212 + 36 > area.width - 2 * SCREEN_MARGIN) columns--;
    const box = column({style_class: 'slated-island-sheet'});
    const header = new St.BoxLayout({style_class: 'slated-island-sheet-header'});
    header.add_child(label(sheet.isHyper ? '✦' : (sheet.modalLabel ?? sheet.title), 'slated-island-keycap slated-island-keycap-accent'));
    header.add_child(label(sheet.isHyper ? 'Hyper' : 'then', 'slated-island-sheet-title'));
    header.add_child(label(items.length === 1 ? '1 shortcut' : `${items.length} shortcuts`, 'slated-island-dim'));
    header.add_child(spacer());
    header.add_child(label(sheet.isHyper ? 'Release Caps Lock to close' : 'Press a key, or Esc to cancel', 'slated-island-hint'));
    box.add_child(header);
    const cells = new Map();
    for (const section of sheet.sections) {
      if (sheet.sections.length > 1) box.add_child(label(section.title.toUpperCase(), 'slated-island-section'));
      for (let i = 0; i < section.items.length; i += columns) {
        const row = new St.BoxLayout({style_class: 'slated-island-sheet-row'});
        for (const item of section.items.slice(i, i + columns)) {
          const cell = new St.BoxLayout({style_class: 'slated-island-cell'});
          cell.add_child(label(itemKeycap(item, sheet), 'slated-island-keycap'));
          cell.add_child(item.region ? regionGlyph(item.region, 21, 14) : icon(iconFor(item.symbol), 'slated-island-cell-icon'));
          cell.add_child(label(item.title, 'slated-island-cell-title', {x_expand: true}));
          if (item.id === state.highlighted) cell.add_style_pseudo_class('highlighted');
          cells.set(item.id, cell);
          row.add_child(cell);
        }
        box.add_child(row);
      }
    }
    return {actor: box, dynamic: [], cells};
  }

  _updateDynamic(state) {
    for (const d of this._dynamic) if (d.text) d.actor.text = d.text(state);
    for (const [id, cell] of this._cells) {
      if (id === state.highlighted) cell.add_style_pseudo_class('highlighted');
      else cell.remove_style_pseudo_class('highlighted');
    }
  }
}

function sheetSignature(sheet) {
  return sheet.sections.map((s) => `${s.title}=${s.items.map((i) => `${i.id}:${i.title}`).join(',')}`).join(';');
}
