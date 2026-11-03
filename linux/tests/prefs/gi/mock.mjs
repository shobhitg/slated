// Mock GObject-introspection namespaces for running the preferences UI (lib/prefs/ui) under Node.
//
// Gtk, Gdk, Adw, Pango and PangoCairo are generated from api.json (the GIR of the oldest supported
// libraries: GTK 4.14 and libadwaita 1.5, GNOME 46). Every class, constructor, method, property,
// signal, enum member and function the UI touches is checked against it, and calls must pass every
// argument GJS requires. API that only newer libraries have (up to GTK 4.20 and libadwaita 1.8,
// GNOME 49) is reachable only after an `'name' in object` check, and in "min" mode it doesn't exist
// at all, so the fallbacks run. Deprecated API is recorded. Removing a widget that isn't a child, or
// adding one that already has a parent, fails like a GTK critical would. A press (world.press) runs a
// window's controllers the way GTK walks them, so a handler that removes them mid-walk fails.
//
// GLib, Gio and GObject are small working fakes backed by a temporary home folder, so the real
// file, monitor and timer code in io.js runs too. Nothing here draws anything: widgets are plain
// objects that remember their properties, children and signal handlers, so a test can find them,
// emit their signals and assert on the result.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export class MockError extends Error {}

const kebab = name => name.replace(/_/g, '-').replace(/[A-Z]/g, c => `-${c.toLowerCase()}`);
const parseInfo = info => {
  const [sig, nargs] = info.split('/');
  const [ret, outs] = sig.split('+');
  return {ret, outs: Number(outs ?? 0), nargs: Number(nargs ?? 0)};
};

// Members every GObject has in GJS (from GObject.Object and GJS itself).
const OBJECT_METHODS = {
  connect: 'n/2', connect_after: 'n/2', disconnect: 'v/1', emit: '?/1', notify: 'v/1', bind_property: '?/4',
  get_property: '?/1', set_property: 'v/2', freeze_notify: 'v/0', thaw_notify: 'v/0', block_signal_handler: 'v/1',
  unblock_signal_handler: 'v/1', stop_emission_by_name: 'v/1', is_floating: 'b/0', ref: '?/0', unref: 'v/0',
  run_dispose: 'v/0', get_data: '?/1', set_data: 'v/2',
};
const BASE_CLASSES = {
  'GObject.Object': {kind: 'class', methods: OBJECT_METHODS, signals: ['notify']},
  'GObject.InitiallyUnowned': {kind: 'class', parent: 'GObject.Object'},
  'Gio.ListModel': {kind: 'interface', methods: {get_n_items: 'n/0', get_item: '?/1', get_item_type: 'n/0', items_changed: 'v/3'}, signals: ['items-changed']},
  'Gio.ActionGroup': {kind: 'interface', methods: {list_actions: 'a/0', has_action: 'b/1', activate_action: 'v/2'}, signals: ['action-added', 'action-removed']},
  'Gio.ActionMap': {kind: 'interface', methods: {add_action: 'v/1', lookup_action: '?/1', remove_action: 'v/1'}},
  'Gio.Icon': {kind: 'interface', methods: {to_string: 's/0'}},
  'Gio.LoadableIcon': {kind: 'interface'},
};

// Methods that put a widget into another (the slot name groups replace-style setters).
const CHILD_METHODS = {
  append: 'list', prepend: 'list', add: 'list', add_named: 'list', add_titled: 'list', add_prefix: 'list',
  add_suffix: 'list', add_row: 'list', add_top_bar: 'list', add_bottom_bar: 'list', add_overlay: 'list',
  pack_start: 'list', pack_end: 'list', insert_child_after: 'list', add_controller: 'controller',
  set_child: 'child', set_content: 'content', set_title_widget: 'title-widget', set_header_suffix: 'header-suffix',
  set_sidebar: 'sidebar', set_extra_child: 'extra-child', set_popover: 'popover', set_header: 'header',
  set_start_widget: 'start-widget', set_end_widget: 'end-widget', set_center_widget: 'center-widget',
};
const CHILD_PROPS = new Set(['child', 'content', 'title-widget', 'header-suffix', 'sidebar', 'extra-child', 'popover',
  'start-widget', 'center-widget', 'end-widget']);
const REMOVE_METHODS = new Set(['remove', 'remove_controller']);

// GJS's Cairo.Context methods the UI may call.
const CAIRO_METHODS = new Set([
  'moveTo', 'lineTo', 'curveTo', 'relMoveTo', 'relLineTo', 'arc', 'arcNegative', 'rectangle', 'closePath', 'newPath',
  'newSubPath', 'fill', 'fillPreserve', 'stroke', 'strokePreserve', 'paint', 'paintWithAlpha', 'clip', 'clipPreserve',
  'resetClip', 'save', 'restore', 'translate', 'scale', 'rotate', 'setSourceRGB', 'setSourceRGBA', 'setSource',
  'setLineWidth', 'setDash', 'setLineCap', 'setLineJoin', 'setOperator', 'selectFontFace', 'setFontSize', 'showText',
  'textExtents', 'getTarget', '$dispose',
]);

/**
 * Creates the mock world.
 *
 * @param {object} options
 * @param {object} options.api the parsed api.json
 * @param {string} options.home the fake home folder (must exist)
 * @param {"min"|"new"} [options.mode] "min": newer API doesn't exist; "new": it exists behind `in` checks
 * @param {(method: string, params: any) => any} [options.dbus] answers D-Bus calls (throw to fail them)
 */
export function createWorld({api, home, mode = 'min', env = {}, dbus = () => {
  throw new Error('GNOME Shell is not running');
}}) {
  // markupRows: rows created with Pango markup on (libadwaita's default), where user text like "a & b" breaks.
  const report = {deprecated: new Set(), toasts: [], dialogs: [], launches: [], clipboard: [], guards: new Set(), drawn: 0, markupRows: []};
  const deprecated = new Set(Object.entries(api.deprecated).flatMap(([ns, list]) => list.map(item => `${ns}.${item}`)));
  const NAMESPACES = api.namespaces;
  let objectIds = 0;

  // --- Classes -----------------------------------------------------------------------------------

  function classEntry(qualified) {
    if (BASE_CLASSES[qualified]) return {entry: BASE_CLASSES[qualified], newer: false};
    const [ns, name] = qualified.split('.');
    const entry = NAMESPACES[ns]?.classes?.[name];
    if (entry) return {entry, newer: false};
    const newerEntry = api.newer[ns]?.classes?.[name];
    if (newerEntry) return {entry: newerEntry, newer: true};
    return null;
  }

  function* ancestry(qualified, seen = new Set()) {
    if (!qualified || seen.has(qualified)) return;
    seen.add(qualified);
    const found = classEntry(qualified);
    if (!found) return;
    yield [qualified, found.entry];
    for (const iface of found.entry.implements ?? []) yield* ancestry(iface, seen);
    for (const pre of found.entry.prerequisites ?? []) yield* ancestry(pre, seen);
    if (found.entry.parent) yield* ancestry(found.entry.parent, seen);
    else if (found.entry.kind === 'class' && qualified !== 'GObject.Object') yield* ancestry('GObject.Object', seen);
  }

  /** Finds a method or property on a class (with ancestors and interfaces), including newer API. */
  function resolve(qualified, name, extra = []) {
    const propName = kebab(name);
    for (const root of [qualified, ...extra]) {
      for (const [owner, entry] of ancestry(root)) {
        const [ns, cls] = owner.split('.');
        if (entry.methods?.[name]) return {kind: 'method', info: entry.methods[name], owner, newer: false};
        if (entry.props?.[propName]) return {kind: 'prop', info: entry.props[propName], owner, name: propName, newer: false};
        if (entry.fields?.includes(name)) return {kind: 'field', owner, newer: false};
        const added = api.newer[ns]?.members?.[cls];
        if (added?.methods?.[name]) return {kind: 'method', info: added.methods[name], owner, newer: true};
        if (added?.props?.[propName]) return {kind: 'prop', info: added.props[propName], owner, name: propName, newer: true};
      }
    }
    return null;
  }

  function signalsOf(qualified, extra = []) {
    const out = new Set(['notify']);
    for (const root of [qualified, ...extra]) {
      for (const [owner, entry] of ancestry(root)) {
        for (const s of entry.signals ?? []) out.add(s);
        const [ns, cls] = owner.split('.');
        for (const s of api.newer[ns]?.members?.[cls]?.signals ?? []) out.add(s);
      }
    }
    return out;
  }

  function isA(qualified, base) {
    for (const [owner] of ancestry(qualified)) if (owner === base) return true;
    return false;
  }

  function noteDeprecated(owner, name) {
    if (deprecated.has(`${owner}.${name}`)) report.deprecated.add(`${owner}.${name}`);
  }

  // --- Instances ---------------------------------------------------------------------------------

  const states = new WeakMap();
  const stateOf = object => states.get(object);
  // The controller a press is being delivered to, and the controllers removed meanwhile (see press()).
  let dispatching = null;

  function defaultValue(code, owner, self, cacheKey) {
    switch (code) {
    case 'v': return undefined;
    case 'b': return false;
    case 'n': return 0;
    case 's': return '';
    case 'a': return [];
    case '?': return null;
    default: {
      if (!code || !code.includes('.')) return null;
      const state = stateOf(self);
      if (state && cacheKey) {
        state.cache[cacheKey] ??= instantiateDefault(code);
        return state.cache[cacheKey];
      }
      return instantiateDefault(code);
    }
    }
  }

  function instantiateDefault(qualified) {
    const found = classEntry(qualified);
    if (!found) return null;
    if (found.entry.kind === 'interface') {
      // An object of some class implementing the interface.
      return instantiate('GObject.Object', {}, {extra: [qualified], internal: true});
    }
    return instantiate(qualified, {}, {internal: true});
  }

  function attach(parent, child, slot) {
    if (child === null || child === undefined || !stateOf(child)) return;
    const c = stateOf(child);
    const p = stateOf(parent);
    if (slot !== 'list' && slot !== 'controller') {
      const previous = p.slots[slot];
      if (previous === child) return;
      if (previous) detach(parent, previous);
      p.slots[slot] = child;
    }
    if (slot === 'controller') {
      p.controllers.push(child);
      c.parent = parent;
      return;
    }
    if (c.parent && c.parent !== parent) {
      throw new MockError(`Adding a ${c.cls} to a ${p.cls}, but it's already inside a ${stateOf(c.parent).cls} (a GTK critical)`);
    }
    if (c.parent === parent && p.children.includes(child)) {
      throw new MockError(`Adding a ${c.cls} to a ${p.cls} twice (a GTK critical)`);
    }
    c.parent = parent;
    p.children.push(child);
  }

  function detach(parent, child) {
    const p = stateOf(parent);
    const c = stateOf(child);
    if (!c) throw new MockError(`remove() of something that isn't a widget on ${p.cls}`);
    if (c.parent !== parent) throw new MockError(`remove() of a ${c.cls} that isn't a child of this ${p.cls} (a GTK critical)`);
    if (p.controllers.includes(child)) {
      if (dispatching?.widget === parent) dispatching.removed.add(child);
      p.controllers = p.controllers.filter(x => x !== child);
    } else {
      p.children = p.children.filter(x => x !== child);
      for (const slot of Object.keys(p.slots)) if (p.slots[slot] === child) delete p.slots[slot];
    }
    c.parent = null;
  }

  function emit(object, signal, ...args) {
    const state = stateOf(object);
    let result;
    for (const handler of [...(state.handlers.get(signal) ?? []).values()]) {
      if (handler.blocked) continue;
      result = handler.fn(object, ...args);
    }
    return result;
  }

  function setProp(object, state, resolved, value, {construct = false} = {}) {
    const flags = resolved.info.includes('!') ? resolved.info.slice(resolved.info.indexOf('!') + 1) : '';
    if (flags === 'r') throw new MockError(`${state.cls}.${resolved.name} is read-only`);
    if (flags === 'c' && !construct) throw new MockError(`${state.cls}.${resolved.name} can only be set at construction`);
    noteDeprecated(resolved.owner, resolved.name);
    const before = state.props.get(resolved.name);
    if (CHILD_PROPS.has(resolved.name)) {
      if (value) attach(object, value, resolved.name);
      else if (state.slots[resolved.name]) detach(object, state.slots[resolved.name]);
    }
    state.props.set(resolved.name, value);
    if (before !== value && !construct) emit(object, `notify::${resolved.name}`);
    hooks.onSet?.(object, state, resolved.name, value);
  }

  function getProp(object, state, resolved) {
    noteDeprecated(resolved.owner, resolved.name);
    if (state.props.has(resolved.name)) return state.props.get(resolved.name);
    const code = resolved.info.split('!')[0];
    if (code === 's') return '';
    return defaultValue(code, resolved.owner, object, `prop:${resolved.name}`);
  }

  function guardKey(object, name) {
    return `${stateOf(object)?.id ?? 'ns'}:${name}`;
  }

  function instantiate(qualified, props = {}, {extra = [], internal = false} = {}) {
    const found = classEntry(qualified);
    if (!found) throw new MockError(`No class ${qualified}`);
    if (!internal && found.entry.abstract) throw new MockError(`${qualified} is abstract`);
    const state = {
      id: ++objectIds, cls: qualified, extra, props: new Map(), handlers: new Map(), nextHandler: 1, children: [],
      controllers: [], slots: {}, parent: null, expandos: {}, cache: {}, data: {},
    };
    const target = {};
    let proxy;
    const handler = {
      get(_t, name) {
        if (typeof name === 'symbol') return undefined;
        if (name === 'then' || name === 'toJSON') return undefined;
        if (name === 'toString') return () => `[mock ${qualified} ${state.id}]`;
        if (Object.prototype.hasOwnProperty.call(state.expandos, name)) return state.expandos[name];
        const resolved = resolve(qualified, name, extra);
        if (resolved) {
          if (resolved.newer) {
            if (mode === 'min') throw new MockError(`${resolved.owner}.${name} doesn't exist on GNOME 46 (${api.versions.minimum})`);
            if (!report.guards.has(guardKey(proxy, name))) {
              throw new MockError(`${resolved.owner}.${name} is newer than GNOME 46: check \`'${name}' in object\` first`);
            }
          }
          if (resolved.kind === 'method') return (...args) => callMethod(proxy, state, name, resolved, args);
          if (resolved.kind === 'prop') return getProp(proxy, state, resolved);
          if (resolved.kind === 'field') return state.props.get(name) ?? 0;
        }
        if (name.startsWith('_')) return undefined; // a private expando read before it's set
        throw new MockError(`${qualified} has no method or property "${name}" in ${api.versions.minimum}`);
      },
      set(_t, name, value) {
        const resolved = typeof name === 'string' ? resolve(qualified, name, extra) : null;
        if (resolved?.kind === 'prop') {
          setProp(proxy, state, resolved, value);
          return true;
        }
        if (resolved?.kind === 'field') {
          state.props.set(name, value);
          return true;
        }
        if (resolved?.kind === 'method') throw new MockError(`Assigning to the method ${qualified}.${name}`);
        state.expandos[name] = value;
        return true;
      },
      has(_t, name) {
        if (typeof name !== 'string') return false;
        if (Object.prototype.hasOwnProperty.call(state.expandos, name)) return true;
        const resolved = resolve(qualified, name, extra);
        if (!resolved) return false;
        if (resolved.newer) {
          if (mode === 'min') return false;
          report.guards.add(guardKey(proxy, name));
        }
        return true;
      },
    };
    proxy = new Proxy(target, handler);
    states.set(proxy, state);
    for (const [key, value] of Object.entries(props ?? {})) {
      const resolved = resolve(qualified, key, extra);
      if (!resolved || resolved.kind !== 'prop') throw new MockError(`new ${qualified}(): no property "${key}"`);
      if (resolved.newer && mode === 'min') throw new MockError(`new ${qualified}(): "${key}" doesn't exist on GNOME 46`);
      setProp(proxy, state, resolved, value, {construct: true});
    }
    hooks.onCreate?.(proxy, state);
    return proxy;
  }

  function callMethod(object, state, name, resolved, args) {
    const info = parseInfo(resolved.info);
    if (args.length < info.nargs) {
      throw new MockError(`Too few arguments to ${resolved.owner}.${name}: GJS needs ${info.nargs}, got ${args.length}`);
    }
    noteDeprecated(resolved.owner, name);
    const override = overrides[`${resolved.owner}.${name}`] ?? overrides[`*.${name}`];
    if (override) {
      const result = override(object, state, args, info);
      if (result !== NEXT) return result;
    }
    if (name === 'connect' || name === 'connect_after') {
      const [signal, fn] = args;
      const [base, detail] = String(signal).split('::');
      const known = signalsOf(state.cls, state.extra);
      if (base === 'notify' && detail) {
        const prop = resolve(state.cls, detail, state.extra);
        if (!prop || prop.kind !== 'prop') throw new MockError(`${state.cls} has no property "${detail}" to watch with notify::`);
        if (prop.newer && mode === 'min') throw new MockError(`notify::${detail} doesn't exist on GNOME 46`);
      } else if (!known.has(base)) {
        throw new MockError(`${state.cls} has no signal "${signal}"`);
      }
      if (typeof fn !== 'function') throw new MockError(`connect("${signal}") needs a function`);
      const id = state.nextHandler++;
      if (!state.handlers.has(signal)) state.handlers.set(signal, new Map());
      state.handlers.get(signal).set(id, {fn, blocked: false});
      return id;
    }
    if (name === 'disconnect') {
      for (const map of state.handlers.values()) map.delete(args[0]);
      return undefined;
    }
    if (name === 'emit') return emit(object, ...args);
    if (name === 'notify') return emit(object, `notify::${kebab(args[0])}`);
    if (CHILD_METHODS[name]) {
      const child = name === 'insert_child_after' ? args[0] : name === 'add_titled' || name === 'add_named' ? args[0] : args[0];
      attach(object, child, CHILD_METHODS[name]);
      if (name === 'add_named') stateOf(child).data.stackName = args[1];
      if (CHILD_METHODS[name] !== 'list' && CHILD_METHODS[name] !== 'controller') state.props.set(CHILD_METHODS[name], child);
      return name === 'add_named' || name === 'add_titled' ? instantiate('Gtk.StackPage', {}, {internal: true}) : undefined;
    }
    if (REMOVE_METHODS.has(name)) {
      detach(object, args[0]);
      return undefined;
    }
    if (name.startsWith('set_')) {
      const prop = resolve(state.cls, name.slice(4), state.extra);
      if (prop?.kind === 'prop') {
        setProp(object, state, prop, args[0]);
        return undefined;
      }
    }
    if (name.startsWith('get_')) {
      const prop = resolve(state.cls, name.slice(4), state.extra);
      if (prop?.kind === 'prop') return getProp(object, state, prop);
    }
    return result(info, object, `method:${name}`);
  }

  function result(info, object, cacheKey) {
    const value = defaultValue(info.ret, null, object, cacheKey);
    if (!info.outs) return value;
    const outs = Array.from({length: info.outs}, () => 0);
    if (info.ret === 'v') return info.outs === 1 ? outs[0] : outs;
    return [value, ...outs];
  }

  // --- Behavior the UI relies on -------------------------------------------------------------------

  const NEXT = Symbol('next');
  const singletons = {};
  const keyNames = {...(env.keyNames ?? {})};
  const hooks = {};

  function navigationStack(view) {
    const state = stateOf(view);
    state.stack ??= [];
    return state.stack;
  }

  function show(page) {
    if (!page) return;
    emit(page, 'showing');
    emit(page, 'shown');
  }

  function hide(page) {
    if (!page) return;
    emit(page, 'hiding');
    emit(page, 'hidden');
  }

  function textChanged(object, state, text) {
    const before = state.props.get('text') ?? '';
    state.props.set('text', text ?? '');
    if (before !== (text ?? '')) {
      emit(object, 'notify::text');
      emit(object, 'changed');
      if (isA(state.cls, 'Gtk.SearchEntry')) emit(object, 'search-changed');
    }
  }

  const overrides = {
    'Gtk.Editable.set_text': (object, state, [text]) => textChanged(object, state, text),
    'Gtk.Editable.get_text': (object, state) => state.props.get('text') ?? '',
    'Gtk.Editable.get_position': () => 0,
    'Gtk.Editable.set_position': () => undefined,
    'Gtk.TextBuffer.set_text': (object, state, [text]) => {
      state.props.set('text', text);
      emit(object, 'changed');
    },
    // As GObject does: a property's current value (a text buffer's text, which TextView fields read).
    'GObject.Object.get_property': (object, state, [name]) => (state.props.has(name) ? state.props.get(name) : null),
    'Gtk.TextView.get_buffer': (object, state) => {
      state.cache.buffer ??= instantiate('Gtk.TextBuffer');
      return state.cache.buffer;
    },
    'Gtk.StringList.new': (_o, _s, [strings]) => {
      const list = instantiate('Gtk.StringList', {}, {internal: true});
      stateOf(list).items = [...strings];
      return list;
    },
    'Gtk.StringList.get_n_items': (o, state) => (state.items ?? []).length,
    'Gio.ListModel.get_n_items': (o, state) => (state.items ?? []).length,
    'Gio.ListModel.get_item': (o, state, [i]) => (state.items ?? [])[i] ?? null,
    'Gtk.StringList.splice': (o, state, [position, removals, additions]) => {
      state.items ??= [];
      state.items.splice(position, removals, ...(additions ?? []));
    },
    'Gtk.StringList.append': (o, state, [text]) => {
      (state.items ??= []).push(text);
    },
    'Gtk.StringList.get_string': (o, state, [i]) => (state.items ?? [])[i] ?? null,
    'Gtk.SpinButton.new_with_range': (_o, _s, [min, max, step]) => instantiate('Gtk.SpinButton', {}, {internal: true}),
    'Gtk.SpinButton.set_value': (object, state, [value]) => {
      const before = state.props.get('value');
      state.props.set('value', value);
      if (before !== value) emit(object, 'value-changed');
    },
    'Gtk.Scale.new_with_range': (_o, _s, [_orientation, min, max]) => {
      const scale = instantiate('Gtk.Scale', {}, {internal: true});
      stateOf(scale).range = [min, max];
      return scale;
    },
    'Gtk.Range.set_value': (object, state, [value]) => {
      const [min, max] = state.range ?? [-Infinity, Infinity];
      const next = Math.min(Math.max(value, min), max);
      const before = state.rangeValue;
      state.rangeValue = next;
      if (before !== next) emit(object, 'value-changed');
    },
    'Gtk.Range.get_value': (_o, state) => state.rangeValue ?? 0,
    'Adw.SpinRow.new_with_range': (_o, _s, [min, max]) => {
      const row = instantiate('Adw.SpinRow', {}, {internal: true});
      stateOf(row).range = [min, max];
      return row;
    },
    'Gtk.DrawingArea.set_draw_func': (object, state, [fn]) => {
      state.drawFunc = fn;
      draw(object);
    },
    'Gtk.Widget.queue_draw': object => {
      draw(object);
    },
    'Gtk.Widget.get_root': object => root(object),
    // What's under the pointer: the target of the press being delivered (see press()).
    'Gtk.Widget.pick': (o, state) => state.picked ?? NEXT,
    'Gtk.Widget.is_ancestor': (o, state, [ancestor]) => {
      for (let p = state.parent; p; p = stateOf(p).parent) if (p === ancestor) return true;
      return false;
    },
    'Gtk.Widget.get_native': object => root(object),
    'Gtk.Widget.get_width': () => 320,
    'Gtk.Widget.get_height': () => 200,
    'Gtk.Widget.get_parent': (o, state) => state.parent,
    'Gtk.Widget.get_first_child': (o, state) => state.children[0] ?? null,
    'Gtk.Widget.get_next_sibling': (o, state) => {
      const parent = state.parent && stateOf(state.parent);
      if (!parent) return null;
      const i = parent.children.indexOf(o);
      return parent.children[i + 1] ?? null;
    },
    'Gtk.Widget.get_color': () => rgba(0.1, 0.1, 0.1, 1),
    'Gtk.Widget.get_clipboard': (o, state) => {
      state.cache.clipboard ??= instantiate('Gdk.Clipboard', {}, {internal: true});
      return state.cache.clipboard;
    },
    'Gdk.Clipboard.set': (o, s, [value]) => {
      report.clipboard.push(value);
    },
    'Gtk.Widget.create_pango_layout': () => instantiate('Pango.Layout', {}, {internal: true}),
    'Gtk.Widget.get_pango_context': (o, state) => {
      state.cache.pango ??= instantiate('Pango.Context', {}, {internal: true});
      return state.cache.pango;
    },
    'Gtk.Widget.grab_focus': () => true,
    'Gtk.Native.get_surface': (o, state) => {
      state.cache.surface ??= instantiate('Gdk.Surface', {}, {extra: ['Gdk.Toplevel'], internal: true});
      return state.cache.surface;
    },
    'Pango.Context.get_font_description': () => instantiate('Pango.FontDescription', {}, {internal: true}),
    'Pango.FontDescription.copy': () => instantiate('Pango.FontDescription', {}, {internal: true}),
    'Pango.FontDescription.get_size': () => 10 * 1024,
    'Pango.Layout.get_pixel_size': () => [60, 14],
    'Gdk.Display.get_default': () => (singletons.display ??= instantiate('Gdk.Display', {}, {internal: true})),
    'Gdk.Display.translate_key': (o, s, [keycode]) => [true, keycode, 0, 0, 0],
    'Adw.StyleManager.get_default': () => (singletons.styleManager ??= instantiate('Adw.StyleManager', {}, {internal: true})),
    'Adw.StyleManager.get_accent_color_rgba': () => rgba(0.2, 0.5, 0.9, 1),
    'Adw.BreakpointCondition.parse': () => instantiate('Adw.BreakpointCondition', {}, {internal: true}),
    'Adw.Breakpoint.add_setter': (o, s, [target, property]) => {
      const prop = resolve(stateOf(target).cls, property);
      if (!prop || prop.kind !== 'prop') throw new MockError(`Breakpoint setter for unknown property ${stateOf(target).cls}:${property}`);
    },
    'Adw.NavigationView.push': (view, state, [page]) => {
      const stack = navigationStack(view);
      if (stack.includes(page)) throw new MockError('Pushing a page that is already in the navigation stack');
      const previous = stack[stack.length - 1];
      if (!stateOf(page).parent) attach(view, page, 'list');
      stack.push(page);
      hide(previous);
      show(page);
      emit(view, 'pushed');
    },
    'Adw.NavigationView.add': (view, state, [page]) => {
      if (!stateOf(page).parent) attach(view, page, 'list');
    },
    'Adw.NavigationView.replace': (view, state, [pages]) => {
      const stack = navigationStack(view);
      const old = stack.splice(0, stack.length);
      for (const page of pages) {
        if (!stateOf(page).parent) attach(view, page, 'list');
        stack.push(page);
      }
      for (const page of old) if (!pages.includes(page)) hide(page);
      show(pages[pages.length - 1]);
    },
    'Adw.NavigationView.pop': view => {
      const stack = navigationStack(view);
      if (stack.length < 2) return false;
      const page = stack.pop();
      hide(page);
      show(stack[stack.length - 1]);
      emit(view, 'popped', page);
      return true;
    },
    'Adw.NavigationView.pop_to_page': (view, state, [target]) => {
      const stack = navigationStack(view);
      const index = stack.indexOf(target);
      if (index < 0) return false;
      while (stack.length > index + 1) {
        const page = stack.pop();
        hide(page);
        emit(view, 'popped', page);
      }
      show(target);
      return true;
    },
    'Adw.NavigationView.get_visible_page': view => {
      const stack = navigationStack(view);
      return stack[stack.length - 1] ?? null;
    },
    'Adw.NavigationView.get_previous_page': (view, state, [page]) => {
      const stack = navigationStack(view);
      const index = stack.indexOf(page);
      return index > 0 ? stack[index - 1] : null;
    },
    'Adw.NavigationView.get_navigation_stack': view => {
      const list = instantiate('GObject.Object', {}, {extra: ['Gio.ListModel'], internal: true});
      stateOf(list).items = [...navigationStack(view)];
      return list;
    },
    'Gtk.ListBox.select_row': (list, state, [row]) => {
      state.selected = row;
      emit(list, 'row-selected', row);
    },
    'Gtk.ListBox.get_selected_row': (list, state) => state.selected ?? null,
    'Gtk.ListBox.set_header_func': (list, state, [fn]) => {
      state.headerFunc = fn;
    },
    'Gtk.ListBox.append': (list, state, [row]) => {
      attach(list, row, 'list');
      state.headerFunc?.(row, state.children[state.children.length - 2] ?? null);
    },
    'Gtk.MenuButton.popup': (button, state) => {
      const popover = state.slots.popover ?? state.props.get('popover');
      if (popover) emit(popover, 'show');
    },
    'Gtk.Popover.popup': popover => {
      emit(popover, 'show');
    },
    'Gtk.Popover.popdown': popover => {
      emit(popover, 'closed');
    },
    'Adw.ToastOverlay.add_toast': (o, s, [toast]) => {
      report.toasts.push(stateOf(toast).props.get('title'));
    },
    'Adw.Dialog.present': dialog => {
      report.dialogs.push(dialog);
    },
    'Gtk.FileLauncher.launch': (launcher, state) => {
      report.launches.push({file: stateOf(state.props.get('file'))?.path ?? null, folder: false});
    },
    'Gtk.FileLauncher.open_containing_folder': (launcher, state) => {
      report.launches.push({file: stateOf(state.props.get('file'))?.path ?? null, folder: true});
    },
    'Gtk.UriLauncher.launch': (launcher, state) => {
      report.launches.push({uri: state.props.get('uri')});
    },
    'Gtk.Window.close': window => {
      if (emit(window, 'close-request') !== true) stateOf(window).closed = true;
    },
    'Gtk.Widget.add_css_class': (o, state, [name]) => {
      const classes = new Set(state.props.get('css-classes') ?? []);
      classes.add(name);
      state.props.set('css-classes', [...classes]);
    },
    'Gtk.Widget.remove_css_class': (o, state, [name]) => {
      state.props.set('css-classes', (state.props.get('css-classes') ?? []).filter(c => c !== name));
    },
    'Gtk.Widget.has_css_class': (o, state, [name]) => (state.props.get('css-classes') ?? []).includes(name),
    'Gtk.CheckButton.set_active': (object, state, [active]) => {
      const before = state.props.get('active') ?? false;
      state.props.set('active', active);
      if (before !== active) {
        emit(object, 'notify::active');
        emit(object, 'toggled');
      }
    },
    'Gtk.ToggleButton.set_active': (object, state, [active]) => {
      const before = state.props.get('active') ?? false;
      state.props.set('active', active);
      if (before !== active) {
        emit(object, 'notify::active');
        emit(object, 'toggled');
      }
    },
  };

  function rgba(red, green, blue, alpha) {
    const color = instantiate('Gdk.RGBA', {}, {internal: true});
    stateOf(color).props.set('red', red);
    stateOf(color).props.set('green', green);
    stateOf(color).props.set('blue', blue);
    stateOf(color).props.set('alpha', alpha);
    return color;
  }

  function root(object) {
    let current = object;
    while (current && stateOf(current)?.parent) current = stateOf(current).parent;
    return current && isA(stateOf(current).cls, 'Gtk.Window') ? current : null;
  }

  function draw(area) {
    const state = stateOf(area);
    if (!state.drawFunc) return;
    report.drawn++;
    state.drawFunc(area, cairoContext(), state.props.get('content-width') || 320, state.props.get('content-height') || 200);
  }

  // --- Namespaces ----------------------------------------------------------------------------------

  function makeCallable(owner, name, info, impl) {
    return (...args) => {
      const parsed = parseInfo(info);
      if (args.length < parsed.nargs) throw new MockError(`Too few arguments to ${owner}.${name}: GJS needs ${parsed.nargs}, got ${args.length}`);
      noteDeprecated(owner, name);
      const override = overrides[`${owner}.${name}`];
      if (override) return override(null, null, args, parsed);
      return impl ? impl(...args) : result(parsed, null, null);
    };
  }

  function makeClass(qualified) {
    const {entry} = classEntry(qualified);
    const ctor = function MockClass(props) {
      if (entry.abstract) throw new MockError(`${qualified} is abstract`);
      if (deprecated.has(qualified)) report.deprecated.add(qualified);
      const object = instantiate(qualified, props ?? {});
      if (isA(qualified, 'Adw.PreferencesRow') && stateOf(object).props.get('use-markup') !== false) report.markupRows.push(qualified);
      return object;
    };
    const statics = {...(entry.ctors ?? {}), ...(entry.functions ?? {})};
    return new Proxy(ctor, {
      construct(_t, args) {
        return ctor(...args);
      },
      apply() {
        throw new MockError(`${qualified} must be constructed with new`);
      },
      get(_t, name) {
        if (typeof name === 'symbol' || name === 'prototype') return ctor[name];
        if (name === '$gtype') return qualified;
        if (statics[name]) {
          return makeCallable(qualified, name, statics[name], () => {
            const parsed = parseInfo(statics[name]);
            if (entry.ctors?.[name]) return instantiate(qualified, {}, {internal: true});
            return result(parsed, null, null);
          });
        }
        throw new MockError(`${qualified} has no constructor or static function "${name}"`);
      },
      has(_t, name) {
        return Boolean(statics[name]);
      },
    });
  }

  function makeNamespace(ns) {
    const data = NAMESPACES[ns];
    const cache = {};
    const newer = api.newer[ns] ?? {classes: {}, functions: {}, enums: {}};
    const lookup = name => {
      if (data.classes[name]) return makeClass(`${ns}.${name}`);
      if (data.enums[name]) return makeEnum(ns, name, data.enums[name], newer.enums?.[name] ?? []);
      if (data.functions[name]) return makeCallable(ns, name, data.functions[name], functions[`${ns}.${name}`]);
      if (data.constants.includes(name)) return 1000 + data.constants.indexOf(name);
      return undefined;
    };
    return new Proxy({}, {
      get(_t, name) {
        if (typeof name === 'symbol' || name === 'then' || name === '__esModule') return undefined;
        if (name in cache) return cache[name];
        const value = lookup(name);
        if (value !== undefined) return (cache[name] = value);
        if (newer.classes?.[name] || newer.functions?.[name]) {
          if (mode === 'min') throw new MockError(`${ns}.${name} doesn't exist on GNOME 46 (${api.versions.minimum})`);
          if (!report.guards.has(`ns:${ns}.${name}`)) throw new MockError(`${ns}.${name} is newer than GNOME 46: check \`'${name}' in ${ns}\` first`);
          return newer.classes?.[name] ? makeClass(`${ns}.${name}`) : makeCallable(ns, name, newer.functions[name]);
        }
        throw new MockError(`${ns}.${name} doesn't exist in ${api.versions.minimum}`);
      },
      has(_t, name) {
        if (lookup(name) !== undefined) return true;
        if (newer.classes?.[name] || newer.functions?.[name]) {
          if (mode === 'min') return false;
          report.guards.add(`ns:${ns}.${name}`);
          return true;
        }
        return false;
      },
    });
  }

  function makeEnum(ns, name, members, newerMembers) {
    const values = {};
    members.forEach((m, i) => {
      values[m.toUpperCase()] = 2 ** Math.min(i, 30);
    });
    return new Proxy(values, {
      get(t, key) {
        if (typeof key === 'symbol') return undefined;
        if (key in t) {
          if (deprecated.has(`${ns}.${name}.${key.toLowerCase()}`)) report.deprecated.add(`${ns}.${name}.${key}`);
          return t[key];
        }
        if (newerMembers.map(m => m.toUpperCase()).includes(key)) {
          if (mode === 'min') throw new MockError(`${ns}.${name}.${key} doesn't exist on GNOME 46`);
          return 2 ** 30;
        }
        throw new MockError(`${ns}.${name} has no member ${key}`);
      },
    });
  }

  const functions = {
    'Gdk.keyval_name': keyval => keyNames[keyval]?.name ?? null,
    'Gdk.keyval_to_unicode': keyval => keyNames[keyval]?.char?.codePointAt(0) ?? 0,
    'Gdk.keyval_to_lower': keyval => keyval,
    'PangoCairo.create_layout': () => instantiate('Pango.Layout', {}, {internal: true}),
    'PangoCairo.show_layout': () => undefined,
  };

  // --- cairo ---------------------------------------------------------------------------------------

  function cairoContext() {
    return new Proxy({}, {
      get(_t, name) {
        if (typeof name === 'symbol') return undefined;
        if (CAIRO_METHODS.has(name)) return () => undefined;
        throw new MockError(`Cairo.Context has no method "${name}" in GJS`);
      },
    });
  }

  class Gradient {
    addColorStopRGB(...args) {
      if (args.length < 4) throw new MockError('addColorStopRGB needs offset, r, g, b');
    }

    addColorStopRGBA(...args) {
      if (args.length < 5) throw new MockError('addColorStopRGBA needs offset, r, g, b, a');
    }
  }
  const cairo = {
    LinearGradient: class extends Gradient {
      constructor(...args) {
        super();
        if (args.length < 4) throw new MockError('Cairo.LinearGradient needs x0, y0, x1, y1');
      }
    },
    RadialGradient: class extends Gradient {},
    Operator: {OVER: 2, SOURCE: 1, CLEAR: 0},
    LineCap: {BUTT: 0, ROUND: 1, SQUARE: 2},
    FontWeight: {NORMAL: 0, BOLD: 1},
    FontSlant: {NORMAL: 0},
  };

  // --- GLib, Gio, GObject (working fakes) -------------------------------------------------------

  const timers = new Map();
  let nextTimer = 1;
  const addTimer = (fn, ms, kind) => {
    const id = nextTimer++;
    timers.set(id, {fn, ms, kind});
    return id;
  };

  class Variant {
    constructor(signature, value) {
      this.signature = signature;
      this.value = value;
    }

    recursiveUnpack() {
      return this.value;
    }

    deep_unpack() {
      return this.value;
    }
  }

  class GLibError extends Error {
    matches() {
      return false;
    }
  }

  const GLib = {
    PRIORITY_DEFAULT: 0, PRIORITY_DEFAULT_IDLE: 200, PRIORITY_HIGH: -100, SOURCE_REMOVE: false, SOURCE_CONTINUE: true,
    FileTest: {EXISTS: 16, IS_REGULAR: 1, IS_DIR: 4},
    SeekType: {CUR: 0, SET: 1, END: 2},
    Variant,
    Error: GLibError,
    get_home_dir: () => home,
    getenv: name => env.vars?.[name] ?? null,
    get_user_config_dir: () => path.join(home, '.config'),
    get_user_state_dir: () => path.join(home, '.local/state'),
    build_filenamev: parts => path.join(...parts),
    path_get_dirname: p => path.dirname(p),
    file_test: p => fs.existsSync(p),
    file_get_contents: p => [true, new Uint8Array(fs.readFileSync(p))],
    mkdir_with_parents: p => {
      fs.mkdirSync(p, {recursive: true});
      return 0;
    },
    timeout_add: (priority, ms, fn) => addTimer(fn, ms, 'timeout'),
    timeout_add_seconds: (priority, seconds, fn) => addTimer(fn, seconds * 1000, 'seconds'),
    idle_add: (priority, fn) => addTimer(fn, 0, 'idle'),
    source_remove: id => {
      if (!timers.delete(id)) throw new MockError(`GLib.source_remove(${id}): no such source (a GLib critical)`);
      return true;
    },
    uuid_string_random: () => crypto.randomUUID(),
    markup_escape_text: text => String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;'),
    DateTime: {new_now_local: () => ({get_hour: () => 9})},
  };

  const monitors = [];
  class FakeFile {
    constructor(p) {
      this.path = p;
      states.set(this, {path: p});
    }

    get_path() {
      return this.path;
    }

    get_uri() {
      return `file://${this.path}`;
    }

    query_exists() {
      return fs.existsSync(this.path);
    }

    query_info() {
      const stats = fs.statSync(this.path);
      return {get_size: () => stats.size, get_attribute_uint32: (attribute) => (attribute === 'unix::mode' ? stats.mode & 0o7777 : 0)};
    }

    set_attribute_uint32(attribute, value) {
      if (attribute !== 'unix::mode') throw new MockError(`Gio.File: unsupported attribute `);
      fs.chmodSync(this.path, value);
      return true;
    }

    read() {
      const data = fs.readFileSync(this.path);
      let offset = 0;
      return {
        seek: (position) => {
          offset = position;
        },
        read_bytes: (count) => {
          const chunk = data.subarray(offset, offset + count);
          offset += chunk.length;
          return {get_data: () => (chunk.length ? new Uint8Array(chunk) : null)};
        },
        close: () => true,
      };
    }

    replace_contents(bytes, _etag, _backup, flags = 0) {
      const tmp = `${this.path}.tmp-${process.pid}`;
      // PRIVATE: a new file only you can read (GIO's G_FILE_CREATE_PRIVATE).
      fs.writeFileSync(tmp, Buffer.from(bytes), {mode: flags & 1 ? 0o600 : 0o644});
      fs.renameSync(tmp, this.path);
      for (const m of monitors) if (m.path === this.path) m.fire();
      return [true, null];
    }

    append_to() {
      const p = this.path;
      return {
        write_all: (bytes) => {
          fs.appendFileSync(p, Buffer.from(bytes));
          return [true, bytes.length];
        },
        close: () => true,
      };
    }

    monitor_file() {
      const handlers = new Map();
      let next = 1;
      const monitor = {
        path: this.path,
        cancelled: false,
        connect: (signal, fn) => {
          if (signal !== 'changed') throw new MockError(`Gio.FileMonitor has no signal ${signal}`);
          handlers.set(next, fn);
          return next++;
        },
        disconnect: id => handlers.delete(id),
        cancel: () => {
          monitor.cancelled = true;
          return true;
        },
        fire: () => {
          if (!monitor.cancelled) for (const fn of handlers.values()) fn(monitor, null, null, 1);
        },
      };
      monitors.push(monitor);
      return monitor;
    }
  }

  const Gio = {
    File: {new_for_path: p => new FakeFile(p)},
    FileCreateFlags: {NONE: 0, PRIVATE: 1, REPLACE_DESTINATION: 2},
    FileMonitorFlags: {NONE: 0, WATCH_MOVES: 8},
    FileQueryInfoFlags: {NONE: 0},
    DBusCallFlags: {NONE: 0},
    DBus: {
      session: {
        call(bus, objectPath, iface, method, parameters, replyType, flags, timeout, cancellable, callback) {
          if (arguments.length < 10) throw new MockError(`Gio.DBusConnection.call needs 10 arguments, got ${arguments.length}`);
          const token = {bus, objectPath, iface, method, parameters};
          addTimer(() => {
            callback({
              call_finish: () => {
                const reply = dbus(method, parameters?.value, token);
                return new Variant('(*)', reply);
              },
            }, token);
            return false;
          }, 0, 'idle');
        },
      },
    },
    // GSettings: only GNOME's keyboard repeat, which Settings → Keyboard → Key Repeat reads.
    Settings: class {
      constructor({schema_id: schema}) {
        if (schema !== 'org.gnome.desktop.peripherals.keyboard') throw new MockError(`GSettings schema ${schema} isn't mocked`);
        if (!env.gnomeKeyboard) throw new Error(`Settings schema '${schema}' is not installed`);
      }
      get_uint(key) {
        if (!['delay', 'repeat-interval'].includes(key)) throw new MockError(`no uint key ${key}`);
        return env.gnomeKeyboard[key];
      }
      get_boolean(key) {
        if (key !== 'repeat') throw new MockError(`no boolean key ${key}`);
        return env.gnomeKeyboard.repeat;
      }
    },
    AppInfo: {
      get_all: () => (env.apps ?? []).map(app => ({
        get_id: () => `${app.id}.desktop`, get_display_name: () => app.name, get_name: () => app.name, should_show: () => true,
      })),
    },
  };

  const GObject = {
    registerClass: (meta, klass) => klass ?? meta,
    Object: function GObjectObject() {},
    TYPE_STRING: 'gchararray', TYPE_BOOLEAN: 'gboolean', TYPE_INT: 'gint', TYPE_DOUBLE: 'gdouble',
    BindingFlags: {DEFAULT: 0, BIDIRECTIONAL: 1, SYNC_CREATE: 2, INVERT_BOOLEAN: 4},
  };

  // --- The Shell's ExtensionPreferences ------------------------------------------------------------

  class ExtensionPreferences {
    constructor(metadata) {
      this.metadata = metadata;
      this.uuid = metadata.uuid;
      this.path = metadata.path;
      this.dir = new FakeFile(metadata.path);
    }

    fillPreferencesWindow() {}

    getSettings() {
      throw new MockError('Slated keeps its settings in config.json, not GSettings');
    }
  }

  const world = {
    report,
    mode,
    namespaces: {
      Gtk: makeNamespace('Gtk'), Gdk: makeNamespace('Gdk'), Adw: makeNamespace('Adw'), Pango: makeNamespace('Pango'),
      PangoCairo: makeNamespace('PangoCairo'), GLib, Gio, GObject,
    },
    cairo,
    prefsModule: {ExtensionPreferences, gettext: s => s, ngettext: (s, p, n) => (n === 1 ? s : p), pgettext: (c, s) => s},
    stateOf,
    emit,
    isA,
    keyNames,
    hooks,
    /** Runs due timers and idles (repeatedly, up to `rounds`), like spinning the main loop. */
    runTimers({rounds = 10, includeRepeating = false} = {}) {
      for (let r = 0; r < rounds && timers.size; r++) {
        for (const [id, timer] of [...timers]) {
          if (!includeRepeating && timer.kind === 'seconds') continue;
          if (!timers.has(id)) continue;
          timers.delete(id);
          const again = timer.fn();
          if (again === true) timers.set(id, timer);
        }
        if (![...timers.values()].some(t => includeRepeating || t.kind !== 'seconds')) break;
      }
    },
    pendingTimers: () => [...timers.values()].map(t => t.kind),
    /**
     * A primary-button press over `target` (what Gtk.Widget.pick finds there), delivered to the
     * capture-phase click gestures of `window` the way gtk_widget_run_controllers does in GTK 4.14 to
     * 4.20: add_controller prepends, so the newest runs first, and the walk saves the next link
     * before it runs a controller. A handler that removes that next controller frees the link GTK
     * reads next, a use-after-free that crashes the settings window or corrupts its heap: that
     * fails here. In "new" mode (GTK 4.20), removing a controller also resets it (since GTK 4.16.2),
     * and a gesture reset inside its own 'pressed' consumes the press. Returns {consumed}: true when
     * GTK stops the press there, so `target` never gets it.
     */
    press(window, target, {x = 10, y = 10} = {}) {
      const state = stateOf(window);
      const capture = world.namespaces.Gtk.PropagationPhase.CAPTURE;
      let consumed = false;
      state.picked = target;
      try {
        let current = state.controllers[state.controllers.length - 1] ?? null;
        while (current) {
          const order = [...state.controllers].reverse();
          const next = order[order.indexOf(current) + 1] ?? null;
          const c = stateOf(current);
          if (isA(c.cls, 'Gtk.GestureClick') && c.props.get('propagation-phase') === capture) {
            dispatching = {widget: window, removed: new Set()};
            emit(current, 'pressed', 1, x, y);
            if (next && dispatching.removed.has(next)) {
              throw new MockError(`A 'pressed' handler removed the ${stateOf(next).cls} that GTK runs next on this ${state.cls}: `
                + 'a use-after-free in gtk_widget_run_controllers');
            }
            if (mode === 'new' && dispatching.removed.has(current)) consumed = true;
            dispatching = null;
          }
          current = next;
        }
      } finally {
        state.picked = null;
        dispatching = null;
      }
      return {consumed};
    },
    /** Pretends a file changed on disk: fires its monitors. */
    touch(p) {
      for (const m of monitors) if (m.path === p) m.fire();
    },
    monitors,
  };
  return world;
}

// --- Walking the widget tree --------------------------------------------------------------------------

/** Every widget under `root` (children, slots and popovers), depth first. */
export function descendants(world, root) {
  const out = [];
  const seen = new Set();
  const visit = node => {
    if (!node || seen.has(node)) return;
    seen.add(node);
    out.push(node);
    const state = world.stateOf(node);
    if (!state) return;
    for (const child of state.children) visit(child);
    for (const child of Object.values(state.slots)) visit(child);
    for (const controller of state.controllers) visit(controller);
    if (state.stack) for (const page of state.stack) visit(page);
  };
  visit(root);
  return out;
}

/** Widgets under `root` of a class (or subclass), optionally filtered. */
export function findAll(world, root, qualified, filter = () => true) {
  return descendants(world, root).filter(w => {
    const state = world.stateOf(w);
    return state && world.isA(state.cls, qualified) && filter(w, state);
  });
}

/** A widget's property as set (or undefined). */
export function prop(world, widget, name) {
  return world.stateOf(widget)?.props.get(name);
}
