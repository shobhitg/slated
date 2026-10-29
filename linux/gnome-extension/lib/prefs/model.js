// The preferences' single source of truth: a draft of the configuration plus what the running
// extension reports (port of Sources/SlatedUI/Model/AppModel.swift).
//
// The configuration is one value here; on disk it's config.json (what your keys do) and
// settings.json (how Slated behaves), read, created and migrated by migration.js. Views edit the
// draft through `update()`. Every change is validated and saved after a short pause, so there's no
// Save button, and a save writes only the file whose content changed. Items with errors are held
// back (their last saved version stays on disk) and flagged in the UI. Hand edits to either file are
// picked up when there are no unsaved edits; if one can't be read, saving pauses rather than
// overwrite anything.
//
// Pure ES module: file access, timers and logging are injected, so tests drive it with fakes.

import {Emitter, clone, deepEqual} from './util.js';
import {newId} from './ids.js';
import {decodeConfiguration, describeError} from './engine.js';
import {decodeConfigurationFiles} from '../core/index.js';
import {keysString, statusKey} from './keys.js';
import {validate, savable, configChanges, target, LAYOUT_NAME_MISSING, LAYOUT_NAME_TAKEN} from './validator.js';
import {parseStatus, emptyStatus, extensionState, bindingState, runningSummary} from './status.js';
import {presetById, starterBindings} from './presets.js';
import {bindingTitle, layoutNames, renameLayout} from './actions.js';
import {builtInShortcut, recipeBindingName, sharesApps} from './automation.js';
import {
  loadConfigFiles, writeConfigFiles, changedFiles, findSlateFiles, importSlateFiles, importSummary, parseRecord,
  recordText, migrationNotice,
} from './migration.js';
import {newBinding, newHotstring} from './config.js';
import {STEPS, parseWindowState, windowStateText, startingPane} from './getstarted.js';

/**
 * @typedef {object} ModelIO The files (migration.ConfigFilesIO, plus the window's own state).
 * @property {() => string|null} readConfig config.json text, or null when it doesn't exist
 * @property {(text: string) => void} writeConfig writes config.json (atomically), creating folders
 * @property {() => string|null} readSettings settings.json text, or null when it doesn't exist
 * @property {(text: string) => void} writeSettings writes settings.json (atomically)
 * @property {(text: string) => boolean} backupConfig writes config.v1.json unless it exists
 * @property {(path: string) => string|null} readFile any file (Slate configs), null if missing
 * @property {string} home the home folder
 * @property {() => string|null} [readRecord] config-migration.json (what a migration imported)
 * @property {(text: string) => void} [writeRecord] writes it
 * @property {() => string|null} [readWindowState] the settings window's own state (settings-window.json)
 * @property {(text: string) => void} [writeWindowState] writes it
 */

/** @typedef {{setTimeout: (fn: () => void, ms: number) => any, clearTimeout: (handle: any) => void}} Scheduler */

export class PrefsModel extends Emitter {
  /**
   * @param {object} options
   * @param {ModelIO} options.io
   * @param {Scheduler} [options.scheduler]
   * @param {(event: string, data?: object, level?: string) => void} [options.log] event log writer
   * @param {() => string} [options.makeId] new binding/hotstring ids
   * @param {number} [options.saveDelay] milliseconds to wait after the last edit before saving
   */
  constructor({io, scheduler = {setTimeout, clearTimeout}, log = () => {}, makeId = newId, saveDelay = 450}) {
    super();
    this.io = io;
    this.scheduler = scheduler;
    this.log = log;
    this.makeId = makeId;
    this.saveDelay = saveDelay;
    this._saveTimer = null;

    this.draft = decodeConfiguration('{}');
    this.saved = clone(this.draft);
    /** settings.json's keys Slated doesn't know, written back as they were. */
    this.settingsExtras = {};
    this.issues = [];
    this.saveState = {kind: 'saved'};
    this.loadError = null;
    /** The file `loadError` is about: "config.json" or "settings.json". */
    this.loadErrorFile = null;
    /** True while the files don't exist (deleted, or creating them failed): the next save writes both. */
    this.firstRun = false;
    /** The files' texts as last read or written (null: none yet), and texts that failed to decode. */
    this._diskTexts = {config: null, settings: null};
    this._badTexts = null;
    /** What the last migration or first run imported (config-migration.json), or null. */
    this.record = null;
    /** The Slate configs there are to import (migration.findSlateFiles), without their text. */
    this.slateFiles = [];

    this.status = emptyStatus();
    this.shell = extensionState(null);
    this.build = null;
    this.runningCommit = null;
    /** The settings window's own state (settings-window.json): {setupFinished, …}. */
    this.windowState = parseWindowState(null);
    /** Get Started's step (getstarted.STEPS): in memory, like the Mac's; a new window starts over. */
    this.getStartedStep = 'welcome';
  }

  // --- Loading --------------------------------------------------------------------------------------

  /**
   * Reads config.json and settings.json, creating them on a first run and migrating version 1, and
   * the window's own state. Call once after construction.
   */
  load() {
    this._loadWindowState();
    this._adopt(loadConfigFiles(this.io, {by: 'settings', makeId: this.makeId, log: this.log}));
    this.refreshSlateFiles();
  }

  /** Takes what migration.loadConfigFiles read (or made). */
  _adopt(result) {
    this._readRecord(result.record);
    if (result.error) {
      this._badTexts = {config: result.configText ?? null, settings: result.settingsText ?? null};
      this._blocked(describeError(result.error), result.error.file ?? 'config.json');
      return;
    }
    this.draft = separateDuplicateIds(result.configuration, this.makeId);
    this.saved = clone(this.draft);
    this.settingsExtras = result.settingsExtras ?? {};
    this._diskTexts = {config: result.configText ?? null, settings: result.settingsText ?? null};
    this._badTexts = null;
    this.loadError = null;
    this.loadErrorFile = null;
    this.firstRun = false;
    this.saveState = {kind: 'saved'};
    if (result.writeError && result.created) {
      // Nothing on disk yet: the next save tries again with both files.
      this.firstRun = true;
      this.saveState = {kind: 'failed', message: describeError(result.writeError)};
    } else if (result.writeError) {
      // A version 1 file that couldn't be migrated: saving now would split it without its copy.
      this._blocked(`Couldn't update config.json to the new format: ${describeError(result.writeError)}`, 'config.json');
      return;
    }
    this._revalidate();
    this.emit('config');
    this.emit('save-state');
  }

  _readRecord(fresh = null) {
    if (fresh) {
      this.record = fresh;
      return;
    }
    try {
      this.record = parseRecord(this.io.readRecord?.() ?? null);
    } catch {
      this.record = null;
    }
  }

  _blocked(message, file = 'config.json') {
    this.loadError = message;
    this.loadErrorFile = file;
    this.saveState = {kind: 'blocked'};
    this.emit('config');
    this.emit('save-state');
  }

  /** The configuration being edited. Treat it as read-only; change it with update(). */
  get configuration() {
    return this.draft;
  }

  // --- Editing and saving ---------------------------------------------------------------------------

  /** Changes the draft: `mutate` receives a copy to modify in place (or returns a replacement). */
  update(mutate) {
    const next = clone(this.draft);
    const replaced = mutate(next);
    const result = replaced === undefined ? next : replaced;
    if (deepEqual(result, this.draft)) return;
    this.draft = result;
    this._draftChanged();
  }

  _revalidate() {
    this.issues = validate(this.draft, {knownLayouts: this.knownLayoutNames()});
  }

  _draftChanged() {
    this._revalidate();
    this._cancelTimer();
    if (this.loadError) {
      this.saveState = {kind: 'blocked'};
    } else {
      this.saveState = {kind: 'pending'};
      this._saveTimer = this.scheduler.setTimeout(() => {
        this._saveTimer = null;
        this.saveNow();
      }, this.saveDelay);
    }
    this.emit('config');
    this.emit('save-state');
  }

  _cancelTimer() {
    if (this._saveTimer !== null) {
      this.scheduler.clearTimeout(this._saveTimer);
      this._saveTimer = null;
    }
  }

  get hasUnsavedChanges() {
    return this._saveTimer !== null;
  }

  /** Writes pending edits now, to the file(s) whose content changed. Call before the window closes. */
  saveNow() {
    this._cancelTimer();
    if (this.loadError) {
      this.saveState = {kind: 'blocked'};
      this.emit('save-state');
      return;
    }
    const output = savable(this.draft, this.saved, this.issues);
    let changed;
    try {
      changed = changedFiles(this.saved, output, this.settingsExtras);
    } catch (error) {
      this._saveFailed(error);
      return;
    }
    const which = {config: changed.config || this.firstRun, settings: changed.settings || this.firstRun};
    if (which.config || which.settings) {
      try {
        writeConfigFiles(this.io, output, this.settingsExtras, which);
      } catch (error) {
        this._saveFailed(error);
        return;
      }
      const changes = configChanges(this.saved, output);
      const files = [which.config && 'config.json', which.settings && 'settings.json'].filter(Boolean);
      if (changes.length) this.log('config.saved', {changes, files, source: 'prefs'});
      // Re-read so `saved` matches what the files decode to (normalized values).
      let reread = output;
      try {
        const texts = {config: this.io.readConfig() ?? null, settings: this.io.readSettings() ?? null};
        if (texts.config !== null) {
          reread = decodeConfigurationFiles(texts.config, texts.settings).configuration;
          this._diskTexts = texts;
        }
      } catch {
        reread = output;
      }
      this.saved = reread;
      this.firstRun = false;
    }
    // A brand-new shortcut still waiting for its keys isn't an error worth counting.
    const waiting = new Set(this.draft.bindings
      .filter(b => !keysString(b.keys) && !this.saved.bindings.some(s => s.id === b.id))
      .map(b => target.binding(b.id)));
    const held = new Set(this.issues.filter(i => i.severity === 'error' && !waiting.has(i.target)).map(i => i.target)).size;
    this.saveState = held ? {kind: 'partial', count: held} : {kind: 'saved'};
    this.emit('save-state');
    this.emit('config');
  }

  _saveFailed(error) {
    const message = describeError(error);
    this.saveState = {kind: 'failed', message};
    this.log('config.save_failed', {message}, 'error');
    this.emit('save-state');
  }

  /**
   * Adopts config.json and settings.json when they changed on disk (hand edits, the extension), unless
   * there are unsaved edits. A version 1 config.json that appears is migrated.
   */
  syncFromDisk() {
    if (this.hasUnsavedChanges) return;
    const texts = {config: null, settings: null};
    try {
      texts.config = this.io.readConfig() ?? null;
    } catch (error) {
      this._blocked(`Couldn't read config.json: ${describeError(error)}`, 'config.json');
      return;
    }
    try {
      texts.settings = this.io.readSettings() ?? null;
    } catch (error) {
      this._blocked(`Couldn't read settings.json: ${describeError(error)}`, 'settings.json');
      return;
    }
    if (texts.config === null) {
      // Deleted: keep what's shown; the next save recreates both files. When saving waited for the
      // broken file that was there, it's gone, so saving resumes as on a first run (with edits made
      // meanwhile).
      if (!this.loadError) {
        this.firstRun = true;
      } else if (this.loadErrorFile === 'config.json') {
        this.loadError = null;
        this.loadErrorFile = null;
        this._badTexts = null;
        this._diskTexts = texts;
        this.firstRun = true;
        this.saveState = {kind: 'saved'};
        if (!deepEqual(this.draft, this.saved)) {
          this._draftChanged();
        } else {
          this._revalidate();
          this.emit('config');
          this.emit('save-state');
        }
      }
      return;
    }
    // The same texts again (a file monitor event, the reload nudge): nothing to adopt.
    const same = other => Boolean(other) && other.config === texts.config && other.settings === texts.settings;
    if (this.loadError ? same(this._badTexts) : same(this._diskTexts)) return;
    let decoded;
    try {
      decoded = decodeConfigurationFiles(texts.config, texts.settings);
    } catch (error) {
      this._badTexts = texts;
      this._blocked(describeError(error), error.file ?? 'config.json');
      return;
    }
    if (decoded.legacy) {
      // A version 1 config.json (an older Slated wrote it, or it was pasted in): migrate it now.
      this._adopt(loadConfigFiles(this.io, {by: 'settings', makeId: this.makeId, log: this.log}));
      return;
    }
    const disk = decoded.configuration;
    this._diskTexts = texts;
    this._badTexts = null;
    this.settingsExtras = decoded.settingsExtras;
    keepGeneratedIds(separateDuplicateIds(disk, this.makeId), this.saved, texts.config);
    const wasBlocked = this.loadError !== null;
    this.loadError = null;
    this.loadErrorFile = null;
    this.firstRun = false;
    if (wasBlocked || !deepEqual(disk, this.saved)) {
      this.saved = disk;
      this.draft = clone(disk);
      this._revalidate();
      this.saveState = {kind: 'saved'};
      this.emit('config');
      this.emit('save-state');
    }
  }

  /** Saves pending edits, then re-reads both files and what there is to import. */
  reload() {
    if (this.hasUnsavedChanges) this.saveNow();
    this.syncFromDisk();
    this._readRecord();
    this.refreshSlateFiles();
    this._revalidate();
    this.emit('config');
  }

  // --- Get Started -----------------------------------------------------------------------------------

  _loadWindowState() {
    let text = null;
    try {
      text = this.io.readWindowState?.() ?? null;
    } catch {
      text = null;
    }
    this.windowState = parseWindowState(text);
  }

  /** Whether Get Started was finished (kept in settings-window.json, not config.json). */
  get setupFinished() {
    return this.windowState.setupFinished;
  }

  /**
   * Setup isn't finished: Get Started is in the sidebar and the window opens on it. (The Mac also
   * counts missing Accessibility access; GNOME needs no permission.)
   */
  get needsSetup() {
    return !this.setupFinished;
  }

  /** The pane a newly opened window shows: Get Started during setup, else Overview. */
  startingPane() {
    return startingPane(this.setupFinished);
  }

  setGetStartedStep(step) {
    if (!STEPS.includes(step) || step === this.getStartedStep) return;
    this.getStartedStep = step;
    this.emit('setup');
  }

  /** Get Started on request (Overview's link): after setup it starts over from the welcome. */
  restartGetStarted() {
    if (!this.needsSetup) this.setGetStartedStep('welcome');
  }

  /**
   * Get Started's last button: setup is done, remembered in settings-window.json. Returns an error
   * message when that file couldn't be written (setup still counts as done for this window).
   */
  finishSetup() {
    let error = null;
    this.windowState = {...this.windowState, setupFinished: true};
    try {
      this.io.writeWindowState?.(windowStateText(this.windowState));
    } catch (e) {
      error = describeError(e);
      this.log('ui.state_failed', {error}, 'error');
    }
    this.log('ui.get_started_finished', {running: this.running, hyper: this.status.hyper.mode, hotstrings: this.status.hotstrings.engine});
    this.emit('setup');
    return error;
  }

  // --- Live state ------------------------------------------------------------------------------------

  /** New status.json text (or null when it's missing). */
  setStatusText(text) {
    const status = parseStatus(text);
    if (deepEqual(status, this.status)) return;
    this.status = status;
    this.emit('status');
  }

  /** GetExtensionInfo's result (a plain object, {} when unknown, null when the shell can't be reached). */
  setShellInfo(info) {
    const shell = extensionState(info);
    if (deepEqual(shell, this.shell)) return;
    this.shell = shell;
    this.emit('status');
  }

  setBuildInfo(build) {
    this.build = build;
    this.emit('status');
  }

  setRunningCommit(commit) {
    if (commit === this.runningCommit) return;
    this.runningCommit = commit;
    this.emit('status');
  }

  /** The Overview headline: see status.runningSummary. */
  summary() {
    return runningSummary({status: this.status, shell: this.shell, build: this.build, runningCommit: this.runningCommit});
  }

  get running() {
    return this.summary().running;
  }

  // --- Slate configs: imported, never loaded ------------------------------------------------------------

  /** Looks for a Slate config to import (~/.slate.js, else ~/.slate). */
  refreshSlateFiles() {
    this.slateFiles = findSlateFiles(this.io).map(({text, ...file}) => file);
    this.emit('sources');
  }

  /** Layout names in the configuration. */
  knownLayoutNames() {
    return [...new Set((this.draft.layouts ?? []).map(l => l.name))];
  }

  /**
   * Whether to suggest importing a Slate config: there's one, and no migration, first run or import
   * in this window brought it in.
   */
  get slateImportSuggested() {
    return this.slateFiles.length > 0 && !this.record?.slate && this.windowState.slateImported !== true;
  }

  /** The Overview's one-time notice after a migration imported Slate files, or null. */
  migrationNotice(configPath) {
    return migrationNotice(this.record, {configPath});
  }

  /** Hides the notice for good (config-migration.json keeps that it was dismissed). */
  dismissMigrationNotice() {
    if (!this.record) return;
    this.record = {...this.record, noticeDismissed: true};
    try {
      this.io.writeRecord?.(recordText(this.record));
    } catch (error) {
      this.log('ui.state_failed', {error: describeError(error)}, 'error');
    }
    this.log('ui.migration_notice_dismissed');
    this.emit('config');
  }

  // --- Bindings ---------------------------------------------------------------------------------------

  binding(id) {
    return this.draft.bindings.find(b => b.id === id) ?? null;
  }

  issuesFor(targetKey) {
    return this.issues.filter(i => i.target === targetKey);
  }

  /** The state of one of Slated's own bindings. */
  bindingState(binding) {
    return bindingState({
      binding, key: statusKey(binding.keys, binding.modal), saved: this.saved.bindings.find(b => b.id === binding.id),
      issues: this.issuesFor(target.binding(binding.id)), status: this.status, running: this.running,
    });
  }

  /** Adds a binding (Left Half until changed) waiting for its keys, and returns its id. */
  addBinding(action = presetById('left-half').action, fields = {}) {
    const binding = newBinding({action: clone(action), ...fields}, this.makeId);
    this.update(config => {
      config.bindings.push(binding);
    });
    return binding.id;
  }

  duplicateBinding(id) {
    const index = this.draft.bindings.findIndex(b => b.id === id);
    if (index < 0) return null;
    const copy = {...clone(this.draft.bindings[index]), id: this.makeId(), keys: ''};
    if (copy.name) copy.name = `${copy.name} Copy`;
    this.update(config => {
      config.bindings.splice(index + 1, 0, copy);
    });
    return copy.id;
  }

  /** Deletes a binding; returns its title (for the "Deleted …" toast) or null. */
  deleteBinding(id) {
    const binding = this.binding(id);
    if (!binding) return null;
    const title = bindingTitle(binding);
    this.update(config => {
      config.bindings = config.bindings.filter(b => b.id !== id);
    });
    return title;
  }

  setBinding(id, mutate) {
    this.update(config => {
      const binding = config.bindings.find(b => b.id === id);
      if (binding) mutate(binding);
    });
  }

  moveBinding(id, offset) {
    this.update(config => {
      const index = config.bindings.findIndex(b => b.id === id);
      const to = index + offset;
      if (index < 0 || to < 0 || to >= config.bindings.length) return;
      const [item] = config.bindings.splice(index, 1);
      config.bindings.splice(to, 0, item);
    });
  }

  /** Adds the starter Hyper shortcuts whose keys aren't used yet; returns how many were added. */
  addStarterBindings() {
    const existing = new Set(this.draft.bindings.map(b => statusKey(b.keys, b.modal)));
    const fresh = starterBindings(this.makeId).filter(b => !existing.has(statusKey(b.keys, null)));
    if (fresh.length) {
      this.update(config => {
        config.bindings.push(...fresh);
      });
    }
    return fresh.length;
  }

  /**
   * Other bindings using the same keys, for duplicate hints. Bindings limited to other apps than this
   * one's never run at the same time, so they don't count.
   */
  otherUses(keys, modal, excludingId) {
    if (!keysString(keys)) return [];
    const key = statusKey(keys, modal);
    const me = this.binding(excludingId) ?? {};
    const uses = this.draft.bindings
      .filter(b => b.id !== excludingId && b.enabled !== false && statusKey(b.keys, b.modal) === key && sharesApps(b, me))
      .map(b => `“${bindingTitle(b)}”`);
    return uses;
  }

  // --- Automation and the built-in shortcuts ------------------------------------------------------------

  /**
   * Adds a binding that runs an automation recipe (`action`: the recipe's, possibly adjusted), named
   * after it and limited to `apps` when given. Returns its id; without keys it waits to be recorded.
   */
  addRecipe(recipe, {keys = '', action = recipe.action, apps = []} = {}) {
    const fields = {name: recipeBindingName(recipe, action), keys: keysString(keys)};
    if (apps.length) fields.onlyInApps = [...apps];
    const id = this.addBinding(action, fields);
    this.log('ui.recipe_added', {recipe: recipe.id, keys: Boolean(fields.keys), apps: apps.length});
    return id;
  }

  /** What takes a built-in shortcut's keys away from it: Slated's bindings, which win. */
  otherUsesOfBuiltIn(id) {
    const builtIn = builtInShortcut(id);
    const keys = builtIn?.keys(this.draft);
    if (!keys) return [];
    const uses = this.draft.bindings
      .filter(b => b.enabled !== false && !b.modal && keysString(b.keys) === keys && b.action?.op !== builtIn.action.op)
      .map(b => `“${bindingTitle(b)}”`);
    return uses;
  }

  /** A built-in shortcut's state as the running extension reports it: {state, reason} or null. */
  builtInState(id) {
    const keys = builtInShortcut(id)?.keys(this.draft);
    if (!keys || !this.running) return null;
    return this.status.hotkeys?.[keys] ?? null;
  }

  // --- Hotstrings -------------------------------------------------------------------------------------

  hotstring(id) {
    return this.draft.hotstrings.find(h => h.id === id) ?? null;
  }

  addHotstring(fields = {}) {
    const hotstring = newHotstring(fields, this.makeId);
    this.update(config => {
      config.hotstrings.push(hotstring);
    });
    return hotstring.id;
  }

  setHotstring(id, mutate) {
    this.update(config => {
      const h = config.hotstrings.find(x => x.id === id);
      if (h) mutate(h);
    });
  }

  deleteHotstring(id) {
    const h = this.hotstring(id);
    if (!h) return null;
    this.update(config => {
      config.hotstrings = config.hotstrings.filter(x => x.id !== id);
    });
    return h.trigger;
  }

  duplicateHotstring(id) {
    const index = this.draft.hotstrings.findIndex(h => h.id === id);
    if (index < 0) return null;
    const copy = {...clone(this.draft.hotstrings[index]), id: this.makeId()};
    copy.trigger += '2';
    this.update(config => {
      config.hotstrings.splice(index + 1, 0, copy);
    });
    return copy.id;
  }

  // --- Layouts ----------------------------------------------------------------------------------------

  addLayout() {
    let name = 'New Layout';
    for (let n = 2; this.knownLayoutNames().includes(name); n++) name = `New Layout ${n}`;
    this.update(config => {
      config.layouts.push({name, apps: [], before: [], after: []});
    });
    return name;
  }

  /**
   * Where Slated's layout called `name` is in config.layouts: at `index` when the layout there has
   * that name (a layout copied in config.json shares its name with the original), else the first
   * with it; -1 when there's none.
   */
  layoutIndex(name, index = null) {
    return layoutIndex(this.draft.layouts, name, index);
  }

  /** Deletes the layout called `name` (the one at `index`, see layoutIndex). */
  deleteLayout(name, index = null) {
    this.update(config => {
      const at = layoutIndex(config.layouts, name, index);
      if (at >= 0) config.layouts.splice(at, 1);
    });
  }

  /**
   * Why the layout called `name` (at `index`) can't be renamed to `newName`, or null. Shortcuts apply
   * a layout by its name, so a rename that clashes would move them to the other layout.
   */
  layoutNameProblem(name, newName, index = null) {
    if (!String(newName ?? '').trim()) return LAYOUT_NAME_MISSING;
    if (newName === name) return null;
    const own = layoutIndex(this.draft.layouts, name, index);
    const taken = this.draft.layouts.some((l, i) => i !== own && l.name === newName);
    return taken ? LAYOUT_NAME_TAKEN : null;
  }

  /** What applies the layout called `name`: "binding:<id>", "hotstring:<id>" and "default:<index>" keys. */
  layoutReferences(name) {
    const refs = new Set();
    for (const b of this.draft.bindings) if (layoutNames(b.action).includes(name)) refs.add(target.binding(b.id));
    for (const h of this.draft.hotstrings) if (layoutNames(h.action).includes(name)) refs.add(target.hotstring(h.id));
    (this.draft.defaults ?? []).forEach((d, i) => d.target === name && refs.add(`default:${i}`));
    return refs;
  }

  /**
   * Changes the layout called `name` (the one at `index`, see layoutIndex); a rename also re-points
   * what applies it: bindings and hotstrings, in any step, and display defaults. Returns the
   * layout's new name. A rename to an empty name or another layout's isn't applied (see
   * layoutNameProblem): the shortcuts would follow it to the other layout, and finding this one by
   * name would find that. What's in `keep` (layoutReferences keys) isn't re-pointed: as a name is
   * typed, the layout editor keeps there what named a name before the layout took it.
   */
  setLayout(name, mutate, {index = null, keep = new Set()} = {}) {
    let newName = name;
    this.update(config => {
      const at = layoutIndex(config.layouts, name, index);
      const layout = config.layouts[at];
      if (!layout) return;
      mutate(layout);
      if (layout.name !== name && this.layoutNameProblem(name, layout.name, at)) layout.name = name;
      newName = layout.name;
      // A copy still has the old name: what applies that name stays with it.
      if (newName === name || config.layouts.some(l => l.name === name)) return;
      for (const b of config.bindings) {
        if (!keep.has(target.binding(b.id))) b.action = renameLayout(b.action, name, newName);
      }
      for (const h of config.hotstrings) {
        if (h.action !== undefined && !keep.has(target.hotstring(h.id))) h.action = renameLayout(h.action, name, newName);
      }
      (config.defaults ?? []).forEach((d, i) => {
        if (d.target === name && !keep.has(`default:${i}`)) d.target = newName;
      });
    });
    return newName;
  }

  /** Bindings that apply the named layout. */
  triggersForLayout(name) {
    return this.draft.bindings.filter(b => b.action?.op === 'layout' && b.action.name === name)
      .map(b => ({keys: b.keys, modal: b.modal ?? null}));
  }

  // --- Importing --------------------------------------------------------------------------------------

  /**
   * What importing the Slate config would do (migration.importSlateFiles: a binding whose trigger
   * Slated already has is skipped). Doesn't change anything.
   */
  planSlateImport() {
    const files = findSlateFiles(this.io);
    return importSlateFiles(this.draft, files, {home: this.io.home, readFile: p => this.io.readFile(p), makeId: this.makeId});
  }

  /** Applies a plan from planSlateImport(), remembers it was done, and logs the counts. */
  applySlateImport(plan) {
    this.update(() => clone(plan.config));
    const summary = importSummary(plan);
    this.windowState = {...this.windowState, slateImported: true};
    try {
      this.io.writeWindowState?.(windowStateText(this.windowState));
    } catch (error) {
      this.log('ui.state_failed', {error: describeError(error)}, 'error');
    }
    this.log('slate.imported', {files: summary.files.length, imported: summary.imported, skipped: summary.skipped,
      unconvertible: summary.unconvertible.length, source: 'prefs'});
    this.emit('sources');
  }
}

/** See PrefsModel.layoutIndex. */
function layoutIndex(layouts, name, index) {
  if (index !== null && index !== undefined && layouts[index]?.name === name) return index;
  return layouts.findIndex(l => l.name === name);
}

/**
 * A binding or hotstring copied in config.json together with its "id" shares it with the original,
 * and the window finds items by id: editing the copy would change the original, and deleting either
 * would delete both. Later ones get a new id, as if written without one (keepGeneratedIds then keeps
 * it across re-reads), and the next save writes it.
 */
export function separateDuplicateIds(config, makeId) {
  for (const key of ['bindings', 'hotstrings']) {
    const seen = new Set();
    for (const item of config[key] ?? []) {
      if (seen.has(item.id)) item.id = makeId();
      seen.add(item.id);
    }
  }
  return config;
}

/**
 * Entries written without an "id" get a new random one each time config.json is decoded (as in
 * Swift). Gives unchanged ones the ids the window already uses, so re-reading a hand-written file
 * doesn't count as an edit or close the editor that's open.
 */
export function keepGeneratedIds(disk, previous, text) {
  const written = String(text).toUpperCase();
  for (const key of ['bindings', 'hotstrings']) {
    const before = previous?.[key] ?? [];
    const list = disk[key] ?? [];
    const used = new Set(list.filter(item => written.includes(item.id)).map(item => item.id));
    list.forEach((item, index) => {
      if (written.includes(item.id)) return;
      const same = other => other && !used.has(other.id) && !written.includes(other.id)
        && deepEqual({...other, id: ''}, {...item, id: ''});
      const match = same(before[index]) ? before[index] : before.find(same);
      if (!match) return;
      item.id = match.id;
      used.add(match.id);
    });
  }
  return disk;
}
