// Edits any action: pick the operation from a categorized palette, start from a preset, then
// fine-tune its parameters (port of the macOS ActionEditor, ActionParameters, OperationListEditor
// and OrientationEditor). Every edit rebuilds a canonical action through actions.updateAction, so
// the draft always holds valid JSON in config.json's shape.
//
// Chains, sequences, layouts' operations and by-orientation branches edit their inner actions on a
// pushed page (drill-down), as GNOME settings do.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {
  CATEGORIES, kindById, kindsInCategory, kindOf, isGeometryKind, formFromAction, updateAction, convertAction,
  actionTitle, actionDetail, EXTRA_STEPS,
} from '../actions.js';
import {PRESETS, PRESET_GROUPS, presetMatches} from '../presets.js';
import {checkExpression, sampleVariables} from '../expressions.js';
import {actionProblems} from '../validator.js';
import {orderedLeftToRight, sampleFrame, mainScreen, previews} from '../placement.js';
import {stableStringify} from '../util.js';
import {
  box, label, button, icon, glyph, comboRow, switchRow, entryRow, spinRow, textArea, notice, group, clear,
} from './widgets.js';
import {ShortcutRecorder} from './recorder.js';
import {PlacementPreview, previewScreens} from './preview.js';
import {appPickerButton} from './apps.js';

const EDGE_ITEMS = [
  {id: 'left', label: 'Left'}, {id: 'right', label: 'Right'}, {id: 'up', label: 'Top'}, {id: 'down', label: 'Bottom'},
];
const CORNER_ITEMS = [
  {id: 'top-left', label: 'Top Left'}, {id: 'top-right', label: 'Top Right'},
  {id: 'bottom-left', label: 'Bottom Left'}, {id: 'bottom-right', label: 'Bottom Right'},
];
const STYLE_ITEMS = [
  {id: 'none', label: 'Keep size'}, {id: 'center', label: 'Centered on the edge'}, {id: 'bar', label: 'Fill the edge'},
  {id: 'bar-resize', label: 'Fill the edge and resize'},
];
const FOCUS_ITEMS = [
  {id: 'left', label: 'Left'}, {id: 'right', label: 'Right'}, {id: 'up', label: 'Up'}, {id: 'down', label: 'Down'},
  {id: 'behind', label: 'Behind'},
];
const METHOD_ITEMS = [
  {id: 'auto', label: 'Automatic'}, {id: 'type', label: 'Typing'}, {id: 'paste', label: 'Pasting'},
];
export const METHOD_HINTS = {
  auto: 'Types short text and pastes long text.',
  type: 'Types each character. Works in every app; slower for long text.',
  paste: 'Pastes through the clipboard, then puts your clipboard back.',
};
const SELECTOR_ITEMS = [
  {id: 'current', label: 'Current App'}, {id: 'all', label: 'All Apps'}, {id: 'allBut', label: 'All Apps But One'},
  {id: 'apps', label: 'These Apps'},
];

const styleKind = style => (typeof style === 'string' && style.startsWith('bar-resize:') ? 'bar-resize' : style || 'none');
const selectorKind = s => (s === 'current' || s === 'all' ? s : typeof s === 'string' && s.startsWith('all-but:') ? 'allBut' : 'apps');

/** Display choices for screen references: the window's own display, relative ones, then each display. */
function screenItems(model, current, allowsNone) {
  const items = allowsNone ? [{id: '', label: "Window's display"}] : [];
  items.push({id: 'next', label: 'Next display'}, {id: 'previous', label: 'Previous display'},
    {id: 'left', label: 'Display to the left'}, {id: 'right', label: 'Display to the right'},
    {id: 'up', label: 'Display above'}, {id: 'down', label: 'Display below'});
  orderedLeftToRight(previewScreens(model)).forEach((screen, i) => items.push({id: String(i), label: `Display ${i + 1} · ${screen.name}`}));
  if (current && !items.some(i => i.id === current)) items.push({id: current, label: current});
  return items;
}

/** Variables for evaluating expressions: the preview's main display and its sample window. */
function variablesFor(model) {
  const screens = previewScreens(model);
  const screen = mainScreen(screens);
  const window = sampleFrame(screens);
  return screen && window ? sampleVariables(screen.visibleFrame, window) : undefined;
}

const VARIABLE_GROUPS = [
  ['Screen (work area)', ['screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY']],
  ['Window', ['windowTopLeftX', 'windowTopLeftY', 'windowSizeX', 'windowSizeY']],
  ['Functions', ['min(', 'max(', 'floor(', 'ceiling(', 'abs(', 'sqrt(']],
];

/** A row with a monospaced expression entry, checked as you type, and a menu of variables. */
function expressionRow(model, {title, value, relative = false, onChange}) {
  let quiet = false;
  const row = new Adw.ActionRow({use_markup: false, title});
  const entry = new Gtk.Entry({
    text: value ?? '', hexpand: true, valign: Gtk.Align.CENTER, width_chars: 22, css_classes: ['slated-mono'],
    placeholder_text: relative ? '+10%' : 'screenSizeX/2',
  });
  const insert = box('vertical', 2);
  for (const [heading, names] of VARIABLE_GROUPS) {
    insert.append(label(heading, {classes: ['heading'], xalign: 0}));
    for (const name of names) {
      insert.append(button(name.endsWith('(') ? `${name}…)` : name, () => {
        popover.popdown();
        entry.set_text(entry.get_text() + name);
        entry.grab_focus();
      }, {classes: ['flat']}));
    }
  }
  const popover = new Gtk.Popover({child: insert});
  const menu = new Gtk.MenuButton({icon_name: 'list-add-symbolic', popover, valign: Gtk.Align.CENTER, css_classes: ['flat'],
    tooltip_text: 'Insert a variable or function'});
  row.add_suffix(entry);
  row.add_suffix(menu);
  const validate = () => {
    const result = checkExpression(entry.get_text(), {relative, variables: variablesFor(model)});
    let message = '';
    let invalid = false;
    if (result.status === 'empty') [message, invalid] = ['Required', true];
    else if (result.status === 'invalid') [message, invalid] = [result.message, true];
    else if (result.value !== null && result.value !== undefined) message = `= ${Math.round(result.value)}`;
    row.set_subtitle(message);
    if (invalid) row.add_css_class('slated-invalid');
    else row.remove_css_class('slated-invalid');
  };
  entry.connect('changed', () => {
    validate();
    if (!quiet) onChange(entry.get_text());
  });
  validate();
  return {
    row,
    sync(next) {
      if (entry.get_text() !== (next ?? '')) {
        quiet = true;
        entry.set_text(next ?? '');
        quiet = false;
      }
      validate();
    },
  };
}

/**
 * Pushes a page that edits one nested action (a chain step, a by-orientation branch, a layout
 * operation). `get()` returns undefined once the item is gone; the page then closes itself.
 */
export function pushActionPage(ctx, {title, get, set, depth}) {
  const page = new Adw.NavigationPage({title});
  const prefs = new Adw.PreferencesPage();
  const preview = new PlacementPreview(ctx.model);
  const previewGroup = group();
  previewGroup.add(preview.widget);
  prefs.add(previewGroup);
  const editor = new ActionEditor(ctx, {get, set, depth});
  for (const g of editor.groups) prefs.add(g);
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  const sync = () => {
    const action = get();
    if (action === undefined) {
      // The item was removed (or its parent changed kind): close this page and any above it.
      if (isInStack(ctx.nav, page)) {
        const previous = ctx.nav.get_previous_page(page);
        if (previous) ctx.nav.pop_to_page(previous);
      }
      return;
    }
    page.set_title(actionTitle(action));
    previewGroup.set_visible(previews(action));
    preview.setAction(action);
    editor.sync();
  };
  const offs = [ctx.model.on('config', sync), ctx.model.on('status', sync)];
  page.connect('hidden', () => {
    editor.stopRecording();
    if (!isInStack(ctx.nav, page)) offs.forEach(off => off());
  });
  sync();
  ctx.nav.push(page);
  return page;
}

function isInStack(nav, page) {
  const stack = nav.get_navigation_stack();
  for (let i = 0; i < stack.get_n_items(); i++) {
    if (stack.get_item(i) === page) return true;
  }
  return false;
}

/** The kind picker: a row whose menu opens a palette of every operation, by category. */
function kindPicker(onPick) {
  const row = new Adw.ActionRow({use_markup: false, title: '', subtitle: ''});
  const kindIcon = icon('view-fullscreen-symbolic', {size: 20});
  row.add_prefix(kindIcon);
  const popover = new Gtk.Popover();
  const menu = new Gtk.MenuButton({
    popover, valign: Gtk.Align.CENTER, css_classes: ['flat'], icon_name: 'pan-down-symbolic', tooltip_text: 'Choose an operation',
  });
  row.add_suffix(menu);
  row.set_activatable_widget(menu);
  let allowComposition = true;
  let selected = null;
  const fill = () => {
    const columns = box('horizontal', 18);
    columns.set_margin_top(6);
    columns.set_margin_bottom(6);
    columns.set_margin_start(6);
    columns.set_margin_end(6);
    for (let c = 0; c < CATEGORIES.length; c += 2) {
      const column = box('vertical', 2);
      for (const category of CATEGORIES.slice(c, c + 2)) {
        const heading = label(category.title, {classes: ['heading']});
        heading.set_margin_top(column.get_first_child() === null ? 0 : 8);
        heading.set_margin_start(8);
        column.append(heading);
        for (const k of kindsInCategory(category.id)) {
          const content = box('horizontal', 8);
          content.append(icon(k.icon));
          const text = label(k.title);
          text.set_hexpand(true);
          content.append(text);
          if (k.id === selected) content.append(icon('object-select-symbolic', {classes: ['accent']}));
          const b = new Gtk.Button({child: content, css_classes: ['flat'], tooltip_text: k.explanation});
          b.set_sensitive(allowComposition || (k.id !== 'chain' && k.id !== 'sequence'));
          b.connect('clicked', () => {
            popover.popdown();
            if (k.id !== selected) onPick(k.id);
          });
          column.append(b);
        }
      }
      columns.append(column);
    }
    popover.set_child(columns);
  };
  popover.connect('show', fill);
  return {
    row,
    set(kindId, {composition = true} = {}) {
      const k = kindById(kindId);
      selected = kindId;
      allowComposition = composition;
      row.set_title(k?.title ?? 'Operation');
      row.set_subtitle(CATEGORIES.find(c => c.id === k?.category)?.title ?? '');
      kindIcon.set_from_icon_name(k?.icon ?? 'dialog-question-symbolic');
    },
  };
}

/** Preset buttons, grouped like the macOS gallery; the current placement is highlighted. */
function presetGallery(onPick) {
  const container = box('vertical', 6);
  const buttons = [];
  for (const g of PRESET_GROUPS) {
    const line = box('horizontal', 4);
    const title = label(g.title, {classes: ['dim-label', 'caption']});
    title.set_width_chars(12);
    line.append(title);
    for (const preset of PRESETS.filter(p => p.group === g.id)) {
      const b = new Gtk.Button({child: glyph(preset.action, {width: 32, height: 21}), css_classes: ['flat', 'slated-preset'], tooltip_text: preset.title});
      b.connect('clicked', () => onPick(preset.action));
      buttons.push({preset, button: b});
      line.append(b);
    }
    container.append(line);
  }
  return {
    widget: container,
    sync(action) {
      for (const {preset, button: b} of buttons) {
        if (presetMatches(preset, action)) b.add_css_class('selected');
        else b.remove_css_class('selected');
      }
    },
  };
}

/**
 * Edits one action. `groups` are Adw.PreferencesGroups for the caller's page: the operation (picker,
 * explanation and presets) and its parameters. Call `sync()` after the model changes.
 */
export class ActionEditor {
  /**
   * @param {object} ctx {model, nav, toast, navigate}
   * @param {object} options
   * @param {() => any} options.get the current action
   * @param {(action: any) => void} options.set stores a new action
   * @param {number} [options.depth] nesting level (chains inside chains stop at 2)
   */
  constructor(ctx, {get, set, depth = 0}) {
    this.ctx = ctx;
    this.get = get;
    this.set = set;
    this.depth = depth;
    this.fields = [];
    this.layoutKey = null;

    this.operationGroup = group({title: 'Action'});
    this.picker = kindPicker(kindId => {
      this.set(convertAction(this.get(), kindId, {knownLayouts: this.ctx.model.knownLayoutNames()}));
    });
    this.operationGroup.add(this.picker.row);
    this.presets = presetGallery(action => this.set(JSON.parse(JSON.stringify(action))));
    this.presetsBox = box('vertical', 6);
    this.presetsBox.set_margin_top(12);
    this.presetsBox.append(label('Presets', {classes: ['heading']}));
    this.presetsBox.append(this.presets.widget);
    this.operationGroup.add(this.presetsBox);

    this.paramsGroup = group();
    this.groups = [this.operationGroup, this.paramsGroup];
    this.sync();
  }

  _update(field, value) {
    this.set(updateAction(this.get(), field, value));
  }

  sync() {
    const action = this.get();
    if (action === undefined) return;
    const form = formFromAction(action);
    this.picker.set(form.kind, {composition: this.depth < 2});
    const kind = kindById(form.kind);
    this.operationGroup.set_description(kind?.explanation ?? '');
    this.presetsBox.set_visible(isGeometryKind(form.kind));
    this.presets.sync(action);
    const key = this._layoutKey(form);
    if (key !== this.layoutKey) {
      this.layoutKey = key;
      this._rebuild(form);
    } else {
      for (const field of this.fields) field.sync?.(form);
    }
  }

  _layoutKey(form) {
    const lists = {
      chain: form.kind === 'chain' ? form.operations.map(op => [actionTitle(op), actionDetail(op)]) : null,
      steps: form.kind === 'sequence' ? form.steps.map(s => [actionTitle(s.action), s.keepWindow]) : null,
      branches: form.kind === 'by-orientation' ? [actionTitle(form.landscape), actionTitle(form.portrait)] : null,
      apps: Array.isArray(form.appSelector) ? form.appSelector : null,
      layouts: form.kind === 'layout' ? this.ctx.model.knownLayoutNames() : null,
    };
    return stableStringify([form.kind, form.resizes, styleKind(form.pushStyle), selectorKind(form.appSelector),
      form.grids.length, lists, previewScreens(this.ctx.model).map(s => s.name)]);
  }

  _add(field) {
    const rows = Array.isArray(field.rows) ? field.rows : [field.row];
    for (const row of rows) this.paramsGroup.add(row);
    this.fields.push(field);
    return field;
  }

  _rebuild(form) {
    for (const field of this.fields) {
      for (const row of Array.isArray(field.rows) ? field.rows : [field.row]) this.paramsGroup.remove(row);
    }
    this.fields = [];
    this.paramsGroup.set_description('');
    const model = this.ctx.model;
    const expr = (title, key, relative = false) => {
      const row = expressionRow(model, {title, value: form[key], relative, onChange: v => this._update(key, v)});
      return this._add({row: row.row, sync: f => row.sync(f[key])});
    };
    const combo = (title, key, items, subtitle = null) => {
      const c = comboRow({title, subtitle, items, selected: form[key], onChange: v => this._update(key, v)});
      return this._add({row: c.row, sync: f => c.set(f[key])});
    };
    const toggle = (title, key, subtitle = null) => {
      const s = switchRow({title, subtitle, active: form[key], onChange: v => this._update(key, v)});
      return this._add({row: s.row, sync: f => s.set(f[key])});
    };
    const text = (title, key, monospace = false) => {
      const e = entryRow({title, text: form[key], monospace, onChange: v => this._update(key, v)});
      return this._add({row: e.row, sync: f => e.set(f[key])});
    };
    const screen = (key, allowsNone = true) => {
      const items = screenItems(model, form[key] ?? '', allowsNone);
      const c = comboRow({title: 'Display', items, selected: form[key] ?? '', onChange: v => this._update(key, v || null)});
      return this._add({row: c.row, sync: f => c.set(f[key] ?? '')});
    };
    // Explanations for the fields go in the group's description, below them.
    const hint = text2 => this.paramsGroup.set_description(text2);

    switch (form.kind) {
    case 'move':
      expr('X', 'x');
      expr('Y', 'y');
      expr('Width', 'width');
      expr('Height', 'height');
      screen('screen');
      break;
    case 'resize':
      expr('Width', 'resizeWidth', true);
      expr('Height', 'resizeHeight', true);
      combo('Anchor', 'anchor', CORNER_ITEMS, 'This corner stays where it is');
      hint('Use +10% or -100 to grow or shrink, or an expression for an exact size.');
      break;
    case 'push': {
      combo('Edge', 'direction', EDGE_ITEMS);
      const style = comboRow({
        title: 'Size', items: STYLE_ITEMS, selected: styleKind(form.pushStyle),
        onChange: v => {
          if (v !== 'bar-resize') {
            this._update('pushStyle', v);
            return;
          }
          // Start resizing at half the screen in the direction the window stretches.
          const current = this._form();
          if (styleKind(current.pushStyle) === 'bar-resize') return;
          this._update('pushStyle', `bar-resize:${['up', 'down'].includes(current.direction) ? 'screenSizeY/2' : 'screenSizeX/2'}`);
        },
      });
      this._add({row: style.row, sync: f => style.set(styleKind(f.pushStyle))});
      if (styleKind(form.pushStyle) === 'bar-resize') {
        const vertical = ['up', 'down'].includes(form.direction);
        const row = expressionRow(model, {
          title: vertical ? 'Height' : 'Width', value: form.pushStyle.slice('bar-resize:'.length),
          onChange: v => this._update('pushStyle', `bar-resize:${v}`),
        });
        this._add({row: row.row, sync: f => row.sync(f.pushStyle.slice('bar-resize:'.length))});
      }
      screen('screen');
      break;
    }
    case 'nudge':
      expr('Horizontal', 'nudgeX', true);
      expr('Vertical', 'nudgeY', true);
      hint('Positive values move right and down. Percentages are of the screen size unless nudgePercentOf says otherwise.');
      break;
    case 'throw':
      screen('throwScreen', false);
      toggle('Resize on the new display', 'resizes');
      if (form.resizes) {
        expr('Width', 'width');
        expr('Height', 'height');
      }
      break;
    case 'corner':
      combo('Corner', 'corner', CORNER_ITEMS);
      toggle('Resize', 'resizes');
      if (form.resizes) {
        expr('Width', 'width');
        expr('Height', 'height');
      }
      screen('screen');
      break;
    case 'chain':
      this._add(new OperationList(this.ctx, {
        mode: 'chain', depth: this.depth,
        get: () => formFromAction(this.get()).operations, set: ops => this._update('operations', ops),
      }));
      break;
    case 'sequence':
      this._add(new OperationList(this.ctx, {
        mode: 'sequence', depth: this.depth,
        get: () => formFromAction(this.get()).steps, set: steps => this._update('steps', steps),
      }));
      break;
    case 'layout': {
      const names = model.knownLayoutNames().sort();
      if (!names.length) {
        const row = new Adw.ActionRow({use_markup: false, title: 'No layouts yet', subtitle: 'Create one in Layouts, then pick it here.'});
        row.add_suffix(button('Layouts', () => this.ctx.navigate('layouts'), {classes: ['flat']}));
        this._add({row});
      } else {
        const items = names.map(n => ({id: n, label: n}));
        if (form.name && !names.includes(form.name)) items.unshift({id: form.name, label: `${form.name} (missing)`});
        if (!form.name) items.unshift({id: '', label: 'Choose…'});
        const c = comboRow({title: 'Layout', items, selected: form.name, onChange: v => this._update('name', v)});
        c.row.add_suffix(button('Edit', () => this.ctx.navigate('layouts'), {classes: ['flat'], tooltip: 'Edit layouts'}));
        this._add({row: c.row, sync: f => c.set(f.name)});
      }
      break;
    }
    case 'by-orientation':
      this._add(orientationRows(this.ctx, {
        depth: this.depth,
        get: () => this.get(),
        setBranch: (branch, value) => this._update(branch, value),
      }));
      break;
    case 'focus':
      combo('Direction', 'focusDirection', FOCUS_ITEMS);
      break;
    case 'focus-app': {
      const e = entryRow({title: 'App name', text: form.app, onChange: v => this._update('app', v)});
      e.row.add_suffix(appPickerButton({onPick: app => this._update('app', app.name)}));
      this._add({row: e.row, sync: f => e.set(f.app)});
      break;
    }
    case 'hint':
      text('Letters (default A–Z, 0–9)', 'hintCharacters', true);
      break;
    case 'grid':
      this._add(gridRows(model, {get: () => formFromAction(this.get()), update: (k, v) => this._update(k, v)}));
      break;
    case 'hide': case 'show': case 'toggle':
      this._add(appSelectorRows({get: () => formFromAction(this.get()).appSelector, set: v => this._update('appSelector', v)}));
      break;
    case 'switch':
      this._add({row: notice({level: 'info', title: 'Not available yet',
        detail: "Slated keeps this binding so your Slate file loads, but the app switcher doesn't run yet."}).widget});
      break;
    case 'snapshot':
      text('Snapshot name', 'snapshotName');
      toggle('Save to disk', 'save', 'Survives restarts');
      toggle('Stack', 'stack', 'Keep earlier snapshots with this name');
      break;
    case 'activate-snapshot':
      text('Snapshot name', 'snapshotName');
      toggle('Delete after restoring', 'delete');
      break;
    case 'delete-snapshot':
      text('Snapshot name', 'snapshotName');
      toggle('Delete every stacked snapshot with this name', 'all');
      break;
    case 'insert-text': {
      const area = textArea({text: form.text, onChange: v => this._update('text', v)});
      this._add({row: area.widget, sync: f => area.set(f.text)});
      const method = comboRow({title: 'Insert by', subtitle: METHOD_HINTS[form.method], items: METHOD_ITEMS, selected: form.method,
        onChange: v => this._update('method', v)});
      this._add({row: method.row, sync: f => {
        method.set(f.method);
        method.row.set_subtitle(METHOD_HINTS[f.method] ?? '');
      }});
      break;
    }
    case 'keystroke': {
      const recorder = new ShortcutRecorder({
        title: 'Keys', keys: form.keys, requiresModifier: false, onChange: keys => keys && this._update('keys', keys),
        subtitle: 'Sent to the focused app',
      });
      this._add({row: recorder.row, sync: f => recorder.set(f.keys), recorder});
      break;
    }
    case 'open-url':
      text('URL', 'url', true);
      break;
    case 'shell':
      text('Command', 'command', true);
      text('Folder (default: home)', 'workingDirectory', true);
      toggle('Wait for the command to finish', 'wait');
      break;
    case 'syntax': {
      const e = entryRow({title: 'Slate operation', text: form.syntax, monospace: true, onChange: v => this.set(v)});
      this._add({row: e.row, sync: f => {
        e.set(f.syntax);
        const problem = actionProblems(f.syntax).find(p => p.severity === 'error');
        if (problem) e.row.add_css_class('error');
        else e.row.remove_css_class('error');
      }});
      hint('Written in Slate\'s syntax, e.g. "push left bar-resize:screenSizeX/2". Pick an operation above to edit it with fields instead.');
      break;
    }
    case 'unknown':
      this._add({row: notice({level: 'warning', title: `Slated doesn't know “${form.raw?.op ?? '?'}”`,
        detail: 'It stays in config.json unchanged. Pick an operation above to replace it.'}).widget});
      break;
    default:
      break;
    }
    this.paramsGroup.set_visible(this.fields.length > 0);
    for (const field of this.fields) field.sync?.(form);
  }

  _form() {
    return formFromAction(this.get());
  }

  /** Stops any shortcut recording in this editor (when its page hides). */
  stopRecording() {
    for (const field of this.fields) field.recorder?.stop();
  }
}

/** The two branches of a by-orientation action, each opening a nested editor. */
function orientationRows(ctx, {depth, get, setBranch}) {
  const rows = ['landscape', 'portrait'].map(branch => {
    const title = branch === 'landscape' ? 'Landscape displays' : 'Portrait displays';
    const row = new Adw.ActionRow({use_markup: false, title, subtitle: '', activatable: true});
    row.add_prefix(icon(branch === 'landscape' ? 'orientation-landscape-symbolic' : 'orientation-portrait-right-symbolic'));
    const g = glyph(get()[branch]);
    row.add_suffix(g);
    row.add_suffix(icon('go-next-symbolic'));
    row.connect('activated', () => pushActionPage(ctx, {
      title, depth: depth + 1,
      get: () => {
        const action = get();
        return action?.op === 'by-orientation' ? action[branch] : undefined;
      },
      set: value => setBranch(branch, value),
    }));
    return {row, glyph: g, branch};
  });
  return {
    rows: rows.map(r => r.row),
    sync() {
      const action = get();
      for (const r of rows) {
        r.row.set_subtitle(actionTitle(action[r.branch]));
        r.glyph._slatedUpdate(action[r.branch]);
      }
    },
  };
}

/**
 * The operations of a chain (each press runs the next), a sequence (all in order; a step can keep
 * the window the run started with) or a plain list (layout operations, before/after).
 */
export class OperationList {
  /**
   * @param {object} ctx
   * @param {object} options
   * @param {"chain"|"sequence"|"plain"} options.mode
   * @param {() => Array} options.get actions (or sequence steps {action, keepWindow})
   * @param {(items: Array) => void} options.set
   * @param {number} options.depth
   * @param {string} [options.emptyText]
   */
  constructor(ctx, {mode, get, set, depth, emptyText = 'No operations yet.'}) {
    this.ctx = ctx;
    this.mode = mode;
    this.getItems = get;
    this.setItems = set;
    this.depth = depth;
    this.emptyText = emptyText;
    this.rows = [];
    this._build();
  }

  _action(item) {
    return this.mode === 'sequence' ? item.action : item;
  }

  _replace(index, action) {
    const items = this.getItems().slice();
    if (index >= items.length) return;
    items[index] = this.mode === 'sequence' ? {...items[index], action} : action;
    this.setItems(items);
  }

  _build() {
    const items = this.getItems() ?? [];
    this.rows = [];
    if (!items.length) this.rows.push(new Adw.ActionRow({use_markup: false, title: this.emptyText, activatable: false}));
    items.forEach((item, index) => {
      const action = this._action(item);
      const prefix = this.mode === 'chain' ? `Press ${index + 1}` : `Step ${index + 1}`;
      const row = new Adw.ActionRow({use_markup: false, title: `${prefix} · ${actionTitle(action)}`, subtitle: actionDetail(action), activatable: true});
      row.set_subtitle_lines(1);
      row.add_prefix(glyph(action));
      if (this.mode === 'sequence' && index > 0) {
        const same = new Gtk.CheckButton({label: 'Same window', active: item.keepWindow === true, valign: Gtk.Align.CENTER,
          tooltip_text: 'Slate\'s “>”: run on the window that was focused when this run of steps began'});
        same.connect('toggled', () => {
          const next = this.getItems().slice();
          next[index] = {...next[index], keepWindow: same.get_active()};
          this.setItems(next);
        });
        row.add_suffix(same);
      }
      row.add_suffix(this._itemMenu(index, items.length));
      row.add_suffix(icon('go-next-symbolic'));
      row.connect('activated', () => pushActionPage(this.ctx, {
        title: prefix, depth: this.depth + 1,
        get: () => {
          const current = this.getItems()?.[index];
          return current === undefined ? undefined : this._action(current);
        },
        set: value => this._replace(index, value),
      }));
      this.rows.push(row);
    });
    this.rows.push(this._addRow());
  }

  _itemMenu(index, count) {
    const content = box('vertical', 2);
    const popover = new Gtk.Popover({child: content});
    const item = (text, enabled, fn, classes = ['flat']) => {
      const b = button(text, () => {
        popover.popdown();
        fn();
      }, {classes});
      b.set_sensitive(enabled);
      content.append(b);
    };
    const move = offset => {
      const items = this.getItems().slice();
      const [moved] = items.splice(index, 1);
      items.splice(index + offset, 0, moved);
      this.setItems(items);
    };
    item('Move Up', index > 0, () => move(-1));
    item('Move Down', index < count - 1, () => move(1));
    item('Remove', true, () => this.setItems(this.getItems().filter((_, i) => i !== index)), ['flat', 'destructive-action']);
    return new Gtk.MenuButton({icon_name: 'view-more-symbolic', popover, valign: Gtk.Align.CENTER, css_classes: ['flat'],
      tooltip_text: 'More'});
  }

  _addRow() {
    const row = new Adw.ActionRow({use_markup: false, title: this.mode === 'chain' ? 'Add Operation' : 'Add Step', activatable: true});
    const content = box('vertical', 2);
    const popover = new Gtk.Popover({child: new Gtk.ScrolledWindow({child: content, max_content_height: 420,
      propagate_natural_height: true, hscrollbar_policy: Gtk.PolicyType.NEVER})});
    const add = action => {
      popover.popdown();
      const copy = JSON.parse(JSON.stringify(action));
      this.setItems([...(this.getItems() ?? []), this.mode === 'sequence' ? {action: copy, keepWindow: false} : copy]);
    };
    for (const g of PRESET_GROUPS) {
      content.append(label(g.title, {classes: ['heading']}));
      for (const preset of PRESETS.filter(p => p.group === g.id)) content.append(button(preset.title, () => add(preset.action), {classes: ['flat']}));
    }
    content.append(label('Other', {classes: ['heading']}));
    for (const extra of EXTRA_STEPS) content.append(button(extra.title, () => add(extra.action), {classes: ['flat']}));
    const menu = new Gtk.MenuButton({icon_name: 'list-add-symbolic', popover, valign: Gtk.Align.CENTER, css_classes: ['flat']});
    row.add_suffix(menu);
    row.set_activatable_widget(menu);
    return row;
  }
}

/** The grid overlay's padding and per-display sizes. */
function gridRows(model, {get, update}) {
  const form = get();
  const rows = [];
  const syncs = [];
  const padding = spinRow({title: 'Padding', subtitle: 'Points between cells', min: 0, max: 40, value: form.gridPadding,
    onChange: v => update('gridPadding', Math.round(v))});
  rows.push(padding.row);
  syncs.push(f => padding.set(f.gridPadding));
  const screenCount = Math.max(previewScreens(model).length, 1);
  form.grids.forEach((grid, index) => {
    const row = new Adw.ActionRow({use_markup: false, title: `Display ${(parseInt(grid.screen, 10) || 0) + 1}`, subtitle: `Grid for screen “${grid.screen}”`});
    const spin = (value, dimension) => {
      const s = Gtk.SpinButton.new_with_range(1, 24, 1);
      s.set_value(value);
      s.set_valign(Gtk.Align.CENTER);
      s.set_tooltip_text(dimension === 'width' ? 'Columns' : 'Rows');
      s.connect('value-changed', () => {
        const grids = get().grids.map((g, i) => (i === index ? {...g, [dimension]: Math.round(s.get_value())} : g));
        update('grids', grids);
      });
      return s;
    };
    const wide = spin(grid.width, 'width');
    const tall = spin(grid.height, 'height');
    row.add_suffix(wide);
    row.add_suffix(label('×'));
    row.add_suffix(tall);
    row.add_suffix(button('', () => update('grids', get().grids.filter((_, i) => i !== index)), {icon: 'list-remove-symbolic', classes: ['flat'], tooltip: 'Remove'}));
    rows.push(row);
    syncs.push(f => {
      const g = f.grids[index];
      if (!g) return;
      if (wide.get_value() !== g.width) wide.set_value(g.width);
      if (tall.get_value() !== g.height) tall.set_value(g.height);
    });
  });
  if (form.grids.length < screenCount) {
    const add = new Adw.ActionRow({
      use_markup: false,
      title: 'Set a Grid Size for a Display', activatable: true,
      subtitle: form.grids.length ? '' : "Without sizes, every display uses Slate's default grid.",
    });
    add.add_suffix(icon('list-add-symbolic'));
    add.connect('activated', () => {
      const used = new Set(get().grids.map(g => g.screen));
      const next = [...Array(screenCount).keys()].map(String).find(s => !used.has(s)) ?? '0';
      update('grids', [...get().grids, {screen: next, width: 6, height: 4}]);
    });
    rows.push(add);
  }
  return {rows, sync: f => syncs.forEach(s => s(f))};
}

/** Which apps hide/show/toggle act on. */
function appSelectorRows({get, set}) {
  const selector = get();
  const rows = [];
  const syncs = [];
  const mode = comboRow({
    title: 'Apps', items: SELECTOR_ITEMS, selected: selectorKind(selector),
    onChange: v => set({current: 'current', all: 'all', allBut: 'all-but:', apps: []}[v]),
  });
  rows.push(mode.row);
  syncs.push(s => mode.set(selectorKind(s)));
  if (selectorKind(selector) === 'allBut') {
    const e = entryRow({title: 'Leave this app alone', text: selector.slice(8), onChange: v => set(`all-but:${v}`)});
    e.row.add_suffix(appPickerButton({onPick: app => set(`all-but:${app.name}`)}));
    rows.push(e.row);
    syncs.push(s => typeof s === 'string' && s.startsWith('all-but:') && e.set(s.slice(8)));
  } else if (selectorKind(selector) === 'apps') {
    for (const name of selector) {
      const row = new Adw.ActionRow({use_markup: false, title: name});
      row.add_suffix(button('', () => set(get().filter(n => n !== name)), {icon: 'list-remove-symbolic', classes: ['flat'], tooltip: 'Remove'}));
      rows.push(row);
    }
    const add = new Adw.EntryRow({use_markup: false, title: 'Add an app by name', show_apply_button: true});
    add.connect('apply', () => {
      const name = add.get_text().trim();
      if (name && !get().includes(name)) set([...get(), name]);
      add.set_text('');
    });
    add.add_suffix(appPickerButton({onPick: app => !get().includes(app.name) && set([...get(), app.name]),
      exclude: app => get().includes(app.name)}));
    rows.push(add);
  }
  return {rows, sync: () => syncs.forEach(fn => fn(get()))};
}
