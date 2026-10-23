// Loads Slate config files alongside Slated's own configuration and reloads them when they change:
// classic `~/.slate` through the core's `parseSlateConfig`, and `~/.slate.js` through the JavaScript
// engine (slateScript.js). A port of the macOS SlateSourceLoader and JavaScriptSources.

import * as Core from '../core/index.js';

import {readText, watchFile} from './files.js';
import {SlateScriptEngine, staticLayout} from './slateScript.js';
import {Debouncer} from './timers.js';
import {abbreviateHome, conditionMatches, defaultEntry, diagnosticText, expandHome} from './util.js';
import {bindingKey, comboOf, modalOf} from './combos.js';

export class SlateSources {
  /**
   * @param {object} options
   * @param {object} options.log
   * @param {object} options.runner     The ActionRunner (plain operations run through it).
   * @param {object} options.host       The GNOME script host (scriptHost.js).
   * @param {object} options.events     ScriptEvents, connected to what the scripts listen for.
   * @param {object} options.platform   For finding apps in JavaScript layouts.
   * @param {object} options.timers
   * @param {string} options.home
   * @param {() => void} options.onChange  A Slate file changed on disk.
   * @param {(diagnostics: object[]) => void} options.onDiagnostics  Problems while running scripts.
   */
  constructor({log, runner, host, events, platform, timers, home, onChange, onDiagnostics, core = Core}) {
    this._log = log;
    this._runner = runner;
    this._host = host;
    this._events = events;
    this._platform = platform;
    this._home = home;
    this._core = core;
    this._onDiagnostics = onDiagnostics;
    this._engines = new Map();
    this._watchers = [];
    this._changed = new Debouncer(timers, 300, () => onChange?.());
    this._loggedSignature = '';
    this._reset();
  }

  _reset() {
    /** For status.json and the preferences app. */
    this.sources = [];
    this.settings = {};
    /** Layouts as plain config.json layouts (the runner applies them). */
    this.layouts = [];
    /** Display defaults naming a layout or snapshot: `{condition, target}`. */
    this.defaults = [];
    this._classicBindings = [];
    this._scriptBindings = [];
    this._scriptLayouts = new Map();
    this._callbackDefaults = [];
  }

  /** Loads `paths` (as written in config.json, `~` allowed), replacing what was loaded before. */
  load(paths) {
    this._reset();
    for (const raw of paths) {
      const path = expandHome(raw, this._home);
      const kind = path.endsWith('.js') ? 'javascript' : 'classic';
      const text = readText(path);
      if (text === null) {
        this.sources.push({path: raw, kind, exists: false, loaded: false, bindings: [], layouts: [], diagnostics: []});
        continue;
      }
      if (kind === 'classic') this._loadClassic(path, raw, text);
      else this._loadJavaScript(path, raw);
    }
    // Engines for files no longer listed go away (with any globals their scripts created).
    const listed = new Set(paths.map((p) => expandHome(p, this._home)));
    for (const [path, engine] of this._engines) {
      if (!listed.has(path)) {
        engine.destroy();
        this._engines.delete(path);
      }
    }
    this._watch(paths);
    this._watchEvents();
    this._logIfChanged();
  }

  // --- Classic .slate ----------------------------------------------------------------------------

  _loadClassic(path, displayPath, text) {
    let file;
    try {
      file = this._core.parseSlateConfig(text, {path, readFile: readText, homeDirectory: this._home});
    } catch (e) {
      this.sources.push({
        path: displayPath,
        kind: 'classic',
        exists: true,
        loaded: false,
        bindings: [],
        layouts: [],
        diagnostics: [{severity: 'error', message: `Couldn't read the file: ${e.message ?? e}`, file: path}],
      });
      return;
    }
    Object.assign(this.settings, file.settings ?? {});
    this.layouts.push(...(file.layouts ?? []));
    for (const entry of file.defaults ?? []) {
      const normalized = defaultEntry(entry);
      if (normalized) this.defaults.push(normalized);
    }
    const summaries = [];
    for (const [index, binding] of (file.bindings ?? []).entries()) {
      if (binding.enabled === false) continue;
      let keys;
      let modal;
      try {
        keys = comboOf(binding.keys, this._core);
        modal = binding.modal ? modalOf(binding.modal, this._core) : null;
      } catch {
        continue;
      }
      if (!keys) continue;
      const id = bindingKey(keys, modal, this._core);
      this._classicBindings.push({id, keys, modal, binding, path, index});
      summaries.push({id, keys, modal, summary: this._format(binding.action), action: binding.action});
    }
    const diagnostics = file.diagnostics ?? [];
    this.sources.push({
      path: displayPath,
      kind: 'classic',
      exists: true,
      loaded: !diagnostics.some((d) => d.severity === 'error') || summaries.length > 0,
      bindings: summaries,
      layouts: file.layouts ?? [],
      diagnostics,
    });
  }

  // --- JavaScript .slate.js ----------------------------------------------------------------------

  _loadJavaScript(path, displayPath) {
    let engine = this._engines.get(path);
    if (!engine) {
      engine = new SlateScriptEngine({host: this._host, core: this._core, readFile: readText, home: this._home});
      this._engines.set(path, engine);
    }
    const result = engine.load(path);
    Object.assign(this.settings, engine.evaluatedSettings());
    for (const layout of result.layouts) {
      const plain = staticLayout(layout);
      if (plain) this.layouts.push(plain);
      else this._scriptLayouts.set(layout.name, {engine, layout});
    }
    for (const entry of result.defaults) {
      if (entry.target.name !== undefined) {
        const normalized = defaultEntry({condition: entry.condition, target: entry.target.name});
        if (normalized) this.defaults.push(normalized);
      } else if (entry.target.callback !== undefined) {
        this._callbackDefaults.push({engine, condition: entry.condition, id: entry.target.callback});
      }
    }
    const source = abbreviateHome(path, this._home);
    for (const binding of result.bindings) this._scriptBindings.push({engine, binding, source});
    this.sources.push({
      path: displayPath,
      kind: 'javascript',
      exists: true,
      loaded: !result.hasErrors || result.bindings.length > 0,
      bindings: result.bindings.map((b) => ({
        id: b.id,
        keys: b.keys,
        modal: b.modal,
        summary: b.summary,
        action: b.target.kind === 'action' ? b.target.action : null,
      })),
      layouts: result.layouts.map(staticLayout).filter(Boolean),
      diagnostics: result.diagnostics,
    });
  }

  // --- Hotkeys -----------------------------------------------------------------------------------

  /** Hotkey entries (keybindings.js) for every binding the sources define. */
  entries(settings) {
    const repeatOps = String(settings.repeatOnHoldOps ?? 'resize,nudge')
      .split(',')
      .map((s) => s.trim());
    const classic = this._classicBindings.map(({id, keys, modal, binding, path, index}) => {
      const source = abbreviateHome(path, this._home);
      return {
        id,
        keys,
        modal,
        repeats: typeof binding.repeats === 'boolean' ? binding.repeats : repeatOps.includes(binding.action?.op),
        source,
        run: () =>
          this._runner.run(binding.action, {chainKey: `${path}#${binding.id ?? index}`, trigger: `hotkey ${id}`, source}),
      };
    });
    const scripts = this._scriptBindings.map(({engine, binding, source}) => ({
      id: binding.id,
      keys: binding.keys,
      modal: binding.modal,
      repeats: !!binding.repeats,
      source,
      run: () => this._runScriptBinding(engine, binding, source),
    }));
    return [...classic, ...scripts];
  }

  _runScriptBinding(engine, binding, source) {
    const trigger = `hotkey ${binding.id}`;
    if (binding.target.kind === 'action') {
      this._runner.run(binding.target.action, {chainKey: `js:${binding.keystroke}`, trigger, source});
      return;
    }
    this._host.source = source;
    const start = Date.now();
    const result = engine.invoke(binding);
    const data = {trigger, source, function: binding.summary, ms: Date.now() - start};
    if (result.diagnostics.length) data.errors = result.diagnostics.map(diagnosticText);
    this._log?.record(result.success ? 'script.binding' : 'script.binding_failed', data, result.success ? 'info' : 'error');
    if (result.diagnostics.length) this._onDiagnostics?.(result.diagnostics);
  }

  // --- Layouts and defaults with JavaScript --------------------------------------------------------

  /** Runs a layout whose steps include JavaScript. Returns false if there's no such layout. */
  runLayout(name) {
    const entry = this._scriptLayouts.get(name);
    if (!entry) return false;
    const {engine, layout} = entry;
    const report = (result) => {
      if (result.diagnostics.length) this._onDiagnostics?.(result.diagnostics);
      return result;
    };
    for (const step of layout.before) report(engine.run(step, null));
    for (const app of layout.apps) {
      const shellApp = this._platform.findApp(app.app);
      if (!shellApp || app.operations.length === 0) continue;
      const windows = this._host.windows(this._host.appHandle(shellApp));
      for (let i = 0; i < windows.length; i++) {
        let index;
        if (i < app.operations.length) index = i;
        else if (app.options?.repeat) index = i % app.operations.length;
        else if (app.options?.repeatLast) index = app.operations.length - 1;
        else break;
        const result = report(engine.run(app.operations[index], windows[i]));
        if (!result.success && !app.options?.ignoreFail) break;
      }
    }
    for (const step of layout.after) report(engine.run(step, null));
    return true;
  }

  /** Runs the first JavaScript display default matching `screens`. Returns true if one ran. */
  runCallbackDefaults(screens) {
    for (const entry of this._callbackDefaults) {
      if (!conditionMatches(entry.condition, screens)) continue;
      const result = entry.engine.run({kind: 'callback', id: entry.id}, null);
      if (result.diagnostics.length) this._onDiagnostics?.(result.diagnostics);
      return true;
    }
    return false;
  }

  // --- Events (`slate.on`) -------------------------------------------------------------------------

  dispatch(event) {
    for (const engine of this._engines.values()) {
      if (!engine.result.events.includes(event.name)) continue;
      const result = engine.dispatch(event);
      if (result.diagnostics.length) this._onDiagnostics?.(result.diagnostics);
    }
  }

  _watchEvents() {
    const names = new Set();
    for (const engine of this._engines.values()) for (const name of engine.result.events) names.add(name);
    const unsupported = this._events?.watch(names) ?? [];
    if (unsupported.length) this._log?.record('script.unsupported_events', {events: [...unsupported].sort()}, 'notice');
  }

  // --- Watching files ------------------------------------------------------------------------------

  _watch(paths) {
    for (const watcher of this._watchers) watcher.cancel();
    const files = new Set(paths.map((p) => expandHome(p, this._home)));
    for (const engine of this._engines.values()) for (const file of engine.result.sourcedFiles) files.add(file);
    this._watchers = [...files].map((file) => watchFile(file, () => this._changed.trigger()));
  }

  /** One event per source when what was loaded changes (not on every config save). */
  _logIfChanged() {
    const signature = JSON.stringify(this.sources.map((s) => [s.path, s.exists, s.loaded, s.bindings.length, s.diagnostics.map(diagnosticText)]));
    if (signature === this._loggedSignature) return;
    this._loggedSignature = signature;
    for (const source of this.sources) {
      if (!source.exists) continue;
      const errors = source.diagnostics.filter((d) => d.severity === 'error');
      const data = {path: source.path, kind: source.kind, loaded: source.loaded, bindings: source.bindings.length};
      if (source.diagnostics.length) data.diagnostics = source.diagnostics.map(diagnosticText);
      this._log?.record('slate.loaded', data, errors.length ? 'error' : 'info');
    }
  }

  _format(action) {
    try {
      return this._core.formatOperation(action);
    } catch {
      return action?.op ?? 'operation';
    }
  }

  destroy() {
    this._changed.cancel();
    for (const watcher of this._watchers) watcher.cancel();
    this._watchers = [];
    this._events?.destroy();
    for (const engine of this._engines.values()) engine.destroy();
    this._engines.clear();
    this._reset();
  }
}
