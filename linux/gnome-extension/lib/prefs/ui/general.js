// Settings → General: Slated in GNOME, feedback, the island, window behavior, and where the
// configuration and log live (port of GeneralPane.swift). There's no "launch at login" on GNOME: the
// extension runs with your session while it's enabled, so this page offers the extension's own switch
// instead. The Mac's "Open Config File", "Open Settings File" and "Import Slate Config into Slated…"
// menu items are buttons here, under Files.

import Adw from 'gi://Adw';

import {tildify} from '../util.js';
import {implemented} from '../engine.js';
import {fileExists} from '../io.js';
import {islandSettings, cheatSheetDelayItems, islandRowsSensitive, cheatSheetDelayText} from '../island.js';
import {button, group, switchRow, comboRow, spinRow, commandRow, launchFile} from './widgets.js';
import {openFileAction} from './overview.js';
import {importSlateDialog, IMPORT_TITLE} from './slateimport.js';
import {CONFIG_KEYS} from '../../core/index.js';
import {noKey, setSubtitle, settingKey} from './configkeys.js';

const REPEAT_ITEMS = [{id: 0.25, label: 'Short'}, {id: 0.4, label: 'Medium'}, {id: 0.7, label: 'Long'}];

/** The repeat choices, plus the current value when a hand edit or an import set another one. */
function repeatItems(value) {
  return REPEAT_ITEMS.some(i => i.id === value) ? REPEAT_ITEMS : [...REPEAT_ITEMS, {id: value, label: `${value} seconds`}];
}

/** "All changes saved" and friends, so it's clear there's no Save button to look for. */
export function saveStateText(state) {
  switch (state.kind) {
  case 'saved': return {text: 'All changes saved', style: 'success'};
  case 'pending': return {text: 'Saving…', style: 'dim'};
  case 'partial': return {text: state.count === 1 ? '1 item has errors and isn\'t saved' : `${state.count} items have errors and aren't saved`, style: 'warning'};
  case 'failed': return {text: `Couldn't save: ${state.message}`, style: 'error'};
  case 'blocked': return {text: `Saving paused until ${state.file ?? 'the configuration'} can be read`, style: 'warning'};
  case 'conflict': return {text: `Not saved: ${(state.files ?? []).join(' and ')} changed on disk`, style: 'warning'};
  default: return {text: '', style: 'dim'};
  }
}

/** "Updated from config.json", "Updated from config.json and settings.json"; empty for none. */
export function updatedText(files) {
  return files?.length ? `Updated from ${files.join(' and ')}` : '';
}

/**
 * What the "Slated is on" switch says turning Slated off does. Slated undoes only what it set up:
 * GNOME's caps:hyper option (xkb mode). keyd's mapping is a system file the extension can't change.
 * The one linux/install.sh wrote stays, whatever Slated's own Hyper switch says, until it's removed
 * with --remove; a keyd configured by hand does what it says, Caps Lock included or not.
 */
export function turningOffText(hyperMode, slatedKeyd) {
  const runs = 'Slated runs with your session while this is on.';
  if (hyperMode === 'xkb') return `${runs} Turning it off restores Caps Lock and stops your shortcuts.`;
  if (slatedKeyd) {
    return `${runs} Turning it off stops your shortcuts; keyd keeps Caps Lock as Hyper until you remove it (linux/install.sh --hyper-keyd --remove).`;
  }
  if (hyperMode === 'keyd') {
    return `${runs} Turning it off stops your shortcuts. Caps Lock stays as your keyd configuration has it: change it there, then run sudo keyd reload.`;
  }
  return `${runs} Turning it off stops your shortcuts.`;
}

const bool = (settings, key, fallback) => (typeof settings[key] === 'boolean' ? settings[key] : fallback);
const number = (settings, key, fallback) => (typeof settings[key] === 'number' ? settings[key] : fallback);

export function createGeneralPane(ctx) {
  const model = ctx.model;
  const paths = ctx.paths;
  const home = paths.home;
  const prefs = new Adw.PreferencesPage();

  // Slated in GNOME
  const extension = group({title: 'Slated in GNOME'});
  let quiet = false;
  const enabled = switchRow({
    title: 'Slated is on', subtitle: '', active: true,
    onChange: on => {
      if (quiet) return;
      ctx.setEnabled(on);
    },
  });
  // GNOME's own switch for the extension: not in Slated's files.
  noKey(enabled.row, "the extension's GNOME switch");
  extension.add(enabled.row);
  // The Mac's menu bar icon: a click opens this window, a right click shows Slated's menu.
  const topBar = switchRow({
    title: 'Show Slated in the top bar',
    subtitle: 'Click the icon to open Slated; right-click it to pause Slated, turn the Hyper key on or off, or open the log. Slated is in your apps too.',
    active: model.configuration.general.showStatusIcon !== false, key: settingKey(CONFIG_KEYS.showStatusIcon),
    onChange: on => model.update(config => {
      config.general.showStatusIcon = on;
    }),
  });
  extension.add(topBar.row);
  prefs.add(extension);

  // Feedback
  const feedback = group({title: 'Feedback'});
  const hud = switchRow({
    title: 'Show what just happened',
    subtitle: 'Names the action each time a shortcut runs — in the island, or a small banner when the island is off. Handy while you learn your bindings.',
    active: model.configuration.general.showActionHUD, key: settingKey(CONFIG_KEYS.showActionHUD),
    onChange: on => model.update(config => {
      config.general.showActionHUD = on;
    }),
  });
  feedback.add(hud.row);
  prefs.add(feedback);

  // The island (the Mac's notch island, at the top center of the screen)
  const islandGroup = group({title: 'Island'});
  const island = () => islandSettings(model.configuration);
  const setIsland = (key, value) => model.update(config => {
    config.island = {...islandSettings(config), [key]: value};
  });
  const islandOn = switchRow({
    title: 'Show the island',
    subtitle: 'Running automations, the active modal key and quick feedback appear at the top center of the screen. Hover over a running automation to stop it.',
    active: island().enabled, key: settingKey(CONFIG_KEYS.islandEnabled),
    onChange: on => setIsland('enabled', on),
  });
  const cheatSheet = switchRow({
    title: 'Hold Caps Lock to see your shortcuts',
    subtitle: 'Keep the Hyper key held for a moment to list every Hyper shortcut; after a modal key, its keys appear the same way.',
    active: island().cheatSheet, key: settingKey(CONFIG_KEYS.islandCheatSheet),
    onChange: on => setIsland('cheatSheet', on),
  });
  const sheetDelay = comboRow({
    title: 'Cheat sheet delay', subtitle: cheatSheetDelayText(false),
    items: cheatSheetDelayItems(island().cheatSheetDelay), selected: island().cheatSheetDelay, key: settingKey(CONFIG_KEYS.islandCheatSheetDelay),
    onChange: value => setIsland('cheatSheetDelay', value),
  });
  const failures = switchRow({
    title: "Explain shortcuts that can't run",
    subtitle: 'When a shortcut has nothing to act on — no window to move, say — the island briefly says why.',
    active: island().showFailures, key: settingKey(CONFIG_KEYS.islandShowFailures),
    onChange: on => setIsland('showFailures', on),
  });
  for (const control of [islandOn, cheatSheet, sheetDelay, failures]) islandGroup.add(control.row);
  prefs.add(islandGroup);

  // Window behavior (Slate's own settings)
  const behavior = group({title: 'Window Behavior', description: "Slate's window settings, kept in settings.json under \"windows\"."});
  const settings = () => model.configuration.windows;
  const leftToRight = switchRow({
    title: 'Number displays from left to right',
    subtitle: "Display 1 is the leftmost. Turn off to use GNOME's order, with the primary display first.",
    active: bool(settings(), 'orderScreensLeftToRight', true), key: settingKey(CONFIG_KEYS.orderScreensLeftToRight),
    onChange: on => model.update(config => {
      config.windows.orderScreensLeftToRight = on;
    }),
  });
  behavior.add(leftToRight.row);
  const repeat = comboRow({
    title: 'Repeat while held', subtitle: 'How long to hold a shortcut before it repeats, for operations that repeat.',
    items: repeatItems(number(settings(), 'secondsBeforeRepeat', 0.4)), selected: number(settings(), 'secondsBeforeRepeat', 0.4),
    key: settingKey(CONFIG_KEYS.secondsBeforeRepeat),
    onChange: value => model.update(config => {
      config.windows.secondsBeforeRepeat = value;
    }),
  });
  behavior.add(repeat.row);
  const undo = spinRow({
    title: 'Undo history', subtitle: 'How many window moves Undo can step back through.', min: 1, max: 50,
    value: number(settings(), 'undoMaxStackSize', 10), key: settingKey(CONFIG_KEYS.undoMaxStackSize),
    onChange: value => model.update(config => {
      config.windows.undoMaxStackSize = Math.round(value);
    }),
  });
  behavior.add(undo.row);
  prefs.add(behavior);

  // Files: what your keys do (config.json), how Slated behaves (settings.json), and the Slate import.
  const configDir = tildify(paths.configDir, home);
  const filesGroup = group({title: 'Files',
    description: `Shortcuts, hotstrings and the Hyper key are in ${tildify(paths.configFile, home)}; these settings are in settings.json, next to it.`,
    suffix: button('', () => ctx.reload(), {icon: 'view-refresh-symbolic', classes: ['flat'], tooltip: 'Reload config.json and settings.json'})});
  const fileRow = (file, path) => {
    const row = new Adw.ActionRow({use_markup: false, title: tildify(path, home), subtitle: '', subtitle_selectable: false});
    row.set_title_selectable(true);
    row.add_css_class('slated-mono-title');
    const open = openFileAction(ctx, file, prefs);
    row.add_suffix(button(`Open ${file}`, () => {
      model.saveNow();
      open.run();
      model.log(file === 'settings.json' ? 'ui.open_settings' : 'ui.open_config');
    }, {classes: ['flat']}));
    filesGroup.add(row);
    return row;
  };
  // The keys under every setting, and the right-click menu that copies them.
  const showKeys = switchRow({
    title: 'Show config keys',
    subtitle: 'Each setting’s key in config.json or settings.json, under its name. Right-click any setting to copy its key or value, or to open its file.',
    active: model.configuration.general.showConfigKeys !== false, key: settingKey(CONFIG_KEYS.showConfigKeys),
    onChange: on => model.update(config => {
      config.general.showConfigKeys = on;
    }),
  });
  filesGroup.add(showKeys.row);
  const configRow = fileRow('config.json', paths.configFile);
  const settingsRow = fileRow('settings.json', paths.settingsFile);
  const folderRow = new Adw.ActionRow({use_markup: false, title: 'Configuration folder', subtitle: configDir});
  folderRow.add_suffix(button('Show in Files', () => {
    launchFile(paths.configFile, prefs, {folder: true, onError: e => ctx.toast(e.message)});
    model.log('ui.reveal_config');
  }, {classes: ['flat']}));
  filesGroup.add(folderRow);
  const importRow = new Adw.ActionRow({use_markup: false, title: 'Slate config',
    subtitle: "Slated doesn't read ~/.slate.js or ~/.slate. Import one to turn its shortcuts into Slated's; shortcuts Slated already has are left alone."});
  importRow.set_subtitle_lines(0);
  importRow.add_suffix(button(IMPORT_TITLE, () => importSlateDialog(ctx), {classes: ['flat']}));
  filesGroup.add(importRow);
  prefs.add(filesGroup);

  // Log
  const logGroup = group({title: 'Event Log',
    description: 'Every shortcut, hotstring, settings change and error, one JSON event per line. It never contains typed text, hotstring replacements or window titles.'});
  const logRow = new Adw.ActionRow({use_markup: false, title: tildify(paths.logFile, home), subtitle: ''});
  logRow.set_title_selectable(true);
  logRow.add_css_class('slated-mono-title');
  logRow.add_suffix(button('Open Log', () => {
    launchFile(paths.logFile, prefs, {onError: e => ctx.toast(`Couldn't open the log: ${e.message}`)});
    model.log('ui.open_log');
  }, {classes: ['flat']}));
  logRow.add_suffix(button('Show in Files', () => launchFile(paths.logFile, prefs, {folder: true, onError: e => ctx.toast(e.message)}), {classes: ['flat']}));
  logGroup.add(logRow);
  logGroup.add(commandRow('Read it from the source folder', 'scripts/logs.py --session last', ctx.toast));
  logGroup.add(commandRow("GNOME Shell's own log (extension errors)", 'journalctl -f -o cat /usr/bin/gnome-shell', ctx.toast));
  prefs.add(logGroup);

  // Version
  const versionGroup = group({title: 'This Build'});
  const versionRow = new Adw.ActionRow({use_markup: false, title: 'Version', subtitle: ''});
  const commitRow = new Adw.ActionRow({use_markup: false, title: 'Commit', subtitle: '', subtitle_selectable: true});
  commitRow.add_css_class('slated-mono-subtitle');
  const builtRow = new Adw.ActionRow({use_markup: false, title: 'Built', subtitle: ''});
  const runningRow = new Adw.ActionRow({use_markup: false, title: 'Running', subtitle: ''});
  const engineRow = new Adw.ActionRow({use_markup: false, title: 'Engine', subtitle: ''});
  for (const row of [versionRow, commitRow, builtRow, runningRow, engineRow]) versionGroup.add(row);
  prefs.add(versionGroup);

  const sync = () => {
    const shell = model.shell;
    quiet = true;
    enabled.set(shell.reachable ? shell.state === 'active' || shell.state === 'activating' : model.status.running);
    quiet = false;
    enabled.row.set_sensitive(shell.reachable && shell.known);
    setSubtitle(enabled.row, !shell.reachable
      ? "Couldn't reach GNOME Shell. Use the Extensions app to turn Slated on or off."
      : shell.userExtensionsEnabled === false
        ? "GNOME's Extensions switch is off, so no extension runs, Slated included. Overview has the button that turns it on."
        : !shell.known
        ? 'GNOME Shell loads Slated after you log out and back in.'
        : turningOffText(model.status.hyper.mode, fileExists(paths.keydConfig)));
    hud.set(model.configuration.general.showActionHUD);
    showKeys.set(model.configuration.general.showConfigKeys !== false);
    topBar.set(model.configuration.general.showStatusIcon !== false);
    const isl = island();
    islandOn.set(isl.enabled);
    cheatSheet.set(isl.cheatSheet);
    sheetDelay.setItems(cheatSheetDelayItems(isl.cheatSheetDelay), isl.cheatSheetDelay);
    failures.set(isl.showFailures);
    const sensitive = islandRowsSensitive(isl);
    cheatSheet.row.set_sensitive(sensitive.cheatSheet);
    sheetDelay.row.set_sensitive(sensitive.cheatSheetDelay);
    failures.row.set_sensitive(sensitive.showFailures);
    // keyd's tap for Escape stops at the delay (linux/install.sh writes it into keyd's config).
    const keydTap = model.running && model.status.hyper.mode === 'keyd' && model.configuration.keyboard.capsLockAlone === 'escape';
    setSubtitle(sheetDelay.row, cheatSheetDelayText(keydTap));
    leftToRight.set(bool(settings(), 'orderScreensLeftToRight', true));
    const delay = number(settings(), 'secondsBeforeRepeat', 0.4);
    repeat.setItems(repeatItems(delay), delay);
    undo.set(number(settings(), 'undoMaxStackSize', 10));
    const save = saveStateText({...model.saveState, file: model.loadErrorFile});
    const fileState = file => (model.loadError
      ? (model.loadErrorFile === file ? `Can't be read: ${model.loadError}` : 'Saving paused')
      : model.firstRun ? 'Not created yet: your first change creates it.' : save.text);
    configRow.set_subtitle(fileState('config.json'));
    settingsRow.set_subtitle(fileState('settings.json'));
    const build = model.build;
    versionRow.set_subtitle(build?.version ?? ctx.ext.metadata?.['version-name'] ?? String(ctx.ext.metadata?.version ?? 'Development build'));
    commitRow.set_subtitle(build?.commit ?? 'Unknown (not installed with linux/install.sh)');
    builtRow.set_subtitle(build?.builtAt ?? build?.buildDate ?? 'Unknown');
    runningRow.set_subtitle(model.runningCommit
      ? `${model.runningCommit}${build?.commit && build.commit !== model.runningCommit ? ' — log out and back in to load the installed build' : ''}`
      : model.status.running ? `Session ${model.status.session ?? '?'}` : 'Not running');
    const pending = ['parseOperation', 'evaluateExpression', 'targetFrame'].filter(name => !implemented(name));
    engineRow.set_subtitle(pending.length ? `Partly built: ${pending.join(', ')} not available yet` : 'Complete');
  };
  model.on('config', sync);
  model.on('status', sync);
  model.on('save-state', sync);
  sync();

  const page = new Adw.NavigationPage({title: 'General', tag: 'general'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  return {id: 'general', title: 'General', iconName: 'preferences-system-symbolic', page, badge: () => null};
}
