// Settings → Windows: Slated's shortcuts, with a search field, keycaps and status badges (port of
// WindowsPane.swift). Shortcuts from a Slate config are here too once imported: Slated doesn't read
// Slate files. Selecting a shortcut opens
// its editor on a pushed page. Automations (shortcuts that click, press or hold) live in
// config.bindings like any shortcut; they get their own group so they're easy to find.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {bindingTitle, bindingSubtitle, actionTitle, actionDetail, containsAutomation} from '../actions.js';
import {RECIPES} from '../automation.js';
import {PRESETS, PRESET_GROUPS} from '../presets.js';
import {statePresentation} from '../status.js';
import {comboLabel, keysString} from '../keys.js';
import {box, label, button, icon, glyph, keycaps, badge, group, emptyState} from './widgets.js';
import {pushBindingEditor} from './bindingeditor.js';

/** A row's secondary text: the state when it's worth calling out, else what the action does. */
function rowSubtitle(presentation, fallback) {
  return presentation.row ?? fallback;
}

export function createWindowsPane(ctx) {
  const model = ctx.model;
  let query = '';

  const search = new Gtk.SearchEntry({placeholder_text: 'Search shortcuts', hexpand: true});
  const searchBar = box('horizontal', 0);
  searchBar.append(search);
  searchBar.set_margin_bottom(6);

  const prefs = new Adw.PreferencesPage();
  const searchGroup = group();
  searchGroup.add(searchBar);
  prefs.add(searchGroup);

  const slatedCount = label('', {classes: ['dim-label']});
  const slatedGroup = group({title: 'Slated', suffix: slatedCount});
  prefs.add(slatedGroup);
  const automationCount = label('', {classes: ['dim-label']});
  const automationGroup = group({title: 'Automation', suffix: automationCount, description: 'Mouse & keys: clicks, held keys and macros.'});
  prefs.add(automationGroup);
  let slatedRows = [];
  let automationRows = [];

  const empty = emptyState({
    iconName: 'focus-windows-symbolic', title: 'Move windows with a keystroke',
    description: 'Create your first shortcut, or start with a set of Hyper shortcuts for halves, maximize, center and more.',
    actions: [
      {label: 'Add Starter Shortcuts', onClick: () => addStarter()},
      {label: 'New Shortcut', suggested: true, onClick: () => newBinding()},
    ],
  });
  const stack = new Gtk.Stack({transition_type: Gtk.StackTransitionType.CROSSFADE});
  stack.add_named(prefs, 'list');
  stack.add_named(empty, 'empty');

  // Header: "From Preset" menu and "New Shortcut".
  const presetBox = box('vertical', 2);
  const presetPopover = new Gtk.Popover({child: new Gtk.ScrolledWindow({child: presetBox, max_content_height: 460,
    propagate_natural_height: true, hscrollbar_policy: Gtk.PolicyType.NEVER})});
  for (const g of PRESET_GROUPS) {
    presetBox.append(label(g.title, {classes: ['heading']}));
    for (const preset of PRESETS.filter(p => p.group === g.id)) {
      const content = box('horizontal', 8);
      content.append(glyph(preset.action));
      content.append(label(preset.title));
      const b = new Gtk.Button({child: content, css_classes: ['flat']});
      b.connect('clicked', () => {
        presetPopover.popdown();
        newBinding(preset.action);
      });
      presetBox.append(b);
    }
  }
  presetBox.append(label('Automation', {classes: ['heading']}));
  for (const recipe of RECIPES) {
    const content = box('horizontal', 8);
    content.append(glyph(recipe.action));
    content.append(label(recipe.title));
    const b = new Gtk.Button({child: content, css_classes: ['flat'], tooltip_text: recipe.detail});
    b.connect('clicked', () => {
      presetPopover.popdown();
      pushBindingEditor(ctx, model.addRecipe(recipe), {autoRecord: true});
    });
    presetBox.append(b);
  }
  const presetMenu = new Gtk.MenuButton({label: 'From Preset', popover: presetPopover, tooltip_text: 'Start a shortcut from a preset placement'});
  const addButton = button('', () => newBinding(), {icon: 'list-add-symbolic', classes: ['suggested-action'], tooltip: 'New Shortcut'});

  function newBinding(action) {
    const id = model.addBinding(action);
    model.log('ui.binding_new', {preset: action ? actionTitle(action) : 'left-half'});
    pushBindingEditor(ctx, id, {autoRecord: true});
  }

  function addStarter() {
    const added = model.addStarterBindings();
    ctx.toast(added ? `Added ${added} Hyper shortcuts` : 'The starter shortcuts are already there');
  }

  const matches = fields => !query || fields.some(f => String(f ?? '').toLowerCase().includes(query));

  function bindingRow(binding) {
    const state = model.bindingState(binding);
    const presentation = statePresentation(state);
    const row = new Adw.ActionRow({use_markup: false, title: bindingTitle(binding), subtitle: rowSubtitle(presentation, bindingSubtitle(binding)), activatable: true});
    row.set_title_lines(1);
    row.set_subtitle_lines(1);
    row.add_prefix(glyph(binding.action));
    if (presentation.row && presentation.style !== 'dim') row.add_css_class(presentation.style === 'error' ? 'slated-invalid' : 'slated-warning-row');
    if (presentation.style === 'accent') row.remove_css_class('slated-warning-row');
    if (binding.enabled === false) row.add_css_class('dim-label');
    if (presentation.icon) row.add_suffix(icon(presentation.icon, {classes: [presentation.style === 'error' ? 'slated-error-text' : 'slated-warning-text']}));
    row.add_suffix(keycaps(binding.keys, {modal: binding.modal, emptyText: 'No shortcut'}));
    row.add_suffix(icon('go-next-symbolic'));
    row.connect('activated', () => pushBindingEditor(ctx, binding.id));
    return row;
  }

  function rebuild() {
    for (const row of slatedRows) slatedGroup.remove(row);
    slatedRows = [];
    for (const row of automationRows) automationGroup.remove(row);
    automationRows = [];

    const bindings = model.configuration.bindings;
    const windowBindings = bindings.filter(b => !containsAutomation(b.action));
    const automations = bindings.filter(b => containsAutomation(b.action));
    const shown = list => list.filter(b => matches([bindingTitle(b), bindingSubtitle(b), actionDetail(b.action), keysString(b.keys), comboLabel(b.keys, b.modal)]));
    const visible = shown(windowBindings);
    slatedCount.set_label(String(windowBindings.length));
    for (const b of visible) slatedRows.push(bindingRow(b));
    if (!windowBindings.length) {
      const row = new Adw.ActionRow({use_markup: false, title: bindings.length ? 'No window shortcuts yet' : 'No shortcuts of your own yet',
        subtitle: 'Start with a set of Hyper shortcuts for halves, maximize and more.'});
      row.add_suffix(button('Add Starter Shortcuts', () => addStarter(), {classes: ['flat']}));
      slatedRows.push(row);
    } else if (!visible.length) {
      slatedRows.push(new Adw.ActionRow({use_markup: false, title: `No matches for “${search.get_text()}”`, activatable: false}));
    }
    for (const row of slatedRows) slatedGroup.add(row);
    automationGroup.set_visible(automations.length > 0);
    automationCount.set_label(String(automations.length));
    const visibleAutomations = shown(automations);
    for (const b of visibleAutomations) automationRows.push(bindingRow(b));
    if (automations.length && !visibleAutomations.length) automationRows.push(new Adw.ActionRow({use_markup: false, title: 'No matches', activatable: false}));
    for (const row of automationRows) automationGroup.add(row);

    const nothing = !bindings.length;
    stack.set_visible_child_name(nothing && !query ? 'empty' : 'list');
  }

  search.connect('search-changed', () => {
    query = search.get_text().trim().toLowerCase();
    rebuild();
  });

  const page = new Adw.NavigationPage({title: 'Windows', tag: 'windows'});
  const toolbar = new Adw.ToolbarView({content: stack});
  const header = new Adw.HeaderBar();
  header.pack_end(addButton);
  header.pack_end(presetMenu);
  toolbar.add_top_bar(header);
  page.set_child(toolbar);

  // Rebuild only while the list is on screen; otherwise remember to when it's shown again.
  let dirty = true;
  const update = () => {
    rebuild();
    dirty = false;
  };
  const refresh = () => {
    if (ctx.isCurrent() && ctx.nav.get_visible_page() === page) update();
    else dirty = true;
  };
  page.connect('showing', () => dirty && update());
  for (const signal of ['config', 'status']) model.on(signal, refresh);

  return {
    id: 'windows',
    title: 'Windows',
    iconName: 'focus-windows-symbolic',
    page,
    activate: () => dirty && update(),
    badge() {
      const counts = Object.values(model.status.hotkeys).filter(h => h.state === 'failed' || h.state === 'duplicate').length;
      if (counts && model.running) return {text: String(counts), warning: true};
      return {text: String(model.configuration.bindings.length), warning: false};
    },
    /** Opens a binding's editor ({binding: id}) or a new one ({newBinding, action}). */
    show(options = {}) {
      if (options.binding && model.binding(options.binding)) pushBindingEditor(ctx, options.binding);
      if (options.newBinding) newBinding(options.action);
    },
    focusSearch() {
      search.grab_focus();
    },
  };
}
