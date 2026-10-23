// A simulated GNOME Shell for integration tests of the runtime's wiring: a main loop with virtual
// time, `global.display` with accelerator grabs and signals, windows and apps, GSettings, file
// monitors, and real file IO under a temporary home. Only what Slated uses is implemented; anything
// else throws, so a test fails if the runtime reaches for an API this fake doesn't know.
//
// Install it before importing extension modules:
//   const gnome = createFakeGnome();
//   globalThis.__slatedGnomeFakes = gnome.modules;
//   globalThis.global = gnome.global;
//   const {SlatedRuntime} = await import('…/runtime.js');

import {existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync, appendFileSync, accessSync, constants} from 'node:fs';
import {dirname} from 'node:path';

import {screens as fixtureScreens} from './fixtures.mjs';

class Signals {
  constructor() {
    this._handlers = new Map();
    this._next = 1;
  }
  connect(signal, callback) {
    const id = this._next++;
    this._handlers.set(id, {signal, callback});
    return id;
  }
  disconnect(id) {
    if (!this._handlers.delete(id)) throw new Error(`disconnect of unknown handler ${id}`);
  }
  emit(signal, ...args) {
    for (const {signal: s, callback} of [...this._handlers.values()]) if (s === signal) callback(this, ...args);
  }
  count(signal) {
    return [...this._handlers.values()].filter((h) => h.signal === signal).length;
  }
  get size() {
    return this._handlers.size;
  }
}

/** Main loop sources with virtual time. */
class Loop {
  constructor() {
    this.now = 0;
    this._sources = new Map();
    this._next = 1;
  }
  add(ms, callback) {
    const id = this._next++;
    this._sources.set(id, {due: this.now + ms, ms, callback});
    return id;
  }
  remove(id) {
    if (!this._sources.delete(id)) throw new Error(`source_remove of unknown source ${id}`);
  }
  get pending() {
    return this._sources.size;
  }
  /** Runs everything due now (idles included), repeatedly, then returns. */
  run() {
    for (let guard = 0; guard < 1000; guard++) {
      const due = [...this._sources.entries()].filter(([, s]) => s.due <= this.now).sort((a, b) => a[1].due - b[1].due);
      if (due.length === 0) return;
      for (const [id, source] of due) {
        if (!this._sources.has(id)) continue;
        const again = source.callback();
        if (again === true) source.due = this.now + Math.max(source.ms, 1);
        else this._sources.delete(id);
      }
    }
    throw new Error('main loop did not settle');
  }
  /** Moves virtual time forward, running sources as they come due. */
  advance(ms) {
    const end = this.now + ms;
    this.run();
    while (true) {
      const next = Math.min(...[...this._sources.values()].map((s) => s.due).filter((d) => d <= end));
      if (!Number.isFinite(next)) break;
      this.now = next;
      this.run();
    }
    this.now = end;
    this.run();
  }
}

export class FakeMetaWindow {
  constructor({id, app = null, title = '', frame, minimized = false}) {
    this.id = id;
    this.app = app;
    this.title = title;
    this.frame = {...frame};
    this.minimized = minimized;
    this.maximized = 0;
    this.signals = new Signals();
    this.moves = [];
  }
  get_id() {
    return this.id;
  }
  get_title() {
    return this.title;
  }
  get_frame_rect() {
    return {...this.frame};
  }
  move_frame(_userOp, x, y) {
    this.frame = {...this.frame, x, y};
  }
  move_resize_frame(_userOp, x, y, width, height) {
    this.frame = {x, y, width, height};
    this.moves.push({x, y, width, height});
  }
  is_override_redirect() {
    return false;
  }
  get_window_type() {
    return 0;
  }
  is_fullscreen() {
    return false;
  }
  get_maximized() {
    return this.maximized;
  }
  unmaximize(flags) {
    if (flags === undefined) throw new Error('Too few arguments to method Meta.Window.unmaximize');
    this.maximized = 0;
  }
  allows_move() {
    return true;
  }
  allows_resize() {
    return true;
  }
  located_on_workspace() {
    return true;
  }
  get_wm_class() {
    return this.app?.id ?? 'unknown';
  }
  get_gtk_application_id() {
    return null;
  }
  get_sandboxed_app_id() {
    return null;
  }
  minimize() {
    this.minimized = true;
  }
  unminimize() {
    this.minimized = false;
  }
  connect(signal, callback) {
    return this.signals.connect(signal, callback);
  }
  disconnect(id) {
    this.signals.disconnect(id);
  }
}

export class FakeShellApp {
  constructor({id, name}) {
    this.id = id;
    this.name = name;
    this.windows = [];
  }
  get_id() {
    return `${this.id}.desktop`;
  }
  get_name() {
    return this.name;
  }
  is_window_backed() {
    return false;
  }
  get_windows() {
    return this.windows;
  }
  get_state() {
    return 2;
  }
  activate() {}
}

export function createFakeGnome({home = '/nonexistent', env = {}, screens = fixtureScreens} = {}) {
  const loop = new Loop();
  const state = {
    home,
    env: {...env},
    focused: null,
    windows: [],
    apps: [],
    settings: {'org.gnome.desktop.input-sources:xkb-options': []},
    taken: new Set(),
    grabs: new Map(),
    allowed: {},
    monitors: new Map(),
    nextGrab: 1,
    locked: false,
  };
  const displaySignals = new Signals();
  const trackerSignals = new Signals();
  const appSystemSignals = new Signals();
  const layoutSignals = new Signals();

  const fileTest = (path, test) => {
    if (!existsSync(path)) return false;
    if (test & 2) return statSync(path).isDirectory();
    if (test & 4) {
      try {
        accessSync(path, constants.X_OK);
        return statSync(path).isFile();
      } catch {
        return false;
      }
    }
    return true;
  };

  const GLib = {
    PRIORITY_DEFAULT: 0,
    PRIORITY_DEFAULT_IDLE: 200,
    SOURCE_REMOVE: false,
    SOURCE_CONTINUE: true,
    FileTest: {EXISTS: 1, IS_DIR: 2, IS_EXECUTABLE: 4},
    getenv: (name) => state.env[name] ?? null,
    get_home_dir: () => state.home,
    get_user_config_dir: () => `${state.home}/.config`,
    get_user_state_dir: () => `${state.home}/.local/state`,
    file_test: fileTest,
    mkdir_with_parents(path) {
      mkdirSync(path, {recursive: true});
      return 0;
    },
    file_set_contents(path, bytes) {
      writeFileSync(path, bytes);
      return true;
    },
    find_program_in_path: () => null,
    get_monotonic_time: () => loop.now * 1000,
    timeout_add: (_priority, ms, callback) => loop.add(ms, callback),
    idle_add: (_priority, callback) => loop.add(0, callback),
    source_remove: (id) => loop.remove(id),
    uri_parse_scheme: (uri) => /^([a-z][a-z0-9+.-]*):/i.exec(uri)?.[1] ?? null,
  };

  class FakeMonitor {
    constructor(path) {
      this.path = path;
      this.signals = new Signals();
      this.cancelled = false;
      if (!state.monitors.has(path)) state.monitors.set(path, new Set());
      state.monitors.get(path).add(this);
    }
    connect(signal, callback) {
      return this.signals.connect(signal, callback);
    }
    disconnect(id) {
      this.signals.disconnect(id);
    }
    cancel() {
      this.cancelled = true;
      state.monitors.get(this.path)?.delete(this);
    }
  }

  class FakeFile {
    constructor(path) {
      this.path = path;
    }
    load_contents() {
      return [true, new Uint8Array(readFileSync(this.path))];
    }
    append_to() {
      mkdirSync(dirname(this.path), {recursive: true});
      const path = this.path;
      return {
        write_all(bytes) {
          appendFileSync(path, bytes);
          return [true, bytes.length];
        },
        close() {
          return true;
        },
      };
    }
    query_info() {
      const stats = statSync(this.path);
      return {get_size: () => stats.size, get_attribute_uint64: () => Math.floor(stats.mtimeMs / 1000)};
    }
    delete() {
      unlinkSync(this.path);
      return true;
    }
    move(destination) {
      renameSync(this.path, destination.path);
      return true;
    }
    monitor_file() {
      return new FakeMonitor(this.path);
    }
  }

  const Gio = {
    File: {new_for_path: (path) => new FakeFile(path)},
    FileCreateFlags: {NONE: 0},
    FileQueryInfoFlags: {NONE: 0},
    FileCopyFlags: {OVERWRITE: 1},
    FileMonitorFlags: {WATCH_MOVES: 8},
    FileMonitorEvent: {CHANGED: 0, CHANGES_DONE_HINT: 1, DELETED: 2, CREATED: 3, ATTRIBUTE_CHANGED: 4, PRE_UNMOUNT: 5},
    Settings: class {
      constructor({schema_id: schema}) {
        this.schema = schema;
      }
      get_strv(key) {
        return [...(state.settings[`${this.schema}:${key}`] ?? [])];
      }
      set_strv(key, value) {
        state.settings[`${this.schema}:${key}`] = [...value];
        return true;
      }
    },
    SettingsSchemaSource: {get_default: () => ({lookup: () => null})},
    Subprocess: {
      new() {
        throw new Error('no subprocesses in tests');
      },
    },
    SubprocessFlags: {NONE: 0, STDOUT_PIPE: 1, STDOUT_SILENCE: 2, STDERR_SILENCE: 8},
    Cancellable: class {
      cancel() {
        this.cancelled = true;
      }
    },
    DBusExportedObject: {
      wrapJSObject(xml, implementation) {
        state.dbus = {xml, implementation, exported: false};
        return {
          export(_connection, path) {
            state.dbus.exported = true;
            state.dbus.path = path;
          },
          unexport() {
            state.dbus.exported = false;
          },
        };
      },
    },
    DBus: {session: {}},
  };

  const Meta = {
    KeyBindingFlags: {NONE: 0, IGNORE_AUTOREPEAT: 16},
    KeyBindingAction: {NONE: 0},
    external_binding_name_for_action: (action) => `external-grab-${action}`,
    WindowType: {NORMAL: 0, DESKTOP: 1, DOCK: 2, DIALOG: 3, MODAL_DIALOG: 4, TOOLBAR: 5, MENU: 6, UTILITY: 7},
    MaximizeFlags: {HORIZONTAL: 1, VERTICAL: 2, BOTH: 3},
    is_wayland_compositor: () => true,
  };

  const tracker = {
    get focus_app() {
      return state.focused?.app ?? null;
    },
    get_window_app: (window) => window?.app ?? null,
    connect: (signal, callback) => trackerSignals.connect(signal, callback),
    disconnect: (id) => trackerSignals.disconnect(id),
  };
  const appSystem = {
    get_running: () => state.apps.filter((a) => a.windows.length > 0),
    connect: (signal, callback) => appSystemSignals.connect(signal, callback),
    disconnect: (id) => appSystemSignals.disconnect(id),
  };
  const Shell = {
    ActionMode: {NONE: 0, NORMAL: 1, OVERVIEW: 2, LOCK_SCREEN: 4, POPUP: 64, SYSTEM_MODAL: 32},
    AppState: {STOPPED: 0, STARTING: 1, RUNNING: 2},
    WindowTracker: {get_default: () => tracker},
    AppSystem: {get_default: () => appSystem},
  };

  const workspace = {
    get_work_area_for_monitor: (i) => ({...screens[i].visibleFrame}),
    list_windows: () => state.windows,
  };

  const global = {
    display: {
      get_n_monitors: () => screens.length,
      get_primary_monitor: () => screens.findIndex((s) => s.isMain),
      get_monitor_geometry: (i) => ({...screens[i].frame}),
      get_monitor_scale: () => 1,
      get_focus_window: () => state.focused,
      list_all_windows: () => state.windows,
      sort_windows_by_stacking: (windows) => [...windows].reverse(), // state.windows is top-first
      grab_accelerator(accelerator, flags) {
        if (state.taken.has(accelerator) || [...state.grabs.values()].some((g) => g.accelerator === accelerator)) return 0;
        const action = state.nextGrab++;
        state.grabs.set(action, {accelerator, flags});
        return action;
      },
      ungrab_accelerator: (action) => state.grabs.delete(action),
      connect: (signal, callback) => displaySignals.connect(signal, callback),
      disconnect: (id) => displaySignals.disconnect(id),
    },
    workspace_manager: {get_active_workspace: () => workspace},
    get_window_actors: () => state.windows.map((w) => ({get_meta_window: () => w})),
    stage: {width: 3000, height: 1920},
    get_pointer: () => [0, 0, 0],
    create_app_launch_context: () => null,
  };

  const Main = {
    wm: {
      allowKeybinding(name, modes) {
        state.allowed[name] = modes;
      },
    },
    layoutManager: {
      connect: (signal, callback) => layoutSignals.connect(signal, callback),
      disconnect: (id) => layoutSignals.disconnect(id),
      primaryIndex: 0,
      getWorkAreaForMonitor: (i) => ({...screens[i].visibleFrame}),
    },
    sessionMode: {
      get isLocked() {
        return state.locked;
      },
    },
    activateWindow(window) {
      state.focused = window;
    },
  };

  return {
    state,
    loop,
    global,
    signals: {display: displaySignals, tracker: trackerSignals, appSystem: appSystemSignals, layout: layoutSignals},
    modules: {
      'gi://GLib': GLib,
      'gi://Gio': Gio,
      'gi://Meta': Meta,
      'gi://Shell': Shell,
      'resource:///org/gnome/shell/ui/main.js': Main,
      'resource:///org/gnome/shell/misc/config.js': {PACKAGE_VERSION: '47.1'},
    },

    /** Adds a window (on top of the stack) and focuses it. */
    addWindow({id, app, title = 'Window', frame}) {
      let shellApp = state.apps.find((a) => a.id === app.id);
      if (!shellApp) {
        shellApp = new FakeShellApp(app);
        state.apps.push(shellApp);
      }
      const window = new FakeMetaWindow({id, app: shellApp, title, frame});
      shellApp.windows.unshift(window);
      state.windows.unshift(window);
      state.focused = window;
      return window;
    },

    /** Presses a grabbed accelerator: Mutter emits accelerator-activated with its action. */
    press(accelerator) {
      for (const [action, grab] of state.grabs) {
        if (grab.accelerator === accelerator) {
          displaySignals.emit('accelerator-activated', action, null, 0);
          return true;
        }
      }
      return false;
    },

    /** What inotify would report after a file changed. */
    fileChanged(path) {
      for (const monitor of state.monitors.get(path) ?? []) monitor.signals.emit('changed', null, null, 1);
    },

    accelerators() {
      return [...state.grabs.values()].map((g) => g.accelerator).sort();
    },
  };
}
