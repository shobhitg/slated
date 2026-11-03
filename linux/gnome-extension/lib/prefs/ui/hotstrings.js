// Settings → Hotstrings: type a short trigger, get the replacement (port of HotstringsPane.swift and
// HotstringEditor.swift). On GNOME, only espanso can type into other apps, so the extension keeps an
// espanso match file in sync with these hotstrings; this page says so and helps install espanso.

import Adw from 'gi://Adw';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {target} from '../validator.js';
import {expandTyping, espansoGuidance, gnomeScopeNote} from '../hotstrings.js';
import {singleLine, truncate} from '../util.js';
import {
  box, label, button, icon, badge, triggerChip, notice, group, emptyState, comboRow, switchRow, entryRow, textArea, launchUri,
  pill,
} from './widgets.js';
import {confirm} from './bindingeditor.js';
import {METHOD_HINTS} from './actioneditor.js';
import {CONFIG_KEYS, appendKey, hotstringSecret, keyDisplay, secretKey} from '../../core/index.js';
import {applyKey, attachKey, fieldKey, groupKey, hotstringScope, itemCaption, noKey, setSubtitle, setTitle, settingKey} from './configkeys.js';

const FIRE_ITEMS = [{id: 'immediately', label: 'Right away'}, {id: 'afterDelimiter', label: 'After a space or punctuation'}];
const METHOD_ITEMS = [{id: 'auto', label: 'Automatic'}, {id: 'type', label: 'Typing'}, {id: 'paste', label: 'Pasting'}];
const SCOPE_ITEMS = [{id: 'everywhere', label: 'Everywhere'}, {id: 'only', label: 'Only in these apps'}, {id: 'except', label: 'Everywhere except these apps'}];

/** What a sensitive hotstring's text shows while it's hidden: always eight dots, whatever its length (as on the Mac). */
export const MASK = '••••••••';
const PLACEHOLDERS = 'Placeholders: {date}, {time}, {datetime}, {clipboard}, {date:yyyy-MM-dd}. Use {{ and }} for literal braces.';
const SENSITIVE_NOTE = 'Its text moves to secrets.json, which only you can read, and stays hidden here. '
  + 'Always typed, never pasted, so it never goes through the clipboard.';
const TYPED_NOTE = "espanso types it key by key (force_mode: keys), exactly as written, never pasting it. "
  + "espanso's match file holds the text, readable only by you.";
const MISSING_TITLE = "Its text isn't on this computer yet: type it here";

/** A hotstring's text as the window shows it: its replacement, or for a sensitive one its secret's while shown, else eight dots. */
export function shownText(model, h, revealed = false) {
  if (hotstringSecret(h) === null) return typeof h.replacement === 'string' ? h.replacement : '';
  return revealed ? model.hotstringText(h.id) ?? '' : MASK;
}

function isInStack(nav, page) {
  const stack = nav.get_navigation_stack();
  for (let i = 0; i < stack.get_n_items(); i++) if (stack.get_item(i) === page) return true;
  return false;
}

function hotstringState(model, h) {
  if (model.issuesFor(target.hotstring(h.id)).some(i => i.severity === 'error')) return {label: 'Not saved', style: 'error'};
  if (h.enabled === false) return {label: 'Off', style: 'dim'};
  if (model.configuration.general.hotstringsEnabled === false) return {label: 'Expansion is off', style: 'dim'};
  // espanso can't tell apps apart on GNOME, so the extension leaves these out (gnomeScopeNote).
  if (h.onlyInApps?.length) return {label: 'Mac only', style: 'dim'};
  if (!model.running) return {label: 'Not running', style: 'dim'};
  const s = model.status.hotstrings;
  if (!s.espansoInstalled || s.engine !== 'espanso') return {label: 'Needs espanso', style: 'warning'};
  return {label: 'Active', style: 'success'};
}

function pushHotstringEditor(ctx, id) {
  const model = ctx.model;
  const page = new Adw.NavigationPage({title: 'Hotstring'});
  page._slatedKey = `hotstring:${id}`;
  // Its fields' keys, under config.json › hotstrings › its trigger (or its index).
  const keys = hotstringScope(model, id);
  const header = new Adw.HeaderBar();
  const enabled = new Gtk.Switch({valign: Gtk.Align.CENTER, tooltip_text: 'Turn this hotstring on or off'});
  let quietSwitch = false;
  enabled.connect('notify::active', () => {
    if (!quietSwitch) model.setHotstring(id, h => {
      h.enabled = enabled.get_active();
    });
  });
  const menuBox = box('vertical', 2);
  const menuPopover = new Gtk.Popover({child: menuBox});
  menuBox.append(button('Duplicate', () => {
    menuPopover.popdown();
    const copy = model.duplicateHotstring(id);
    if (copy) pushHotstringEditor(ctx, copy);
  }, {classes: ['flat']}));
  menuBox.append(button('Delete…', () => {
    menuPopover.popdown();
    confirm(ctx, {
      heading: 'Delete this hotstring?', body: 'It stops expanding right away.', accept: 'Delete',
      onAccept: () => {
        const trigger = model.deleteHotstring(id);
        ctx.toast(trigger ? `Deleted “${trigger}”` : 'Deleted hotstring');
      },
    });
  }, {classes: ['flat', 'destructive-action']}));
  header.pack_end(new Gtk.MenuButton({icon_name: 'view-more-symbolic', popover: menuPopover, tooltip_text: 'More'}));
  attachKey(enabled, fieldKey(keys, 'enabled'), {kind: 'widget'});
  header.pack_end(enabled);

  const h0 = model.hotstring(id);
  const prefs = new Adw.PreferencesPage();

  // Summary
  const top = group();
  const summary = box('horizontal', 10);
  const chipHolder = box('horizontal', 0);
  const arrow = label('→', {classes: ['dim-label']});
  const replacementLabel = label('', {classes: ['title-3'], ellipsize: true});
  replacementLabel.set_hexpand(true);
  const stateHolder = box('horizontal', 0);
  summary.append(chipHolder);
  summary.append(arrow);
  summary.append(replacementLabel);
  summary.append(stateHolder);
  top.add(summary);
  const location = itemCaption(keys.resolve);
  top.add(location.widget);
  prefs.add(top);

  // Trigger
  const triggerGroup = group({title: 'Trigger'});
  const trigger = entryRow({title: 'Trigger', text: h0.trigger, monospace: true, key: fieldKey(keys, 'trigger'), onChange: v => model.setHotstring(id, h => {
    h.trigger = v;
  })});
  triggerGroup.add(trigger.row);
  const triggerIssues = new Adw.ActionRow({use_markup: false, title: 'Tip', subtitle: '', activatable: false});
  triggerIssues.set_subtitle_lines(0);
  triggerGroup.add(triggerIssues);
  const fire = comboRow({title: 'Expand', items: FIRE_ITEMS, selected: h0.fire, key: fieldKey(keys, 'fire'), onChange: v => model.setHotstring(id, h => {
    h.fire = v;
  })});
  triggerGroup.add(fire.row);
  const caseRow = switchRow({title: 'Match case exactly', active: h0.caseSensitive !== false, key: fieldKey(keys, 'caseSensitive'), onChange: v => model.setHotstring(id, h => {
    h.caseSensitive = v;
  })});
  triggerGroup.add(caseRow.row);
  const word = switchRow({title: 'Only at the start of a word', active: h0.wordBoundary === true, key: fieldKey(keys, 'wordBoundary'), onChange: v => model.setHotstring(id, h => {
    h.wordBoundary = v;
  })});
  triggerGroup.add(word.row);
  prefs.add(triggerGroup);

  // Replacement
  const replacementGroup = group({title: 'Replacement'});
  groupKey(replacementGroup, fieldKey(keys, 'replacement'), PLACEHOLDERS);
  const count = label('', {classes: ['dim-label', 'caption']});
  replacementGroup.set_header_suffix(count);
  // Sensitive: the text moves to secrets.json and stays hidden here until its eye shows it (while this
  // page is open). Shown or not, Copy Value on it copies the reference in config.json, never the text.
  let revealed = false;
  const sensitive = switchRow({
    title: 'Sensitive', subtitle: SENSITIVE_NOTE, active: hotstringSecret(h0) !== null, key: fieldKey(keys, 'replacement'),
    onChange: on => {
      revealed = false;
      model.setHotstringSensitive(id, on);
    },
  });
  replacementGroup.add(sensitive.row);
  const replacement = textArea({text: typeof h0.replacement === 'string' ? h0.replacement : '', key: fieldKey(keys, 'replacement'),
    onChange: v => model.setHotstring(id, h => {
      h.replacement = v;
    })});
  replacementGroup.add(replacement.widget);
  // Where the text is (`secrets.json › pw`, the file's name a link), with the replacement's menu.
  const secretInfo = {
    get text() {
      const name = hotstringSecret(model.hotstring(id) ?? {});
      return name ? keyDisplay(secretKey(name)) : '';
    },
    resolve: () => fieldKey(keys, 'replacement').resolve(),
  };
  const masked = new Adw.ActionRow({use_markup: false, title: MASK});
  attachKey(masked, secretInfo, {title: MASK});
  const eye = button('', () => {
    revealed = !revealed;
    sync();
  }, {icon: 'view-reveal-symbolic', classes: ['flat'], tooltip: 'Show'});
  eye.set_valign(Gtk.Align.CENTER);
  masked.add_prefix(icon('changes-prevent-symbolic'));
  masked.add_suffix(eye);
  replacementGroup.add(masked);
  const secretText = textArea({text: '', key: secretInfo, onChange: v => model.setHotstringSecretText(id, v)});
  replacementGroup.add(secretText.widget);
  // Copied in without secrets.json: type the text here; it doesn't expand until then.
  const missing = new Adw.PasswordEntryRow({use_markup: false, title: MISSING_TITLE, show_apply_button: true});
  attachKey(missing, secretInfo, {kind: 'entry', title: MISSING_TITLE});
  missing.connect('apply', () => {
    model.setHotstringSecretText(id, missing.get_text());
    missing.set_text('');
  });
  replacementGroup.add(missing);
  const method = comboRow({title: 'Insert by', subtitle: METHOD_HINTS[h0.method ?? 'auto'], items: METHOD_ITEMS, selected: h0.method ?? 'auto',
    key: fieldKey(keys, 'method'),
    onChange: v => model.setHotstring(id, h => {
      h.method = v;
    })});
  replacementGroup.add(method.row);
  // A sensitive hotstring is always typed, whatever its method says (kept for when it isn't sensitive).
  const typed = new Adw.ActionRow({use_markup: false, title: 'Always typed', subtitle: TYPED_NOTE, activatable: false});
  typed.set_subtitle_lines(0);
  replacementGroup.add(typed);
  prefs.add(replacementGroup);

  // Where it works
  // App filters hold Mac bundle identifiers: espanso can't tell apps apart on GNOME (gnomeScopeNote),
  // so there's no picker of GNOME apps here, only a field for the shared config's Mac side.
  const whereGroup = group({title: 'Where It Works', description: 'Expands in every app.'});
  let storedScope = h0.onlyInApps?.length ? 'only' : h0.exceptInApps?.length ? 'except' : 'everywhere';
  // onlyInApps, or exceptInApps once "Everywhere except" is picked.
  const appsKey = {
    get text() {
      return storedScope === 'except' ? 'exceptInApps' : 'onlyInApps';
    },
    resolve: () => {
      const key = keys.resolve();
      return key ? appendKey(key, appsKey.text) : null;
    },
  };
  const scope = comboRow({title: 'Expands', items: SCOPE_ITEMS, selected: storedScope, key: appsKey, onChange: v => {
    storedScope = v;
    model.setHotstring(id, h => {
      const apps = h.onlyInApps?.length ? h.onlyInApps : (h.exceptInApps ?? []);
      h.onlyInApps = v === 'only' ? apps : [];
      h.exceptInApps = v === 'except' ? apps : [];
    });
    syncApps();
  }});
  whereGroup.add(scope.row);
  let appRows = [];
  const addApp = new Adw.EntryRow({use_markup: false, title: 'Add a Mac app (bundle identifier)', show_apply_button: true});
  attachKey(addApp, appsKey, {kind: 'entry', title: 'Add a Mac app (bundle identifier)'});
  const appendApp = appId => {
    const value = appId.trim();
    if (!value) return;
    model.setHotstring(id, h => {
      const key = storedScope === 'except' ? 'exceptInApps' : 'onlyInApps';
      if (!h[key].includes(value)) h[key] = [...h[key], value];
    });
  };
  addApp.connect('apply', () => {
    appendApp(addApp.get_text());
    addApp.set_text('');
  });
  let addAppShown = false;
  prefs.add(whereGroup);

  function syncApps() {
    const h = model.hotstring(id);
    if (!h) return;
    for (const row of appRows) whereGroup.remove(row);
    if (addAppShown) whereGroup.remove(addApp);
    addAppShown = false;
    appRows = [];
    const active = h.onlyInApps?.length ? 'only' : h.exceptInApps?.length ? 'except' : storedScope;
    scope.set(active);
    applyKey(scope.row);
    applyKey(addApp);
    const list = active === 'only' ? h.onlyInApps : active === 'except' ? h.exceptInApps : [];
    for (const appId of list) {
      const row = new Adw.ActionRow({use_markup: false, title: appId});
      row.add_css_class('slated-mono');
      row.add_suffix(button('', () => model.setHotstring(id, x => {
        x.onlyInApps = x.onlyInApps.filter(a => a !== appId);
        x.exceptInApps = x.exceptInApps.filter(a => a !== appId);
      }), {icon: 'list-remove-symbolic', classes: ['flat'], tooltip: 'Remove'}));
      whereGroup.add(row);
      appRows.push(row);
    }
    whereGroup.set_description(gnomeScopeNote(h)?.detail ?? (active === 'everywhere'
      ? 'Expands in every app.'
      : `Add the apps below. ${active === 'only' ? 'Mac only' : 'On GNOME it still expands everywhere'}: espanso can't tell apps apart on GNOME.`));
    if (active !== 'everywhere') {
      // The "add" row stays last, below the apps already chosen.
      whereGroup.add(addApp);
      addAppShown = true;
    }
  }

  // Try it
  const tryGroup = group({title: 'Try It', description: 'Simulates this hotstring in the field below. If espanso is running, it may expand here too — that\'s the real thing.'});
  const tryEntry = noKey(new Gtk.Entry({hexpand: true}), "a test field that isn't saved");
  const tryStatus = label('', {classes: ['dim-label', 'caption']});
  let previous = '';
  let quietTry = false;
  let flash = 0;
  tryEntry.connect('changed', () => {
    if (quietTry) return;
    const current = tryEntry.get_text();
    const h = model.hotstring(id);
    // A sensitive hotstring expands to dots here unless its text is shown: the field isn't hidden.
    const expanded = h ? expandTyping(previous, current, {...h, replacement: shownText(model, h, revealed)}) : null;
    previous = current;
    if (expanded === null) return;
    quietTry = true;
    tryEntry.set_text(expanded);
    tryEntry.set_position(-1);
    quietTry = false;
    previous = expanded;
    tryStatus.set_label('Expanded');
    if (flash) GLib.source_remove(flash);
    flash = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1600, () => {
      flash = 0;
      syncTryHelp();
      return GLib.SOURCE_REMOVE;
    });
  });
  const tryBox = box('vertical', 6);
  tryBox.append(tryEntry);
  tryBox.append(tryStatus);
  tryGroup.add(tryBox);
  prefs.add(tryGroup);
  function syncTryHelp() {
    const h = model.hotstring(id);
    if (!h) return;
    tryEntry.set_placeholder_text(h.trigger ? `Type “${h.trigger}” here…` : 'Add a trigger, then type it here');
    if (!flash) {
      tryStatus.set_label(!h.trigger ? 'Nothing to try yet.' : h.fire === 'afterDelimiter'
        ? 'Expands when you type a space or punctuation after the trigger.' : 'Expands as soon as you finish typing the trigger.');
    }
  }

  // Notes
  const notesGroup = group({title: 'Notes'});
  groupKey(notesGroup, fieldKey(keys, 'notes'));
  const notes = textArea({text: h0.notes ?? '', minHeight: 60, key: fieldKey(keys, 'notes'), onChange: v => model.setHotstring(id, h => {
    if (v) h.notes = v;
    else delete h.notes;
  })});
  notesGroup.add(notes.widget);
  prefs.add(notesGroup);

  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(header);
  page.set_child(toolbar);

  const sync = () => {
    const h = model.hotstring(id);
    if (!h) {
      if (ctx.nav.get_visible_page() === page) ctx.nav.pop();
      return;
    }
    page.set_title(h.trigger || 'New Hotstring');
    location.update();
    chipHolder.get_first_child() && chipHolder.remove(chipHolder.get_first_child());
    chipHolder.append(triggerChip(h.trigger || 'trigger'));
    const isSensitive = hotstringSecret(h) !== null;
    const shown = shownText(model, h, revealed);
    replacementLabel.set_label(shown ? truncate(singleLine(shown), 60) : 'Replacement');
    stateHolder.get_first_child() && stateHolder.remove(stateHolder.get_first_child());
    stateHolder.append(pill(hotstringState(model, h)));
    quietSwitch = true;
    enabled.set_active(h.enabled !== false);
    quietSwitch = false;
    trigger.set(h.trigger);
    const issues = model.issuesFor(target.hotstring(h.id)).filter(i => i.field === 'trigger');
    triggerIssues.set_title(issues.length ? (issues.some(i => i.severity === 'error') ? 'Problem' : 'Heads up') : 'Tip');
    triggerIssues.set_subtitle(issues.map(i => i.message).join('\n') ||
      'Tip: start triggers with a character you rarely type, like ; or //, so they never fire by accident.');
    if (issues.some(i => i.severity === 'error')) triggerIssues.add_css_class('slated-invalid');
    else triggerIssues.remove_css_class('slated-invalid');
    if (issues.length && !issues.some(i => i.severity === 'error')) triggerIssues.add_css_class('slated-warning-row');
    else triggerIssues.remove_css_class('slated-warning-row');
    fire.set(h.fire);
    caseRow.set(h.caseSensitive !== false);
    word.set(h.wordBoundary === true);
    sensitive.set(isSensitive);
    const missingText = model.isMissingSecret(id);
    replacement.widget.set_visible(!isSensitive);
    masked.set_visible(isSensitive && !missingText);
    secretText.widget.set_visible(isSensitive && !missingText && revealed);
    missing.set_visible(missingText);
    method.row.set_visible(!isSensitive);
    typed.set_visible(isSensitive);
    if (isSensitive) {
      applyKey(masked);
      applyKey(secretText.widget);
      applyKey(missing);
      setTitle(masked, revealed ? 'Shown below until you leave this page' : MASK);
      eye.set_icon_name(revealed ? 'view-conceal-symbolic' : 'view-reveal-symbolic');
      eye.set_tooltip_text(revealed ? 'Hide' : 'Show');
      secretText.set(revealed ? model.hotstringText(id) ?? '' : '');
    } else {
      replacement.set(typeof h.replacement === 'string' ? h.replacement : '');
    }
    // Never a hidden text's length.
    count.set_label(isSensitive && !revealed ? '' : `${[...shown].length} characters`);
    setSubtitle(replacementGroup, isSensitive ? 'Typed exactly as written: no placeholders.' : PLACEHOLDERS);
    method.set(h.method ?? 'auto');
    setSubtitle(method.row, METHOD_HINTS[h.method ?? 'auto'] ?? '');
    notes.set(h.notes ?? '');
    syncApps();
    syncTryHelp();
  };
  const offs = [model.on('config', sync), model.on('status', sync)];
  page.connect('hidden', () => {
    if (!isInStack(ctx.nav, page)) {
      offs.forEach(off => off());
      if (flash) GLib.source_remove(flash);
      flash = 0;
    }
  });
  sync();
  ctx.nav.push(page);
  return page;
}

export function createHotstringsPane(ctx) {
  const model = ctx.model;
  let query = '';

  const prefs = new Adw.PreferencesPage();
  const infoGroup = group();
  const guidance = notice({level: 'info', title: '', actions: []});
  const installButton = button('Install espanso', () => launchUri('https://espanso.org/install/linux/', prefs), {classes: ['pill']});
  installButton.set_valign(Gtk.Align.CENTER);
  guidance.widget.append(installButton);
  infoGroup.add(guidance.widget);
  prefs.add(infoGroup);

  const search = new Gtk.SearchEntry({placeholder_text: 'Search hotstrings', hexpand: true});
  const searchGroup = group();
  searchGroup.add(search);
  prefs.add(searchGroup);

  const countLabel = label('', {classes: ['dim-label']});
  const listGroup = group({title: 'Hotstrings', suffix: countLabel});
  prefs.add(listGroup);
  let rows = [];

  const newHotstring = () => {
    const id = model.addHotstring();
    pushHotstringEditor(ctx, id);
  };
  const empty = emptyState({
    iconName: 'insert-text-symbolic', title: 'No hotstrings yet',
    description: 'Hotstrings expand short triggers into longer text — like ;shrug into ¯\\_(ツ)_/¯ or ;addr into your address.',
    actions: [{label: 'Create Your First Hotstring', suggested: true, onClick: newHotstring}],
  });
  const stack = new Gtk.Stack({transition_type: Gtk.StackTransitionType.CROSSFADE});
  stack.add_named(prefs, 'list');
  stack.add_named(empty, 'empty');

  // The master switch, independent of each hotstring's own switch.
  const master = new Gtk.Switch({valign: Gtk.Align.CENTER, tooltip_text: 'Turn all text expansion on or off. Each hotstring keeps its own setting.'});
  let quietMaster = false;
  master.connect('notify::active', () => {
    if (quietMaster) return;
    model.update(config => {
      config.general.hotstringsEnabled = master.get_active();
    });
    model.log('ui.hotstrings_enabled', {enabled: master.get_active()});
  });
  const masterBox = box('horizontal', 8);
  const masterText = box('vertical', 0);
  masterText.set_valign(Gtk.Align.CENTER);
  masterText.append(label('Expansion', {classes: ['dim-label']}));
  masterText.append(itemCaption(() => CONFIG_KEYS.hotstringsEnabled).widget);
  masterBox.append(masterText);
  masterBox.append(master);
  attachKey(masterBox, settingKey(CONFIG_KEYS.hotstringsEnabled), {kind: 'widget'});

  const page = new Adw.NavigationPage({title: 'Hotstrings', tag: 'hotstrings'});
  const toolbar = new Adw.ToolbarView({content: stack});
  const header = new Adw.HeaderBar();
  header.pack_end(button('', newHotstring, {icon: 'list-add-symbolic', classes: ['suggested-action'], tooltip: 'New Hotstring'}));
  header.pack_end(masterBox);
  toolbar.add_top_bar(header);
  page.set_child(toolbar);

  function rebuild() {
    const g = espansoGuidance(model.status.hotstrings, model.running, model.espansoRunning);
    guidance.update({level: g.level, title: g.title, detail: g.detail});
    installButton.set_visible(Boolean(g.link));
    quietMaster = true;
    master.set_active(model.configuration.general.hotstringsEnabled !== false);
    quietMaster = false;

    for (const row of rows) listGroup.remove(row);
    rows = [];
    const all = model.configuration.hotstrings;
    countLabel.set_label(String(all.length));
    // A sensitive hotstring's text is never searched: typing part of it finds nothing.
    const searched = h => [h.trigger, typeof h.replacement === 'string' ? h.replacement : '', h.notes];
    const visible = all.filter(h => !query || searched(h).some(f => (f ?? '').toLowerCase().includes(query)));
    for (const h of visible) {
      const issues = model.issuesFor(target.hotstring(h.id));
      const issue = issues.find(i => i.severity === 'error') ?? issues.find(i => i.severity === 'warning');
      const caption = issue?.message ?? [gnomeScopeNote(h)?.caption ?? null, h.notes?.split('\n')[0] ?? null].filter(Boolean).join(' · ');
      const text = shownText(model, h);
      const row = new Adw.ActionRow({
        use_markup: false,
        title: text ? truncate(singleLine(text), 80) : 'Nothing yet', subtitle: caption, activatable: true,
      });
      // `;pw → ••••••••` with a lock: a sensitive hotstring's text never shows in the list.
      if (hotstringSecret(h) !== null) row.add_suffix(icon('changes-prevent-symbolic'));
      row.set_title_lines(1);
      row.set_subtitle_lines(1);
      row.add_prefix(triggerChip(h.trigger || 'new'));
      if (issue) row.add_css_class(issue.severity === 'error' ? 'slated-invalid' : 'slated-warning-row');
      if (h.enabled === false) {
        row.add_css_class('dim-label');
        row.add_suffix(badge('Off'));
      }
      row.add_suffix(icon('go-next-symbolic'));
      row.connect('activated', () => pushHotstringEditor(ctx, h.id));
      rows.push(row);
    }
    if (all.length && !visible.length) rows.push(new Adw.ActionRow({use_markup: false, title: `No matches for “${search.get_text()}”`, activatable: false}));
    for (const row of rows) listGroup.add(row);
    stack.set_visible_child_name(all.length ? 'list' : 'empty');
  }

  search.connect('search-changed', () => {
    query = search.get_text().trim().toLowerCase();
    rebuild();
  });

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
  for (const signal of ['config', 'status']) model.on(signal, refresh);

  return {
    id: 'hotstrings',
    title: 'Hotstrings',
    iconName: 'insert-text-symbolic',
    page,
    activate: () => dirty && update(),
    badge: () => ({text: String(model.configuration.hotstrings.length), warning: false}),
    show(options = {}) {
      if (options.newHotstring) newHotstring();
    },
  };
}
