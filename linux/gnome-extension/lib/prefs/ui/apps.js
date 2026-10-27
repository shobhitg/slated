// Installed applications, for app pickers: "Focus App", layouts, hotstring app filters, the apps a
// shortcut works in and the clipboard's excluded apps. Slate matches apps by name; hotstring filters,
// onlyInApps and excludedApps use desktop app ids (e.g. org.gnome.TextEditor).

import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

import {box, label} from './widgets.js';

let cache = null;

/** Visible desktop apps as [{id, name}], sorted by name. `id` drops the ".desktop" suffix. */
export function installedApps() {
  if (cache) return cache;
  const seen = new Set();
  cache = Gio.AppInfo.get_all()
    .filter(app => app.should_show())
    .map(app => ({id: (app.get_id() ?? '').replace(/\.desktop$/, ''), name: app.get_display_name() ?? app.get_name() ?? ''}))
    .filter(app => app.name && !seen.has(app.name) && seen.add(app.name))
    .sort((a, b) => a.name.localeCompare(b.name));
  return cache;
}

/**
 * A menu button that offers a searchable list of apps and calls `onPick(app)` with {id, name}.
 * `exclude(app)` hides apps already chosen. `sections()` lists what to offer as [{title, apps}]
 * (installed apps by default); an app shows once, in the first section that has it.
 */
export function appPickerButton({
  onPick, exclude = () => false, tooltip = 'Choose an installed app', iconName = 'view-app-grid-symbolic', sections = null,
}) {
  const list = new Gtk.ListBox({selection_mode: Gtk.SelectionMode.NONE, css_classes: ['navigation-sidebar']});
  const search = new Gtk.SearchEntry({placeholder_text: 'Search apps'});
  const scroller = new Gtk.ScrolledWindow({
    child: list, min_content_height: 120, max_content_height: 320, propagate_natural_height: true,
    hscrollbar_policy: Gtk.PolicyType.NEVER,
  });
  const content = box('vertical', 6);
  content.set_size_request(260, -1);
  content.append(search);
  content.append(scroller);
  const popover = new Gtk.Popover({child: content});
  const menu = new Gtk.MenuButton({icon_name: iconName, popover, valign: Gtk.Align.CENTER, css_classes: ['flat'], tooltip_text: tooltip});

  const fill = () => {
    let child = list.get_first_child();
    while (child) {
      const next = child.get_next_sibling();
      list.remove(child);
      child = next;
    }
    const query = search.get_text().trim().toLowerCase();
    const matches = app => !exclude(app) && (!query || app.name.toLowerCase().includes(query) || app.id.toLowerCase().includes(query));
    const shown = new Set();
    let count = 0;
    const groups = sections ? sections() : [{title: null, apps: installedApps()}];
    for (const group of groups) {
      const apps = group.apps.filter(app => matches(app) && !shown.has(app.id));
      if (!apps.length) continue;
      if (group.title && groups.length > 1) {
        const heading = new Gtk.ListBoxRow({child: label(group.title, {classes: ['heading', 'dim-label']}), activatable: false, selectable: false});
        list.append(heading);
      }
      for (const app of apps.slice(0, 200)) {
        shown.add(app.id);
        const row = new Gtk.ListBoxRow({child: label(app.name, {ellipsize: true}), activatable: true});
        row.set_tooltip_text(app.id);
        row._slatedApp = app;
        list.append(row);
        count++;
      }
    }
    if (!count) list.append(new Gtk.ListBoxRow({child: label('No matching apps', {classes: ['dim-label']}), activatable: false}));
  };
  list.connect('row-activated', (_list, row) => {
    if (!row._slatedApp) return;
    popover.popdown();
    onPick(row._slatedApp);
  });
  search.connect('search-changed', fill);
  popover.connect('show', () => {
    search.set_text('');
    fill();
    search.grab_focus();
  });
  return menu;
}
