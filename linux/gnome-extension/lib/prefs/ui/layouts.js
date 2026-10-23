// Settings → Layouts: several apps arranged at once (Slate's `layout`; port of LayoutsPane.swift).
// Slated's own layouts are editable; the Slate files' are read-only.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {actionTitle, actionDetail} from '../actions.js';
import {presetById} from '../presets.js';
import {defaultLayoutAppOptions} from '../config.js';
import {target} from '../validator.js';
import {stableStringify} from '../util.js';
import {box, label, button, icon, keycaps, group, emptyState, entryRow, switchRow, notice, clear} from './widgets.js';
import {OperationList} from './actioneditor.js';
import {LayoutPreview} from './preview.js';
import {appPickerButton} from './apps.js';
import {confirm} from './bindingeditor.js';

const OPTION_ROWS = [
  ['ignoreFail', 'Skip quietly if the app isn\'t running'],
  ['repeat', 'Repeat the operations for extra windows'],
  ['mainFirst', 'Arrange the main window first'],
  ['sortTitle', 'Order windows by title'],
];

const OPTION_TAGS = {ignoreFail: 'If running', repeat: 'Repeat', repeatLast: 'Repeat last', mainFirst: 'Main first', mainLast: 'Main last', sortTitle: 'By title'};

function isInStack(nav, page) {
  const stack = nav.get_navigation_stack();
  for (let i = 0; i < stack.get_n_items(); i++) if (stack.get_item(i) === page) return true;
  return false;
}

function appSummary(app) {
  const ops = (app.operations ?? []).map(actionTitle);
  const tags = Object.entries(OPTION_TAGS).filter(([key]) => app.options?.[key]).map(([, tag]) => tag);
  return [ops.join(' → ') || 'No operations', ...tags].join(' · ');
}

/**
 * Pushes the layout editor. `source` is null for Slated's own layouts (editable), or the Slate
 * source the layout comes from (read-only).
 */
function pushLayoutEditor(ctx, name, source = null) {
  const model = ctx.model;
  const editable = source === null;
  let currentName = name;
  const getLayout = () => (editable
    ? model.configuration.layouts.find(l => l.name === currentName)
    : source.layouts.find(l => l.name === currentName));
  const mutate = fn => {
    currentName = model.setLayout(currentName, fn);
  };

  const page = new Adw.NavigationPage({title: name || 'Layout'});
  page._slatedKey = `layout:${name}`;
  const header = new Adw.HeaderBar();
  if (editable) {
    header.pack_end(button('', () => confirm(ctx, {
      heading: `Delete “${currentName}”?`, body: 'Shortcuts that apply it will stop working.', accept: 'Delete',
      onAccept: () => {
        model.deleteLayout(currentName);
        ctx.toast(`Deleted layout “${currentName}”`);
      },
    }), {icon: 'user-trash-symbolic', classes: ['flat'], tooltip: 'Delete Layout'}));
  }
  const prefs = new Adw.PreferencesPage();

  const top = group();
  if (!editable) top.add(notice({level: 'info', title: `Read-only · ${source.displayPath}`, detail: 'Edit this layout in your Slate file.'}).widget);
  const nameRow = editable ? entryRow({title: 'Name', text: name, onChange: v => mutate(l => {
    l.name = v;
  })}) : null;
  if (nameRow) top.add(nameRow.row);
  const nameIssue = new Adw.ActionRow({use_markup: false, title: 'Not saved', subtitle: '', activatable: false});
  nameIssue.add_css_class('slated-invalid');
  top.add(nameIssue);
  const triggersRow = new Adw.ActionRow({use_markup: false, title: 'Shortcut'});
  const triggersBox = box('horizontal', 6);
  triggersRow.add_suffix(triggersBox);
  top.add(triggersRow);
  prefs.add(top);

  const previewGroup = group();
  const preview = new LayoutPreview(model);
  previewGroup.add(preview.widget);
  prefs.add(previewGroup);

  const appsGroup = group({title: 'Apps', description: editable
    ? 'Operations apply to an app\'s windows in order: the first to its first window, and so on.' : ''});
  prefs.add(appsGroup);
  let appWidgets = [];
  let appsKey = null;
  const expanded = new Set();

  const beforeAfter = group({title: 'Before & After', description: 'Operations that run before the apps are arranged, and after.'});
  prefs.add(beforeAfter);
  let beforeAfterRows = [];
  let beforeAfterKey = null;

  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(header);
  page.set_child(toolbar);

  function rebuildApps(layout) {
    for (const w of appWidgets) appsGroup.remove(w.row);
    appWidgets = [];
    (layout.apps ?? []).forEach((app, index) => {
      const row = new Adw.ExpanderRow({use_markup: false, title: app.app || 'App', subtitle: appSummary(app)});
      row.set_subtitle_lines(1);
      row.set_expanded(expanded.has(index));
      row.connect('notify::expanded', () => (row.get_expanded() ? expanded.add(index) : expanded.delete(index)));
      const widget = {row, sync: null};
      if (editable) {
        const appName = entryRow({title: 'App name', text: app.app, onChange: v => mutate(l => {
          if (l.apps[index]) l.apps[index].app = v;
        })});
        appName.row.add_suffix(appPickerButton({onPick: picked => mutate(l => {
          if (l.apps[index]) l.apps[index].app = picked.name;
        })}));
        row.add_row(appName.row);
        const ops = new OperationList(ctx, {
          mode: 'plain', depth: 1, emptyText: 'No operations: the app is left where it is.',
          get: () => getLayout()?.apps?.[index]?.operations,
          set: operations => mutate(l => {
            if (l.apps[index]) l.apps[index].operations = operations;
          }),
        });
        for (const r of ops.rows) row.add_row(r);
        const switches = OPTION_ROWS.map(([key, title]) => {
          const s = switchRow({title, active: app.options?.[key] === true, onChange: v => mutate(l => {
            if (l.apps[index]) l.apps[index].options = {...defaultLayoutAppOptions(), ...l.apps[index].options, [key]: v};
          })});
          row.add_row(s.row);
          return [key, s];
        });
        const remove = new Adw.ActionRow({use_markup: false, title: 'Remove this app from the layout', activatable: false});
        remove.add_suffix(button('Remove', () => mutate(l => {
          l.apps.splice(index, 1);
        }), {classes: ['destructive-action']}));
        row.add_row(remove);
        widget.sync = a => {
          appName.set(a.app);
          row.set_title(a.app || 'App');
          row.set_subtitle(appSummary(a));
          for (const [key, s] of switches) s.set(a.options?.[key] === true);
        };
      } else {
        for (const op of app.operations ?? []) {
          const r = new Adw.ActionRow({use_markup: false, title: actionTitle(op), subtitle: actionDetail(op), activatable: false});
          r.add_css_class('slated-mono-subtitle');
          row.add_row(r);
        }
      }
      appsGroup.add(row);
      appWidgets.push(widget);
    });
    if (editable) {
      const add = new Adw.EntryRow({use_markup: false, title: 'Add an app by name', show_apply_button: true});
      const addApp = appName => {
        if (!appName.trim()) return;
        mutate(l => {
          l.apps.push({app: appName.trim(), operations: [JSON.parse(JSON.stringify(presetById('maximize').action))], options: defaultLayoutAppOptions()});
        });
        expanded.add((getLayout()?.apps?.length ?? 1) - 1);
      };
      add.connect('apply', () => {
        addApp(add.get_text());
        add.set_text('');
      });
      add.add_suffix(appPickerButton({onPick: app => addApp(app.name), exclude: app => (getLayout()?.apps ?? []).some(a => a.app === app.name)}));
      appsGroup.add(add);
      appWidgets.push({row: add, sync: null});
    } else if (!(layout.apps ?? []).length) {
      const none = new Adw.ActionRow({use_markup: false, title: 'No apps', activatable: false});
      appsGroup.add(none);
      appWidgets.push({row: none, sync: null});
    }
  }

  function rebuildBeforeAfter(layout) {
    for (const r of beforeAfterRows) beforeAfter.remove(r);
    beforeAfterRows = [];
    for (const [key, title] of [['before', 'Before arranging'], ['after', 'After arranging']]) {
      const heading = new Adw.ActionRow({use_markup: false, title, activatable: false});
      heading.add_css_class('heading');
      beforeAfterRows.push(heading);
      if (editable) {
        const list = new OperationList(ctx, {
          mode: 'plain', depth: 1, emptyText: 'Nothing',
          get: () => getLayout()?.[key],
          set: ops => mutate(l => {
            l[key] = ops;
          }),
        });
        beforeAfterRows.push(...list.rows);
      } else {
        for (const op of layout[key] ?? []) beforeAfterRows.push(new Adw.ActionRow({use_markup: false, title: actionTitle(op), subtitle: actionDetail(op), activatable: false}));
        if (!(layout[key] ?? []).length) beforeAfterRows.push(new Adw.ActionRow({use_markup: false, title: 'Nothing', activatable: false}));
      }
    }
    for (const r of beforeAfterRows) beforeAfter.add(r);
  }

  const sync = () => {
    const layout = getLayout();
    if (!layout) {
      if (ctx.nav.get_visible_page() === page) ctx.nav.pop();
      return;
    }
    page.set_title(layout.name || 'Untitled Layout');
    nameRow?.set(layout.name);
    const issues = editable ? model.issuesFor(target.layout(layout.name)).filter(i => i.field === 'name') : [];
    nameIssue.set_subtitle(issues.map(i => i.message).join('\n'));
    nameIssue.set_visible(issues.length > 0);
    clear(triggersBox);
    const triggers = model.triggersForLayout(layout.name);
    for (const t of triggers) triggersBox.append(keycaps(t.keys, {modal: t.modal}));
    if (!triggers.length) {
      if (editable) {
        triggersBox.append(button('Add a Shortcut', () => ctx.navigate('windows', {newBinding: true, action: {op: 'layout', name: layout.name}}), {classes: ['flat']}));
      } else {
        triggersBox.append(label('No shortcut', {classes: ['dim-label']}));
      }
    }
    preview.setLayout(layout);
    const key = stableStringify((layout.apps ?? []).map(a => [(a.operations ?? []).map(op => [actionTitle(op), actionDetail(op)])]));
    if (key !== appsKey) {
      appsKey = key;
      rebuildApps(layout);
    } else {
      (layout.apps ?? []).forEach((a, i) => appWidgets[i]?.sync?.(a));
    }
    const baKey = stableStringify([layout.before, layout.after].map(list => (list ?? []).map(actionTitle)));
    if (baKey !== beforeAfterKey) {
      beforeAfterKey = baKey;
      rebuildBeforeAfter(layout);
    }
    beforeAfter.set_visible(editable || (layout.before ?? []).length > 0 || (layout.after ?? []).length > 0);
  };
  const offs = [model.on('config', sync), model.on('sources', sync), model.on('status', sync)];
  page.connect('hidden', () => {
    if (!isInStack(ctx.nav, page)) offs.forEach(off => off());
  });
  sync();
  ctx.nav.push(page);
  return page;
}

export function createLayoutsPane(ctx) {
  const model = ctx.model;
  const prefs = new Adw.PreferencesPage();
  const slatedGroup = group({title: 'Slated'});
  prefs.add(slatedGroup);
  let slatedRows = [];
  let sourceGroups = [];

  const newLayout = () => {
    const name = model.addLayout();
    pushLayoutEditor(ctx, name);
  };
  const empty = emptyState({
    iconName: 'view-dual-symbolic', title: 'No layouts yet',
    description: 'A layout puts your editor on the left two-thirds, the browser on the right and chat on your second display — all with one shortcut.',
    actions: [{label: 'Create a Layout', suggested: true, onClick: newLayout}],
  });
  const stack = new Gtk.Stack({transition_type: Gtk.StackTransitionType.CROSSFADE});
  stack.add_named(prefs, 'list');
  stack.add_named(empty, 'empty');

  function layoutRow(layout, source) {
    const row = new Adw.ActionRow({
      use_markup: false,
      title: layout.name || 'Untitled', subtitle: (layout.apps ?? []).length ? layout.apps.map(a => a.app).join(', ') : 'No apps yet',
      activatable: true,
    });
    row.set_subtitle_lines(1);
    row.add_prefix(icon('view-dual-symbolic'));
    const trigger = model.triggersForLayout(layout.name)[0];
    if (trigger) row.add_suffix(keycaps(trigger.keys, {modal: trigger.modal}));
    row.add_suffix(icon('go-next-symbolic'));
    row.connect('activated', () => pushLayoutEditor(ctx, layout.name, source));
    return row;
  }

  function rebuild() {
    for (const r of slatedRows) slatedGroup.remove(r);
    slatedRows = model.configuration.layouts.map(l => layoutRow(l, null));
    if (!slatedRows.length) slatedRows.push(new Adw.ActionRow({use_markup: false, title: 'None yet', subtitle: 'Use the + button to create one.', activatable: false}));
    for (const r of slatedRows) slatedGroup.add(r);
    for (const g of sourceGroups) prefs.remove(g);
    sourceGroups = [];
    for (const source of model.sources.filter(s => s.layouts.length)) {
      const g = group({title: source.displayPath, suffix: label('Read-only', {classes: ['dim-label']})});
      for (const layout of source.layouts) g.add(layoutRow(layout, source));
      prefs.add(g);
      sourceGroups.push(g);
    }
    const nothing = !model.configuration.layouts.length && !model.sources.some(s => s.layouts.length);
    stack.set_visible_child_name(nothing ? 'empty' : 'list');
  }

  const page = new Adw.NavigationPage({title: 'Layouts', tag: 'layouts'});
  const toolbar = new Adw.ToolbarView({content: stack});
  const header = new Adw.HeaderBar();
  header.pack_end(button('', newLayout, {icon: 'list-add-symbolic', classes: ['suggested-action'], tooltip: 'New Layout'}));
  toolbar.add_top_bar(header);
  page.set_child(toolbar);

  let dirty = true;
  const update = () => {
    rebuild();
    dirty = false;
  };
  const refresh = () => {
    if (ctx.isCurrent() && ctx.nav.get_visible_page() === page) update();
    else dirty = true;
  };
  page.connect('showing', () => dirty && update());
  for (const signal of ['config', 'sources']) model.on(signal, refresh);

  return {
    id: 'layouts',
    title: 'Layouts',
    iconName: 'view-dual-symbolic',
    page,
    activate: () => dirty && update(),
    badge: () => ({text: String(model.configuration.layouts.length + model.sources.reduce((n, s) => n + s.layouts.length, 0)), warning: false}),
  };
}
