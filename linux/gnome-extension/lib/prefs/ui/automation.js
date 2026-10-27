// Settings → Automation: game-style automation (AutoHotkey's job). What it is and how it's kept safe,
// what runs right now, your automations, one-click recipes, the safety settings, and what GNOME does
// differently (port of AutomationPane.swift and RecipeGallery.swift).
//
// Automations are ordinary bindings in config.bindings: recipes add one and open its editor with the
// shortcut recorder running, so every option stays one page away.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {bindingTitle, containsAutomation} from '../actions.js';
import {statePresentation} from '../status.js';
import {statusKey, keysString, comboLabel} from '../keys.js';
import {
  RECIPES, automationBindings, automationSettings, bindingForRecipe, recipeChip, recipeBadge, sentence,
  TIME_LIMITS, timeLimitTitle, withCurrent, appDisplayName, defaultAutomationSettings, GNOME_NOTES,
} from '../automation.js';
import {box, label, button, icon, keycaps, pill, notice, group, comboRow, switchRow, glyph, commandRow} from './widgets.js';
import {ShortcutRecorder} from './recorder.js';
import {pushBindingEditor} from './bindingeditor.js';
import {installedApps} from './apps.js';

/** The hero's safety rails as pills: the stop shortcut, app switches, the time limit. */
function rails(container, config) {
  let child = container.get_first_child();
  while (child) {
    const next = child.get_next_sibling();
    container.remove(child);
    child = next;
  }
  const settings = automationSettings(config);
  if (settings.stopShortcut) {
    const stop = box('horizontal', 6);
    stop.append(keycaps(settings.stopShortcut));
    stop.append(label('stops everything', {classes: ['dim-label', 'caption']}));
    container.append(stop);
  } else {
    container.append(pill({label: 'No stop shortcut', style: 'warning'}));
  }
  container.append(pill({label: settings.stopOnAppSwitch ? 'Stops on app switch' : 'Runs across apps', style: 'accent'}));
  container.append(pill({label: settings.maxRunMinutes > 0 ? `Stops after ${timeLimitTitle(settings.maxRunMinutes)}` : 'No time limit', style: 'dim'}));
}

export function createAutomationPane(ctx) {
  const model = ctx.model;
  const prefs = new Adw.PreferencesPage();

  // Hero
  const heroGroup = group();
  const hero = box('vertical', 8, ['card', 'slated-hero']);
  hero.append(label('ON AUTOPILOT', {classes: ['slated-greeting']}));
  hero.append(label('Let Slated click and press for you', {classes: ['title-2'], wrap: true}));
  hero.append(label('Auto-clickers, held keys and short macros. Each automation is a shortcut: press it to start, press it '
    + 'again to stop. Limit one to a game, and even a plain key like F works as its shortcut.', {wrap: true, classes: ['dim-label']}));
  const railBox = box('horizontal', 8);
  railBox.set_margin_top(4);
  hero.append(railBox);
  heroGroup.add(hero);
  prefs.add(heroGroup);

  const fairPlay = group();
  fairPlay.add(notice({level: 'warning', title: "Check the game's rules first",
    detail: "Many games accept automated input, but online games with anti-cheat may block it, and their terms of service can forbid it. Use automation where it's allowed: single-player and idle games, and your own work."}).widget);
  prefs.add(fairPlay);

  // Running now
  const runningGroup = group({title: 'Running Now'});
  prefs.add(runningGroup);
  let runningRows = [];

  // Your automations
  const newButton = button('New Automation', () => newAutomation(), {icon: 'list-add-symbolic', classes: ['flat']});
  const yoursGroup = group({title: 'Your Automations', suffix: newButton});
  prefs.add(yoursGroup);
  let yourRows = [];

  // Recipes
  const recipesGroup = group({title: 'Recipes', description: 'Pick one, then press the keys to start it with. You can change everything afterwards.'});
  prefs.add(recipesGroup);
  let recipeRows = [];

  // Safety
  const safety = group({title: 'Safety',
    description: 'Slated never leaves a button or key held down: turning Slated off, locking the screen, reloading the configuration and logging out all let go of everything.'});
  const setAutomation = mutate => model.update(config => {
    config.automation = {...automationSettings(config)};
    mutate(config.automation);
  });
  const stopRecorder = new ShortcutRecorder({
    title: 'Stop shortcut', keys: automationSettings(model.configuration).stopShortcut ?? '', allowClear: true,
    subtitle: 'Stops every automation and lets go of anything held, from any app. Backspace while recording clears it.',
    onChange: keys => setAutomation(a => {
      a.stopShortcut = keys || null;
    }),
  });
  const restoreStop = button('Default', () => setAutomation(a => {
    a.stopShortcut = defaultAutomationSettings().stopShortcut;
  }), {classes: ['flat'], tooltip: `Use ${comboLabel(defaultAutomationSettings().stopShortcut)} again`});
  stopRecorder.row.add_suffix(restoreStop);
  safety.add(stopRecorder.row);
  const noStop = notice({level: 'warning', title: 'No stop shortcut',
    detail: "Stop automations by pressing each one's shortcut again, or with a shortcut that runs Stop Automations."});
  safety.add(noStop.widget);
  const appSwitch = switchRow({
    title: 'Stop when you switch apps',
    subtitle: "Leaving the app an automation started in stops it; opening the Activities overview counts as leaving. Slated's own settings window doesn't count.",
    active: automationSettings(model.configuration).stopOnAppSwitch,
    onChange: on => setAutomation(a => {
      a.stopOnAppSwitch = on;
    }),
  });
  safety.add(appSwitch.row);
  const timeItems = minutes => withCurrent(TIME_LIMITS, minutes).map(m => ({id: m, label: timeLimitTitle(m)}));
  const limit = comboRow({
    title: 'Time limit', subtitle: 'Stop everything after a while, in case you walk away.',
    items: timeItems(automationSettings(model.configuration).maxRunMinutes), selected: automationSettings(model.configuration).maxRunMinutes,
    onChange: minutes => setAutomation(a => {
      a.maxRunMinutes = minutes;
    }),
  });
  safety.add(limit.row);
  const indicator = switchRow({
    title: 'Show an indicator', subtitle: 'A small pill at the top of the screen while anything runs, with the stop shortcut.',
    active: automationSettings(model.configuration).showIndicator,
    onChange: on => setAutomation(a => {
      a.showIndicator = on;
    }),
  });
  safety.add(indicator.row);
  prefs.add(safety);

  // What GNOME does differently
  const gnome = group({title: 'On GNOME'});
  const heldRow = new Adw.ActionRow({use_markup: false, title: 'Repeats while held', subtitle: ''});
  heldRow.add_prefix(icon('input-keyboard-symbolic'));
  gnome.add(heldRow);
  const mouseRow = new Adw.ActionRow({use_markup: false, title: 'Mouse buttons as shortcuts',
    subtitle: "GNOME can't use mouse buttons as shortcuts. Map a side button to a key with keyd, then use that key: Slated knows F13 to F20."});
  mouseRow.add_prefix(icon('input-mouse-symbolic'));
  gnome.add(mouseRow);
  gnome.add(commandRow('keyd: the side button as F13 (see man keyd)', 'mouse1 = f13', ctx.toast));
  const gamesRow = new Adw.ActionRow({use_markup: false, title: 'Where it works',
    subtitle: 'Slated clicks and types through a virtual mouse and keyboard inside GNOME Shell, so it reaches Wayland and X11 (XWayland) games alike.'});
  gamesRow.add_prefix(icon('input-gaming-symbolic'));
  gnome.add(gamesRow);
  prefs.add(gnome);

  function newAutomation() {
    const id = model.addBinding(RECIPES[0].action, {name: RECIPES[0].title});
    model.log('ui.binding_new', {preset: 'automation'});
    pushBindingEditor(ctx, id, {autoRecord: true});
  }

  function addRecipe(recipe) {
    const id = model.addRecipe(recipe);
    pushBindingEditor(ctx, id, {autoRecord: true});
  }

  function rebuildRunning() {
    for (const row of runningRows) runningGroup.remove(row);
    runningRows = [];
    const running = model.running ? model.status.automation?.running ?? [] : [];
    const stop = automationSettings(model.configuration).stopShortcut;
    for (const title of running) {
      const row = new Adw.ActionRow({use_markup: false, title});
      row.add_prefix(icon('media-record-symbolic', {classes: ['slated-error-text']}));
      runningRows.push(row);
    }
    if (!running.length) {
      runningRows.push(new Adw.ActionRow({use_markup: false, title: 'Nothing is running',
        subtitle: model.running ? "Press an automation's shortcut to start it." : "Slated isn't running, so no automation can run. See Overview."}));
    }
    for (const row of runningRows) runningGroup.add(row);
    runningGroup.set_description(running.length && stop ? `Press ${comboLabel(stop)} to stop everything.` : '');
  }

  function automationRow(binding) {
    const state = model.bindingState(binding);
    const presentation = statePresentation(state);
    const running = (model.status.automation?.shortcuts ?? []).includes(statusKey(binding.keys, binding.modal)) && model.running;
    const apps = binding.onlyInApps ?? [];
    const where = apps.length
      ? ` · Only in ${apps.slice(0, 2).map(id => appDisplayName(id, {installed: installedApps(), recent: model.status.recentApps})).join(', ')}${apps.length > 2 ? ` and ${apps.length - 2} more` : ''}`
      : '';
    const row = new Adw.ActionRow({use_markup: false, title: bindingTitle(binding),
      subtitle: `${presentation.row ?? sentence(binding.action)}${where}`, activatable: true});
    row.set_title_lines(1);
    row.set_subtitle_lines(2);
    row.add_prefix(glyph(binding.action));
    if (running) row.add_suffix(pill({label: 'Running', style: 'error'}));
    else if (presentation.icon) row.add_suffix(icon(presentation.icon, {classes: [presentation.style === 'error' ? 'slated-error-text' : 'slated-warning-text']}));
    row.add_suffix(keycaps(binding.keys, {modal: binding.modal, emptyText: 'No shortcut'}));
    const enabled = new Gtk.Switch({active: binding.enabled !== false, valign: Gtk.Align.CENTER,
      tooltip_text: binding.enabled !== false ? 'Turn this automation off' : 'Turn this automation on'});
    enabled.connect('notify::active', () => model.setBinding(binding.id, b => {
      b.enabled = enabled.get_active();
    }));
    row.add_suffix(enabled);
    row.add_suffix(icon('go-next-symbolic'));
    if (binding.enabled === false) row.add_css_class('dim-label');
    row.connect('activated', () => pushBindingEditor(ctx, binding.id));
    return row;
  }

  function rebuildYours() {
    for (const row of yourRows) yoursGroup.remove(row);
    yourRows = automationBindings(model.configuration).map(automationRow);
    if (!yourRows.length) {
      const row = new Adw.ActionRow({use_markup: false, title: 'No automations yet',
        subtitle: 'Add a recipe below, or build your own. Each one is a shortcut, also listed in Windows.'});
      row.add_prefix(icon('input-gaming-symbolic'));
      yourRows.push(row);
    }
    for (const row of yourRows) yoursGroup.add(row);
  }

  function recipeRow(recipe) {
    const existing = bindingForRecipe(model.configuration, recipe);
    const chip = [recipeBadge(recipe.action), recipeChip(recipe.action)].filter(Boolean).join(' · ');
    const row = new Adw.ActionRow({use_markup: false, title: recipe.title, subtitle: recipe.summary});
    row.set_subtitle_lines(2);
    row.set_tooltip_text(recipe.detail);
    row.add_prefix(icon(recipe.icon, {size: 20}));
    if (existing && keysString(existing.keys)) {
      row.add_suffix(icon('object-select-symbolic', {classes: ['success']}));
      row.add_suffix(keycaps(existing.keys, {modal: existing.modal}));
      row.add_suffix(button('Edit', () => pushBindingEditor(ctx, existing.id), {classes: ['flat'], tooltip: 'You already have this one'}));
    } else {
      row.add_suffix(label(chip, {classes: ['dim-label', 'caption']}));
      row.add_suffix(button('Add', () => addRecipe(recipe), {icon: 'list-add-symbolic', classes: ['flat'], tooltip: recipe.detail}));
    }
    return row;
  }

  function rebuildRecipes() {
    for (const row of recipeRows) recipesGroup.remove(row);
    recipeRows = RECIPES.map(recipeRow);
    const own = new Adw.ActionRow({use_markup: false, title: 'Build Your Own', subtitle: 'Clicks, keys, holds and waits, in any order.', activatable: true});
    own.add_prefix(icon('list-add-symbolic', {size: 20}));
    own.add_suffix(icon('go-next-symbolic'));
    own.connect('activated', () => newAutomation());
    recipeRows.push(own);
    for (const row of recipeRows) recipesGroup.add(row);
  }

  function syncSettings() {
    const settings = automationSettings(model.configuration);
    rails(railBox, model.configuration);
    stopRecorder.set(settings.stopShortcut ?? '');
    restoreStop.set_visible(keysString(settings.stopShortcut ?? '') !== keysString(defaultAutomationSettings().stopShortcut));
    const conflicts = model.otherUsesOfBuiltIn('stopAutomations');
    const state = model.builtInState('stopAutomations');
    if (conflicts.length) {
      stopRecorder.row.set_subtitle(`Also used by ${conflicts.join(', ')}, which wins over the stop shortcut.`);
      stopRecorder.row.add_css_class('slated-warning-row');
    } else if (state?.state === 'failed') {
      stopRecorder.row.set_subtitle(`GNOME didn't take it: ${state.reason}`);
      stopRecorder.row.add_css_class('slated-warning-row');
    } else {
      stopRecorder.row.set_subtitle('Stops every automation and lets go of anything held, from any app. Backspace while recording clears it.');
      stopRecorder.row.remove_css_class('slated-warning-row');
    }
    noStop.widget.set_visible(!settings.stopShortcut);
    appSwitch.set(settings.stopOnAppSwitch);
    limit.setItems(timeItems(settings.maxRunMinutes), settings.maxRunMinutes);
    indicator.set(settings.showIndicator);
    heldRow.set_subtitle(model.status.automation?.whileHeld === 'toggle' ? GNOME_NOTES.repeatOff
      : `${GNOME_NOTES.whileHeld} A while-held repeat that presses keys, or a modal key's, works like a toggle.`);
  }

  const page = new Adw.NavigationPage({title: 'Automation', tag: 'automation'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);

  // Rebuild only while the page is on screen; otherwise when it's shown again.
  let dirty = true;
  const update = () => {
    rebuildRunning();
    rebuildYours();
    rebuildRecipes();
    syncSettings();
    dirty = false;
  };
  const refresh = () => {
    if (ctx.isCurrent() && ctx.nav.get_visible_page() === page) update();
    else dirty = true;
  };
  page.connect('showing', () => dirty && update());
  page.connect('hidden', () => stopRecorder.stop());
  for (const signal of ['config', 'status']) model.on(signal, refresh);

  return {
    id: 'automation',
    title: 'Automation',
    iconName: 'input-gaming-symbolic',
    page,
    activate: () => dirty && update(),
    badge() {
      const running = model.running ? (model.status.automation?.running ?? []).length : 0;
      if (running) return {text: String(running), warning: true};
      const count = model.configuration.bindings.filter(b => containsAutomation(b.action)).length;
      return count ? {text: String(count), warning: false} : null;
    },
    /** Adds a recipe ({recipe: id}) or opens an automation's editor ({binding: id}). */
    show(options = {}) {
      if (options.binding && model.binding(options.binding)) pushBindingEditor(ctx, options.binding);
      const recipe = RECIPES.find(r => r.id === options.recipe);
      if (recipe) addRecipe(recipe);
    },
  };
}

