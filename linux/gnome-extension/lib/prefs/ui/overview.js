// Settings → Overview: status at a glance from status.json and GNOME Shell, clear guidance when
// Slated isn't running, the last thing it did, a "get started" checklist (the macOS onboarding's
// steps), next steps and tips drawn from the user's own setup (port of OverviewPane.swift).

import Adw from 'gi://Adw';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {hotkeyCounts} from '../status.js';
import {espansoGuidance} from '../hotstrings.js';
import {matchingPreset} from '../presets.js';
import {bindingTitle, actionTitle} from '../actions.js';
import {plural, formatList, truncate, singleLine} from '../util.js';
import {box, label, button, icon, keycaps, pill, group, triggerChip, launchFile} from './widgets.js';
import {slatedMark} from './about.js';

function greeting() {
  const hour = GLib.DateTime.new_now_local().get_hour();
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour >= 12 && hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/** A status row: icon, title, value as subtitle, a pill and an optional button. */
function statusRow(title, iconName) {
  const row = new Adw.ActionRow({title, subtitle: ''});
  row.add_prefix(icon(iconName, {size: 20}));
  const pillHolder = box('horizontal', 0);
  row.add_suffix(pillHolder);
  const actionButton = new Gtk.Button({valign: Gtk.Align.CENTER, css_classes: ['flat'], visible: false});
  let handler = null;
  actionButton.connect('clicked', () => handler?.());
  row.add_suffix(actionButton);
  return {
    row,
    update({value, state, action = null}) {
      row.set_subtitle(value);
      pillHolder.get_first_child() && pillHolder.remove(pillHolder.get_first_child());
      pillHolder.append(pill(state));
      actionButton.set_visible(Boolean(action));
      if (action) {
        actionButton.set_label(action.label);
        handler = action.run;
      }
    },
  };
}

export function createOverviewPane(ctx) {
  const model = ctx.model;
  const prefs = new Adw.PreferencesPage();

  // Hero
  const heroGroup = group();
  const hero = box('horizontal', 18, ['card', 'slated-hero']);
  const heroTexts = box('vertical', 6);
  heroTexts.set_hexpand(true);
  heroTexts.set_valign(Gtk.Align.CENTER);
  const greet = label('', {classes: ['slated-greeting']});
  const headline = label('', {classes: ['title-1'], wrap: true});
  const detail = label('', {wrap: true, selectable: true, classes: ['dim-label']});
  const heroButtons = box('horizontal', 8);
  heroButtons.set_margin_top(6);
  const primary = new Gtk.Button({css_classes: ['suggested-action', 'pill'], halign: Gtk.Align.START});
  let primaryAction = null;
  primary.connect('clicked', () => primaryAction?.());
  heroButtons.append(primary);
  heroTexts.append(greet);
  heroTexts.append(headline);
  heroTexts.append(detail);
  heroTexts.append(heroButtons);
  hero.append(heroTexts);
  hero.append(slatedMark(76));
  heroGroup.add(hero);
  prefs.add(heroGroup);

  // Status
  const statusGroup = group({title: 'Status'});
  const extensionRow = statusRow('Slated', 'system-run-symbolic');
  const hyperRow = statusRow('Hyper Key', 'input-keyboard-symbolic');
  const hotstringsRow = statusRow('Hotstrings', 'insert-text-symbolic');
  const shortcutsRow = statusRow('Shortcuts', 'focus-windows-symbolic');
  const slateRow = statusRow('Slate Config', 'text-x-generic-symbolic');
  for (const r of [extensionRow, hyperRow, hotstringsRow, shortcutsRow, slateRow]) statusGroup.add(r.row);
  prefs.add(statusGroup);

  // Activity
  const activityGroup = group({title: 'Activity'});
  const lastAction = new Adw.ActionRow({title: '', subtitle: ''});
  lastAction.add_prefix(icon('media-playback-start-symbolic', {size: 20}));
  const lastError = new Adw.ActionRow({title: '', subtitle: 'Last problem'});
  lastError.set_title_lines(0);
  lastError.add_prefix(icon('dialog-warning-symbolic', {size: 20, classes: ['slated-warning-text']}));
  activityGroup.add(lastAction);
  activityGroup.add(lastError);
  prefs.add(activityGroup);

  // Get started (the onboarding steps, as a checklist)
  const startGroup = group({title: 'Get Started'});
  prefs.add(startGroup);
  let startRows = [];

  // Next steps and tips
  const nextGroup = group({title: "What's Next"});
  prefs.add(nextGroup);
  let nextRows = [];
  const tipsGroup = group({title: 'Try These'});
  prefs.add(tipsGroup);
  let tipRows = [];

  const actions = {
    enable: {label: 'Turn On Slated', run: () => ctx.setEnabled(true)},
    relogin: {label: 'Log Out…', run: () => ctx.logout()},
    log: {label: 'Open the Log', run: () => launchFile(ctx.paths.logFile, prefs, {onError: e => ctx.toast(e.message)})},
    review: {label: 'Review Shortcuts', run: () => ctx.navigate('windows')},
  };

  function rebuildList(groupWidget, rows, items) {
    for (const r of rows) groupWidget.remove(r);
    const next = items.map(item => {
      const row = new Adw.ActionRow({title: item.title, subtitle: item.detail ?? '', activatable: Boolean(item.run)});
      row.set_subtitle_lines(2);
      if (item.prefix) row.add_prefix(item.prefix);
      if (item.done !== undefined) {
        row.add_prefix(icon(item.done ? 'object-select-symbolic' : 'media-record-symbolic',
          {classes: [item.done ? 'success' : 'dim-label']}));
      }
      if (item.suffix) row.add_suffix(item.suffix);
      if (item.run) {
        row.add_suffix(icon('go-next-symbolic'));
        row.connect('activated', item.run);
      }
      groupWidget.add(row);
      return row;
    });
    groupWidget.set_visible(next.length > 0);
    return next;
  }

  const sync = () => {
    const summary = model.summary();
    const status = model.status;
    const config = model.configuration;
    const counts = hotkeyCounts(status);
    const running = summary.running;

    greet.set_label(greeting().toUpperCase());
    if (model.loadError) {
      headline.set_label('config.json needs a fix');
      detail.set_label(`Slated can't read your configuration file, so it keeps running what it last loaded. Edits here won't be saved until the file is fixed.\n${model.loadError}`);
      primaryAction = () => launchFile(ctx.paths.configFile, prefs, {onError: e => ctx.toast(e.message)});
      primary.set_label('Open config.json');
      primary.set_visible(true);
    } else {
      headline.set_label(summary.title);
      let text = summary.detail;
      if (summary.level === 'ok') {
        const parts = [plural(counts.active, 'shortcut')];
        if (status.hotstrings.engine === 'espanso' && status.hotstrings.count) parts.push(plural(status.hotstrings.count, 'hotstring'));
        if (status.hyper.active) parts.push('the Hyper key');
        text = `${formatList(parts)} ${parts.length === 1 && counts.active === 1 ? 'is' : 'are'} live.`;
      }
      detail.set_label(text ?? '');
      const action = actions[summary.action];
      primary.set_visible(Boolean(action));
      if (action) {
        primary.set_label(action.label);
        primaryAction = action.run;
      }
    }

    // Status rows
    const shellState = model.shell;
    extensionRow.update({
      value: running ? `Running${status.session ? ` · session ${status.session}` : ''}${status.version ? ` · ${status.version}` : ''}` : summary.title,
      state: running ? {label: 'Running', style: 'success'} : summary.level === 'error' ? {label: 'Error', style: 'error'}
        : {label: shellState.state === 'inactive' ? 'Off' : 'Not running', style: 'warning'},
      action: running ? null : actions[summary.action] ?? null,
    });
    const hyperOn = config.keyboard.capsLock === 'hyper';
    const mods = config.keyboard.hyperModifiers.includes('cmd') ? 'Ctrl Alt Shift Super' : 'Ctrl Alt Shift';
    hyperRow.update({
      value: hyperOn ? `Caps Lock acts as ${mods}${status.hyper.mode !== 'off' && running ? ` · ${status.hyper.mode}` : ''}` : 'Caps Lock is normal',
      state: !hyperOn ? {label: 'Off', style: 'dim'} : running && status.hyper.active ? {label: 'On', style: 'success'}
        : {label: running ? 'Not active' : 'Waiting', style: 'warning'},
      action: hyperOn ? null : {label: 'Set Up', run: () => ctx.navigate('keyboard')},
    });
    const enabledHotstrings = config.hotstrings.filter(h => h.enabled !== false).length;
    const espanso = espansoGuidance(status.hotstrings, running);
    hotstringsRow.update({
      value: config.general.hotstringsEnabled === false ? 'Text expansion is turned off'
        : `${plural(enabledHotstrings, 'hotstring')} · ${espanso.title.toLowerCase()}`,
      state: config.general.hotstringsEnabled === false ? {label: 'Off', style: 'dim'}
        : espanso.level === 'ok' ? {label: 'Active', style: 'success'}
          : espanso.level === 'warning' ? {label: 'Needs espanso', style: 'warning'} : {label: 'Waiting', style: 'dim'},
      action: {label: 'Edit', run: () => ctx.navigate('hotstrings')},
    });
    const problems = [];
    if (counts.duplicate) problems.push(plural(counts.duplicate, 'duplicate'));
    if (counts.failed) problems.push(`${counts.failed} failed`);
    shortcutsRow.update({
      value: problems.length && running ? problems.join(' · ')
        : `${config.bindings.length} in Slated · ${model.sourceBindingCount()} from Slate${running ? ` · ${counts.active} active` : ''}`,
      state: !running ? {label: 'Waiting', style: 'dim'} : problems.length ? {label: 'Attention', style: 'warning'} : {label: `${counts.active} active`, style: 'success'},
      action: {label: problems.length && running ? 'Review' : 'Edit', run: () => ctx.navigate('windows')},
    });
    const loaded = model.sources.filter(s => s.exists);
    const errors = loaded.reduce((n, s) => n + (model.sourceStatus(s)?.diagnostics.length ?? s.diagnostics.filter(d => d.severity === 'error').length), 0);
    slateRow.update({
      value: !model.slateLoading ? 'Slate files are ignored' : !loaded.length ? 'No ~/.slate or ~/.slate.js'
        : `${loaded.map(s => s.displayPath).join(', ')} · ${plural(model.sourceBindingCount(), 'binding')}${errors ? ` · ${plural(errors, 'problem')}` : ''}`,
      state: !model.slateLoading ? {label: 'Off', style: 'dim'} : errors ? {label: 'Problems', style: 'warning'}
        : loaded.length ? {label: 'Loaded', style: 'success'} : {label: 'None', style: 'dim'},
      action: {label: 'Details', run: () => ctx.navigate('slate')},
    });

    // Activity
    lastAction.set_title(status.lastAction ?? 'Nothing yet');
    lastAction.set_subtitle(status.lastAction ? 'Last action' : 'Use a shortcut and it shows up here.');
    lastError.set_title(status.lastError ?? '');
    lastError.set_visible(Boolean(status.lastError));
    activityGroup.set_visible(running);

    // Get started
    const totalShortcuts = config.bindings.filter(b => b.enabled !== false).length + (model.slateLoading ? model.sourceBindingCount() : 0);
    const steps = [
      {title: 'Slated is running', detail: running ? 'GNOME Shell loaded the extension.' : summary.title, done: running,
        run: running ? null : actions[summary.action]?.run},
      {title: 'Caps Lock is your Hyper key', detail: hyperOn ? (status.hyper.active ? 'Hold Caps Lock for ✦' : 'Turned on; active once Slated runs') : 'Optional, and well worth it',
        done: hyperOn && status.hyper.active, run: () => ctx.navigate('keyboard')},
      {title: 'Shortcuts are ready', detail: `${plural(totalShortcuts, 'shortcut')}`, done: totalShortcuts > 0, run: () => ctx.navigate('windows')},
    ];
    if (config.hotstrings.length) {
      steps.push({title: 'espanso expands your hotstrings', detail: espanso.title, done: espanso.level === 'ok', run: () => ctx.navigate('hotstrings')});
    }
    startRows = rebuildList(startGroup, startRows, steps.every(s => s.done) ? [] : steps);

    // Next steps (as on macOS: up to three)
    const next = [];
    const copyable = model.sources.flatMap(s => s.bindings).filter(b => !model.isCopied(b));
    if (!hyperOn) next.push({title: 'Turn on the Hyper key', detail: 'Caps Lock becomes Ctrl+Alt+Shift+Super — room for dozens of shortcuts.', run: () => ctx.navigate('keyboard')});
    if (copyable.length && model.slateLoading) next.push({title: 'Bring over your Slate bindings', detail: `${plural(copyable.length, 'binding')} can be imported into Slated and edited here.`, run: () => ctx.navigate('slate')});
    if (config.hotstrings.length < 3) next.push({title: 'Add a hotstring', detail: 'Type a short trigger, get a whole sentence.', run: () => ctx.navigate('hotstrings', {newHotstring: true})});
    if (!config.layouts.length) next.push({title: 'Create a layout', detail: 'Arrange all your apps for a task with one shortcut.', run: () => ctx.navigate('layouts')});
    if (next.length < 3) next.push({title: 'Fine-tune a shortcut', detail: 'Every window shortcut has a live preview of where it lands.', run: () => ctx.navigate('windows')});
    nextRows = rebuildList(nextGroup, nextRows, next.slice(0, 3));

    // Tips from the user's own setup
    const tips = [];
    const enabledBindings = config.bindings.filter(b => b.enabled !== false && b.keys);
    const snap = enabledBindings.find(b => matchingPreset(b.action)?.group === 'halves');
    if (snap) tips.push({title: 'Snap a window', detail: `${bindingTitle(snap)} for the window in front.`, suffix: keycaps(snap.keys, {modal: snap.modal})});
    const chain = enabledBindings.find(b => b.action?.op === 'chain');
    if (chain) {
      tips.push({title: 'Cycle sizes', detail: `Press it again and again: ${(chain.action.operations ?? []).slice(0, 3).map(actionTitle).join(' → ')}.`,
        suffix: keycaps(chain.keys, {modal: chain.modal})});
    }
    const hs = config.hotstrings.find(h => h.enabled !== false && h.trigger);
    if (hs) tips.push({title: 'Expand text', detail: `Type ${hs.trigger} anywhere to get “${truncate(singleLine(hs.replacement), 24)}”.`, suffix: triggerChip(hs.trigger)});
    if (!tips.length && hyperOn) tips.push({title: 'Hold Caps Lock', detail: "It's Ctrl+Alt+Shift+Super now — a modifier no app uses, so ✦ shortcuts never clash.", suffix: keycaps('hyper+a')});
    tipRows = rebuildList(tipsGroup, tipRows, running ? tips.slice(0, 3) : []);
  };
  for (const signal of ['config', 'status', 'sources']) model.on(signal, sync);
  sync();

  const page = new Adw.NavigationPage({title: 'Overview', tag: 'overview'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  return {
    id: 'overview',
    title: 'Overview',
    iconName: 'go-home-symbolic',
    page,
    badge() {
      if (model.loadError) return {text: '!', warning: true};
      return model.summary().level === 'ok' ? null : {text: '!', warning: true};
    },
  };
}
