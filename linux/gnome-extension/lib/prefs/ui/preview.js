// The live placement preview: the displays in miniature, the sample window (dashed) and where an
// action puts it, drawn with Cairo on a Gtk.DrawingArea. Displays come from status.json when the
// extension reports them, else a sample landscape + portrait pair. The window math is the engine's
// targetFrame; while that is a stub the preview says "Preview unavailable" instead of guessing.

import Gtk from 'gi://Gtk';
import Cairo from 'cairo';
import PangoCairo from 'gi://PangoCairo';

import {
  SAMPLE_SCREENS, place, screenMap, screenAt, describeFrame, layoutPlacements, mainScreen,
} from '../placement.js';
import {foreground, accent, isDark, roundedRect, setColor, box, label, button} from './widgets.js';
import {resolveAction} from '../actions.js';

const WALLPAPER_LIGHT = [[0x9f, 0xb6, 0xff], [0xb9, 0xa8, 0xff], [0xf0, 0xb8, 0xe4]];
const WALLPAPER_DARK = [[0x23, 0x30, 0x5f], [0x3a, 0x2c, 0x6e], [0x5f, 0x2d, 0x63]];

function hsv(h, s, v) {
  const i = Math.floor(h * 6);
  const f = h * 6 - i;
  const p = v * (1 - s);
  const q = v * (1 - f * s);
  const t = v * (1 - (1 - f) * s);
  const [r, g, b] = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i % 6];
  return {r, g, b, a: 1};
}

/** Displays to draw: the real ones from status.json, else the sample pair. */
export function previewScreens(model) {
  return model.status.screens ?? SAMPLE_SCREENS;
}

/**
 * The drawing surface shared by the binding preview and the layout preview. `state` holds
 * {screens, origin, target, windows, dimmed}.
 */
export class ScreenCanvas {
  constructor({height = 200, onScreenClicked = null} = {}) {
    this.state = {screens: SAMPLE_SCREENS, origin: null, target: null, windows: [], dimmed: false};
    this.area = new Gtk.DrawingArea({content_height: height, hexpand: true});
    this.area.set_draw_func((area, cr, width, h) => this._draw(cr, width, h));
    this.message = new Gtk.Label({
      wrap: true, justify: Gtk.Justification.CENTER, max_width_chars: 44, halign: Gtk.Align.CENTER,
      valign: Gtk.Align.CENTER, css_classes: ['card', 'slated-preview-message'], visible: false,
    });
    this.widget = new Gtk.Overlay({child: this.area, css_classes: ['slated-preview']});
    this.widget.add_overlay(this.message);
    if (onScreenClicked) {
      const click = new Gtk.GestureClick();
      click.connect('pressed', (gesture, presses, x, y) => {
        const map = screenMap(this.state.screens, this.area.get_width(), this.area.get_height(), {padding: 10, labelHeight: 18});
        const index = screenAt(this.state.screens, map.fromCanvas(x, y));
        if (index >= 0) onScreenClicked(index);
      });
      this.area.add_controller(click);
    }
  }

  update(state, message = null) {
    this.state = {...this.state, ...state};
    this.message.set_label(message ?? '');
    this.message.set_visible(Boolean(message));
    this.area.queue_draw();
  }

  _text(cr, text, x, y, {width = null, color, bold = false, scale = 0.85} = {}) {
    const layout = this.area.create_pango_layout(text);
    const description = this.area.get_pango_context().get_font_description().copy();
    description.set_size(Math.round(description.get_size() * scale));
    if (bold) description.set_weight(700);
    layout.set_font_description(description);
    const [w, h] = layout.get_pixel_size();
    const left = width === null ? x : x + Math.max(0, (width - w) / 2);
    setColor(cr, color);
    cr.moveTo(left, y);
    PangoCairo.show_layout(cr, layout);
    return {width: w, height: h};
  }

  _window(cr, r, fill, labelText = null) {
    const radius = Math.min(6, Math.max(2.5, r.width * 0.03));
    roundedRect(cr, r.x, r.y, Math.max(r.width, 6), Math.max(r.height, 6), radius);
    setColor(cr, fill, 0.88);
    cr.fillPreserve();
    cr.setSourceRGBA(1, 1, 1, 0.6);
    cr.setLineWidth(1);
    cr.stroke();
    if (r.height > 18 && r.width > 24) {
      // A header bar strip, like a GNOME window's.
      roundedRect(cr, r.x + 1, r.y + 1, r.width - 2, Math.min(7, r.height * 0.12), radius - 1);
      cr.setSourceRGBA(1, 1, 1, 0.22);
      cr.fill();
    }
    if (labelText && r.width > 40 && r.height > 22) {
      this._text(cr, labelText, r.x, r.y + r.height / 2 - 7, {width: r.width, color: {r: 1, g: 1, b: 1, a: 1}, bold: true, scale: 0.8});
    }
  }

  _draw(cr, width, height) {
    const {screens, origin, target, windows, dimmed} = this.state;
    if (!screens.length) {
      cr.$dispose();
      return;
    }
    const map = screenMap(screens, width, height, {padding: 10, labelHeight: 18});
    const fg = foreground(this.area);
    const wallpaper = isDark() ? WALLPAPER_DARK : WALLPAPER_LIGHT;
    for (const screen of screens) {
      const r = map.toCanvas(screen.frame);
      const outer = {x: r.x + 2, y: r.y + 2, width: r.width - 4, height: r.height - 4};
      roundedRect(cr, outer.x, outer.y, outer.width, outer.height, 5);
      cr.setSourceRGBA(0.09, 0.09, 0.1, 1);
      cr.fill();
      const inner = {x: outer.x + 2, y: outer.y + 2, width: outer.width - 4, height: outer.height - 4};
      const gradient = new Cairo.LinearGradient(inner.x, inner.y, inner.x + inner.width, inner.y + inner.height);
      wallpaper.forEach(([red, green, blue], i) => {
        gradient.addColorStopRGBA(i / (wallpaper.length - 1), red / 255, green / 255, blue / 255, dimmed ? 0.45 : 1);
      });
      roundedRect(cr, inner.x, inner.y, inner.width, inner.height, 3.5);
      cr.setSource(gradient);
      cr.fill();
      // GNOME's top bar: the part of the screen above its work area.
      const bar = Math.max(2.5, (screen.visibleFrame.y - screen.frame.y) * map.scale);
      if (screen.visibleFrame.y > screen.frame.y) {
        cr.rectangle(inner.x, inner.y, inner.width, Math.min(bar, inner.height));
        cr.setSourceRGBA(isDark() ? 0 : 1, isDark() ? 0 : 1, isDark() ? 0 : 1, 0.4);
        cr.fill();
      }
      const name = screen.isMain ? `${screen.name} · main` : screen.name;
      this._text(cr, name, r.x - 20, r.y + r.height + 3, {width: r.width + 40, color: {...fg, a: 0.65}});
    }
    windows.forEach(w => this._window(cr, map.toCanvas(w.frame), hsv(w.hue, 0.55, 0.92), w.label));
    if (origin) {
      const r = map.toCanvas(origin);
      roundedRect(cr, r.x, r.y, r.width, r.height, 3);
      cr.setSourceRGBA(1, 1, 1, 0.8);
      cr.setLineWidth(1);
      cr.setDash([3, 2.5], 0);
      cr.stroke();
      cr.setDash([], 0);
    }
    if (target) {
      const r = map.toCanvas(target);
      this._window(cr, r, accent(), r.width > 74 && r.height > 34 ? `${Math.round(target.width)} × ${Math.round(target.height)}` : null);
    }
    cr.$dispose();
  }
}

/**
 * The binding editor's preview card: header with a chain stepper and caption, and the canvas.
 * Call `setAction(action)` whenever the action changes.
 */
export class PlacementPreview {
  constructor(model) {
    this.model = model;
    this.action = null;
    this.step = 0;
    this.startScreen = null;

    this.caption = label('', {classes: ['dim-label', 'caption'], ellipsize: true});
    this.caption.set_hexpand(true);
    this.caption.set_xalign(1);
    this.stepLabel = label('', {classes: ['caption']});
    this.stepper = box('horizontal', 2);
    this.stepper.append(button('', () => this._step(-1), {icon: 'go-previous-symbolic', classes: ['flat', 'circular'], tooltip: 'Previous press'}));
    this.stepper.append(this.stepLabel);
    this.stepper.append(button('', () => this._step(1), {icon: 'go-next-symbolic', classes: ['flat', 'circular'], tooltip: 'Next press'}));

    const header = box('horizontal', 8);
    header.append(label('Preview', {classes: ['heading']}));
    header.append(this.stepper);
    header.append(this.caption);

    this.canvas = new ScreenCanvas({
      onScreenClicked: index => {
        this.startScreen = index;
        this.refresh();
      },
    });
    this.widget = box('vertical', 8);
    this.widget.append(header);
    this.widget.append(this.canvas.widget);
  }

  setAction(action) {
    this.action = action;
    this.refresh();
  }

  _step(delta) {
    const ops = resolveAction(this.action)?.operations ?? [];
    if (!ops.length) return;
    this.step = (this.step + delta + ops.length) % ops.length;
    this.refresh();
  }

  refresh() {
    const screens = previewScreens(this.model);
    if (this.startScreen !== null && this.startScreen >= screens.length) this.startScreen = null;
    const resolved = resolveAction(this.action);
    const ops = resolved?.op === 'chain' ? (resolved.operations ?? []) : [];
    this.stepper.set_visible(ops.length > 1);
    if (ops.length) this.step %= ops.length;
    this.stepLabel.set_label(ops.length > 1 ? `Press ${this.step + 1} of ${ops.length}` : '');

    const placement = place(this.action, {screens, settings: this.model.configuration.windows, step: this.step, startScreen: this.startScreen});
    const sample = this.model.status.screens ? '' : ' (sample displays)';
    if (!placement) {
      this.caption.set_label('');
      this.canvas.update({screens, origin: null, target: null, windows: [], dimmed: true}, 'No displays found');
      return;
    }
    const start = screens[this.startScreen ?? -1] ?? mainScreen(screens);
    const state = placement.state;
    if (state.kind === 'placed') {
      this.caption.set_label(describeFrame(state.frame) + sample);
      this.canvas.update({screens, origin: placement.sample, target: state.frame, windows: [], dimmed: false});
    } else if (state.kind === 'unavailable') {
      this.caption.set_label(`From the center of ${start?.name ?? 'the main display'}${sample}`);
      const message = state.reason ? `Preview unavailable\n${state.reason}` : 'Preview unavailable';
      this.canvas.update({screens, origin: placement.sample, target: null, windows: [], dimmed: true}, message);
    } else {
      this.caption.set_label('');
      this.canvas.update({screens, origin: null, target: null, windows: [], dimmed: true}, state.message);
    }
    this.canvas.area.set_tooltip_text(screens.length > 1 ? 'Click a display to start the window there' : null);
  }
}

/** The layout editor's preview: each app's first window where its first operation puts it. */
export class LayoutPreview {
  constructor(model) {
    this.model = model;
    this.canvas = new ScreenCanvas({height: 190});
    this.widget = box('vertical', 8);
    this.widget.append(label('Preview', {classes: ['heading']}));
    this.widget.append(this.canvas.widget);
  }

  setLayout(layout) {
    const screens = previewScreens(this.model);
    const {windows, reason} = layoutPlacements(layout, {screens, settings: this.model.configuration.windows});
    let message = null;
    if (!windows.length) {
      message = (layout.apps ?? []).length ? `Preview unavailable${reason ? `\n${reason}` : ''}` : 'Add apps to see the layout';
    }
    this.canvas.update({screens, origin: null, target: null, windows, dimmed: !windows.length}, message);
  }
}
