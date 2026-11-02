// Every setting shows its key in the files under its title (`settings.json › island.enabled`), and a
// right-click on it offers Copy Key, Copy Value as JSON and Open the file (port of the Mac's
// ConfigKeyViews.swift). Settings name their key from the registry (lib/core/configKeys.js); an item
// editor's fields name theirs relative to the item (`trigger`, `action.direction`), resolving the
// item's full key when the menu is used, since its place in the list can change. The preferences UI
// test fails when a control in a pane has neither a key nor a reason it has none.

import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {appendKey, bindingKey, hotstringKey, itemKey, keyDisplay, keyPath, layoutKey, valueText} from '../../core/index.js';
import {escapeMarkup} from '../util.js';
import {keyLinkMarkup} from '../filelinks.js';
import {linkedMarkup, setLinkedDescription, wireLinks} from './filelinks.js';

/** The window's model and actions: {model, toast(message), open(file)}. Set once by the window. */
let context = null;

export function setConfigKeyContext(value) {
  context = value;
}

/** Whether keys are shown (`general.showConfigKeys`, on by default). */
export function keysShown() {
  return context?.model?.configuration?.general?.showConfigKeys !== false;
}

/**
 * A key as a row shows it: {text, resolve()}. `text` is what's shown, `resolve` gives the key now
 * (null when the item isn't in the file).
 */
export function settingKey(key) {
  return {text: keyDisplay(key), resolve: () => key};
}

/** The fields of an item: `resolve` gives the item's key now. */
export function itemScope(resolve) {
  return {text: '', resolve};
}

/** The fields of the binding with `id`, wherever it is in the list now. */
export function bindingScope(model, id) {
  return itemScope(() => {
    const index = model.configuration.bindings.findIndex(b => b.id === id);
    return index < 0 ? null : bindingKey(model.configuration, index);
  });
}

/** The fields of the hotstring with `id`. */
export function hotstringScope(model, id) {
  return itemScope(() => {
    const index = model.configuration.hotstrings.findIndex(h => h.id === id);
    return index < 0 ? null : hotstringKey(model.configuration, index);
  });
}

/** The fields of the layout the editor shows; `index()` gives its place in the list now. */
export function layoutScope(model, index) {
  return itemScope(() => {
    const i = index();
    return i === null || i < 0 || i >= model.configuration.layouts.length ? null : layoutKey(model.configuration, i);
  });
}

/** The field at `path` (dotted) under `scope`. */
export function fieldKey(scope, path) {
  if (!scope) return null;
  return {
    text: scope.text ? `${scope.text}.${path}` : path,
    resolve: () => {
      const key = scope.resolve();
      return key ? appendKey(key, path) : null;
    },
  };
}

/** The item at `index` of the list `scope` names (a chain's operations). */
export function fieldIndex(scope, index) {
  if (!scope) return null;
  return {
    text: `${scope.text}[${index}]`,
    resolve: () => {
      const key = scope.resolve();
      return key ? itemKey(key, index) : null;
    },
  };
}

// The key's file name is a link that opens the file (filelinks.js); the rest is plain.
const keyMarkup = text => `<span font_family="monospace" size="small">${keyLinkMarkup(text)}</span>`;
/** Text for a row with markup on: only what Pango would read as markup is escaped, so titles stay as written. */
const markupText = text => String(text ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/**
 * Shows `info`'s key on `row` and gives the row the right-click menu. `kind` is how: "action" rows
 * (Adw.ActionRow, SwitchRow, ComboRow, SpinRow, ExpanderRow) show it under the title, above
 * `subtitle`; "entry" rows (Adw.EntryRow, whose title is its placeholder) at their end; "widget" (a
 * switch, a text view) in its tooltip, for a widget whose row or heading shows the key too.
 * Returns `row`.
 */
export function attachKey(row, info, {kind = 'action', title = null, subtitle = null} = {}) {
  if (!info) return row;
  row._slatedConfigKey = {info, kind, title, subtitle, tooltip: kind === 'widget' ? row.get_tooltip_text() : null};
  if (kind === 'action') row.set_use_markup(true);
  if (kind === 'entry') {
    const caption = new Gtk.Label({use_markup: true, css_classes: ['dim-label', 'slated-config-key'], valign: Gtk.Align.CENTER});
    row.add_suffix(caption);
    row._slatedConfigKey.caption = caption;
  }
  applyKey(row);
  // The file's name in the key opens it, wherever the row shows it (its subtitle is a label of its own).
  if (kind !== 'widget') wireLinks(row);
  const click = new Gtk.GestureClick({button: 3});
  click.connect('pressed', () => showMenu(row));
  row.add_controller(click);
  return row;
}

/**
 * Keys rows a helper built (an action's parameter rows) that don't have a key of their own yet, each
 * the way its kind of row shows one: rows with a subtitle under the title, entry rows beside it,
 * anything else in its tooltip.
 */
export function keyRows(rows, info) {
  for (const row of rows) {
    if (!row || row._slatedConfigKey || row._slatedNoKey) continue;
    // `in`, not typeof: a GObject wrapper may throw for a method its class doesn't have.
    if ('set_subtitle' in row) attachKey(row, info, {title: row.get_title(), subtitle: row.get_subtitle() || null});
    else if ('set_show_apply_button' in row) attachKey(row, info, {kind: 'entry'});
    else attachKey(row, info, {kind: 'widget'});
  }
}

/**
 * Shows `info`'s key in an Adw.PreferencesGroup's description, after `description`, for a group whose
 * controls (a list of apps, a switch in its header) edit one setting. Returns the group.
 */
export function groupKey(group, info, description = '') {
  return attachKey(group, info, {kind: 'group', subtitle: description});
}

/** Marks a control that edits nothing in the files (a test field, a search), for the UI test. */
export function noKey(widget, reason) {
  widget._slatedNoKey = reason;
  return widget;
}

/** Shows the row's key, or hides it, as "Show config keys" says. */
export function applyKey(row) {
  const s = row._slatedConfigKey;
  if (!s) return;
  if (s.kind === 'caption') {
    row._slatedCaptionUpdate?.();
    return;
  }
  const text = keysShown() ? s.info.text : '';
  if (s.kind === 'entry') {
    s.caption.set_label(keyLinkMarkup(text));
    s.caption.set_visible(Boolean(text));
  } else if (s.kind === 'action') {
    if (s.title !== null) row.set_title(markupText(s.title));
    row.set_subtitle([text && keyMarkup(text), s.subtitle && linkedMarkup(s.subtitle)].filter(Boolean).join('\n'));
  } else if (s.kind === 'group') {
    // A group's description is plain text: the key goes on a line of its own, and the label libadwaita
    // shows it in gets the markup with the links.
    const markup = [s.subtitle && linkedMarkup(s.subtitle), text && keyLinkMarkup(text)].filter(Boolean).join('\n');
    setLinkedDescription(row, [s.subtitle, text].filter(Boolean).join('\n'), markup);
  } else {
    row.set_tooltip_text([s.tooltip, text].filter(Boolean).join('\n') || null);
  }
}

/** Changes a keyed row's subtitle (plain text), keeping its key above it. */
export function setSubtitle(row, subtitle) {
  if (!row._slatedConfigKey) {
    row.set_subtitle(subtitle ?? '');
    return;
  }
  row._slatedConfigKey.subtitle = subtitle;
  applyKey(row);
}

/** Changes a keyed row's title (plain text), escaping it for the markup the key needs. */
export function setTitle(row, title) {
  if (!row._slatedConfigKey) {
    row.set_title(title ?? '');
    return;
  }
  row._slatedConfigKey.title = title;
  applyKey(row);
}

/** Re-applies every key under `root`, after "Show config keys" changed. */
export function refreshKeys(root) {
  const walk = widget => {
    if (widget._slatedConfigKey) applyKey(widget);
    for (let child = widget.get_first_child(); child; child = child.get_next_sibling()) walk(child);
  };
  if (root) walk(root);
}

/** A small caption with an item's location, for an editor's header: `config.json › hotstrings › ";sig"`. */
export function itemCaption(resolve, {pathOnly = false} = {}) {
  const caption = new Gtk.Label({xalign: 0, use_markup: true, css_classes: ['dim-label', 'slated-config-key'], selectable: false});
  caption._slatedConfigKey = {info: {text: '', resolve}, kind: 'caption'};
  const click = new Gtk.GestureClick({button: 3});
  click.connect('pressed', () => showMenu(caption));
  caption.add_controller(click);
  const update = () => {
    const key = keysShown() ? resolve() : null;
    caption.set_label(key ? (pathOnly ? escapeMarkup(keyPath(key)) : keyLinkMarkup(keyDisplay(key))) : '');
    caption.set_visible(Boolean(key));
  };
  caption._slatedCaptionUpdate = update;
  wireLinks(caption);
  update();
  return {widget: caption, update};
}

function showMenu(widget) {
  const key = widget._slatedConfigKey?.info.resolve();
  if (!key || !context) return;
  const popover = new Gtk.Popover();
  const list = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, spacing: 0});
  const item = (text, run) => {
    const button = new Gtk.Button({child: new Gtk.Label({label: text, xalign: 0}), css_classes: ['flat']});
    button.connect('clicked', () => {
      popover.popdown();
      run();
    });
    list.append(button);
  };
  item('Copy Key', () => copyKey(widget, key));
  item('Copy Value as JSON', () => copyValue(widget, key));
  item(`Open ${key.file}`, () => context.open(key.file));
  popover.set_child(list);
  popover.set_parent(widget);
  // The open menu, for the preferences UI test (the popover isn't one of the widget's children).
  widget._slatedConfigKeyMenu = popover;
  // Made for this one right-click: gone once closed, so no row is left holding a popover.
  popover.connect('closed', () => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
    popover.unparent();
    return GLib.SOURCE_REMOVE;
  }));
  popover.popup();
}

/** Copy Key: the key's path in its file (`island.cheatSheetDelay`, `hotstrings[2].replacement`). */
export function copyKey(widget, key) {
  widget.get_clipboard().set(keyPath(key));
  context.model.log('ui.config_key_copied', {file: key.file, copied: 'key'});
  context.toast(`Copied ${keyPath(key)}`);
}

/** Copy Value as JSON: the value as the file has it (the window's version, which is what's saved). */
export function copyValue(widget, key) {
  const text = valueText(context.model.configuration, key, context.model.extras);
  if (text === null) {
    context.toast(`${keyPath(key)} isn't in ${key.file}: it's at its default.`);
    return;
  }
  widget.get_clipboard().set(text);
  context.model.log('ui.config_key_copied', {file: key.file, copied: 'value'});
  context.toast(`Copied the value of ${keyPath(key)}`);
}
