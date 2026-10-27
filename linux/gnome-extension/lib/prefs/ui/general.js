// Settings → General: Slated in GNOME, feedback, window behavior, and where the configuration and
// log live (port of GeneralPane.swift). There's no "launch at login" on GNOME: the extension runs
// with your session while it's enabled, so this page offers the extension's own switch instead.

import Adw from 'gi://Adw';

import {tildify} from '../util.js';
import {implemented} from '../engine.js';
import {button, group, switchRow, comboRow, spinRow, commandRow, launchFile} from './widgets.js';

const REPEAT_ITEMS = [{id: 0.25, label: 'Short'}, {id: 0.4, label: 'Medium'}, {id: 0.7, label: 'Long'}];

/** The repeat choices, plus the current value when a hand edit or Slate file set another one. */
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
  case 'blocked': return {text: 'Saving paused until config.json can be read', style: 'warning'};
  default: return {text: '', style: 'dim'};
  }
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
  extension.add(enabled.row);
  prefs.add(extension);

  // Feedback
  const feedback = group({title: 'Feedback'});
  const hud = switchRow({
    title: 'Show what just happened',
    subtitle: 'A small banner names the action each time a shortcut runs — handy while you learn your bindings.',
    active: model.configuration.general.showActionHUD,
    onChange: on => model.update(config => {
      config.general.showActionHUD = on;
    }),
  });
  feedback.add(hud.row);
  prefs.add(feedback);

  // Window behavior (Slate's own settings)
  const behavior = group({title: 'Window Behavior', description: "These are Slate's own settings; a Slate file can override them."});
  const settings = () => model.configuration.settings;
  const leftToRight = switchRow({
    title: 'Number displays from left to right',
    subtitle: "Display 1 is the leftmost. Turn off to use GNOME's order, with the primary display first.",
    active: bool(settings(), 'orderScreensLeftToRight', true),
    onChange: on => model.update(config => {
      config.settings.orderScreensLeftToRight = on;
    }),
  });
  behavior.add(leftToRight.row);
  const repeat = comboRow({
    title: 'Repeat while held', subtitle: 'How long to hold a shortcut before it repeats, for operations that repeat.',
    items: repeatItems(number(settings(), 'secondsBeforeRepeat', 0.4)), selected: number(settings(), 'secondsBeforeRepeat', 0.4),
    onChange: value => model.update(config => {
      config.settings.secondsBeforeRepeat = value;
    }),
  });
  behavior.add(repeat.row);
  const undo = spinRow({
    title: 'Undo history', subtitle: 'How many window moves Undo can step back through.', min: 1, max: 50,
    value: number(settings(), 'undoMaxStackSize', 10),
    onChange: value => model.update(config => {
      config.settings.undoMaxStackSize = Math.round(value);
    }),
  });
  behavior.add(undo.row);
  prefs.add(behavior);

  // Configuration file
  const configGroup = group({title: 'Configuration File'});
  const configRow = new Adw.ActionRow({use_markup: false, title: tildify(paths.configFile, home), subtitle: '', subtitle_selectable: false});
  configRow.set_title_selectable(true);
  configRow.add_css_class('slated-mono-title');
  configRow.add_suffix(button('Open', () => {
    model.saveNow();
    launchFile(paths.configFile, prefs, {onError: e => ctx.toast(`Couldn't open config.json: ${e.message}`)});
    model.log('ui.open_config');
  }, {classes: ['flat']}));
  configRow.add_suffix(button('Show in Files', () => {
    launchFile(paths.configFile, prefs, {folder: true, onError: e => ctx.toast(e.message)});
    model.log('ui.reveal_config');
  }, {classes: ['flat']}));
  configRow.add_suffix(button('', () => ctx.reload(), {icon: 'view-refresh-symbolic', classes: ['flat'], tooltip: 'Reload config.json and your Slate files'}));
  configGroup.add(configRow);
  prefs.add(configGroup);

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
    enabled.row.set_subtitle(!shell.reachable
      ? "Couldn't reach GNOME Shell. Use the Extensions app to turn Slated on or off."
      : !shell.known
        ? 'GNOME Shell loads Slated after you log out and back in.'
        // keyd's mapping is a system service's, which the extension can't undo (see Keyboard).
        : model.status.hyper.mode === 'keyd'
          ? 'Slated runs with your session while this is on. Turning it off stops your shortcuts; keyd keeps Caps Lock as Hyper until you remove it (linux/install.sh --hyper-keyd --remove).'
          : 'Slated runs with your session while this is on. Turning it off restores Caps Lock and stops your shortcuts.');
    hud.set(model.configuration.general.showActionHUD);
    leftToRight.set(bool(settings(), 'orderScreensLeftToRight', true));
    const delay = number(settings(), 'secondsBeforeRepeat', 0.4);
    repeat.setItems(repeatItems(delay), delay);
    undo.set(number(settings(), 'undoMaxStackSize', 10));
    const save = saveStateText(model.saveState);
    configRow.set_subtitle(model.loadError ? `Can't be read: ${model.loadError}` : model.firstRun ? 'Not created yet: your first change creates it.' : save.text);
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
