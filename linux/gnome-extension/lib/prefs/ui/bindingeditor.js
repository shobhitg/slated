// The editor for one of Slated's own shortcuts (name, keys, action, live preview), and the
// read-only detail page for a binding from a Slate file (port of BindingEditor.swift and
// SourceBindingDetail.swift).

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {bindingTitle, actionTitle, actionDetail, containsAutomation} from '../actions.js';
import {statePresentation, stateExplanation} from '../status.js';
import {target} from '../validator.js';
import {previews} from '../placement.js';
import {formatList} from '../util.js';
import {comboLabel, keysCombo} from '../keys.js';
import {
  automationSettings, appDisplayName, normalizeAppId, timeLimitTitle, whileHeldBehavior, whileHeldRepeat, GNOME_NOTES,
  suggestedAutomationKeys, usedShortcutKeys,
} from '../automation.js';
import {box, label, button, glyph, keycaps, pill, notice, group, comboRow, switchRow, entryRow, clear, launchFile} from './widgets.js';
import {ShortcutRecorder} from './recorder.js';
import {PlacementPreview} from './preview.js';
import {ActionEditor} from './actioneditor.js';
import {appPickerButton, installedApps} from './apps.js';

const REPEAT_ITEMS = [{id: 'default', label: 'Default'}, {id: 'held', label: 'While held'}, {id: 'never', label: 'Never'}];
const repeatId = repeats => (repeats === true ? 'held' : repeats === false ? 'never' : 'default');
const SCOPE_ITEMS = [{id: 'everywhere', label: 'Everywhere'}, {id: 'only', label: 'Only in some apps'}];

/** Apps to offer in "Only in…" pickers: the ones used lately (games without a desktop file too), then installed ones. */
export function appSections(model) {
  return [
    {title: 'Used Lately', apps: model.status.recentApps ?? []},
    {title: 'Installed', apps: installedApps()},
  ];
}

/** A one-line summary of the automation safety settings: "✦ Esc stops everything · stops when you switch apps". */
export function safetySummary(config) {
  const settings = automationSettings(config);
  const parts = [settings.stopShortcut ? `${comboLabel(settings.stopShortcut)} stops everything` : 'No stop shortcut'];
  parts.push(settings.stopOnAppSwitch ? 'stops when you switch apps' : 'keeps running across apps');
  if (settings.maxRunMinutes > 0) parts.push(`stops after ${timeLimitTitle(settings.maxRunMinutes)}`);
  return parts.join(' · ');
}

/**
 * "Works in": everywhere, or only while one of some apps (usually a game) has focus. Limited to an
 * app, a shortcut can be a plain key like F: GNOME grabs it only while that app is in front.
 * Returns {group, sync()}.
 */
function appScopeEditor(ctx, id) {
  const model = ctx.model;
  const scopeGroup = group({title: 'Works In'});
  let choosing = false;
  const scope = comboRow({
    title: 'Works in', items: SCOPE_ITEMS, selected: model.binding(id)?.onlyInApps?.length ? 'only' : 'everywhere',
    onChange: value => {
      choosing = value === 'only';
      if (value === 'everywhere') {
        model.setBinding(id, b => {
          delete b.onlyInApps;
        });
      }
      sync();
    },
  });
  scopeGroup.add(scope.row);
  const addApp = appId => {
    const value = appId.trim();
    if (!value) return;
    model.setBinding(id, b => {
      const apps = b.onlyInApps ?? [];
      if (!apps.some(a => normalizeAppId(a) === normalizeAppId(value))) b.onlyInApps = [...apps, value];
    });
  };
  const add = new Adw.EntryRow({use_markup: false, title: 'Add an app id or window class', show_apply_button: true});
  add.connect('apply', () => {
    addApp(add.get_text());
    add.set_text('');
  });
  add.add_suffix(appPickerButton({
    tooltip: 'Choose a game or app', sections: () => appSections(model), onPick: app => addApp(app.id),
    exclude: app => (model.binding(id)?.onlyInApps ?? []).some(a => normalizeAppId(a) === normalizeAppId(app.id)),
  }));
  let appRows = [];
  let addShown = false;

  function sync() {
    const binding = model.binding(id);
    if (!binding) return;
    const apps = binding.onlyInApps ?? [];
    const limited = apps.length > 0 || choosing;
    scope.set(limited ? 'only' : 'everywhere');
    for (const row of appRows) scopeGroup.remove(row);
    appRows = [];
    if (addShown) scopeGroup.remove(add);
    addShown = false;
    if (limited) {
      const names = {installed: installedApps(), recent: model.status.recentApps ?? []};
      for (const appId of apps) {
        const title = appDisplayName(appId, names);
        const row = new Adw.ActionRow({use_markup: false, title, subtitle: title === appId ? '' : appId});
        row.add_css_class('slated-mono-subtitle');
        row.add_suffix(button('', () => model.setBinding(id, b => {
          b.onlyInApps = (b.onlyInApps ?? []).filter(a => a !== appId);
          if (!b.onlyInApps.length) delete b.onlyInApps;
        }), {icon: 'list-remove-symbolic', classes: ['flat'], tooltip: 'Remove'}));
        scopeGroup.add(row);
        appRows.push(row);
      }
      // The "add" row stays last, below the apps already chosen.
      scopeGroup.add(add);
      addShown = true;
    }
    const first = apps[0];
    scopeGroup.set_description(!limited
      ? 'Works in every app.'
      : !first
        ? "Add the game or app it's for. It then works only there, and plain keys like F are fine as shortcuts. "
          + 'GNOME knows an app by its desktop id, or by its window class for games without one.'
        : `Active only while ${apps.length === 1 ? appDisplayName(first, {installed: installedApps(), recent: model.status.recentApps ?? []}) : 'one of these apps'} is in front; the keys work normally everywhere else.`);
  }
  return {group: scopeGroup, sync};
}

/** A header block: glyph, title, pills and keycaps. Returns {widget, update({...})}. */
function summary() {
  const outer = box('horizontal', 14);
  outer.set_margin_bottom(6);
  const glyphHolder = box('horizontal', 0);
  outer.append(glyphHolder);
  const texts = box('vertical', 6);
  texts.set_valign(Gtk.Align.CENTER);
  const title = label('', {classes: ['title-2'], wrap: true});
  const line = box('horizontal', 8);
  texts.append(title);
  texts.append(line);
  outer.append(texts);
  return {
    widget: outer,
    update({action, titleText, pills = [], keys = null, modal = null}) {
      clear(glyphHolder);
      if (action !== null && action !== undefined) glyphHolder.append(glyph(action, {width: 40, height: 28}));
      else glyphHolder.append(new Gtk.Image({icon_name: 'text-x-generic-symbolic', pixel_size: 28}));
      title.set_label(titleText);
      clear(line);
      for (const p of pills) line.append(pill(p));
      if (keys) line.append(keycaps(keys, {modal}));
    },
  };
}

function confirm(ctx, {heading, body, accept, destructive = true, onAccept}) {
  const dialog = new Adw.AlertDialog({heading, body});
  dialog.add_response('cancel', 'Cancel');
  dialog.add_response('accept', accept);
  dialog.set_response_appearance('accept', destructive ? Adw.ResponseAppearance.DESTRUCTIVE : Adw.ResponseAppearance.SUGGESTED);
  dialog.set_default_response('cancel');
  dialog.set_close_response('cancel');
  dialog.connect('response', (_dialog, response) => {
    if (response === 'accept') onAccept();
  });
  dialog.present(ctx.window);
}
export {confirm};

/**
 * Pushes the editor for Slated binding `id` onto the Windows page's navigation view.
 * `autoRecord` starts the shortcut recorder as soon as the page shows (new bindings).
 */
export function pushBindingEditor(ctx, id, {autoRecord = false} = {}) {
  const model = ctx.model;
  const page = new Adw.NavigationPage({title: 'Shortcut'});
  // No tag: a NavigationView treats duplicate tags as errors, and editors come and go.
  page._slatedKey = `binding:${id}`;
  const header = new Adw.HeaderBar();
  const enabled = new Gtk.Switch({valign: Gtk.Align.CENTER, tooltip_text: 'Turn this shortcut on or off'});
  let quietSwitch = false;
  enabled.connect('notify::active', () => {
    if (!quietSwitch) model.setBinding(id, b => {
      b.enabled = enabled.get_active();
    });
  });
  const menuBox = box('vertical', 2);
  const menuPopover = new Gtk.Popover({child: menuBox});
  menuBox.append(button('Duplicate', () => {
    menuPopover.popdown();
    const copy = model.duplicateBinding(id);
    if (copy) pushBindingEditor(ctx, copy, {autoRecord: true});
  }, {classes: ['flat']}));
  menuBox.append(button('Delete…', () => {
    menuPopover.popdown();
    const binding = model.binding(id);
    if (!binding) return;
    confirm(ctx, {
      heading: `Delete “${bindingTitle(binding)}”?`, body: 'The shortcut stops working right away.', accept: 'Delete',
      onAccept: () => {
        const title = model.deleteBinding(id);
        if (title) ctx.toast(`Deleted “${title}”`);
      },
    });
  }, {classes: ['flat', 'destructive-action']}));
  header.pack_end(new Gtk.MenuButton({icon_name: 'view-more-symbolic', popover: menuPopover, tooltip_text: 'More'}));
  header.pack_end(enabled);

  const prefs = new Adw.PreferencesPage();
  const top = group();
  const head = summary();
  top.add(head.widget);
  const problem = notice({level: 'warning', title: ''});
  top.add(problem.widget);
  prefs.add(top);

  const previewGroup = group();
  const preview = new PlacementPreview(model);
  previewGroup.add(preview.widget);
  prefs.add(previewGroup);

  const shortcut = group({title: 'Shortcut'});
  const name = entryRow({title: 'Name', text: model.binding(id)?.name ?? '', onChange: value => model.setBinding(id, b => {
    if (value.trim()) b.name = value;
    else delete b.name;
  })});
  shortcut.add(name.row);
  const recorder = new ShortcutRecorder({
    title: 'Keys', keys: model.binding(id)?.keys ?? '',
    plainKeyHint: 'Or limit the shortcut to a game below to use a plain key there.',
    onChange: keys => model.setBinding(id, b => {
      b.keys = keys;
    }),
  });
  shortcut.add(recorder.row);
  const uses = new Adw.ActionRow({use_markup: false, title: 'Also used by', subtitle: '', activatable: false});
  uses.add_css_class('slated-warning-text');
  shortcut.add(uses);
  // An automation without keys yet: free keys one click away (a function key needs no modifier and
  // stays out of a game's way), as on the Mac.
  const suggested = new Adw.ActionRow({use_markup: false, title: 'Suggested', subtitle: 'Free right now'});
  const suggestedKeys = box('horizontal', 4);
  suggestedKeys.set_valign(Gtk.Align.CENTER);
  suggested.add_suffix(suggestedKeys);
  shortcut.add(suggested);

  const advanced = new Adw.ExpanderRow({use_markup: false, title: 'Advanced', subtitle: 'Repeat and modal keys'});
  const repeat = comboRow({
    title: 'Repeat while held', items: REPEAT_ITEMS, selected: repeatId(model.binding(id)?.repeats),
    onChange: value => model.setBinding(id, b => {
      if (value === 'default') delete b.repeats;
      else b.repeats = value === 'held';
    }),
  });
  advanced.add_row(repeat.row);
  const modalSwitch = switchRow({
    title: 'Press a modal key first', subtitle: "Slate's modal keys: press it, then this shortcut's key",
    active: Boolean(model.binding(id)?.modal),
    onChange: on => model.setBinding(id, b => {
      if (on) b.modal = {keys: 'ctrl+f4', toggle: false};
      else delete b.modal;
    }),
  });
  advanced.add_row(modalSwitch.row);
  const modalRecorder = new ShortcutRecorder({
    title: 'Modal key', keys: model.binding(id)?.modal?.keys ?? '', requiresModifier: false,
    onChange: keys => keys && model.setBinding(id, b => {
      if (b.modal) b.modal.keys = keys;
    }),
  });
  advanced.add_row(modalRecorder.row);
  const modalToggle = switchRow({
    title: 'Stay in modal mode after the shortcut runs', active: model.binding(id)?.modal?.toggle === true,
    onChange: on => model.setBinding(id, b => {
      if (b.modal) b.modal.toggle = on;
    }),
  });
  advanced.add_row(modalToggle.row);
  shortcut.add(advanced);
  prefs.add(shortcut);

  const scopeEditor = appScopeEditor(ctx, id);
  prefs.add(scopeEditor.group);

  // Automations: how they're kept safe, with a way to the settings.
  const safety = group();
  const safetyNotice = notice({level: 'info', iconName: 'security-high-symbolic', title: 'Automation safety',
    actions: [{label: 'Safety Settings', onClick: () => ctx.navigate('automation')}]});
  safety.add(safetyNotice.widget);
  prefs.add(safety);

  const editor = new ActionEditor(ctx, {
    get: () => model.binding(id)?.action,
    set: action => model.setBinding(id, b => {
      b.action = action;
    }),
  });
  for (const g of editor.groups) prefs.add(g);

  const warnings = group();
  let warningWidgets = [];
  prefs.add(warnings);

  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(header);
  page.set_child(toolbar);

  const sync = () => {
    const binding = model.binding(id);
    if (!binding) {
      if (ctx.nav.get_visible_page() === page) ctx.nav.pop();
      return;
    }
    const state = model.bindingState(binding);
    const presentation = statePresentation(state);
    page.set_title(bindingTitle(binding));
    head.update({action: binding.action, titleText: bindingTitle(binding), pills: [presentation], keys: binding.keys, modal: binding.modal});
    const explanation = state.state === 'disabled' ? null : stateExplanation(state);
    problem.update({level: state.state === 'duplicate' || state.state === 'not-running' ? 'warning' : 'error', title: presentation.label, detail: explanation});
    problem.widget.set_visible(Boolean(explanation));
    quietSwitch = true;
    enabled.set_active(binding.enabled !== false);
    quietSwitch = false;
    previewGroup.set_visible(previews(binding.action));
    preview.setAction(binding.action);
    name.set(binding.name ?? '');
    recorder.set(binding.keys);
    // Limited to some apps, a plain key is fine: it's grabbed only while one of them has focus.
    recorder.requiresModifier = !(binding.onlyInApps ?? []).length;
    // Errors and the typing warning go under the keys; longer notes (mouse buttons, the built-in
    // shortcuts) are cards below. Shared keys are listed in "Also used by".
    const keyIssues = model.issuesFor(target.binding(id))
      .filter(i => i.field === 'keys' && i.message !== 'Record a shortcut.' && !i.message.startsWith('Same shortcut as'));
    const inline = keyIssues.find(i => i.severity === 'error') ?? keyIssues.find(i => i.message.startsWith('Without '));
    recorder.row.set_subtitle(inline?.message ?? '');
    if (keyIssues.some(i => i.severity === 'error')) recorder.row.add_css_class('slated-invalid');
    else recorder.row.remove_css_class('slated-invalid');
    const others = model.otherUses(binding.keys, binding.modal, id);
    uses.set_subtitle(formatList(others));
    uses.set_visible(others.length > 0);
    clear(suggestedKeys);
    const offer = !keysCombo(binding.keys).key && containsAutomation(binding.action)
      ? suggestedAutomationKeys(model.configuration, usedShortcutKeys(model.configuration)) : [];
    for (const keys of offer) {
      const b = new Gtk.Button({child: keycaps(keys), css_classes: ['flat'], tooltip_text: `Use ${comboLabel(keys)}`});
      b.connect('clicked', () => {
        recorder.stop();
        model.setBinding(id, x => {
          x.keys = keys;
        });
      });
      suggestedKeys.append(b);
    }
    suggested.set_visible(offer.length > 0);
    repeat.set(repeatId(binding.repeats));
    modalSwitch.set(Boolean(binding.modal));
    modalRecorder.set(binding.modal?.keys ?? '');
    modalRecorder.row.set_visible(Boolean(binding.modal));
    modalToggle.set(binding.modal?.toggle === true);
    modalToggle.row.set_visible(Boolean(binding.modal));
    scopeEditor.sync();
    const automation = containsAutomation(binding.action);
    safety.set_visible(automation);
    if (automation) {
      safetyNotice.update({level: automationSettings(model.configuration).stopShortcut ? 'info' : 'warning', title: 'Automation safety',
        detail: `${safetySummary(model.configuration)}. Turning Slated off, locking the screen and reloading the configuration let go of anything held.`});
    }
    editor.sync();
    // A PreferencesGroup has internal children, so remove exactly the notices added here.
    for (const widget of warningWidgets) warnings.remove(widget);
    const issues = model.issuesFor(target.binding(id));
    const notes = [
      ...issues.filter(i => i.severity === 'warning' && i.field === 'keys' && i !== inline && !i.message.startsWith('Same shortcut as'))
        .map(i => ({level: 'warning', title: i.message})),
      ...issues.filter(i => i.severity === 'warning' && i.field === 'action').map(i => ({level: 'warning', title: i.message})),
    ];
    // How GNOME runs a while-held repeat the editor above can't see: behind a modal key, or in a step.
    const behavior = whileHeldBehavior(binding, model.status.automation?.whileHeld);
    const nested = whileHeldRepeat(binding.action) !== binding.action;
    if (behavior === 'modal' || (nested && behavior && behavior !== 'key-repeat')) {
      notes.push({level: 'info', title: behavior === 'modal' ? GNOME_NOTES.modal : behavior === 'sends-keys' ? GNOME_NOTES.sendsKeys : GNOME_NOTES.repeatOff});
    }
    warningWidgets = notes.map(n => notice(n).widget);
    for (const widget of warningWidgets) warnings.add(widget);
    warnings.set_visible(warningWidgets.length > 0);
  };
  const offs = [model.on('config', sync), model.on('status', sync), model.on('sources', sync)];
  let recorded = !autoRecord;
  page.connect('shown', () => {
    if (!recorded) {
      recorded = true;
      recorder.start();
    }
  });
  page.connect('hidden', () => {
    recorder.stop();
    modalRecorder.stop();
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

/** The read-only page for a binding defined in a Slate file. */
export function pushSourceBinding(ctx, source, binding) {
  const model = ctx.model;
  const probed = binding.action ? {action: binding.action} : binding.probe();
  const action = binding.action ?? probed.action ?? null;
  const page = new Adw.NavigationPage({title: action ? actionTitle(action) : 'JavaScript Function'});
  const prefs = new Adw.PreferencesPage();

  const top = group();
  const head = summary();
  top.add(head.widget);
  const problem = notice({level: 'warning', title: ''});
  top.add(problem.widget);
  prefs.add(top);

  if (action && previews(action)) {
    const previewGroup = group();
    const preview = new PlacementPreview(model);
    preview.setAction(action);
    previewGroup.add(preview.widget);
    prefs.add(previewGroup);
  }

  const defined = group({title: 'Defined In'});
  const fileRow = new Adw.ActionRow({use_markup: false, title: 'File', subtitle: source.displayPath, subtitle_selectable: true});
  fileRow.add_suffix(button('Open', () => launchFile(source.file, page, {onError: e => ctx.toast(e.message)}), {classes: ['flat']}));
  defined.add(fileRow);
  if (binding.line) defined.add(new Adw.ActionRow({use_markup: false, title: 'Line', subtitle: String(binding.line)}));
  const keysRow = new Adw.ActionRow({use_markup: false, title: 'Keys'});
  keysRow.add_suffix(keycaps(binding.keys, {modal: binding.modal}));
  defined.add(keysRow);
  if (binding.modal) {
    defined.add(new Adw.ActionRow({use_markup: false, title: 'Modal key',
      subtitle: `Press ${binding.modal.keys} first${binding.modal.toggle ? '; stays on until pressed again' : ''}`}));
  }
  const opRow = new Adw.ActionRow({use_markup: false, title: 'Operation', subtitle: binding.summary ?? actionDetail(action), subtitle_selectable: true});
  opRow.add_css_class('slated-mono-subtitle');
  defined.add(opRow);
  prefs.add(defined);

  if (binding.isFunction) {
    const what = group({title: 'What It Does'});
    if (probed.action?.op === 'by-orientation') {
      what.add(new Adw.ActionRow({use_markup: false, title: 'On landscape displays', subtitle: actionTitle(probed.action.landscape)}));
      what.add(new Adw.ActionRow({use_markup: false, title: 'On portrait displays', subtitle: actionTitle(probed.action.portrait)}));
    } else if (probed.action) {
      what.add(new Adw.ActionRow({use_markup: false, title: 'On every display', subtitle: actionTitle(probed.action)}));
    } else {
      what.add(notice({level: 'info', title: 'This shortcut runs JavaScript',
        detail: `Slated can't turn it into a plain shortcut: it ${probed.reason}. Edit it in ${source.displayPath}; the extension reloads the file when it changes.`}).widget);
    }
    prefs.add(what);
  }

  const copy = group();
  const copyRow = new Adw.ActionRow({use_markup: false, title: '', subtitle: ''});
  const copyButton = button('Copy into Slated', () => {
    const id = model.copyIntoSlated(binding);
    if (id) ctx.toast('Copied into Slated. Remove it from your Slate file to avoid a duplicate.');
  }, {classes: ['suggested-action']});
  copyRow.add_suffix(copyButton);
  copy.add(copyRow);
  copy.set_visible(Boolean(action));
  prefs.add(copy);

  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);

  const sync = () => {
    const state = model.sourceBindingState(binding);
    const presentation = statePresentation(state);
    head.update({
      action, titleText: action ? actionTitle(action) : 'JavaScript Function',
      pills: [{label: 'Read-only', style: 'dim'}, presentation], keys: binding.keys, modal: binding.modal,
    });
    const explanation = stateExplanation(state);
    problem.update({level: state.state === 'failed' ? 'error' : 'warning', title: presentation.label, detail: explanation});
    problem.widget.set_visible(Boolean(explanation));
    const copied = model.isCopied(binding);
    copyRow.set_title(copied ? 'Already in Slated' : 'Make it editable');
    copyRow.set_subtitle(copied
      ? `Slated has its own copy of this shortcut. Remove this one from ${source.displayPath} to avoid a duplicate.`
      : `Copy this shortcut into Slated to change its keys or action here. Then remove it from ${source.displayPath} so the two don't collide.`);
    copyButton.set_sensitive(!copied);
  };
  const offs = [model.on('config', sync), model.on('status', sync)];
  page.connect('hidden', () => {
    if (!isInStack(ctx.nav, page)) offs.forEach(off => off());
  });
  sync();
  ctx.nav.push(page);
  return page;
}
