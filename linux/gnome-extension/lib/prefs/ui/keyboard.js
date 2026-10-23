// Settings → Keyboard: Caps Lock as a Hyper key (the Karabiner-Elements part; port of
// KeyboardPane.swift). On GNOME there are two ways to get there, and the extension reports which
// one is active in status.json ("hyper.mode"):
//
// - xkb: GNOME's own keyboard option (caps:hyper). No extra software; Caps Lock becomes the Hyper
//   modifier. Some layouts share it with Super, and tapping it alone can't send Escape.
// - keyd: a small system daemon maps Caps Lock to Ctrl+Alt+Shift+Super, exactly like the macOS
//   Hyper key, and can send Escape on a tap. Set up once with `linux/install.sh --hyper-keyd`.
//
// keyd's configuration is a root-owned file, so the extension can't change it: the installer writes
// it from config.json's capsLockAlone and hyperModifiers, and this page says to run it again after
// changing either. GNOME's option always sends Hyper and can't tell a tap from a hold.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {box, label, group, switchRow, comboRow, pill, commandRow} from './widgets.js';

const MODIFIER_ITEMS = [
  {id: 'hyper', label: 'Hyper: Ctrl Alt Shift Super'},
  {id: 'meh', label: 'Meh: Ctrl Alt Shift'},
];

function keycap(text, accent = false) {
  const classes = ['slated-keycap', 'large'];
  if (accent) classes.push('hyper');
  return new Gtk.Label({label: text, css_classes: classes, valign: Gtk.Align.CENTER});
}

/** Caps Lock → ✦ = Ctrl + Alt + Shift + Super (or Hyper, with GNOME's option), drawn with keycaps. */
function illustration() {
  const row = box('horizontal', 8);
  row.set_halign(Gtk.Align.CENTER);
  row.set_margin_top(12);
  row.set_margin_bottom(12);
  const caps = keycap('Caps Lock');
  const arrow = label('→', {classes: ['title-2', 'dim-label']});
  const hyper = keycap('✦', true);
  const equals = label('=', {classes: ['title-3', 'dim-label']});
  row.append(caps);
  row.append(arrow);
  row.append(hyper);
  row.append(equals);
  const mods = box('horizontal', 4);
  row.append(mods);
  return {
    widget: row,
    update(modifiers, on) {
      let child = mods.get_first_child();
      while (child) {
        const next = child.get_next_sibling();
        mods.remove(child);
        child = next;
      }
      const names = {ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', cmd: 'Super', hyperModifier: 'Hyper'};
      modifiers.forEach((m, i) => {
        if (i) mods.append(label('+', {classes: ['dim-label']}));
        mods.append(keycap(names[m] ?? m));
      });
      row.set_opacity(on ? 1 : 0.5);
    },
  };
}

export function createKeyboardPane(ctx) {
  const model = ctx.model;
  const prefs = new Adw.PreferencesPage();

  // Hero
  const hero = group({title: 'Caps Lock as Hyper',
    description: 'Hold Caps Lock and press another key for a ✦ shortcut, like ✦← for the left half. With keyd, ✦ is Ctrl, Alt, Shift and Super at once, a combination apps leave alone.'});
  const statusPill = box('horizontal', 0);
  hero.set_header_suffix(statusPill);
  const picture = illustration();
  hero.add(picture.widget);
  const enabled = switchRow({
    title: 'Use Caps Lock as Hyper', subtitle: 'Caps Lock no longer toggles capitals; hold Shift instead.',
    active: model.configuration.keyboard.capsLock === 'hyper',
    onChange: on => model.update(config => {
      config.keyboard.capsLock = on ? 'hyper' : 'off';
    }),
  });
  hero.add(enabled.row);
  prefs.add(hero);

  // Modes
  const modes = group({title: 'How Slated Does It',
    description: 'Wayland lets no app remap keys, so the Hyper key comes from GNOME itself or from keyd. Slated uses whichever is set up.'});
  const xkbRow = new Adw.ActionRow({
    use_markup: false,
    title: 'GNOME keyboard option (xkb)',
    subtitle: 'Built in, nothing to install: GNOME turns Caps Lock into the Hyper modifier (caps:hyper). In many keyboard layouts Hyper shares a modifier with Super, so GNOME takes ✦A and Super+A for the same shortcut. Tapping Caps Lock alone does nothing.',
  });
  xkbRow.set_subtitle_lines(0);
  const xkbBadge = box('horizontal', 0);
  xkbRow.add_suffix(xkbBadge);
  modes.add(xkbRow);
  const keydRow = new Adw.ActionRow({
    use_markup: false,
    title: 'keyd',
    subtitle: 'A small system service sends Ctrl+Alt+Shift+Super while Caps Lock is held, exactly like the macOS Hyper key, in every app (Xwayland too), and can send Escape on a tap. Set it up once from the Slated source folder:',
  });
  keydRow.set_subtitle_lines(0);
  const keydBadge = box('horizontal', 0);
  keydRow.add_suffix(keydBadge);
  modes.add(keydRow);
  modes.add(commandRow('Set up keyd (asks for your password)', 'linux/install.sh --hyper-keyd', ctx.toast));
  prefs.add(modes);

  // Options
  const options = group({title: 'Options'});
  const escape = switchRow({
    title: 'Tap Caps Lock alone for Escape', subtitle: '',
    active: model.configuration.keyboard.capsLockAlone === 'escape',
    onChange: on => model.update(config => {
      config.keyboard.capsLockAlone = on ? 'escape' : 'nothing';
    }),
  });
  options.add(escape.row);
  const modifiers = comboRow({
    title: 'Hyper key sends', subtitle: '', items: MODIFIER_ITEMS,
    selected: model.configuration.keyboard.hyperModifiers.includes('cmd') ? 'hyper' : 'meh',
    onChange: id => model.update(config => {
      config.keyboard.hyperModifiers = id === 'hyper' ? ['ctrl', 'alt', 'shift', 'cmd'] : ['ctrl', 'alt', 'shift'];
    }),
  });
  options.add(modifiers.row);
  prefs.add(options);

  // Good to know
  const know = group({title: 'Good to Know'});
  const karabiner = new Adw.ActionRow({
    use_markup: false,
    title: 'Like Karabiner-Elements, built into GNOME',
    subtitle: "On the Mac, Karabiner-Elements remaps Caps Lock with a driver. On GNOME, Slated asks the keyboard layer GNOME already has (or keyd) to do the same, so there's no extra app to keep running.",
  });
  karabiner.set_subtitle_lines(0);
  know.add(karabiner);
  const others = new Adw.ActionRow({
    use_markup: false,
    title: 'Already remapping Caps Lock?',
    subtitle: 'GNOME Tweaks, keyd, kmonad or input-remapper may also claim Caps Lock. Keep only one of them in charge of it.',
  });
  others.set_subtitle_lines(0);
  know.add(others);
  const terminals = new Adw.ActionRow({
    use_markup: false,
    title: 'Hyper in terminals and games',
    subtitle: "Apps that read raw keys may see Hyper as Super in xkb mode. keyd mode sends real modifiers, so it behaves the same everywhere.",
  });
  terminals.set_subtitle_lines(0);
  know.add(terminals);
  prefs.add(know);

  const sync = () => {
    const keyboard = model.configuration.keyboard;
    const on = keyboard.capsLock === 'hyper';
    const hyper = model.status.hyper;
    enabled.set(on);
    escape.set(keyboard.capsLockAlone === 'escape');
    modifiers.set(keyboard.hyperModifiers.includes('cmd') ? 'hyper' : 'meh');
    const xkb = model.running && hyper.mode === 'xkb';
    picture.update(xkb ? ['hyperModifier'] : keyboard.hyperModifiers, on);
    options.set_sensitive(on);
    let status;
    if (!on) status = {label: 'Off', style: 'dim'};
    else if (!model.running) status = {label: 'Not running', style: 'dim'};
    else if (hyper.active) status = {label: `Active · ${hyper.mode}`, style: 'success'};
    else status = {label: 'Not active', style: 'warning'};
    statusPill.get_first_child() && statusPill.remove(statusPill.get_first_child());
    statusPill.append(pill(status));
    for (const [holder, mode] of [[xkbBadge, 'xkb'], [keydBadge, 'keyd']]) {
      holder.get_first_child() && holder.remove(holder.get_first_child());
      if (model.running && hyper.mode === mode) holder.append(pill({label: hyper.active ? 'In use' : 'Selected', style: hyper.active ? 'success' : 'warning'}));
    }
    const keyd = model.running && hyper.mode === 'keyd';
    const rerun = 'keyd applies it: run linux/install.sh --hyper-keyd again after changing this.';
    escape.row.set_subtitle(xkb
      ? "Needs keyd: GNOME's keyboard option can't tell a tap from a hold."
      : keyd ? `A quick tap sends Escape; holding it is still Hyper. ${rerun}`
        : 'A quick tap sends Escape; holding it is still Hyper. On GNOME this needs keyd (see above).');
    const choice = keyboard.hyperModifiers.includes('cmd')
      ? 'All four, like the Mac\'s Hyper key.'
      : 'Meh leaves out Super, so ✦ shortcuts stay clear of GNOME\'s own Super shortcuts.';
    modifiers.row.set_subtitle(xkb
      ? "GNOME's keyboard option always sends the Hyper modifier; this applies with keyd and on the Mac."
      : keyd ? `${choice} ${rerun}` : choice);
  };
  model.on('config', sync);
  model.on('status', sync);
  sync();

  const page = new Adw.NavigationPage({title: 'Keyboard', tag: 'keyboard'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  return {id: 'keyboard', title: 'Keyboard', iconName: 'input-keyboard-symbolic', page, badge: () => null};
}
