// Settings → Clipboard: clipboard history (Keyboard Maestro's clipboard switcher). The switch and
// the shortcut, how much to keep, privacy, and how the switcher works on GNOME (port of
// ClipboardPane.swift).
//
// The history itself lives in the running extension, which reports only how many items it holds
// (status.json). Searching, pasting, pinning and deleting happen in the switcher.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {tildify} from '../util.js';
import {keysString, comboLabel} from '../keys.js';
import {
  clipboardSettings, defaultClipboardSettings, MAX_ITEMS, RETENTION_DAYS, retentionTitle, withCurrent, appDisplayName,
  normalizeAppId, passwordManagerApps,
} from '../automation.js';
import {box, label, button, keycaps, pill, group, comboRow, switchRow} from './widgets.js';
import {ShortcutRecorder} from './recorder.js';
import {appPickerButton, installedApps} from './apps.js';

/** The hero's status pill: what clipboard history is doing right now. */
export function clipboardStatus(model) {
  const settings = clipboardSettings(model.configuration);
  if (!settings.enabled) return {label: 'Off', style: 'dim'};
  if (!model.running) return {label: 'Not running', style: 'dim'};
  if (model.builtInState('clipboard')?.state === 'failed') return {label: 'Shortcut failed', style: 'error'};
  return {label: 'Recording', style: 'success'};
}

export function createClipboardPane(ctx) {
  const model = ctx.model;
  const prefs = new Adw.PreferencesPage();
  const setClipboard = mutate => model.update(config => {
    config.clipboard = {...clipboardSettings(config)};
    mutate(config.clipboard);
  });

  // Hero: the switch, the shortcut and what's saved
  const statusHolder = box('horizontal', 8);
  const enabled = new Gtk.Switch({valign: Gtk.Align.CENTER, tooltip_text: 'Turn clipboard history on or off'});
  let quiet = false;
  enabled.connect('notify::active', () => {
    if (!quiet) setClipboard(c => {
      c.enabled = enabled.get_active();
    });
  });
  statusHolder.append(enabled);
  const hero = group({title: 'Clipboard History', suffix: statusHolder,
    description: 'Everything you copy, a keystroke away: search it, pin favorites, paste it again.'});
  const pressRow = new Adw.ActionRow({use_markup: false, title: 'Press in any app to bring it back', subtitle: ''});
  const pressKeys = box('horizontal', 0);
  pressRow.add_suffix(pressKeys);
  hero.add(pressRow);
  const statsRow = new Adw.ActionRow({use_markup: false, title: 'Saved', subtitle: ''});
  hero.add(statsRow);
  prefs.add(hero);

  // Shortcut
  const shortcut = group({title: 'Shortcut'});
  const recorder = new ShortcutRecorder({
    title: 'Open the switcher', keys: clipboardSettings(model.configuration).shortcut ?? '', allowClear: true,
    subtitle: '', onChange: keys => setClipboard(c => {
      c.shortcut = keys || null;
    }),
  });
  const restore = button('Default', () => setClipboard(c => {
    c.shortcut = defaultClipboardSettings().shortcut;
  }), {classes: ['flat'], tooltip: `Use ${comboLabel(defaultClipboardSettings().shortcut)} again`});
  recorder.row.add_suffix(restore);
  shortcut.add(recorder.row);
  const paste = switchRow({
    title: 'Paste after picking',
    subtitle: 'Pick an item and Slated pastes it into the app you were using (Ctrl+V, or Ctrl+Shift+V in terminals). Off: it\'s only copied, ready for you to paste.',
    active: clipboardSettings(model.configuration).pasteAfterSelecting,
    onChange: on => setClipboard(c => {
      c.pasteAfterSelecting = on;
    }),
  });
  shortcut.add(paste.row);
  prefs.add(shortcut);

  // History
  const history = group({title: 'History', description: 'Pinned items are never forgotten, pushed out or cleared.'});
  const itemChoices = n => withCurrent(MAX_ITEMS, n).map(v => ({id: v, label: `${v} items`}));
  const dayChoices = d => withCurrent(RETENTION_DAYS, d).map(v => ({id: v, label: retentionTitle(v)}));
  const settings0 = clipboardSettings(model.configuration);
  const maxItems = comboRow({
    title: 'Remember up to', subtitle: 'The oldest items make room for new ones.', items: itemChoices(settings0.maxItems), selected: settings0.maxItems,
    onChange: n => setClipboard(c => {
      c.maxItems = n;
    }),
  });
  history.add(maxItems.row);
  const retention = comboRow({
    title: 'Forget items after', subtitle: "Older items are removed, so history doesn't pile up.", items: dayChoices(settings0.retentionDays),
    selected: settings0.retentionDays,
    onChange: d => setClipboard(c => {
      c.retentionDays = d;
    }),
  });
  history.add(retention.row);
  const persist = switchRow({
    title: 'Keep history across restarts', subtitle: '', active: settings0.persist,
    onChange: on => setClipboard(c => {
      c.persist = on;
    }),
  });
  history.add(persist.row);
  prefs.add(history);

  // Privacy
  const privacy = group({title: 'Privacy',
    description: "Clipboard history never leaves this computer. Slated's log notes how long a copy was, never what it said."});
  const concealed = switchRow({
    title: 'Ignore passwords and other secrets',
    subtitle: 'Password managers such as KeePassXC mark what they copy as secret. Slated skips those, so passwords never land in your history.',
    active: settings0.ignoreConcealed,
    onChange: on => setClipboard(c => {
      c.ignoreConcealed = on;
    }),
  });
  privacy.add(concealed.row);
  prefs.add(privacy);
  const excluded = group({title: 'Never Record Copies From', description: "Anything copied in these apps stays out of your history."});
  const excludedApps = () => clipboardSettings(model.configuration).excludedApps ?? [];
  const isExcluded = id => excludedApps().some(a => normalizeAppId(a) === normalizeAppId(id));
  const exclude = id => {
    const value = id.trim();
    if (!value || isExcluded(value)) return;
    setClipboard(c => {
      c.excludedApps = [...(c.excludedApps ?? []), value];
    });
  };
  const addExcluded = new Adw.EntryRow({use_markup: false, title: 'Add an app id', show_apply_button: true});
  addExcluded.connect('apply', () => {
    exclude(addExcluded.get_text());
    addExcluded.set_text('');
  });
  addExcluded.add_suffix(appPickerButton({
    tooltip: 'Choose an app', onPick: app => exclude(app.id), exclude: app => isExcluded(app.id),
    sections: () => [
      {title: 'Password Managers', apps: passwordManagerApps(installedApps())},
      {title: 'Used Lately', apps: model.status.recentApps ?? []},
      {title: 'Installed', apps: installedApps()},
    ],
  }));
  excluded.add(addExcluded);
  prefs.add(excluded);
  let excludedRows = [];

  // Using the switcher
  const using = group({title: 'Using the Switcher'});
  const keyRow = (title, keys) => {
    const row = new Adw.ActionRow({use_markup: false, title});
    row.add_suffix(label(keys, {classes: ['dim-label']}));
    using.add(row);
  };
  keyRow('Search', 'Type');
  keyRow('Paste the selected item', 'Return');
  keyRow('Paste item 1 to 9', 'Ctrl 1…9');
  keyRow('Copy without pasting', 'Ctrl C');
  keyRow('Pin or unpin', 'Ctrl P');
  keyRow('Delete', 'Ctrl Backspace');
  keyRow('Clear everything but pinned items', 'Ctrl Shift Backspace');
  keyRow('Close', 'Esc');
  const note = new Adw.ActionRow({use_markup: false, title: 'Text only',
    subtitle: "Slated keeps copied text. Images and files aren't recorded, and only copies made while Slated runs are."});
  using.add(note);
  prefs.add(using);

  function syncExcluded() {
    for (const row of excludedRows) excluded.remove(row);
    excludedRows = [];
    excluded.remove(addExcluded);
    const names = {installed: installedApps(), recent: model.status.recentApps ?? []};
    for (const id of excludedApps()) {
      const title = appDisplayName(id, names);
      const row = new Adw.ActionRow({use_markup: false, title, subtitle: title === id ? '' : id});
      row.add_css_class('slated-mono-subtitle');
      row.add_suffix(button('', () => setClipboard(c => {
        c.excludedApps = (c.excludedApps ?? []).filter(a => a !== id);
      }), {icon: 'list-remove-symbolic', classes: ['flat'], tooltip: 'Remove'}));
      excluded.add(row);
      excludedRows.push(row);
    }
    if (!excludedRows.length) {
      const row = new Adw.ActionRow({use_markup: false, title: "Every app's copies are recorded", subtitle: "Add the apps you'd rather keep out."});
      excluded.add(row);
      excludedRows.push(row);
    }
    // The "add" row stays last, below the apps already chosen.
    excluded.add(addExcluded);
  }

  function sync() {
    const settings = clipboardSettings(model.configuration);
    quiet = true;
    enabled.set_active(settings.enabled);
    quiet = false;
    let child = statusHolder.get_first_child();
    while (child) {
      const next = child.get_next_sibling();
      if (child !== enabled) statusHolder.remove(child);
      child = next;
    }
    statusHolder.prepend(pill(clipboardStatus(model)));
    let cap = pressKeys.get_first_child();
    while (cap) {
      const next = cap.get_next_sibling();
      pressKeys.remove(cap);
      cap = next;
    }
    if (settings.enabled && settings.shortcut) pressKeys.append(keycaps(settings.shortcut));
    pressRow.set_visible(settings.enabled && Boolean(settings.shortcut));
    pressRow.set_subtitle(settings.pasteAfterSelecting
      ? 'Type to search, then press Return to paste into the app you were in.'
      : 'Type to search, then press Return to copy it, ready to paste yourself.');
    const items = model.status.clipboard?.items ?? 0;
    statsRow.set_subtitle(!settings.enabled
      ? `Turn it on and Slated remembers the last ${settings.maxItems} things you copy, ready to search and paste again. Passwords are never recorded.`
      : !model.running
        ? "Slated isn't running, so nothing is being recorded right now."
        : items ? `${items} item${items === 1 ? '' : 's'}` : 'Nothing saved yet. Copy some text in any app.');
    for (const g of [shortcut, history, privacy, excluded]) g.set_sensitive(settings.enabled);

    recorder.set(settings.shortcut ?? '');
    restore.set_visible(keysString(settings.shortcut ?? '') !== keysString(defaultClipboardSettings().shortcut));
    const conflicts = model.otherUsesOfBuiltIn('clipboard');
    const state = model.builtInState('clipboard');
    if (!settings.shortcut) {
      recorder.row.set_subtitle('No shortcut: open it with a shortcut that runs Clipboard History.');
      recorder.row.remove_css_class('slated-warning-row');
    } else if (conflicts.length) {
      recorder.row.set_subtitle(`Also used by ${conflicts.join(', ')}, which wins over this shortcut.`);
      recorder.row.add_css_class('slated-warning-row');
    } else if (state?.state === 'failed') {
      recorder.row.set_subtitle(`GNOME didn't take it: ${state.reason}`);
      recorder.row.add_css_class('slated-warning-row');
    } else {
      recorder.row.set_subtitle('Works in any app. Super is the key Slated calls cmd. Backspace while recording clears it.');
      recorder.row.remove_css_class('slated-warning-row');
    }
    paste.set(settings.pasteAfterSelecting);
    maxItems.setItems(itemChoices(settings.maxItems), settings.maxItems);
    retention.setItems(dayChoices(settings.retentionDays), settings.retentionDays);
    persist.set(settings.persist);
    persist.row.set_subtitle(`Saved only on this computer, in ${tildify(ctx.paths.clipboardFile, ctx.paths.home)}, which only you can read. `
      + 'Off: history starts fresh each time Slated starts.');
    concealed.set(settings.ignoreConcealed);
    syncExcluded();
  }

  const page = new Adw.NavigationPage({title: 'Clipboard', tag: 'clipboard'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  page.connect('hidden', () => recorder.stop());
  model.on('config', sync);
  model.on('status', sync);
  sync();

  return {
    id: 'clipboard',
    title: 'Clipboard',
    iconName: 'edit-paste-symbolic',
    page,
    badge() {
      const settings = clipboardSettings(model.configuration);
      if (!settings.enabled) return {text: 'Off', warning: false};
      const items = model.running ? model.status.clipboard?.items ?? 0 : 0;
      return items ? {text: String(items), warning: false} : null;
    },
  };
}
