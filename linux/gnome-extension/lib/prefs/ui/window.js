// The Slated settings window, built inside the Adw.PreferencesWindow GNOME Shell hands to
// fillPreferencesWindow().
//
// Slated has the Mac's main-window pages in the Mac's order, more than a view switcher fits, so the
// window shows a sidebar like GNOME Settings: an Adw.NavigationSplitView that collapses to a single
// column on narrow widths. Each section has its own Adw.NavigationView so editors open as drill-down
// pages with a back button. Get Started (first-run setup) leads the sidebar until it's finished, and
// the window opens on it; afterwards it opens on Overview, never on the pane it was left on. The
// window keeps the model in sync with config.json, settings.json and status.json through file
// monitors, and asks GNOME Shell over D-Bus whether the extension is running.

import Adw from 'gi://Adw';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {PrefsModel} from '../model.js';
import {slatedPaths} from '../paths.js';
import {lastStart} from '../eventlog.js';
import {sessionId} from '../util.js';
import {readText, readTail, writeTextAtomic, writeTextIfMissing, readBuildInfo, watchFile, glibScheduler, EventLogWriter, fileExists} from '../io.js';
import {linkForFile, openFileLink} from '../filelinks.js';
import {getExtensionInfo, getUserExtensionsEnabled, setUserExtensionsEnabled, setExtensionEnabled, requestLogout, espansoRunning} from '../shell.js';
import {installStyles} from './style.js';
import {box, label, icon, button, badge as badgeLabel, emptyState, launchFile} from './widgets.js';
import {setConfigKeyContext, keysShown, refreshKeys} from './configkeys.js';
import {setFileLinkContext, setLinkedLabel} from './filelinks.js';
import {stopAllRecording} from './recorder.js';
import {saveStateText, updatedText} from './general.js';
import {createGetStartedPane} from './getstarted.js';
import {createOverviewPane} from './overview.js';
import {createWindowsPane} from './windows.js';
import {createHotstringsPane} from './hotstrings.js';
import {createClipboardPane} from './clipboard.js';
import {createAutomationPane} from './automation.js';
import {createKeyboardPane} from './keyboard.js';
import {createLayoutsPane} from './layouts.js';
import {createGeneralPane} from './general.js';
import {createAboutPane} from './about.js';

const PANES = [
  ['getStarted', 'Get Started', 'emoji-flags-symbolic', createGetStartedPane],
  ['overview', 'Overview', 'go-home-symbolic', createOverviewPane],
  ['windows', 'Windows', 'focus-windows-symbolic', createWindowsPane],
  ['hotstrings', 'Hotstrings', 'insert-text-symbolic', createHotstringsPane],
  ['clipboard', 'Clipboard', 'edit-paste-symbolic', createClipboardPane],
  ['automation', 'Automation', 'input-gaming-symbolic', createAutomationPane],
  ['keyboard', 'Keyboard', 'input-keyboard-symbolic', createKeyboardPane],
  ['layouts', 'Layouts', 'view-dual-symbolic', createLayoutsPane],
  ['general', 'General', 'preferences-system-symbolic', createGeneralPane],
  ['about', 'About', 'help-about-symbolic', createAboutPane],
];

const SAVE_ICONS = {success: 'object-select-symbolic', dim: 'content-loading-symbolic', warning: 'dialog-warning-symbolic', error: 'dialog-error-symbolic'};

export class SlatedSettings {
  /**
   * @param {Adw.PreferencesWindow} window the window from fillPreferencesWindow()
   * @param {{path: string, uuid: string, metadata: object}} ext the extension
   */
  constructor(window, ext) {
    this.window = window;
    this.ext = ext;
    this.closed = false;
    this.current = null;
    this.panes = new Map();
    installStyles();

    this.paths = slatedPaths(GLib.get_home_dir(), name => GLib.getenv(name));
    this.prefsSession = sessionId();
    this.logger = new EventLogWriter(this.paths.logFile, () => this.model?.status.session ?? this.prefsSession);
    this.model = new PrefsModel({
      io: {
        home: this.paths.home,
        readConfig: () => readText(this.paths.configFile),
        writeConfig: text => writeTextAtomic(this.paths.configFile, text),
        readSettings: () => readText(this.paths.settingsFile),
        writeSettings: text => writeTextAtomic(this.paths.settingsFile, text),
        backupConfig: text => writeTextIfMissing(this.paths.backupFile, text),
        readRecord: () => readText(this.paths.migrationFile),
        writeRecord: text => writeTextAtomic(this.paths.migrationFile, text),
        readFile: path => {
          try {
            return readText(path);
          } catch {
            return null;
          }
        },
        readWindowState: () => readText(this.paths.settingsWindowFile),
        writeWindowState: text => writeTextAtomic(this.paths.settingsWindowFile, text),
      },
      scheduler: glibScheduler,
      log: (event, data, level) => this.logger.record(event, data, level),
      // New ids come from the engine's randomUUID (the model's default), as config.json requires.
    });
    this.model.load();
    // The keys under every setting: their right-click menus copy through the model and open the files.
    setConfigKeyContext({
      model: this.model,
      toast: message => this.toast(message),
      open: file => this.openLink(linkForFile(file)),
    });
    // Every file name the window shows opens that file (filelinks.js).
    setFileLinkContext({open: link => this.openLink(link), slateFound: () => this.model.slateFiles.length > 0});
    this.model.setBuildInfo(readBuildInfo(ext.path));
    this._readStatus();
    this._refreshShell();

    this._build();

    this.watchers = [
      watchFile(this.paths.configFile, () => this.model.syncFromDisk(), 250),
      watchFile(this.paths.settingsFile, () => this.model.syncFromDisk(), 250),
      watchFile(this.paths.statusFile, () => this._readStatus(), 150),
    ];
    // GNOME Shell doesn't announce extension state changes to other processes; ask now and then.
    this.poll = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 4, () => {
      this._refreshShell();
      this._readStatus();
      return GLib.SOURCE_CONTINUE;
    });
    window.connect('close-request', () => {
      this._close();
      return false;
    });
    this.model.log('ui.settings_opened', {pane: this.current, source: 'prefs'});
  }

  // --- Live state ------------------------------------------------------------------------------------

  _readStatus() {
    if (this.closed) return;
    let text = null;
    try {
      text = readText(this.paths.statusFile);
    } catch {
      text = null;
    }
    this.model.setStatusText(text);
    try {
      const start = lastStart(readTail(this.paths.logFile) ?? '', this.model.status.session);
      this.model.setRunningCommit(start?.data?.commit ?? null);
    } catch {
      this.model.setRunningCommit(null);
    }
  }

  _refreshShell() {
    Promise.all([getExtensionInfo(this.ext.uuid), getUserExtensionsEnabled()]).then(([info, extensionsOn]) => {
      if (!this.closed) this.model.setShellInfo(info, extensionsOn);
    });
    // Only espanso says whether it runs; ask while Slated hands it hotstrings.
    if (this.model.status.hotstrings.engine === 'espanso') {
      espansoRunning(this.paths.home).then(running => {
        if (!this.closed) this.model.setEspansoRunning(running);
      });
    } else {
      this.model.setEspansoRunning(null);
    }
  }

  // --- Actions panes can ask for ---------------------------------------------------------------------

  toast(message) {
    this.toastOverlay?.add_toast(new Adw.Toast({title: GLib.markup_escape_text(message, -1), timeout: 3}));
  }

  setEnabled(on) {
    this.model.log('ui.extension_enabled', {enabled: on});
    setExtensionEnabled(this.ext.uuid, on).then(ok => {
      if (!ok) this.toast(on ? "GNOME Shell didn't turn Slated on. Log out and back in, then try again." : "GNOME Shell didn't turn Slated off.");
      this._refreshShell();
    }).catch(error => this.toast(`Couldn't reach GNOME Shell: ${error.message}`));
  }

  /** GNOME's Extensions switch, on: Slated starts, and so do the other extensions you had turned on. */
  enableUserExtensions() {
    this.model.log('ui.user_extensions_enabled');
    setUserExtensionsEnabled(true).then(() => {
      this.toast('GNOME extensions are on');
      this._refreshShell();
    }).catch(error => this.toast(`Couldn't turn on GNOME extensions: ${error.message}. Use the Extensions app's switch instead.`));
  }

  logout() {
    this.model.saveNow();
    this.model.log('ui.logout');
    requestLogout().catch(error => this.toast(`Couldn't open the log-out dialog: ${error.message}`));
  }

  /** Saves, re-reads everything, and nudges the extension to reload the configuration. */
  reload() {
    this.model.reload();
    if (!this.model.loadError && !this.model.firstRun) {
      try {
        // The extension watches both files; rewriting one as it is makes it read both.
        const text = readText(this.paths.configFile);
        if (text !== null) writeTextAtomic(this.paths.configFile, text);
      } catch (error) {
        this.toast(`Couldn't reload: ${error.message}`);
        return;
      }
    }
    this.model.setBuildInfo(readBuildInfo(this.ext.path));
    this._readStatus();
    this._refreshShell();
    this.model.log('ui.reload');
    this.toast(this.model.loadError ? `${this.model.loadErrorFile ?? 'config.json'} still can't be read. Overview shows what to fix.` : 'Configuration reloaded');
  }

  /** Opens Get Started on request (Overview's link). After setup it starts over from the welcome. */
  showGetStarted() {
    this.model.restartGetStarted();
    this.navigate('getStarted');
  }

  /** Get Started's last button: setup is done (kept in settings-window.json), on to Overview. */
  finishGetStarted() {
    const error = this.model.finishSetup();
    if (error) this.toast(`Couldn't remember that setup is done: ${error}`);
    this.navigate('overview');
  }

  // --- Building --------------------------------------------------------------------------------------

  _build() {
    const window = this.window;
    this.toastOverlay = new Adw.ToastOverlay();
    this.split = new Adw.NavigationSplitView({min_sidebar_width: 200, max_sidebar_width: 270, sidebar_width_fraction: 0.24});

    // Sidebar
    this.sidebarList = new Gtk.ListBox({css_classes: ['navigation-sidebar'], selection_mode: Gtk.SelectionMode.SINGLE});
    this.sidebarRows = new Map();
    for (const [id, title, iconName] of PANES) {
      const content = box('horizontal', 12);
      content.append(icon(iconName));
      const text = label(title, {ellipsize: true});
      text.set_hexpand(true);
      content.append(text);
      const holder = box('horizontal', 0);
      content.append(holder);
      const row = new Gtk.ListBoxRow({child: content});
      row._slatedId = id;
      this.sidebarList.append(row);
      this.sidebarRows.set(id, {row, holder});
    }
    // Sections as on the Mac: Get Started on its own while it's there, then the pages, then General and About.
    this.sidebarList.set_header_func((row, before) => {
      const starts = (row._slatedId === 'general' && before) || (row._slatedId === 'overview' && before?._slatedId === 'getStarted');
      row.set_header(starts ? new Gtk.Separator({margin_top: 6, margin_bottom: 6}) : null);
    });
    this.sidebarList.connect('row-selected', (_list, row) => {
      if (row && !this._selecting) this.showPane(row._slatedId);
    });
    this.sidebarList.connect('row-activated', (_list, row) => {
      this.showPane(row._slatedId);
      this.split.set_show_content(true);
    });
    this.windowTitle = new Adw.WindowTitle({title: 'Slated', subtitle: ''});
    const sidebarHeader = new Adw.HeaderBar({title_widget: this.windowTitle});
    // "All changes saved" (there's no Save button to look for), a moment's "Updated from config.json"
    // when a hand edit is picked up, and Reload.
    this.saveIcon = icon('object-select-symbolic');
    this.saveIcon.set_valign(Gtk.Align.START);
    this.saveLabel = label('', {classes: ['caption'], ellipsize: true});
    this.updatedLabel = label('', {classes: ['caption', 'accent'], ellipsize: true});
    this.updatedLabel.set_visible(false);
    const statusTexts = box('vertical', 2);
    statusTexts.set_hexpand(true);
    statusTexts.append(this.saveLabel);
    statusTexts.append(this.updatedLabel);
    const footer = box('horizontal', 6, ['slated-sidebar-status']);
    footer.append(this.saveIcon);
    footer.append(statusTexts);
    footer.append(button('', () => this.reload(), {icon: 'view-refresh-symbolic', classes: ['flat', 'circular'], tooltip: 'Reload config.json and settings.json'}));
    const sidebarView = new Adw.ToolbarView({
      content: new Gtk.ScrolledWindow({child: this.sidebarList, hscrollbar_policy: Gtk.PolicyType.NEVER, vexpand: true}),
    });
    sidebarView.add_top_bar(sidebarHeader);
    sidebarView.add_bottom_bar(footer);
    this.split.set_sidebar(new Adw.NavigationPage({title: 'Slated', tag: 'sidebar', child: sidebarView}));

    // Content: one navigation view per section, in a stack.
    this.contentStack = new Gtk.Stack({transition_type: Gtk.StackTransitionType.CROSSFADE, transition_duration: 120, vexpand: true});
    // Above every section: a file changed on disk while the window had unsaved edits in it. The user
    // picks the version, never Slated.
    this.conflictBanner = conflictBanner({
      reload: () => this.model.reloadConflictingFiles(),
      keep: () => this.model.keepMyChanges(),
    });
    const content = box('vertical', 0);
    content.append(this.conflictBanner.widget);
    content.append(this.contentStack);
    this.contentPage = new Adw.NavigationPage({title: 'Overview', tag: 'content', child: content});
    // Collapsed, the sidebar replaces the content: a recording there would swallow the keys that
    // move through the sidebar.
    this.contentPage.connect('hidden', () => stopAllRecording());
    this.split.set_content(this.contentPage);
    for (const [id, title, iconName, create] of PANES) this._createPane(id, title, iconName, create);

    this.toastOverlay.set_child(this.split);

    // Collapse to one column on narrow windows (libadwaita 1.4+). The breakpoint lives on Slated's
    // own BreakpointBin rather than the window: Adw.PreferencesWindow has breakpoints of its own, and
    // when several match only one applies.
    const bin = new Adw.BreakpointBin({child: this.toastOverlay, width_request: 360, height_request: 294});
    const breakpoint = new Adw.Breakpoint({condition: Adw.BreakpointCondition.parse('max-width: 620sp')});
    breakpoint.add_setter(this.split, 'collapsed', true);
    bin.add_breakpoint(breakpoint);
    window.set_default_size(1060, 760);
    // The window's own search would look through pages Slated doesn't show.
    window.set_search_enabled(false);
    window.set_content(bin);

    for (const signal of ['config', 'status', 'sources', 'save-state', 'setup']) this.model.on(signal, () => this._syncChrome());
    // "Show config keys" shows or hides the key under every setting at once.
    this._keysShown = keysShown();
    this.model.on('config', () => {
      if (keysShown() === this._keysShown) return;
      this._keysShown = keysShown();
      refreshKeys(bin);
    });
    this.showPane(this.model.startingPane());
    this._syncChrome();
  }

  /**
   * Opens the file a link or button names (config.json, settings.json, config.v1.json, the folder, a
   * Slate config): the pending edit saved first, then its default app, or a toast when it isn't there.
   */
  openLink(link) {
    return openFileLink(link, {
      paths: this.paths, exists: fileExists,
      launch: path => launchFile(path, this.window, {onError: e => this.toast(e.message)}),
      toast: message => this.toast(message),
      log: (event, data) => this.model.log(event, data),
      saveNow: () => this.model.saveNow(),
    });
  }

  _createPane(id, title, iconName, create) {
    const nav = new Adw.NavigationView();
    const ctx = {
      model: this.model, window: this.window, ext: this.ext, paths: this.paths, nav,
      toast: message => this.toast(message),
      navigate: (target, options) => this.navigate(target, options),
      isCurrent: () => this.current === id,
      setEnabled: on => this.setEnabled(on),
      enableUserExtensions: () => this.enableUserExtensions(),
      logout: () => this.logout(),
      reload: () => this.reload(),
      openLink: link => this.openLink(link),
      showGetStarted: () => this.showGetStarted(),
      finishGetStarted: () => this.finishGetStarted(),
    };
    let pane;
    try {
      pane = create(ctx);
    } catch (error) {
      // One broken section must not take the whole window down.
      logError(error, `Slated: couldn't build the ${title} page`);
      const page = new Adw.NavigationPage({title, tag: id});
      const toolbar = new Adw.ToolbarView({content: emptyState({
        iconName: 'dialog-error-symbolic', title: `The ${title} page couldn't be shown`,
        description: `${error.message}\nThis is a bug in Slated; the log has details (journalctl -f -o cat /usr/bin/gnome-shell).`,
      })});
      toolbar.add_top_bar(new Adw.HeaderBar());
      page.set_child(toolbar);
      pane = {id, title, iconName, page, badge: () => ({text: '!', warning: true})};
    }
    nav.replace([pane.page]);
    this.contentStack.add_named(nav, id);
    this.panes.set(id, {...pane, nav});
  }

  showPane(id) {
    const pane = this.panes.get(id);
    if (!pane) return;
    // A recorder in the section being left would keep taking every key typed in this one.
    stopAllRecording();
    const changed = this.current !== id;
    this.current = id;
    this.contentStack.set_visible_child_name(id);
    this.contentPage.set_title(pane.title);
    this._selecting = true;
    this.sidebarList.select_row(this.sidebarRows.get(id).row);
    this._selecting = false;
    pane.activate?.();
    this._syncGetStartedRow();
    if (changed) this.model.log('ui.pane', {pane: id});
  }

  /** Get Started is in the sidebar while setup isn't finished, and while it's open. */
  _syncGetStartedRow() {
    const row = this.sidebarRows.get('getStarted')?.row;
    const shown = this.model.needsSetup || this.current === 'getStarted';
    if (!row || this._getStartedShown === shown) return;
    this._getStartedShown = shown;
    row.set_visible(shown);
    this.sidebarList.invalidate_headers();
  }

  /** Shows a section, optionally with something in it ({binding: id}, {newBinding, action}, {newHotstring}, {recipe: id}). */
  navigate(id, options = null) {
    const pane = this.panes.get(id);
    if (!pane) return;
    pane.nav.pop_to_page(pane.page);
    this.showPane(id);
    this.split.set_show_content(true);
    if (options) pane.show?.(options);
  }

  _syncChrome() {
    if (this.closed) return;
    const summary = this.model.summary();
    this.windowTitle.set_subtitle(this.model.loadError ? 'config.json needs a fix' : summary.running ? 'Running' : summary.title);
    const save = saveStateText({...this.model.saveState, file: this.model.loadErrorFile});
    setLinkedLabel(this.saveLabel, save.text);
    this.saveLabel.set_tooltip_text(save.text);
    const updated = updatedText(this.model.updatedFromDisk);
    setLinkedLabel(this.updatedLabel, updated);
    this.updatedLabel.set_visible(Boolean(updated));
    this.conflictBanner.update(this.model.conflict);
    this.saveIcon.set_from_icon_name(SAVE_ICONS[save.style] ?? SAVE_ICONS.dim);
    this.saveIcon.set_css_classes(save.style === 'success' ? ['success'] : save.style === 'warning' ? ['warning'] : save.style === 'error' ? ['error'] : ['dim-label']);
    this._syncGetStartedRow();
    for (const [id, pane] of this.panes) {
      const holder = this.sidebarRows.get(id)?.holder;
      if (!holder) continue;
      holder.get_first_child() && holder.remove(holder.get_first_child());
      let b = null;
      try {
        b = pane.badge?.();
      } catch (error) {
        logError(error, `Slated: badge for ${id}`);
      }
      if (b) holder.append(badgeLabel(b.text, {warning: b.warning}));
    }
  }

  _close() {
    if (this.closed) return;
    this.model.saveNow();
    this.model.log('ui.settings_closed');
    this.closed = true;
    for (const watcher of this.watchers ?? []) watcher.cancel();
    if (this.poll) GLib.source_remove(this.poll);
    this.poll = 0;
  }
}

/**
 * "config.json changed on disk", with Reload from File and Keep My Changes (the Mac's ConflictBanner).
 * Adw.Banner has room for one button, so it's a card. Returns {widget, update(files)}.
 */
function conflictBanner({reload, keep}) {
  const card = box('vertical', 6, ['card', 'slated-notice', 'warning', 'slated-conflict']);
  const title = label('', {classes: ['heading'], wrap: true});
  const detail = label("You have changes here that aren't saved yet. Reload from File shows the file and drops your changes to it; Keep My Changes saves your version over the file's.", {wrap: true});
  const buttons = box('horizontal', 6);
  buttons.append(button('Reload from File', reload, {classes: ['pill']}));
  buttons.append(button('Keep My Changes', keep, {classes: ['pill']}));
  card.append(title);
  card.append(detail);
  card.append(buttons);
  card.set_visible(false);
  return {
    widget: card,
    update(files) {
      card.set_visible(files.length > 0);
      if (files.length) setLinkedLabel(title, `${files.join(' and ')} changed on disk`);
    },
  };
}
