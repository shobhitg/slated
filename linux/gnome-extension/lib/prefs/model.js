// The preferences' single source of truth: a draft of config.json plus what the running extension
// reports (port of Sources/SlatedUI/Model/AppModel.swift).
//
// Views edit the draft through `update()`. Every change is validated and saved after a short pause,
// so there's no Save button. Items with errors are held back (their last saved version stays on
// disk) and flagged in the UI. Hand edits to config.json are picked up when there are no unsaved
// edits; if the file can't be read, saving pauses rather than overwrite it.
//
// Pure ES module: file access, timers and logging are injected, so tests drive it with fakes.

import {Emitter, clone, deepEqual, expandHome, tildify} from './util.js';
import {newId} from './ids.js';
import {
  decodeConfiguration, encodeConfiguration, starterConfiguration, parseSlateConfig, describeError, isNotImplemented,
} from './engine.js';
import {keysString, statusKey} from './keys.js';
import {validate, savable, configChanges, target, LAYOUT_NAME_MISSING, LAYOUT_NAME_TAKEN} from './validator.js';
import {parseStatus, emptyStatus, extensionState, bindingState, runningSummary} from './status.js';
import {presetById, starterBindings} from './presets.js';
import {bindingTitle, layoutNames, renameLayout} from './actions.js';
import {builtInShortcut, recipeBindingName, sharesApps} from './automation.js';
import {loadSlateScript, importSlateScript, importClassic, planImport} from './importer.js';
import {newBinding, newHotstring} from './config.js';
import {STEPS, parseWindowState, windowStateText, startingPane} from './getstarted.js';

/**
 * @typedef {object} ModelIO
 * @property {() => string|null} readConfig config.json text, or null when it doesn't exist
 * @property {(text: string) => void} writeConfig writes config.json (atomically), creating folders
 * @property {(path: string) => string|null} readFile any file (Slate configs), null if missing
 * @property {string} home the home folder
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
    this.issues = [];
    this.saveState = {kind: 'saved'};
    this.loadError = null;
    /** True while config.json doesn't exist yet: the first edit creates it. */
    this.firstRun = false;
    /** config.json's text as last read or written (null: none yet), and text that failed to decode. */
    this._diskText = null;
    this._badText = null;

    this.status = emptyStatus();
    this.shell = extensionState(null);
    this.build = null;
    this.runningCommit = null;
    this.sources = [];
    /** The settings window's own state (settings-window.json): {setupFinished, …}. */
    this.windowState = parseWindowState(null);
    /** Get Started's step (getstarted.STEPS): in memory, like the Mac's; a new window starts over. */
    this.getStartedStep = 'welcome';
  }

  // --- Loading --------------------------------------------------------------------------------------

  /** Reads config.json, the Slate files and the window's own state. Call once after construction. */
  load() {
    this._loadWindowState();
    let text;
    try {
      text = this.io.readConfig();
    } catch (error) {
      this._blocked(`Couldn't read config.json: ${describeError(error)}`);
      return;
    }
    if (text === null || text === undefined) {
      this.firstRun = true;
      this.draft = this._initialConfiguration();
      this.saved = clone(this.draft);
    } else {
      try {
        this.draft = separateDuplicateIds(decodeConfiguration(text), this.makeId);
        this.saved = clone(this.draft);
        this.firstRun = false;
        this._diskText = text;
      } catch (error) {
        this._badText = text;
        this._blocked(describeError(error));
        return;
      }
    }
    this.loadError = null;
    this.saveState = {kind: 'saved'};
    this.refreshSources();
    this._revalidate();
    this.emit('config');
    this.emit('save-state');
  }

  /**
   * What a first run starts with, as on macOS: with a Slate config, no bindings of Slated's own (the
   * Slate file is the default); otherwise the built-in starter bindings, when the engine provides them.
   */
  _initialConfiguration() {
    const defaults = decodeConfiguration('{}');
    const hasSlate = defaults.general.slateConfigPaths.some(p => this.io.readFile(expandHome(p, this.io.home)) !== null);
    if (hasSlate) return defaults;
    let starter = null;
    try {
      starter = starterConfiguration();
    } catch {
      starter = null;
    }
    return starter ? decodeConfiguration(encodeConfiguration(starter)) : defaults;
  }

  _blocked(message) {
    this.loadError = message;
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
    const pathsChanged = !deepEqual(result.general?.slateConfigPaths, this.draft.general?.slateConfigPaths);
    this.draft = result;
    if (pathsChanged) this.refreshSources();
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

  /** Writes pending edits now. Call before the window closes. */
  saveNow() {
    this._cancelTimer();
    if (this.loadError) {
      this.saveState = {kind: 'blocked'};
      this.emit('save-state');
      return;
    }
    const output = savable(this.draft, this.saved, this.issues);
    if (!deepEqual(output, this.saved)) {
      try {
        this.io.writeConfig(encodeConfiguration(output));
      } catch (error) {
        const message = describeError(error);
        this.saveState = {kind: 'failed', message};
        this.log('config.save_failed', {message}, 'error');
        this.emit('save-state');
        return;
      }
      const changes = configChanges(this.saved, output);
      if (changes.length) this.log('config.saved', {changes, source: 'prefs'});
      // Re-read so `saved` matches what the file decodes to (normalized values).
      let reread = output;
      try {
        const text = this.io.readConfig();
        if (text !== null && text !== undefined) {
          reread = decodeConfiguration(text);
          this._diskText = text;
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

  /** Adopts config.json when it changed on disk (hand edits), unless there are unsaved edits. */
  syncFromDisk() {
    if (this.hasUnsavedChanges) return;
    let text;
    try {
      text = this.io.readConfig();
    } catch (error) {
      this._blocked(`Couldn't read config.json: ${describeError(error)}`);
      return;
    }
    if (text === null || text === undefined) {
      // Deleted: keep what's shown; the next save recreates it. When saving waited for the broken
      // file that was there, it's gone, so saving resumes as on a first run (with edits made meanwhile).
      if (this.loadError) {
        this.loadError = null;
        this._badText = null;
        this._diskText = null;
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
    // The same text again (a file monitor event, the reload nudge): nothing to adopt.
    if (this.loadError ? text === this._badText : text === this._diskText) return;
    let disk;
    try {
      disk = decodeConfiguration(text);
    } catch (error) {
      this._badText = text;
      this._blocked(describeError(error));
      return;
    }
    this._diskText = text;
    this._badText = null;
    keepGeneratedIds(separateDuplicateIds(disk, this.makeId), this.saved, text);
    const wasBlocked = this.loadError !== null;
    this.loadError = null;
    this.firstRun = false;
    if (wasBlocked || !deepEqual(disk, this.saved)) {
      const pathsChanged = !deepEqual(disk.general?.slateConfigPaths, this.draft.general?.slateConfigPaths);
      this.saved = disk;
      this.draft = clone(disk);
      if (pathsChanged) this.refreshSources();
      this._revalidate();
      this.saveState = {kind: 'saved'};
      this.emit('config');
      this.emit('save-state');
    }
  }

  /** Saves pending edits, then re-reads config.json and the Slate files. */
  reload() {
    if (this.hasUnsavedChanges) this.saveNow();
    this.syncFromDisk();
    this.refreshSources();
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

  // --- Slate files -----------------------------------------------------------------------------------

  /** Re-reads every Slate file in general.slateConfigPaths, for the read-only lists. */
  refreshSources() {
    const home = this.io.home;
    const paths = this.draft.general?.slateConfigPaths ?? [];
    this.sources = paths.filter(p => p && p.trim()).map(raw => {
      const file = expandHome(raw.trim(), home);
      const kind = file.endsWith('.js') ? 'javascript' : 'classic';
      const source = {
        path: raw, file, displayPath: tildify(file, home), kind, exists: false, bindings: [], layouts: [],
        diagnostics: [], error: null,
      };
      let text = null;
      try {
        text = this.io.readFile(file);
      } catch (error) {
        source.error = describeError(error);
      }
      if (text === null || text === undefined) return source;
      source.exists = true;
      source.text = text;
      try {
        if (kind === 'javascript') {
          const loaded = loadSlateScript(text, {path: file, home, readFile: p => this.io.readFile(p)});
          source.bindings = loaded.bindings.map(b => ({
            keys: b.keys, modal: b.modal, statusKey: b.statusKey, action: b.action, summary: b.summary,
            keystroke: b.keystroke, line: b.line, isFunction: !b.action,
            probe: memo(() => loaded.probe(b)),
          }));
          source.layouts = loaded.layouts;
          source.diagnostics = loaded.diagnostics;
        } else {
          const parsed = parseSlateConfig(text, {path: file, readFile: p => this.io.readFile(expandHome(p, home))});
          source.bindings = (parsed.bindings ?? []).filter(b => b.enabled !== false).map(b => {
            const keys = keysString(b.keys);
            const modal = b.modal ? {keys: keysString(b.modal.keys), toggle: b.modal.toggle === true} : null;
            return {
              keys, modal, statusKey: statusKey(keys, modal), action: b.action, summary: null, isFunction: false,
              probe: () => ({action: b.action}),
            };
          });
          source.layouts = parsed.layouts ?? [];
          source.diagnostics = parsed.diagnostics ?? [];
        }
      } catch (error) {
        source.error = isNotImplemented(error)
          ? 'Classic .slate files show up here once the Slated engine can read them. The extension still loads them.'
          : describeError(error);
      }
      return source;
    });
    this.emit('sources');
  }

  /** The status.json entry for a source, matched by path. */
  sourceStatus(source) {
    const home = this.io.home;
    return this.status.sources.find(s => expandHome(s.path, home) === source.file) ?? null;
  }

  /** Layout names from config.json and the Slate files. */
  knownLayoutNames() {
    return [...new Set([...(this.draft.layouts ?? []).map(l => l.name), ...this.sources.flatMap(s => s.layouts.map(l => l.name))])];
  }

  get slateLoading() {
    return this.draft.general?.loadSlateConfigs !== false;
  }

  /** Whether a Slate file's binding was imported while the file kept loading, so it's ignored. */
  isImportedSlateShortcut(sourceBinding) {
    const imported = this.draft.general?.importedSlateShortcuts;
    return Array.isArray(imported) && imported.includes(sourceBinding.statusKey);
  }

  sourceBindingCount() {
    return this.sources.filter(s => s.exists).reduce((n, s) => n + s.bindings.length, 0);
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

  /** The state of a read-only Slate binding. */
  sourceBindingState(sourceBinding) {
    return bindingState({
      binding: sourceBinding, key: sourceBinding.statusKey, status: this.status, running: this.running,
      slateLoading: this.slateLoading, isSource: true, imported: this.isImportedSlateShortcut(sourceBinding),
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

  /** Copies a static (or probed) Slate binding into Slated's own bindings. Returns the new id or null. */
  copyIntoSlated(sourceBinding) {
    const action = sourceBinding.action ?? sourceBinding.probe?.().action;
    if (!action) return null;
    const binding = newBinding({keys: sourceBinding.keys, action: clone(action)}, this.makeId);
    if (sourceBinding.modal) binding.modal = clone(sourceBinding.modal);
    this.update(config => {
      config.bindings.push(binding);
    });
    return binding.id;
  }

  /** True when Slated already has a binding with the same keys and action. */
  isCopied(sourceBinding) {
    const action = sourceBinding.action ?? sourceBinding.probe?.().action;
    return this.draft.bindings.some(b => statusKey(b.keys, b.modal) === sourceBinding.statusKey && deepEqual(b.action, action));
  }

  /**
   * Other bindings (Slated's and the Slate files') using the same keys, for duplicate hints. Bindings
   * limited to other apps than this one's never run at the same time, so they don't count.
   */
  otherUses(keys, modal, excludingId) {
    if (!keysString(keys)) return [];
    const key = statusKey(keys, modal);
    const me = this.binding(excludingId) ?? {};
    const uses = this.draft.bindings
      .filter(b => b.id !== excludingId && b.enabled !== false && statusKey(b.keys, b.modal) === key && sharesApps(b, me))
      .map(b => `“${bindingTitle(b)}”`);
    if (this.slateLoading) {
      for (const source of this.sources.filter(s => s.exists)) {
        for (const b of source.bindings) {
          if (b.statusKey === key && !this.isImportedSlateShortcut(b)) uses.push(`“${b.summary ?? b.keys}” in ${source.displayPath}`);
        }
      }
    }
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

  /** What takes a built-in shortcut's keys away from it: Slated bindings (which win) and Slate files'. */
  otherUsesOfBuiltIn(id) {
    const builtIn = builtInShortcut(id);
    const keys = builtIn?.keys(this.draft);
    if (!keys) return [];
    const uses = this.draft.bindings
      .filter(b => b.enabled !== false && !b.modal && keysString(b.keys) === keys && b.action?.op !== builtIn.action.op)
      .map(b => `“${bindingTitle(b)}”`);
    if (this.slateLoading) {
      for (const source of this.sources.filter(s => s.exists)) {
        for (const b of source.bindings) if (b.statusKey === keys) uses.push(`“${b.summary ?? b.keys}” in ${source.displayPath}`);
      }
    }
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
   * a layout by its name, so a rename that clashes would move them to the other layout. A Slate
   * file's layouts count, as for addLayout: their shortcuts would come along too.
   */
  layoutNameProblem(name, newName, index = null) {
    if (!String(newName ?? '').trim()) return LAYOUT_NAME_MISSING;
    if (newName === name) return null;
    const own = layoutIndex(this.draft.layouts, name, index);
    const taken = this.draft.layouts.some((l, i) => i !== own && l.name === newName)
      || this.sources.some(s => s.layouts.some(l => l.name === newName));
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

  /** Bindings (Slated's and the Slate files') that apply the named layout. */
  triggersForLayout(name) {
    const result = this.draft.bindings.filter(b => b.action?.op === 'layout' && b.action.name === name)
      .map(b => ({keys: b.keys, modal: b.modal ?? null}));
    for (const source of this.sources) {
      for (const b of source.bindings) {
        if (b.action?.op === 'layout' && b.action.name === name) result.push({keys: b.keys, modal: b.modal});
      }
    }
    return result;
  }

  // --- Importing --------------------------------------------------------------------------------------

  /** What importing every existing Slate file would do (see importer.planImport). Doesn't change anything. */
  planSlateImport() {
    const results = [];
    const errors = [];
    for (const source of this.sources.filter(s => s.exists)) {
      try {
        const options = {path: source.file, home: this.io.home, readFile: p => this.io.readFile(p), makeId: this.makeId};
        const result = source.kind === 'javascript' ? importSlateScript(source.text, options) : importClassic(source.text, options);
        results.push({path: source.displayPath, result});
      } catch (error) {
        errors.push({path: source.displayPath, message: isNotImplemented(error)
          ? "the Slated engine can't read classic .slate files yet" : describeError(error)});
      }
    }
    // A source that couldn't be read at all means Slate files must keep loading.
    const plan = planImport(this.draft, results, {keepLoading: errors.length > 0});
    return {...plan, errors};
  }

  /** Applies a plan from planSlateImport() and logs it. */
  applySlateImport(plan) {
    this.update(() => clone(plan.config));
    this.log('slate.imported', {
      imported: plan.added.length,
      skipped: plan.skipped.map(s => `${s.keystroke}: ${s.reason}`),
      neverRun: plan.neverRun.map(s => `${s.keystroke}: ${s.reason}`),
      source: 'prefs',
    });
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

function memo(fn) {
  let done = false;
  let value;
  return () => {
    if (!done) {
      value = fn();
      done = true;
    }
    return value;
  };
}
