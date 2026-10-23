// Settings → Slate Compatibility: the Slate files Slated loads next to its own configuration, their
// status and problems, importing them into config.json, and which files to load (port of
// SlateCompatibilityPane.swift and the macOS "Import Slate Config into Slated…").

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {DEFAULT_SLATE_PATHS} from '../config.js';
import {deepEqual, plural} from '../util.js';
import {box, label, button, icon, pill, group, switchRow, entryRow, launchFile} from './widgets.js';

/** The pill for a source, from the extension's report when it runs, else from the preferences' own read. */
function sourcePresentation(model, source) {
  if (!source.exists) return {label: 'Not found', style: 'dim'};
  if (!model.slateLoading) return {label: 'Off', style: 'dim'};
  const reported = model.sourceStatus(source);
  if (model.running && reported) {
    if (!reported.loaded) return {label: 'Failed to load', style: 'error'};
    if (reported.diagnostics.length) return {label: 'Loaded with problems', style: 'warning'};
    return {label: 'Loaded', style: 'success'};
  }
  if (source.error) return {label: 'Unreadable here', style: 'warning'};
  if (source.diagnostics.some(d => d.severity === 'error')) return {label: 'Has errors', style: 'warning'};
  return {label: model.running ? 'Not reported' : 'Found', style: 'dim'};
}

function sourceSummary(model, source) {
  if (!source.exists) return 'Not found — create the file to use it.';
  const reported = model.running ? model.sourceStatus(source) : null;
  const count = reported?.bindings ?? source.bindings.length;
  const parts = [plural(count, 'binding')];
  if (source.layouts.length) parts.push(plural(source.layouts.length, 'layout'));
  const problems = reported ? reported.diagnostics.length : source.diagnostics.length;
  if (problems) parts.push(plural(problems, 'problem'));
  return `${source.kind === 'javascript' ? 'JavaScript' : 'Classic'} · ${parts.join(' · ')}`;
}

function diagnosticRows(model, source) {
  const reported = model.running ? model.sourceStatus(source) : null;
  if (source.error) return [{severity: 'warning', text: source.error}];
  if (reported) return reported.diagnostics.map(text => ({severity: /warning/i.test(text) ? 'warning' : 'error', text}));
  return source.diagnostics.map(d => ({severity: d.severity, text: d.line ? `Line ${d.line}: ${d.message}` : d.message}));
}

/** Shows what importing would do, then does it. */
function importDialog(ctx) {
  const model = ctx.model;
  model.saveNow();
  const plan = model.planSlateImport();
  const lines = [];
  if (plan.added.length) lines.push(`${plural(plan.added.length, 'shortcut')} will be copied into Slated, where you can edit them.`);
  if (plan.duplicates.length) lines.push(`${plural(plan.duplicates.length, 'shortcut')} Slated already has will be left alone.`);
  if (plan.skipped.length) lines.push(`${plural(plan.skipped.length, 'item')} need JavaScript and stay in your Slate file, which keeps loading.`);
  if (plan.errors.length) lines.push(...plan.errors.map(e => `${e.path}: ${e.message}.`));
  if (plan.stopsLoading && plan.added.length) lines.push('Everything converts, so Slated will stop loading your Slate files.');

  const dialog = new Adw.AlertDialog({
    heading: plan.added.length ? `Import ${plural(plan.added.length, 'shortcut')}?` : 'Nothing new to import',
    body: lines.join('\n\n') || 'Your Slate files have no bindings Slated can import.',
  });
  if (plan.skipped.length) {
    const details = box('vertical', 4);
    for (const s of plan.skipped) {
      const item = label(`${s.keystroke}: ${s.reason}`, {wrap: true, selectable: true, classes: ['caption']});
      details.append(item);
    }
    dialog.set_extra_child(new Gtk.ScrolledWindow({child: details, max_content_height: 200, propagate_natural_height: true,
      hscrollbar_policy: Gtk.PolicyType.NEVER}));
  }
  dialog.add_response('cancel', plan.added.length ? 'Cancel' : 'Close');
  if (plan.added.length) {
    dialog.add_response('import', 'Import');
    dialog.set_response_appearance('import', Adw.ResponseAppearance.SUGGESTED);
    dialog.set_default_response('import');
  }
  dialog.set_close_response('cancel');
  dialog.connect('response', (_d, response) => {
    if (response !== 'import') return;
    model.applySlateImport(plan);
    model.saveNow();
    ctx.toast(plan.stopsLoading
      ? `Imported ${plural(plan.added.length, 'shortcut')}. Slate files are no longer loaded.`
      : `Imported ${plural(plan.added.length, 'shortcut')}. Your Slate file still loads for the rest.`);
  });
  model.log('ui.import_slate', {importable: plan.added.length, skipped: plan.skipped.length});
  dialog.present(ctx.window);
}

export function createSlatePane(ctx) {
  const model = ctx.model;
  const prefs = new Adw.PreferencesPage();

  const loadGroup = group({description: "Your existing ~/.slate.js and ~/.slate keep working, unchanged, next to Slated's own settings. Slated reloads a file the moment you save it; its bindings are read-only here."});
  const load = switchRow({
    title: 'Load Slate config files', active: model.slateLoading,
    onChange: on => model.update(config => {
      config.general.loadSlateConfigs = on;
    }),
  });
  loadGroup.add(load.row);
  prefs.add(loadGroup);

  const filesGroup = group({title: 'Files', suffix: button('Reload', () => {
    model.reload();
    ctx.toast('Reloaded config.json and your Slate files');
    model.log('ui.reload', {source: 'slate'});
  }, {icon: 'view-refresh-symbolic', classes: ['flat']})});
  prefs.add(filesGroup);
  let fileRows = [];

  const importGroup = group({title: 'Import into Slated',
    description: 'Copy your Slate bindings into Slated so you can edit them here. Functions that do one thing per screen shape become plain shortcuts (or a by-orientation pair); anything that needs JavaScript stays in the file.'});
  const importRow = new Adw.ActionRow({use_markup: false, title: '', subtitle: ''});
  const importButton = button('Import…', () => importDialog(ctx), {classes: ['suggested-action']});
  importRow.add_suffix(importButton);
  importGroup.add(importRow);
  prefs.add(importGroup);

  const pathsGroup = group({title: 'Paths', description: "Files load in this order; a later file's settings win. ~ means your home folder."});
  prefs.add(pathsGroup);
  let pathRows = [];
  let pathFields = [];
  let pathCount = -1;
  let restoreShown = null;

  function rebuildFiles() {
    for (const r of fileRows) filesGroup.remove(r);
    fileRows = [];
    for (const source of model.sources) {
      const row = new Adw.ExpanderRow({use_markup: false, title: source.displayPath, subtitle: sourceSummary(model, source)});
      row.add_css_class('slated-mono-title');
      row.add_suffix(pill(sourcePresentation(model, source)));
      const diagnostics = diagnosticRows(model, source);
      for (const d of diagnostics) {
        const r = new Adw.ActionRow({use_markup: false, title: d.text, activatable: false});
        r.set_title_lines(0);
        r.set_title_selectable(true);
        r.add_prefix(icon(d.severity === 'error' ? 'dialog-error-symbolic' : 'dialog-warning-symbolic',
          {classes: [d.severity === 'error' ? 'slated-error-text' : 'slated-warning-text']}));
        row.add_row(r);
      }
      if (source.exists) {
        const actions = new Adw.ActionRow({use_markup: false, title: source.file, activatable: false});
        actions.set_title_lines(1);
        actions.add_suffix(button('Open', () => launchFile(source.file, prefs, {onError: e => ctx.toast(e.message)}), {classes: ['flat']}));
        actions.add_suffix(button('Show in Files', () => {
          launchFile(source.file, prefs, {folder: true, onError: e => ctx.toast(e.message)});
          model.log('ui.reveal_file', {path: source.displayPath});
        }, {classes: ['flat']}));
        if (source.bindings.length) actions.add_suffix(button('Show Bindings', () => ctx.navigate('windows'), {classes: ['flat']}));
        row.add_row(actions);
      }
      row.set_enable_expansion(source.exists);
      row.set_expanded(source.exists && diagnostics.length > 0);
      filesGroup.add(row);
      fileRows.push(row);
    }
    if (!model.sources.length) {
      const none = new Adw.ActionRow({use_markup: false, title: 'No Slate files configured', subtitle: 'Add a path below to load a Slate config.'});
      filesGroup.add(none);
      fileRows.push(none);
    }
  }

  function rebuildPaths() {
    for (const r of pathRows) pathsGroup.remove(r);
    pathRows = [];
    pathFields = [];
    const paths = model.configuration.general.slateConfigPaths;
    paths.forEach((path, index) => {
      const field = entryRow({title: `File ${index + 1}`, text: path, monospace: true, onChange: v => model.update(config => {
        if (index < config.general.slateConfigPaths.length) config.general.slateConfigPaths[index] = v;
      })});
      field.row.add_suffix(button('', () => model.update(config => {
        config.general.slateConfigPaths.splice(index, 1);
      }), {icon: 'list-remove-symbolic', classes: ['flat'], tooltip: 'Stop loading this file'}));
      pathsGroup.add(field.row);
      pathRows.push(field.row);
      pathFields.push(field);
    });
    const actions = new Adw.ActionRow({use_markup: false, title: 'Load another file', activatable: false});
    actions.add_suffix(button('Add Path', () => model.update(config => {
      config.general.slateConfigPaths.push('');
    }), {icon: 'list-add-symbolic', classes: ['flat']}));
    if (!deepEqual(paths, DEFAULT_SLATE_PATHS)) {
      actions.add_suffix(button('Restore Defaults', () => model.update(config => {
        config.general.slateConfigPaths = [...DEFAULT_SLATE_PATHS];
      }), {classes: ['flat']}));
    }
    pathsGroup.add(actions);
    pathRows.push(actions);
  }

  const sync = () => {
    load.set(model.slateLoading);
    rebuildFiles();
    const existing = model.sources.filter(s => s.exists);
    const count = existing.reduce((n, s) => n + s.bindings.length, 0);
    importRow.set_title(existing.length ? `${plural(count, 'binding')} in ${existing.map(s => s.displayPath).join(' and ')}` : 'No Slate files found');
    importRow.set_subtitle(existing.length ? 'Nothing changes until you confirm.' : 'Create ~/.slate.js or ~/.slate, or add another path below.');
    importButton.set_sensitive(existing.length > 0);
    const paths = model.configuration.general.slateConfigPaths;
    const custom = !deepEqual(paths, DEFAULT_SLATE_PATHS);
    if (paths.length !== pathCount || custom !== restoreShown) {
      pathCount = paths.length;
      restoreShown = custom;
      rebuildPaths();
    } else {
      paths.forEach((p, i) => pathFields[i]?.set(p));
    }
  };
  model.on('config', sync);
  model.on('sources', sync);
  model.on('status', sync);
  sync();

  const page = new Adw.NavigationPage({title: 'Slate Compatibility', tag: 'slate'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  return {
    id: 'slate',
    title: 'Slate Compatibility',
    iconName: 'text-x-generic-symbolic',
    page,
    badge() {
      const problems = model.sources.some(s => s.exists && sourcePresentation(model, s).style === 'error');
      return problems ? {text: '!', warning: true} : null;
    },
  };
}
