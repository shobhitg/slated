// Settings → Get Started: first-run setup as a page of the settings window (port of
// GetStarted/GetStartedPane.swift and GetStartedSteps.swift). Welcome, the Hyper key (keyd
// recommended), hotstrings (espanso), the Slate config, done; finishing lands on Overview. It leads
// the sidebar while setup isn't finished, and Overview links back to it. The step lives on the model
// (model.getStartedStep), so the sidebar badge follows it. Texts and decisions: ../getstarted.js.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {
  STEPS, primaryTitle, loadedSourceBindings, hyperSubtitle, tapSubtitle, keydAdvice, hotstringsStep, slateStep,
  sourceSummary, starterAdded, doneChecklist, tryItTip,
} from '../getstarted.js';
import {starterBindings} from '../presets.js';
import {fileExists} from '../io.js';
import {plural} from '../util.js';
import {box, label, button, icon, keycaps, group, notice, switchRow, commandRow, triggerChip, launchUri, clear} from './widgets.js';
import {slatedMark} from './about.js';
import {hyperIllustration} from './keyboard.js';
import {summaryActions} from './overview.js';

/** A step's scrolling, centered column. */
function stepPage() {
  const column = box('vertical', 22);
  column.set_valign(Gtk.Align.CENTER);
  column.set_margin_top(24);
  column.set_margin_bottom(24);
  column.set_margin_start(12);
  column.set_margin_end(12);
  const clamp = new Adw.Clamp({maximum_size: 600, child: column});
  return {column, widget: new Gtk.ScrolledWindow({hscrollbar_policy: Gtk.PolicyType.NEVER, child: clamp, vexpand: true})};
}

/** Title and subtitle shared by every step (StepTitle). */
function stepTitle(titleText = '', subtitleText = '') {
  const column = box('vertical', 10);
  const title = label(titleText, {classes: ['title-1'], wrap: true, xalign: 0.5});
  const subtitle = label(subtitleText, {classes: ['dim-label'], wrap: true, xalign: 0.5});
  for (const l of [title, subtitle]) l.set_justify(Gtk.Justification.CENTER);
  column.append(title);
  column.append(subtitle);
  return {
    widget: column,
    set(t, s) {
      title.set_label(t);
      subtitle.set_label(s);
    },
  };
}

function stepIcon(name) {
  const image = icon(name, {size: 64, classes: ['slated-step-icon']});
  image.set_halign(Gtk.Align.CENTER);
  return image;
}

/** A small centered note under a step (the Mac's info label). */
function note(text) {
  const l = label(text, {classes: ['dim-label', 'caption'], wrap: true, xalign: 0.5});
  l.set_justify(Gtk.Justification.CENTER);
  return l;
}

function keycapLabel(text, hyper = false) {
  return new Gtk.Label({label: text, css_classes: hyper ? ['slated-keycap', 'hyper'] : ['slated-keycap'], valign: Gtk.Align.CENTER});
}

function row(title, subtitle = '', {prefix = null, suffix = null} = {}) {
  const r = new Adw.ActionRow({use_markup: false, title, subtitle});
  r.set_subtitle_lines(0);
  if (prefix) r.add_prefix(prefix);
  if (suffix) r.add_suffix(suffix);
  return r;
}

export function createGetStartedPane(ctx) {
  const model = ctx.model;
  const stack = new Gtk.Stack({vhomogeneous: false, transition_duration: 220, transition_type: Gtk.StackTransitionType.CROSSFADE});
  const page = new Adw.NavigationPage({title: 'Get Started', tag: 'getStarted'});
  const actions = summaryActions(ctx, page);

  // --- Welcome
  const welcome = stepPage();
  welcome.column.append(slatedMark(92));
  welcome.column.append(stepTitle('Welcome to Slated',
    "Keyboard-first window management, a Hyper key and text expansion. A few quick steps and you're set.").widget);
  const features = group();
  const capsToHyper = box('horizontal', 4);
  capsToHyper.append(keycapLabel('Caps Lock'));
  capsToHyper.append(label('→', {classes: ['dim-label']}));
  capsToHyper.append(keycapLabel('✦', true));
  features.add(row('Windows', 'Snap, resize and throw windows between displays.',
    {prefix: icon('focus-windows-symbolic', {size: 24}), suffix: keycaps('hyper+left')}));
  features.add(row('Hyper Key', 'Caps Lock becomes Ctrl+Alt+Shift+Super — a modifier just for you.',
    {prefix: icon('input-keyboard-symbolic', {size: 24}), suffix: capsToHyper}));
  features.add(row('Hotstrings', 'Type a short trigger, get a whole sentence.',
    {prefix: icon('insert-text-symbolic', {size: 24}), suffix: triggerChip(';shrug')}));
  welcome.column.append(features);

  // --- Hyper key (keyd recommended)
  const hyper = stepPage();
  const picture = hyperIllustration();
  hyper.column.append(picture.widget);
  hyper.column.append(stepTitle('Turn Caps Lock into a Hyper key',
    'Hold Caps Lock and it presses Ctrl, Alt, Shift and Super at once — a combination apps leave alone, so shortcuts like ✦← never clash with anything.').widget);
  const hyperGroup = group();
  const useHyper = switchRow({
    title: 'Use Caps Lock as Hyper', subtitle: '', active: model.configuration.keyboard.capsLock === 'hyper',
    onChange: on => model.update(config => {
      config.keyboard.capsLock = on ? 'hyper' : 'off';
    }),
  });
  useHyper.row.set_subtitle_lines(0);
  const tap = switchRow({
    title: 'Tap alone for Escape', subtitle: '', active: model.configuration.keyboard.capsLockAlone === 'escape',
    onChange: on => model.update(config => {
      config.keyboard.capsLockAlone = on ? 'escape' : 'nothing';
    }),
  });
  tap.row.set_subtitle_lines(0);
  hyperGroup.add(useHyper.row);
  hyperGroup.add(tap.row);
  hyper.column.append(hyperGroup);
  const keydNotice = notice({level: 'info', title: ''});
  hyper.column.append(keydNotice.widget);
  const keydSetup = group();
  keydSetup.add(commandRow('Set up keyd (asks for your password)', 'linux/install.sh --hyper-keyd', ctx.toast));
  hyper.column.append(keydSetup);
  hyper.column.append(note("Already remapping Caps Lock with GNOME Tweaks, kmonad or input-remapper? Turn that off first so the two don't conflict."));

  // --- Hotstrings (espanso)
  const hotstrings = stepPage();
  hotstrings.column.append(stepIcon('insert-text-symbolic'));
  hotstrings.column.append(stepTitle('Let espanso type your hotstrings',
    'Type a short trigger, get a whole sentence. On GNOME, only espanso can type into other apps, so Slated hands it your hotstrings and keeps them in sync.').widget);
  const espansoNotice = notice({level: 'info', title: ''});
  hotstrings.column.append(espansoNotice.widget);
  const install = group();
  let installLink = null;
  install.add(row('Install espanso', 'Its Wayland build, from espanso.org.',
    {suffix: button('Open espanso.org', () => installLink && launchUri(installLink, page), {classes: ['flat']})}));
  install.add(commandRow('Then start it', 'espanso service register && espanso start', ctx.toast));
  hotstrings.column.append(install);
  const yours = group();
  const chipHolder = box('horizontal', 0);
  const yoursRow = row('Your hotstrings', '', {suffix: chipHolder});
  yours.add(yoursRow);
  hotstrings.column.append(yours);

  // --- Slate config
  const slate = stepPage();
  const slateIcon = stepIcon('document-new-symbolic');
  slate.column.append(slateIcon);
  const slateTitle = stepTitle();
  slate.column.append(slateTitle.widget);
  const sourcesGroup = group();
  let sourceRows = [];
  const loadSlate = switchRow({
    title: 'Load my Slate config', subtitle: "Turn off to start fresh with only Slated's own shortcuts.", active: model.slateLoading,
    onChange: on => model.update(config => {
      config.general.loadSlateConfigs = on;
    }),
  });
  const loadGroup = group();
  loadGroup.add(loadSlate.row);
  slate.column.append(sourcesGroup);
  slate.column.append(loadGroup);
  const starterCount = starterBindings(() => '').length;
  const starterGroup = group();
  const starterButton = button(`Add ${starterCount}`, () => {
    const added = model.addStarterBindings();
    ctx.toast(added ? `Added ${plural(added, 'starter shortcut')}` : 'Their keys are taken already');
  }, {classes: ['suggested-action']});
  const starterCheck = icon('object-select-symbolic', {size: 20, classes: ['success']});
  const starterRow = row('', 'Halves, maximize, center, next display and undo, all on ✦.', {suffix: starterButton});
  starterRow.add_suffix(starterCheck);
  starterGroup.add(starterRow);
  slate.column.append(starterGroup);

  // --- Done
  const done = stepPage();
  const doneBadge = box('vertical', 0, ['slated-done-badge']);
  doneBadge.set_halign(Gtk.Align.CENTER);
  const check = icon('object-select-symbolic', {size: 36});
  check.set_vexpand(true);
  doneBadge.append(check);
  done.column.append(doneBadge);
  done.column.append(stepTitle("You're all set",
    "Close this window and Slated keeps working in GNOME Shell. Open Slated's settings from the Extensions app any time to come back here.").widget);
  const checklist = group();
  let checklistRows = [];
  done.column.append(checklist);
  const tip = box('horizontal', 8);
  tip.set_halign(Gtk.Align.CENTER);
  done.column.append(tip);

  for (const [name, step] of [['welcome', welcome], ['hyperKey', hyper], ['hotstrings', hotstrings], ['slateConfig', slate], ['done', done]]) {
    stack.add_named(step.widget, name);
  }

  // --- Footer: Back, progress dots, the main button
  const back = button('Back', () => go(-1), {classes: ['flat']});
  const dots = box('horizontal', 6);
  dots.set_valign(Gtk.Align.CENTER);
  const dotWidgets = STEPS.map(() => {
    const dot = new Gtk.Box({css_classes: ['slated-step-dot'], valign: Gtk.Align.CENTER});
    dots.append(dot);
    return dot;
  });
  const primary = button('', () => {
    if (model.getStartedStep === 'done') ctx.finishGetStarted();
    else go(1);
  }, {classes: ['suggested-action', 'pill']});
  const footer = new Gtk.CenterBox({start_widget: back, center_widget: dots, end_widget: primary, css_classes: ['slated-get-started-footer']});

  function go(delta) {
    const index = STEPS.indexOf(model.getStartedStep) + delta;
    if (index < 0 || index >= STEPS.length) return;
    stack.set_transition_type(delta > 0 ? Gtk.StackTransitionType.SLIDE_LEFT : Gtk.StackTransitionType.SLIDE_RIGHT);
    model.setGetStartedStep(STEPS[index]);
  }

  const sync = () => {
    const config = model.configuration;
    const status = model.status;
    const running = model.running;
    const step = model.getStartedStep;
    const sourceBindings = loadedSourceBindings(model.sources, model.slateLoading);

    // Hyper key
    const hyperOn = config.keyboard.capsLock === 'hyper';
    useHyper.set(hyperOn);
    useHyper.row.set_subtitle(hyperSubtitle({bindings: config.bindings, sourceBindings, hyperOn}));
    tap.set(config.keyboard.capsLockAlone === 'escape');
    tap.row.set_subtitle(tapSubtitle({running, hyper: status.hyper}));
    tap.row.set_sensitive(hyperOn);
    picture.update(running && status.hyper.mode === 'xkb' ? ['hyperModifier'] : config.keyboard.hyperModifiers, hyperOn);
    const keyd = keydAdvice({running, hyper: status.hyper, keydConfigured: fileExists(ctx.paths.keydConfig)});
    keydNotice.update(keyd);
    keydSetup.set_visible(keyd.offerSetup);

    // Hotstrings
    const hs = hotstringsStep({config, status, running});
    espansoNotice.update(hs.guidance);
    installLink = hs.installLink;
    install.set_visible(Boolean(hs.installLink));
    yoursRow.set_subtitle(hs.summary);
    clear(chipHolder);
    if (hs.first) chipHolder.append(triggerChip(hs.first));

    // Slate config
    const s = slateStep({sources: model.sources, slateLoading: model.slateLoading, bindings: config.bindings});
    slateIcon.set_from_icon_name(s.found.length ? 'text-x-generic-symbolic' : 'document-new-symbolic');
    slateTitle.set(s.title, s.subtitle);
    for (const r of sourceRows) sourcesGroup.remove(r);
    sourceRows = s.found.map(source => {
      const caps = box('horizontal', 6);
      for (const b of source.bindings.slice(0, 2)) caps.append(keycaps(b.keys, {modal: b.modal}));
      const r = row(source.displayPath, sourceSummary(source, model.slateLoading), {
        prefix: icon('text-x-generic-symbolic', {size: 20}), suffix: caps,
      });
      r.add_css_class('slated-mono-title');
      sourcesGroup.add(r);
      return r;
    });
    sourcesGroup.set_visible(s.found.length > 0);
    loadGroup.set_visible(s.found.length > 0);
    loadSlate.set(model.slateLoading);
    const added = starterAdded(config.bindings);
    starterGroup.set_visible(s.offerStarter);
    starterRow.set_title(added ? 'Starter shortcuts added' : 'Add starter shortcuts');
    starterButton.set_visible(!added);
    starterCheck.set_visible(added);

    // Done
    const totalShortcuts = config.bindings.filter(b => b.enabled !== false).length + sourceBindings.length;
    for (const r of checklistRows) checklist.remove(r);
    checklistRows = doneChecklist({summary: model.summary(), config, status, running, totalShortcuts}).map(item => {
      const r = row(item.title, '', {
        prefix: icon(item.done ? 'object-select-symbolic' : 'media-record-symbolic', {classes: [item.done ? 'success' : 'slated-warning-text']}),
        suffix: label(item.detail, {classes: ['dim-label'], ellipsize: true}),
      });
      const action = item.action && actions[item.action];
      if (action) r.add_suffix(button(action.label, action.run, {classes: ['flat']}));
      checklist.add(r);
      return r;
    });
    clear(tip);
    const tryIt = tryItTip({bindings: config.bindings, sourceBindings});
    tip.set_visible(Boolean(tryIt));
    if (tryIt) {
      tip.append(label('Try it now:', {classes: ['dim-label']}));
      tip.append(keycaps(tryIt.keys, {modal: tryIt.modal}));
      tip.append(label(tryIt.text, {classes: ['dim-label'], wrap: true}));
    }

    // Step and footer
    if (stack.get_visible_child_name() !== step) stack.set_visible_child_name(step);
    back.set_visible(step !== 'welcome' && step !== 'done');
    const index = STEPS.indexOf(step);
    dotWidgets.forEach((dot, i) => {
      dot.set_css_classes(['slated-step-dot', ...(i === index ? ['current'] : i < index ? ['past'] : [])]);
    });
    dots.set_tooltip_text(`Step ${index + 1} of ${STEPS.length}`);
    primary.set_label(primaryTitle(step, {hotstringsReady: hs.ready}));
  };
  for (const signal of ['config', 'status', 'sources', 'setup']) model.on(signal, sync);
  sync();

  const toolbar = new Adw.ToolbarView({content: stack});
  toolbar.add_top_bar(new Adw.HeaderBar());
  toolbar.add_bottom_bar(footer);
  page.set_child(toolbar);
  return {
    id: 'getStarted',
    title: 'Get Started',
    iconName: 'emoji-flags-symbolic',
    page,
    activate: sync,
    /** "2 of 5" while setup isn't finished, as on the Mac. */
    badge: () => (model.needsSetup ? {text: `${STEPS.indexOf(model.getStartedStep) + 1} of ${STEPS.length}`, warning: false} : null),
  };
}
