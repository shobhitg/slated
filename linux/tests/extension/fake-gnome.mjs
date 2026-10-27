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

import {existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync, appendFileSync, accessSync, chmodSync, constants} from 'node:fs';
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
  get_monitor() {
    return this.monitor ?? 0;
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
    return this.wmClass ?? this.app?.id ?? 'unknown';
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

/** A Clutter/St actor: a tree with positions, signals, style pseudo classes and instant animations. */
export class FakeActor {
  constructor(props = {}) {
    Object.assign(this, {x: 0, y: 0, width: 0, height: 0, opacity: 255, visible: true}, props);
    this.children = [];
    this.parent = null;
    this.handlers = new Map();
    this.nextHandler = 1;
    this.pseudoClasses = new Set();
    this.destroyed = false;
  }
  add_child(child) {
    child.parent = this;
    this.children.push(child);
  }
  remove_child(child) {
    this.children = this.children.filter((c) => c !== child);
    child.parent = null;
  }
  set_child(child) {
    for (const c of [...this.children]) this.remove_child(c);
    this.add_child(child);
    this.child = child;
  }
  set_child_above_sibling() {}
  set_position(x, y) {
    this.x = x;
    this.y = y;
  }
  connect(signal, callback) {
    const id = this.nextHandler++;
    this.handlers.set(id, {signal, callback});
    return id;
  }
  disconnect(id) {
    this.handlers.delete(id);
  }
  /** Delivers an event the way Clutter does: to this actor, then up to its parents until stopped. */
  emit(signal, event) {
    for (let actor = this; actor; actor = actor.parent) {
      for (const {signal: s, callback} of [...actor.handlers.values()]) {
        if (s === signal && callback(actor, event) === true) return true;
      }
    }
    return false;
  }
  add_style_pseudo_class(name) {
    this.pseudoClasses.add(name);
  }
  remove_style_pseudo_class(name) {
    this.pseudoClasses.delete(name);
  }
  destroy_all_children() {
    for (const child of [...this.children]) child.destroy();
  }
  get_allocation_box() {
    return {x1: this.x, y1: this.y, x2: this.x + this.width, y2: this.y + this.height};
  }
  get_text() {
    return this.text ?? '';
  }
  set_text(text) {
    this.text = text;
  }
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    for (const child of [...this.children]) child.destroy();
    this.parent?.remove_child(this);
    this.handlers.clear();
  }
  ease(params) {
    for (const key of ['opacity', 'x', 'y']) if (key in params) this[key] = params[key];
    params.onComplete?.();
  }
  remove_all_transitions() {}
  grab_key_focus() {
    FakeActor.keyFocus = this;
  }
  show() {
    this.visible = true;
  }
  hide() {
    this.visible = false;
  }
  get_preferred_width() {
    return [0, this.width || 120];
  }
  get_preferred_height() {
    return [0, this.height || 36];
  }
  transform_stage_point(x, y) {
    let ox = 0;
    let oy = 0;
    for (let actor = this; actor; actor = actor.parent) {
      ox += actor.x;
      oy += actor.y;
    }
    return [true, x - ox, y - oy];
  }
  /** Every descendant matching `predicate`. */
  find(predicate) {
    const found = [];
    const visit = (actor) => {
      for (const child of actor.children) {
        if (predicate(child)) found.push(child);
        visit(child);
      }
    };
    visit(this);
    return found;
  }
}

/** A key or button event as the extension reads it. */
export function fakeEvent({keysym = 0, unicode = '', x = 0, y = 0, actor = null} = {}) {
  return {
    get_key_symbol: () => keysym,
    get_key_unicode: () => unicode,
    get_coords: () => [x, y],
    actor,
  };
}

export class FakeShellApp {
  constructor({id, name}) {
    this.id = id;
    this.name = name;
    this.windows = [];
  }
  create_icon_texture(size) {
    return new FakeActor({width: size, height: size, icon: this.id});
  }
  get_id() {
    // GNOME names apps without a desktop file "window:<n>", after their first window.
    return this.is_window_backed() ? this.id : `${this.id}.desktop`;
  }
  get_name() {
    return this.name;
  }
  is_window_backed() {
    return String(this.id).startsWith('window:');
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
  const overviewSignals = new Signals();
  // D-Bus signals on the system bus, by "interface.member" (Gio.DBusConnection.signal_subscribe), and
  // method calls, recorded in `state.dbusCalls` and answered on the next main-loop turn.
  const systemBusSignals = new Signals();
  const systemBus = {
    signal_subscribe(sender, iface, member, path, _arg0, _flags, callback) {
      return systemBusSignals.connect(`${iface}.${member}`, (_signals, parameters) => callback(systemBus, sender, path, iface, member, parameters));
    },
    signal_unsubscribe: (id) => systemBusSignals.disconnect(id),
    call(name, path, iface, method, _parameters, _replyType, _flags, _timeout, cancellable, callback) {
      state.dbusCalls.push(`${iface}.${method}`);
      if (callback) loop.add(0, () => callback(systemBus, {cancellable}));
    },
    call_finish(result) {
      if (result.cancellable?.cancelled) throw new Error('Operation was cancelled');
      return null;
    },
  };

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
    find_program_in_path: (name) => state.programs?.[name] ?? null,
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
    monitor_directory() {
      return new FakeMonitor(this.path);
    }
    enumerate_children() {
      const names = readdirSync(this.path);
      return {next_file: () => (names.length ? {get_name: () => names.shift()} : null), close: () => true};
    }
    replace_contents(bytes, _etag, _backup, flags) {
      mkdirSync(dirname(this.path), {recursive: true});
      writeFileSync(this.path, bytes, {mode: flags & 1 ? 0o600 : 0o644});
      return [true, null];
    }
    set_attribute_uint32(attribute, value) {
      if (attribute !== 'unix::mode') throw new Error(`unsupported attribute ${attribute}`);
      chmodSync(this.path, value);
      return true;
    }
  }

  const Gio = {
    File: {new_for_path: (path) => new FakeFile(path)},
    FileCreateFlags: {NONE: 0, PRIVATE: 1, REPLACE_DESTINATION: 2},
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
      get_boolean(key) {
        const value = state.settings[`${this.schema}:${key}`];
        if (value === undefined) throw new Error(`no boolean ${this.schema}:${key} in the fake`);
        return value;
      }
      get_uint(key) {
        const value = state.settings[`${this.schema}:${key}`];
        if (value === undefined) throw new Error(`no uint ${this.schema}:${key} in the fake`);
        return value;
      }
    },
    SettingsSchemaSource: {get_default: () => ({lookup: () => null})},
    // Off unless a test sets `state.subprocesses = []`: then each process is recorded there and ends
    // when the test calls its `exit(successful)`.
    Subprocess: {
      new(argv) {
        if (!state.subprocesses) throw new Error('no subprocesses in tests');
        const proc = {
          argv,
          cancellable: null,
          callback: null,
          successful: false,
          wait_async(cancellable, callback) {
            this.cancellable = cancellable;
            this.callback = callback;
          },
          wait_finish() {
            if (this.cancellable?.cancelled) throw new Error('Operation was cancelled');
            return true;
          },
          get_successful() {
            return this.successful;
          },
          exit(successful) {
            this.successful = successful;
            this.callback?.(this, null);
          },
        };
        state.subprocesses.push(proc);
        return proc;
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
    DBus: {session: {}, system: systemBus},
    DBusSignalFlags: {NONE: 0},
    DBusCallFlags: {NONE: 0},
  };

  const Meta = {
    KeyBindingFlags: {NONE: 0, IGNORE_AUTOREPEAT: 16},
    KeyBindingAction: {NONE: 0},
    external_binding_name_for_action: (action) => `external-grab-${action}`,
    WindowType: {NORMAL: 0, DESKTOP: 1, DOCK: 2, DIALOG: 3, MODAL_DIALOG: 4, TOOLBAR: 5, MENU: 6, UTILITY: 7},
    MaximizeFlags: {HORIZONTAL: 1, VERTICAL: 2, BOTH: 3},
    SelectionType: {SELECTION_PRIMARY: 0, SELECTION_CLIPBOARD: 1, SELECTION_DND: 2},
    is_wayland_compositor: () => true,
  };

  // The clipboard: Meta.Selection reports new owners, St.Clipboard reads and writes text.
  const selectionSignals = new Signals();
  const selection = {
    connect: (signal, callback) => selectionSignals.connect(signal, callback),
    disconnect: (id) => selectionSignals.disconnect(id),
    get_mimetypes: (type) => (type === 1 ? [...state.clipboardMimeTypes] : []),
  };
  const clipboard = {
    get_text: (_type, callback) => callback(clipboard, state.clipboard ?? null),
    set_text: (_type, text) => {
      state.clipboard = text;
      state.clipboardMimeTypes = ['text/plain;charset=utf-8'];
      state.clipboardWrites.push(text);
      selectionSignals.emit('owner-changed', 1, null);
    },
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

  class Widget extends FakeActor {}
  class Label extends FakeActor {}
  const St = {
    Widget,
    Label,
    Bin: class extends FakeActor {
      constructor(props = {}) {
        super(props);
        if (props.child) this.set_child(props.child);
      }
    },
    BoxLayout: class extends FakeActor {},
    Icon: class extends FakeActor {},
    Button: class extends FakeActor {
      constructor(props = {}) {
        super({hover: false, ...props});
      }
    },
    ScrollView: class extends FakeActor {
      constructor(props = {}) {
        super(props);
        this.vadjustment = {value: 0, page_size: 400};
      }
    },
    Entry: class extends FakeActor {
      constructor(props = {}) {
        super(props);
        this.clutter_text = new FakeActor({text: ''});
        this.clutter_text.entry = this;
      }
      get_text() {
        return this.clutter_text.text;
      }
      set_text(text) {
        this.clutter_text.text = text;
        this.clutter_text.emit('text-changed');
      }
    },
    ClipboardType: {PRIMARY: 0, CLIPBOARD: 1},
    Clipboard: {get_default: () => clipboard},
  };
  const Clutter = {
    BinLayout: class {},
    ActorAlign: {FILL: 0, START: 1, END: 2, CENTER: 3},
    EVENT_STOP: true,
    EVENT_PROPAGATE: false,
    KEY_Escape: 0xff1b,
    GrabState: {NONE: 0, POINTER: 1, KEYBOARD: 2, ALL: 3},
    AnimationMode: {EASE_OUT_QUAD: 2},
    keysym_to_unicode: (keysym) => (keysym < 0x100 ? keysym : 0),
    InputDeviceType: {POINTER_DEVICE: 0, KEYBOARD_DEVICE: 1},
    KeyState: {RELEASED: 0, PRESSED: 1},
    ButtonState: {RELEASED: 0, PRESSED: 1},
    ModifierType: {SHIFT_MASK: 1, CONTROL_MASK: 4, MOD1_MASK: 8, MOD4_MASK: 64, SUPER_MASK: 1 << 26, HYPER_MASK: 1 << 27, META_MASK: 1 << 28},
    get_default_backend: () => ({
      get_default_seat: () => ({
        create_virtual_device: (type) =>
          type === 0
            ? {
                notify_button: (time, button, buttonState) => state.buttons.push({button, pressed: buttonState === 1, time}),
                run_dispose() {
                  state.disposed.push('pointer');
                },
              }
            : {
                notify_keyval: (time, keysym, keyState) => state.typed.push({keysym, pressed: keyState === 1}),
                notify_key: (time, code, keyState) => state.typed.push({code, pressed: keyState === 1}),
                run_dispose() {
                  state.disposed.push('keyboard');
                },
              },
      }),
    }),
  };
  state.chrome = new Set();
  state.dbusCalls = [];
  state.modal = [];
  state.typed = [];
  state.buttons = [];
  state.disposed = [];
  state.clipboard = null;
  state.clipboardMimeTypes = [];
  state.clipboardWrites = [];
  state.inputSource = {type: 'xkb', id: 'us', xkbId: 'us'};
  const uiGroup = new FakeActor();

  const global = {
    display: {
      get_n_monitors: () => screens.length,
      get_primary_monitor: () => screens.findIndex((s) => s.isMain),
      get_monitor_geometry: (i) => ({...screens[i].frame}),
      get_monitor_scale: () => 1,
      get_focus_window: () => state.focused,
      get_selection: () => selection,
      get_current_monitor: () => 0,
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
    stage: {width: 3000, height: 1920, get_event_actor: (event) => event.actor},
    // The modifiers held on the real keyboard (Clutter.ModifierType bits): `state.modifiers`.
    get_pointer: () => [0, 0, state.modifiers ?? 0],
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
      addTopChrome: (actor) => state.chrome.add(actor),
      removeChrome: (actor) => state.chrome.delete(actor),
    },
    uiGroup,
    overview: {
      get visible() {
        return !!state.overview;
      },
      connect: (signal, callback) => overviewSignals.connect(signal, callback),
      disconnect: (id) => overviewSignals.disconnect(id),
    },
    sessionMode: {
      get isLocked() {
        return state.locked;
      },
    },
    activateWindow(window) {
      state.focused = window;
    },
    pushModal(actor, params) {
      state.modal.push({actor, params});
      return {get_seat_state: () => 3};
    },
    popModal() {
      state.modal.pop();
    },
  };

  return {
    state,
    loop,
    global,
    signals: {
      display: displaySignals, tracker: trackerSignals, appSystem: appSystemSignals, layout: layoutSignals, selection: selectionSignals,
      overview: overviewSignals, systemBus: systemBusSignals,
    },

    /** Opens or closes the overview, as GNOME Shell's Main.overview reports it. */
    overview(visible) {
      state.overview = visible;
      overviewSignals.emit(visible ? 'showing' : 'hidden');
    },

    /** A signal on the system bus ("interface.member") with these values (a GLib.Variant's deep_unpack). */
    systemSignal(name, values) {
      systemBusSignals.emit(name, {deep_unpack: () => values});
    },

    /** logind announces a suspend (true) or the wake-up after it (false): PrepareForSleep(b). */
    prepareForSleep(start) {
      this.systemSignal('org.freedesktop.login1.Manager.PrepareForSleep', [start]);
    },
    modules: {
      'gi://GLib': GLib,
      'gi://Gio': Gio,
      'gi://Meta': Meta,
      'gi://Shell': Shell,
      'gi://St': St,
      'gi://Clutter': Clutter,
      'resource:///org/gnome/shell/ui/main.js': Main,
      'resource:///org/gnome/shell/misc/config.js': {PACKAGE_VERSION: '47.1'},
      'resource:///org/gnome/shell/ui/status/keyboard.js': {getInputSourceManager: () => ({currentSource: state.inputSource})},
    },

    /** Adds a window (on top of the stack) and focuses it, telling focus watchers. */
    addWindow({id, app, title = 'Window', frame, wmClass}) {
      let shellApp = state.apps.find((a) => a.id === app.id);
      if (!shellApp) {
        shellApp = new FakeShellApp(app);
        state.apps.push(shellApp);
      }
      const window = new FakeMetaWindow({id, app: shellApp, title, frame});
      if (wmClass) window.wmClass = wmClass;
      shellApp.windows.unshift(window);
      state.windows.unshift(window);
      state.focused = window;
      displaySignals.emit('notify::focus-window');
      return window;
    },

    /** Focuses a window (or nothing: the overview), as Mutter reports it. */
    focus(window) {
      state.focused = window;
      displaySignals.emit('notify::focus-window');
    },

    /** Another app copies something: a new clipboard owner with these MIME types. */
    copy(text, mimeTypes = ['text/plain;charset=utf-8', 'UTF8_STRING']) {
      state.clipboard = text;
      state.clipboardMimeTypes = [...mimeTypes];
      selectionSignals.emit('owner-changed', 1, {});
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
