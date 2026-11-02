// Settings → Overview: status at a glance from status.json and GNOME Shell, clear guidance when
// Slated isn't running, the last thing it did, tips drawn from the user's own setup and next steps,
// with a link back to Get Started (port of OverviewPane.swift). After the move to version 2 imported
// your Slate config, it says so once, until dismissed.

import Adw from 'gi://Adw';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {hotkeyCounts} from '../status.js';
import {overviewRows} from '../statusRows.js';
import {fileExists} from '../io.js';
import {matchingPreset} from '../presets.js';
import {bindingTitle, actionTitle, containsAutomation} from '../actions.js';
import {plural, formatList, truncate, singleLine, tildify} from '../util.js';
import {box, label, button, icon, keycaps, pill, group, triggerChip, launchFile} from './widgets.js';
import {slatedMark} from './about.js';
import {importSlateDialog} from './slateimport.js';
import {linkForFile} from '../filelinks.js';
import {setLinkedLabel, setLinkedRow} from './filelinks.js';

/** "Open Config File" or "Open Settings File" (the Mac's menu items), and the file it opens (as its links do). */
export function openFileAction(ctx, file) {
  return {
    label: file === 'settings.json' ? 'Open Settings File' : 'Open Config File',
    run: () => ctx.openLink(linkForFile(file)),
  };
}

function greeting() {
  const hour = GLib.DateTime.new_now_local().get_hour();
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour >= 12 && hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/**
 * A status row: icon, title, value as subtitle, a pill and an optional button. The button's action is
 * {label, run}, or {copy: command} for a "Copy Command" button.
 */
function statusRow(title, iconName, toast) {
  const row = new Adw.ActionRow({use_markup: false, title, subtitle: ''});
  row.set_subtitle_lines(0);
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
      if (action?.copy) {
        const command = action.copy;
        actionButton.set_label('Copy Command');
        actionButton.set_tooltip_text(command);
        handler = () => {
          // GJS exposes gdk_clipboard_set_value() as set(); set_text() isn't introspectable.
          actionButton.get_clipboard().set(command);
          toast?.(`Copied “${command}”: paste it in a terminal`);
        };
      } else if (action) {
        actionButton.set_label(action.label);
        actionButton.set_tooltip_text(null);
        handler = action.run;
      }
    },
  };
}

/** The buttons for runningSummary()'s `action`, what gets Slated running. Also on Get Started. */
export function summaryActions(ctx, parent) {
  return {
    enableExtensions: {label: 'Turn On Extensions', run: () => ctx.enableUserExtensions()},
    enable: {label: 'Turn On Slated', run: () => ctx.setEnabled(true)},
    relogin: {label: 'Log Out…', run: () => ctx.logout()},
    log: {label: 'Open the Log', run: () => launchFile(ctx.paths.logFile, parent, {onError: e => ctx.toast(e.message)})},
    review: {label: 'Review Shortcuts', run: () => ctx.navigate('windows')},
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

  // The one-time notice after the move to version 2 imported your Slate config (as on the Mac).
  const noticeGroup = group();
  const noticeRow = new Adw.ActionRow({use_markup: false, title: '', subtitle: '', activatable: false});
  noticeRow.set_title_lines(0);
  noticeRow.set_subtitle_lines(0);
  noticeRow.add_prefix(icon('dialog-information-symbolic', {size: 20}));
  noticeRow.add_suffix(button('Dismiss', () => model.dismissMigrationNotice(), {classes: ['flat']}));
  noticeGroup.add(noticeRow);
  prefs.add(noticeGroup);

  // Status
  const statusGroup = group({title: 'Status'});
  const extensionRow = statusRow('Slated', 'system-run-symbolic', ctx.toast);
  const hyperRow = statusRow('Hyper Key', 'input-keyboard-symbolic', ctx.toast);
  const hotstringsRow = statusRow('Hotstrings', 'insert-text-symbolic', ctx.toast);
  const shortcutsRow = statusRow('Shortcuts', 'focus-windows-symbolic', ctx.toast);
  for (const r of [extensionRow, hyperRow, hotstringsRow, shortcutsRow]) statusGroup.add(r.row);
  prefs.add(statusGroup);

  // Activity
  const activityGroup = group({title: 'Activity'});
  const lastAction = new Adw.ActionRow({use_markup: false, title: '', subtitle: ''});
  lastAction.add_prefix(icon('media-playback-start-symbolic', {size: 20}));
  const lastError = new Adw.ActionRow({use_markup: false, title: '', subtitle: 'Last problem'});
  lastError.set_title_lines(0);
  lastError.add_prefix(icon('dialog-warning-symbolic', {size: 20, classes: ['slated-warning-text']}));
  activityGroup.add(lastAction);
  activityGroup.add(lastError);
  prefs.add(activityGroup);

  // Tips, then next steps (as on the Mac). Get Started leaves the sidebar once setup is done; it's
  // still a click away here.
  const tipsGroup = group({title: 'Try These'});
  prefs.add(tipsGroup);
  let tipRows = [];
  const nextGroup = group({title: "What's Next",
    suffix: button('Get Started', () => ctx.showGetStarted(), {icon: 'emoji-flags-symbolic', classes: ['flat']})});
  prefs.add(nextGroup);
  let nextRows = [];

  const actions = {
    ...summaryActions(ctx, prefs),
    keyboard: {label: 'Set Up', run: () => ctx.navigate('keyboard')},
    hotstrings: {label: 'Edit', run: () => ctx.navigate('hotstrings')},
    windows: {label: 'Edit', run: () => ctx.navigate('windows')},
  };
  const rowAction = action => (action && typeof action === 'object' ? action : actions[action] ?? null);

  function rebuildList(groupWidget, rows, items) {
    for (const r of rows) groupWidget.remove(r);
    const next = items.map(item => {
      const row = new Adw.ActionRow({use_markup: false, title: item.title, subtitle: item.detail ?? '', activatable: Boolean(item.run)});
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
      const file = model.loadErrorFile ?? 'config.json';
      setLinkedLabel(headline, `${file} needs a fix`);
      setLinkedLabel(detail, `Slated can't read ${file}, so it keeps running what it last loaded. Edits here won't be saved until the file is fixed.\n${model.loadError}`);
      const open = openFileAction(ctx, file);
      primaryAction = open.run;
      primary.set_label(open.label);
      primary.set_visible(true);
    } else {
      setLinkedLabel(headline, summary.title);
      let text = summary.detail;
      if (summary.level === 'ok') {
        const parts = [plural(counts.active, 'shortcut')];
        if (status.hotstrings.engine === 'espanso' && status.hotstrings.count) parts.push(plural(status.hotstrings.count, 'hotstring'));
        if (status.hyper.active) parts.push('the Hyper key');
        text = `${formatList(parts)} ${parts.length === 1 && counts.active === 1 ? 'is' : 'are'} live.`;
      }
      setLinkedLabel(detail, text ?? '');
      const action = actions[summary.action];
      primary.set_visible(Boolean(action));
      if (action) {
        primary.set_label(action.label);
        primaryAction = action.run;
      }
    }

    // Status rows: each says what's missing and offers what fixes it (statusRows.js).
    const statusRows = overviewRows({
      summary, status, shell: model.shell, config, keydConfigured: fileExists(ctx.paths.keydConfig), espansoRunning: model.espansoRunning,
    });
    for (const [row, data] of [[extensionRow, statusRows.extension], [hyperRow, statusRows.hyper], [hotstringsRow, statusRows.hotstrings],
      [shortcutsRow, statusRows.shortcuts]]) {
      row.update({value: data.value, state: data.state, action: rowAction(data.action)});
    }
    const notice = model.migrationNotice(tildify(ctx.paths.configFile, ctx.paths.home));
    noticeGroup.set_visible(Boolean(notice));
    if (notice) {
      setLinkedRow(noticeRow, {title: notice.text, subtitle: notice.unconvertible ?? ''});
    }
    const hyperOn = config.keyboard.capsLock === 'hyper';

    // Activity
    lastAction.set_title(status.lastAction ?? 'Nothing yet');
    lastAction.set_subtitle(status.lastAction ? 'Last action' : 'Use a shortcut and it shows up here.');
    lastError.set_title(status.lastError ?? '');
    lastError.set_visible(Boolean(status.lastError));
    activityGroup.set_visible(running);

    // Next steps (as on the Mac: up to three). GNOME starts Slated with the session: no "Launch at login".
    const next = [];
    if (!hyperOn) next.push({title: 'Turn on the Hyper key', detail: 'Caps Lock becomes ✦ — room for dozens of shortcuts.', run: () => ctx.navigate('keyboard')});
    if (model.slateImportSuggested) {
      next.push({title: 'Import your Slate config', detail: `Bring the shortcuts in ${model.slateFiles[0].displayPath} into Slated, where you can edit them.`,
        run: () => importSlateDialog(ctx)});
    }
    if (config.hotstrings.length < 3) next.push({title: 'Add a hotstring', detail: 'Type a short trigger, get a whole sentence.', run: () => ctx.navigate('hotstrings', {newHotstring: true})});
    if (config.clipboard?.enabled === false) next.push({title: 'Turn on clipboard history', detail: 'Paste anything you copied earlier, from one shortcut.', run: () => ctx.navigate('clipboard')});
    if (!config.bindings.some(b => containsAutomation(b.action))) {
      next.push({title: 'Try an auto-clicker', detail: 'Let Slated click, hold or press keys for you, with a stop shortcut.', run: () => ctx.navigate('automation')});
    }
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
    // Not one limited to some apps: those are Mac only (espanso can't tell apps apart on GNOME).
    const hs = config.hotstrings.find(h => h.enabled !== false && h.trigger && !h.onlyInApps?.length);
    if (hs) tips.push({title: 'Expand text', detail: `Type ${hs.trigger} anywhere to get “${truncate(singleLine(hs.replacement), 24)}”.`, suffix: triggerChip(hs.trigger)});
    if (!tips.length && hyperOn) tips.push({title: 'Hold Caps Lock', detail: "It's your Hyper key now: hold it and press a letter for a ✦ shortcut.", suffix: keycaps('hyper+a')});
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
