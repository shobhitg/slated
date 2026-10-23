#!/usr/bin/env python3
"""Builds api.json, the GObject-introspection manifest the preferences UI test mocks are made from.

The mocks (mock.mjs) let Node run the real GTK/libadwaita code in lib/prefs/ui and fail on any
class, method, property, signal or enum member that doesn't exist in the oldest supported
libraries, on calls with too few arguments, and on unguarded use of newer API.

Inputs are GIR files (they come with the -dev packages):
  - the minimum: GNOME 46 = Ubuntu 24.04: Gtk-4.0.gir and Gdk-4.0.gir from libgtk-4-dev 4.14,
    Adw-1.gir from libadwaita-1-dev 1.5;
  - the newest: GNOME 49 = Ubuntu 25.10: GTK 4.20 and libadwaita 1.8, to know what's newer (allowed
    only behind an `in` check) and what's deprecated;
  - Pango-1.0.gir and PangoCairo-1.0.gir (any recent version).

Usage:
  build-api.py --min-gtk Gtk-4.14.gir --min-gdk Gdk-4.14.gir --min-adw Adw-1.5.gir \\
               --new-gtk Gtk-4.20.gir --new-gdk Gdk-4.20.gir --new-adw Adw-1.8.gir \\
               --pango Pango-1.0.gir --pangocairo PangoCairo-1.0.gir > api.json

On Ubuntu: apt download libgtk-4-dev libadwaita-1-dev, then `dpkg-deb -x` them; the GIRs are in
usr/share/gir-1.0/.
"""
import argparse
import json
import sys
import xml.etree.ElementTree as ET

NS = {'c': 'http://www.gtk.org/introspection/core/1.0', 'glib': 'http://www.gtk.org/introspection/glib/1.0'}
C = '{http://www.gtk.org/introspection/core/1.0}'
GLIB = '{http://www.gtk.org/introspection/glib/1.0}'

NUMBER_TYPES = {
    'gint', 'guint', 'gint8', 'guint8', 'gint16', 'guint16', 'gint32', 'guint32', 'gint64', 'guint64', 'gfloat',
    'gdouble', 'glong', 'gulong', 'gsize', 'gssize', 'gunichar', 'GType', 'gshort', 'gushort', 'gchar', 'guchar',
    'int', 'double', 'float', 'goffset', 'time_t',
}


def qualify(name, namespace):
    if name is None:
        return None
    return name if '.' in name else f'{namespace}.{name}'


def type_code(node, namespace, enums):
    """'v' void, 'b' boolean, 'n' number (incl. enums), 's' string, 'a' array, 'Ns.Type' object, '?' other."""
    if node is None:
        return 'v'
    if node.find(f'{C}array') is not None:
        return 'a'
    t = node.find(f'{C}type')
    if t is None:
        return '?'
    name = t.get('name')
    if name in (None, 'none'):
        return 'v'
    if name == 'gboolean':
        return 'b'
    if name in NUMBER_TYPES:
        return 'n'
    if name in ('utf8', 'filename'):
        return 's'
    if name in ('GLib.List', 'GLib.SList', 'GLib.PtrArray', 'GLib.Array'):
        return 'a'
    if name in ('gpointer', 'gconstpointer', 'GObject.Value', 'va_list'):
        return '?'
    qualified = qualify(name, namespace)
    if qualified in enums:
        return 'n'
    return qualified


def callable_info(node, namespace, enums):
    """Return code, number of required JS arguments and out parameters for a method/function."""
    ret = type_code(node.find(f'{C}return-value'), namespace, enums)
    params = node.find(f'{C}parameters')
    hidden = set()
    ins = []
    outs = 0
    if params is not None:
        plist = [p for p in params.findall(f'{C}parameter')]
        for p in plist:
            arr = p.find(f'{C}array')
            if arr is not None and arr.get('length') is not None:
                hidden.add(int(arr.get('length')))
            # A callback's `closure` and `destroy` point at its user data and destroy notify, which GJS
            # hides. (The user data parameter's own `closure` points back at the callback.)
            if p.get('scope') is not None:
                for attr in ('closure', 'destroy'):
                    if p.get(attr) is not None:
                        hidden.add(int(p.get(attr)))
        ret_node = node.find(f'{C}return-value')
        ret_arr = ret_node.find(f'{C}array') if ret_node is not None else None
        if ret_arr is not None and ret_arr.get('length') is not None:
            hidden.add(int(ret_arr.get('length')))
        for index, p in enumerate(plist):
            if index in hidden:
                continue
            t = p.find(f'{C}type')
            if t is not None and t.get('name') == 'GLib.DestroyNotify':
                continue
            direction = p.get('direction', 'in')
            if direction == 'out':
                # GJS allocates caller-allocates structs itself and returns them, like other outs
                # (widget.get_color() returns a Gdk.RGBA).
                outs += 1
            elif direction == 'inout':
                ins.append(p)
                outs += 1
            else:
                ins.append(p)
    code = ret
    if outs:
        code += f'+{outs}'
    return f'{code}/{len(ins)}'


def collect(gir_path):
    root = ET.parse(gir_path).getroot()
    ns_node = root.find('c:namespace', NS)
    namespace = ns_node.get('name')
    enums = {f'{namespace}.{e.get("name")}' for kind in ('enumeration', 'bitfield') for e in ns_node.findall(f'c:{kind}', NS)}
    out = {'classes': {}, 'enums': {}, 'functions': {}, 'constants': []}
    deprecated = []
    for kind in ('class', 'interface', 'record', 'union'):
        for el in ns_node.findall(f'c:{kind}', NS):
            name = el.get('name')
            if el.get(f'{GLIB}is-gtype-struct-for') or name.endswith('Private'):
                continue
            entry = {'kind': kind}
            if el.get('parent'):
                entry['parent'] = qualify(el.get('parent'), namespace)
            impl = [qualify(i.get('name'), namespace) for i in el.findall('c:implements', NS)]
            if impl:
                entry['implements'] = impl
            prereq = [qualify(i.get('name'), namespace) for i in el.findall('c:prerequisite', NS)]
            if prereq:
                entry['prerequisites'] = prereq
            if el.get('abstract') == '1':
                entry['abstract'] = True
            methods, functions, ctors, props, signals, fields = {}, {}, {}, {}, [], []
            for child in el:
                tag = child.tag.replace(C, '').replace(GLIB, '')
                cname = child.get('name')
                if child.get('introspectable') == '0' or cname is None:
                    continue
                # GJS exposes a method that `shadows` another under the other's name (Gdk.Clipboard's
                # set_value is called as clipboard.set(value)).
                if child.get('shadowed-by'):
                    continue
                if child.get('shadows'):
                    cname = child.get('shadows')
                if child.get('deprecated') == '1':
                    deprecated.append(f'{name}.{cname}')
                if tag == 'method':
                    methods[cname] = callable_info(child, namespace, enums)
                elif tag == 'function':
                    functions[cname] = callable_info(child, namespace, enums)
                elif tag == 'constructor':
                    ctors[cname] = callable_info(child, namespace, enums)
                elif tag == 'property':
                    flags = ''
                    if child.get('writable') != '1':
                        flags = '!r'  # read-only
                    elif child.get('construct-only') == '1':
                        flags = '!c'
                    props[cname] = type_code(child, namespace, enums) + flags
                elif tag == 'signal':
                    signals.append(cname)
                elif tag == 'field' and child.get('private') != '1':
                    fields.append(cname)
            if el.get('deprecated') == '1':
                deprecated.append(name)
            for key, value in (('methods', methods), ('functions', functions), ('ctors', ctors), ('props', props)):
                if value:
                    entry[key] = value
            if signals:
                entry['signals'] = signals
            if fields:
                entry['fields'] = fields
            out['classes'][name] = entry
    for kind in ('enumeration', 'bitfield'):
        for el in ns_node.findall(f'c:{kind}', NS):
            out['enums'][el.get('name')] = [m.get('name') for m in el.findall('c:member', NS)]
            if el.get('deprecated') == '1':
                deprecated.append(el.get('name'))
    for el in ns_node.findall('c:function', NS):
        if el.get('introspectable') == '0' or el.get('shadowed-by'):
            continue
        name = el.get('shadows') or el.get('name')
        out['functions'][name] = callable_info(el, namespace, enums)
        if el.get('deprecated') == '1':
            deprecated.append(name)
    out['constants'] = sorted(c.get('name') for c in ns_node.findall('c:constant', NS))
    return namespace, out, deprecated


def newer_members(old, new):
    """Classes, members, enums and functions in `new` that `old` doesn't have."""
    result = {'classes': {}, 'members': {}, 'enums': {}, 'functions': {}}
    for name, entry in new['classes'].items():
        if name not in old['classes']:
            result['classes'][name] = entry
            continue
        before = old['classes'][name]
        added = {}
        for key in ('methods', 'functions', 'ctors', 'props'):
            extra = {k: v for k, v in entry.get(key, {}).items() if k not in before.get(key, {})}
            if extra:
                added[key] = extra
        extra_signals = [s for s in entry.get('signals', []) if s not in before.get('signals', [])]
        if extra_signals:
            added['signals'] = extra_signals
        if added:
            result['members'][name] = added
    for name, members in new['enums'].items():
        extra = [m for m in members if m not in old['enums'].get(name, [])]
        if extra:
            result['enums'][name] = extra
    for name, info in new['functions'].items():
        if name not in old['functions']:
            result['functions'][name] = info
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for flag in ('min-gtk', 'min-gdk', 'min-adw', 'new-gtk', 'new-gdk', 'new-adw', 'pango', 'pangocairo'):
        parser.add_argument(f'--{flag}', required=True)
    args = parser.parse_args()
    api = {'namespaces': {}, 'newer': {}, 'deprecated': {}, 'versions': {}}
    for key, label in (('min_gtk', 'Gtk'), ('min_gdk', 'Gdk'), ('min_adw', 'Adw'), ('pango', 'Pango'), ('pangocairo', 'PangoCairo')):
        namespace, data, deprecated = collect(getattr(args, key))
        api['namespaces'][namespace] = data
        api['deprecated'][namespace] = sorted(set(deprecated))
    for key, namespace in (('new_gtk', 'Gtk'), ('new_gdk', 'Gdk'), ('new_adw', 'Adw')):
        _, data, deprecated = collect(getattr(args, key))
        api['newer'][namespace] = newer_members(api['namespaces'][namespace], data)
        api['deprecated'][namespace] = sorted(set(api['deprecated'][namespace]) | set(deprecated))
    api['versions'] = {'minimum': 'GTK 4.14, libadwaita 1.5 (GNOME 46)', 'newest': 'GTK 4.20, libadwaita 1.8 (GNOME 49)'}
    json.dump(api, sys.stdout, sort_keys=True, separators=(',', ':'))
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
