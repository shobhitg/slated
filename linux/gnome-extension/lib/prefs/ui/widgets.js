// Small building blocks shared by the settings pages: keycaps, status pills, notices, action glyphs,
// rows with guarded two-way updates, and launching files and links.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import Pango from 'gi://Pango';

import {keycaps as keycapLabels, keysCombo, spokenCombo} from '../keys.js';
import {matchingPreset} from '../presets.js';
import {kindById, kindOf} from '../actions.js';
import {escapeMarkup} from '../util.js';

// --- Text and layout --------------------------------------------------------------------------------

export function label(text, {classes = [], xalign = 0, wrap = false, selectable = false, ellipsize = false, markup = false} = {}) {
  const widget = new Gtk.Label({label: text ?? '', xalign, wrap, selectable, use_markup: markup, css_classes: classes});
  if (wrap) widget.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
  if (ellipsize) widget.set_ellipsize(Pango.EllipsizeMode.END);
  return widget;
}

export function box(orientation = 'vertical', spacing = 6, classes = []) {
  return new Gtk.Box({
    orientation: orientation === 'vertical' ? Gtk.Orientation.VERTICAL : Gtk.Orientation.HORIZONTAL,
    spacing, css_classes: classes,
  });
}

/** Removes every child of a Gtk.Box (or similar container with get_first_child/remove). */
export function clear(container) {
  let child = container.get_first_child();
  while (child) {
    const next = child.get_next_sibling();
    container.remove(child);
    child = next;
  }
}

export function button(labelText, onClick, {classes = [], icon = null, tooltip = null, valign = Gtk.Align.CENTER} = {}) {
  const widget = new Gtk.Button({css_classes: classes, valign, tooltip_text: tooltip});
  if (icon && labelText) widget.set_child(new Adw.ButtonContent({icon_name: icon, label: labelText}));
  else if (icon) widget.set_icon_name(icon);
  else widget.set_label(labelText);
  widget.connect('clicked', () => onClick(widget));
  return widget;
}

export function icon(name, {size = 16, classes = []} = {}) {
  return new Gtk.Image({icon_name: name, pixel_size: size, css_classes: classes});
}

// --- Keycaps, pills, badges -----------------------------------------------------------------------

/**
 * A key combination as keycaps: ✦ A, or Ctrl Alt ←; a modal key comes first, with an arrow.
 * `keys` is a config string ("hyper+a") or KeyCombo object.
 */
export function keycaps(keys, {modal = null, size = 'small', dim = false, emptyText = null} = {}) {
  const row = box('horizontal', 3, ['slated-keycaps']);
  if (dim) row.add_css_class('dim');
  row.set_valign(Gtk.Align.CENTER);
  const addCaps = combo => {
    for (const cap of keycapLabels(keysCombo(combo))) {
      const classes = ['slated-keycap'];
      if (cap.hyper) classes.push('hyper');
      if (size === 'large') classes.push('large');
      row.append(new Gtk.Label({label: cap.label, css_classes: classes, valign: Gtk.Align.CENTER}));
    }
  };
  const combo = keysCombo(keys);
  if (!combo.key && emptyText) {
    row.append(label(emptyText, {classes: ['dim-label', 'caption']}));
    return row;
  }
  if (modal?.keys) {
    addCaps(modal.keys);
    row.append(new Gtk.Label({label: '→', css_classes: ['dim-label'], margin_start: 2, margin_end: 2}));
  }
  addCaps(keys);
  row.set_tooltip_text(spokenCombo(combo));
  return row;
}

/** A status pill: {label, style} from status.statePresentation (style: success/warning/error/accent/dim). */
export function pill(presentation) {
  return new Gtk.Label({
    label: presentation.label, css_classes: ['slated-pill', presentation.style ?? 'dim'], valign: Gtk.Align.CENTER,
  });
}

export function badge(text, {warning = false} = {}) {
  const classes = ['slated-badge'];
  if (warning) classes.push('warning');
  return new Gtk.Label({label: String(text), css_classes: classes, valign: Gtk.Align.CENTER});
}

/** A hotstring trigger in a monospaced accent chip. */
export function triggerChip(text) {
  return new Gtk.Label({label: text || '—', css_classes: ['slated-trigger'], valign: Gtk.Align.CENTER});
}

// --- Notices and empty states ---------------------------------------------------------------------

const NOTICE_ICONS = {
  info: 'dialog-information-symbolic', ok: 'object-select-symbolic', warning: 'dialog-warning-symbolic',
  error: 'dialog-error-symbolic',
};

/**
 * A card with an icon, a title, optional detail text and buttons ({label, onClick, suggested}).
 * Returns {widget, update({level, title, detail})}.
 */
export function notice({level = 'info', title, detail = null, iconName = null, actions = []}) {
  const card = box('horizontal', 12, ['card', 'slated-notice', level]);
  const image = icon(iconName ?? NOTICE_ICONS[level] ?? NOTICE_ICONS.info, {size: 16});
  image.set_valign(Gtk.Align.START);
  image.set_margin_top(2);
  card.append(image);
  const texts = box('vertical', 4);
  texts.set_hexpand(true);
  const titleLabel = label(title, {classes: ['heading'], wrap: true});
  const detailLabel = label(detail ?? '', {wrap: true, selectable: true});
  detailLabel.set_visible(Boolean(detail));
  texts.append(titleLabel);
  texts.append(detailLabel);
  card.append(texts);
  if (actions.length) {
    const buttons = box('horizontal', 6);
    buttons.set_valign(Gtk.Align.CENTER);
    for (const action of actions) {
      buttons.append(button(action.label, action.onClick, {classes: action.suggested ? ['suggested-action', 'pill'] : ['pill']}));
    }
    card.append(buttons);
  }
  return {
    widget: card,
    update({level: newLevel = level, title: newTitle = title, detail: newDetail = null}) {
      for (const l of Object.keys(NOTICE_ICONS)) card.remove_css_class(l);
      card.add_css_class(newLevel);
      image.set_from_icon_name(iconName ?? NOTICE_ICONS[newLevel] ?? NOTICE_ICONS.info);
      titleLabel.set_label(newTitle);
      detailLabel.set_label(newDetail ?? '');
      detailLabel.set_visible(Boolean(newDetail));
    },
  };
}

/** An Adw.StatusPage with buttons ({label, onClick, suggested}). The description is plain text. */
export function emptyState({iconName, title, description, actions = []}) {
  // StatusPage's description is always Pango markup (its title never is).
  const page = new Adw.StatusPage({icon_name: iconName, title, description: escapeMarkup(description), vexpand: true});
  if (actions.length) {
    const buttons = box('horizontal', 12);
    buttons.set_halign(Gtk.Align.CENTER);
    for (const action of actions) {
      buttons.append(button(action.label, action.onClick, {classes: action.suggested ? ['suggested-action', 'pill'] : ['pill']}));
    }
    page.set_child(buttons);
  }
  return page;
}

// --- Colors and drawing ---------------------------------------------------------------------------

/** The widget's foreground color as {r, g, b, a} (GTK 4.10+ get_color). */
export function foreground(widget) {
  const c = widget.get_color();
  return {r: c.red, g: c.green, b: c.blue, a: c.alpha};
}

/** The accent color: the system accent on libadwaita 1.6+ (GNOME 47), else Adwaita blue. */
export function accent() {
  const manager = Adw.StyleManager.get_default();
  if ('get_accent_color_rgba' in manager) {
    const c = manager.get_accent_color_rgba();
    return {r: c.red, g: c.green, b: c.blue, a: 1};
  }
  return {r: 0x35 / 255, g: 0x84 / 255, b: 0xe4 / 255, a: 1};
}

export function isDark() {
  return Adw.StyleManager.get_default().get_dark();
}

/** Adds a rounded rectangle to the current Cairo path. */
export function roundedRect(cr, x, y, width, height, radius) {
  const r = Math.max(0, Math.min(radius, width / 2, height / 2));
  cr.newSubPath();
  cr.arc(x + width - r, y + r, r, -Math.PI / 2, 0);
  cr.arc(x + width - r, y + height - r, r, 0, Math.PI / 2);
  cr.arc(x + r, y + height - r, r, Math.PI / 2, Math.PI);
  cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
  cr.closePath();
}

const setColor = (cr, c, alpha = 1) => cr.setSourceRGBA(c.r, c.g, c.b, (c.a ?? 1) * alpha);
export {setColor};

/**
 * A small glyph for an action: the screen region its preset covers (left half…), or the operation's
 * icon. Redraws itself; call `.update(action)` when the action changes.
 */
export function glyph(action, {width = 26, height = 18} = {}) {
  const stack = new Gtk.Stack({valign: Gtk.Align.CENTER, halign: Gtk.Align.CENTER});
  const area = new Gtk.DrawingArea({content_width: width, content_height: height});
  const image = icon('view-fullscreen-symbolic', {size: Math.round(height * 0.8)});
  stack.add_named(area, 'region');
  stack.add_named(image, 'icon');
  let region = null;
  area.set_draw_func((_area, cr, w, h) => {
    const fg = foreground(area);
    roundedRect(cr, 0.5, 0.5, w - 1, h - 1, 3.5);
    setColor(cr, fg, 0.06);
    cr.fillPreserve();
    setColor(cr, fg, 0.3);
    cr.setLineWidth(1);
    cr.stroke();
    if (region) {
      const inner = {x: 2, y: 2, width: w - 4, height: h - 4};
      roundedRect(cr, inner.x + region.x * inner.width + 0.25, inner.y + region.y * inner.height + 0.25,
        Math.max(2, region.width * inner.width - 0.5), Math.max(2, region.height * inner.height - 0.5), 1.8);
      setColor(cr, accent(), 0.9);
      cr.fill();
    }
    cr.$dispose();
  });
  const update = next => {
    const preset = matchingPreset(next);
    region = preset?.region ?? null;
    if (region) {
      stack.set_visible_child_name('region');
      area.queue_draw();
    } else {
      image.set_from_icon_name(preset?.icon ?? kindById(kindOf(next))?.icon ?? 'dialog-question-symbolic');
      stack.set_visible_child_name('icon');
    }
  };
  update(action);
  stack._slatedUpdate = update;
  return stack;
}

// --- Rows with guarded two-way updates ----------------------------------------------------------------

/**
 * An Adw.ComboRow over fixed choices. `items` is [{id, label}]; `onChange(id)` runs on user changes
 * only. Returns {row, set(id), setItems(items)}.
 */
export function comboRow({title, subtitle = null, items, selected, onChange}) {
  let current = items;
  let quiet = false;
  const model = Gtk.StringList.new(current.map(i => i.label));
  const row = new Adw.ComboRow({use_markup: false, title, subtitle: subtitle ?? '', model});
  const indexOf = id => Math.max(0, current.findIndex(i => i.id === id));
  row.set_selected(indexOf(selected));
  row.connect('notify::selected', () => {
    if (quiet) return;
    const item = current[row.get_selected()];
    if (item) onChange(item.id);
  });
  const set = id => {
    const index = indexOf(id);
    if (row.get_selected() === index) return;
    quiet = true;
    row.set_selected(index);
    quiet = false;
  };
  return {
    row,
    set,
    setItems(items, id) {
      const same = items.length === current.length && items.every((item, i) => item.id === current[i].id && item.label === current[i].label);
      if (same) {
        set(id);
        return;
      }
      quiet = true;
      current = items;
      model.splice(0, model.get_n_items(), items.map(i => i.label));
      row.set_selected(indexOf(id));
      quiet = false;
    },
  };
}

/** An Adw.SwitchRow. Returns {row, set(active)}. */
export function switchRow({title, subtitle = null, active, onChange}) {
  let quiet = false;
  const row = new Adw.SwitchRow({use_markup: false, title, subtitle: subtitle ?? '', active: Boolean(active)});
  row.connect('notify::active', () => {
    if (!quiet) onChange(row.get_active());
  });
  return {
    row,
    set(value) {
      if (row.get_active() === Boolean(value)) return;
      quiet = true;
      row.set_active(Boolean(value));
      quiet = false;
    },
  };
}

/** An Adw.EntryRow. Returns {row, set(text)}; `onChange` runs as the user types. */
export function entryRow({title, text, onChange, monospace = false}) {
  let quiet = false;
  const row = new Adw.EntryRow({use_markup: false, title, text: text ?? ''});
  if (monospace) row.add_css_class('slated-mono');
  row.connect('changed', () => {
    if (!quiet) onChange(row.get_text());
  });
  return {
    row,
    set(value) {
      if (row.get_text() === (value ?? '')) return;
      quiet = true;
      row.set_text(value ?? '');
      quiet = false;
    },
  };
}

/** An Adw.SpinRow (libadwaita 1.4+). Returns {row, set(value)}. */
export function spinRow({title, subtitle = null, min, max, step = 1, digits = 0, value, onChange}) {
  let quiet = false;
  const row = Adw.SpinRow.new_with_range(min, max, step);
  row.set_title(title);
  if (subtitle) row.set_subtitle(subtitle);
  row.set_digits(digits);
  row.set_value(value);
  row.connect('notify::value', () => {
    if (!quiet) onChange(row.get_value());
  });
  return {
    row,
    set(next) {
      if (row.get_value() === next) return;
      quiet = true;
      row.set_value(next);
      quiet = false;
    },
  };
}

/** A multi-line text editor in a card. Returns {widget, set(text), get()}. */
export function textArea({text, onChange, monospace = false, minHeight = 80, placeholder = null}) {
  let quiet = false;
  const view = new Gtk.TextView({
    wrap_mode: Gtk.WrapMode.WORD_CHAR,
    top_margin: 4, bottom_margin: 4, left_margin: 4, right_margin: 4,
    monospace, accepts_tab: false,
  });
  view.get_buffer().set_text(text ?? '', -1);
  view.get_buffer().connect('changed', () => {
    if (!quiet) onChange(view.get_buffer().get_property('text'));
  });
  const scroller = new Gtk.ScrolledWindow({
    child: view, min_content_height: minHeight, max_content_height: Math.max(minHeight, 220), propagate_natural_height: true,
    hscrollbar_policy: Gtk.PolicyType.NEVER, css_classes: ['card', 'slated-textview'],
  });
  if (placeholder) view.set_tooltip_text(placeholder);
  return {
    widget: scroller,
    view,
    get: () => view.get_buffer().get_property('text'),
    set(value) {
      if (view.get_buffer().get_property('text') === (value ?? '')) return;
      quiet = true;
      view.get_buffer().set_text(value ?? '', -1);
      quiet = false;
    },
  };
}

/** A row showing a shell command in monospace, with a Copy button. */
export function commandRow(title, command, toast = null) {
  const row = new Adw.ActionRow({use_markup: false, title, subtitle: command, subtitle_selectable: true});
  row.add_css_class('slated-mono-subtitle');
  const copy = button('', () => {
    // GJS exposes gdk_clipboard_set_value() as set(); set_text() isn't introspectable.
    copy.get_clipboard().set(command);
    toast?.('Copied to the clipboard');
  }, {icon: 'edit-copy-symbolic', classes: ['flat'], tooltip: 'Copy'});
  row.add_suffix(copy);
  return row;
}

/** A PreferencesGroup with optional header suffix. */
export function group({title = null, description = null, suffix = null} = {}) {
  const g = new Adw.PreferencesGroup({title: title ?? '', description: description ?? ''});
  if (suffix) g.set_header_suffix(suffix);
  return g;
}

// --- Files and links ---------------------------------------------------------------------------------

/** Opens a file with its default app (or shows it in Files with `folder: true`). */
export function launchFile(path, parent, {folder = false, onError = null} = {}) {
  const launcher = new Gtk.FileLauncher({file: Gio.File.new_for_path(path)});
  const root = parent?.get_root?.() ?? null;
  const done = (source, result) => {
    try {
      if (folder) launcher.open_containing_folder_finish(result);
      else launcher.launch_finish(result);
    } catch (error) {
      if (!error.matches?.(Gtk.DialogError, Gtk.DialogError.DISMISSED)) onError?.(error);
    }
  };
  if (folder) launcher.open_containing_folder(root, null, done);
  else launcher.launch(root, null, done);
}

export function launchUri(uri, parent) {
  const launcher = new Gtk.UriLauncher({uri});
  launcher.launch(parent?.get_root?.() ?? null, null, (source, result) => {
    try {
      launcher.launch_finish(result);
    } catch {
      // The user dismissed the app chooser.
    }
  });
}
