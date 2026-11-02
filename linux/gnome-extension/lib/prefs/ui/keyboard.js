// Settings → Keyboard: Caps Lock as a Hyper key (the Karabiner-Elements part; port of
// KeyboardPane.swift). On GNOME there are two ways to get there, and the extension reports which
// one is active in status.json ("hyper.mode"):
//
// - keyd (recommended, the author's choice): a small system daemon maps Caps Lock to
//   Ctrl+Alt+Shift+Super, exactly like the macOS Hyper key, and can send Escape on a tap. Set up once
//   with `linux/install.sh --hyper-keyd`.
// - xkb, the fallback: GNOME's own keyboard option (caps:hyper). No extra software; Caps Lock becomes
//   the Hyper modifier. Some layouts share it with Super, and tapping it alone can't send Escape.
//
// keyd's configuration is a root-owned file, so the extension can't change it: the installer writes
// it from config.json's capsLockAlone and hyperModifiers, and this page says to run it again after
// changing either. GNOME's option always sends Hyper and can't tell a tap from a hold.
//
// Key repeat (config.json's keyboard.keyRepeat, lib/prefs/keyRepeat.js) is on this page too, as on
// the Mac: the extension applies it to GNOME's own setting, and copying config.json to another
// computer (a Mac too) takes it along.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

import {
  GNOME_DEFAULT_KEY_REPEAT, KEY_REPEAT_RANGES, RATE_RANGE, delayLabel, intervalForRate, keyRepeatStatusLine, rateLabel,
  repeatsPerSecond, withKeyRepeat,
} from '../keyRepeat.js';
import {clampKeyRepeat, CONFIG_KEYS} from '../../core/index.js';
import {attachKey, noKey, setSubtitle, settingKey} from './configkeys.js';
import {box, label, group, switchRow, comboRow, pill, commandRow} from './widgets.js';
import {setLinkedDescription} from './filelinks.js';

/** This computer's key repeat (GNOME Settings → Keyboard), clamped as config.json holds it; null if unreadable. */
function computerKeyRepeat() {
  try {
    const settings = new Gio.Settings({schema_id: 'org.gnome.desktop.peripherals.keyboard'});
    return clampKeyRepeat({delay: settings.get_uint('delay'), interval: settings.get_uint('repeat-interval')});
  } catch {
    return null;
  }
}

/**
 * A slider with a number field beside it, both in milliseconds as far as `onChange` knows: the slider
 * may run in other units (`toScale`/`fromScale`). Returns {row, set(ms)}.
 */
function sliderRow({title, scale: [min, max], marks, spin: [spinMin, spinMax], toScale = v => v, fromScale = v => v, onChange, key = null}) {
  const row = new Adw.ActionRow({use_markup: false, title});
  attachKey(row, key, {title});
  const scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, min, max, 1);
  scale.set_draw_value(false);
  scale.set_hexpand(true);
  scale.set_size_request(220, -1);
  scale.set_valign(Gtk.Align.CENTER);
  for (const [value, text] of marks) scale.add_mark(value, Gtk.PositionType.BOTTOM, text);
  const spin = Gtk.SpinButton.new_with_range(spinMin, spinMax, 1);
  spin.set_valign(Gtk.Align.CENTER);
  spin.set_tooltip_text('Milliseconds');
  row.add_suffix(scale);
  row.add_suffix(spin);
  let quiet = false;
  const set = ms => {
    quiet = true;
    scale.set_value(toScale(ms));
    spin.set_value(ms);
    quiet = false;
  };
  scale.connect('value-changed', () => {
    if (quiet) return;
    const ms = fromScale(Math.round(scale.get_value()));
    quiet = true;
    spin.set_value(ms);
    quiet = false;
    onChange(ms);
  });
  spin.connect('value-changed', () => {
    if (quiet) return;
    const ms = Math.round(spin.get_value());
    quiet = true;
    scale.set_value(toScale(ms));
    quiet = false;
    onChange(ms);
  });
  return {row, set};
}

const MODIFIER_ITEMS = [
  {id: 'hyper', label: 'Hyper: Ctrl Alt Shift Super'},
  {id: 'meh', label: 'Meh: Ctrl Alt Shift'},
];

function keycap(text, accent = false) {
  const classes = ['slated-keycap', 'large'];
  if (accent) classes.push('hyper');
  return new Gtk.Label({label: text, css_classes: classes, valign: Gtk.Align.CENTER});
}

/**
 * Caps Lock → ✦ = Ctrl + Alt + Shift + Super (or Hyper, with GNOME's option), drawn with keycaps.
 * Also on Get Started's Hyper key step.
 */
export function hyperIllustration() {
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
  const picture = hyperIllustration();
  hero.add(picture.widget);
  const enabled = switchRow({
    title: 'Use Caps Lock as Hyper', subtitle: 'Caps Lock no longer toggles capitals; hold Shift instead.',
    active: model.configuration.keyboard.capsLock === 'hyper', key: settingKey(CONFIG_KEYS.capsLock),
    onChange: on => model.update(config => {
      config.keyboard.capsLock = on ? 'hyper' : 'off';
    }),
  });
  hero.add(enabled.row);
  prefs.add(hero);

  // Modes
  const modes = group({title: 'How Slated Does It',
    description: 'Wayland lets no app remap keys, so the Hyper key comes from keyd or from GNOME itself. keyd is recommended: it works exactly like the Mac. Until it’s set up, Slated uses GNOME’s option.'});
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
  const xkbRow = new Adw.ActionRow({
    use_markup: false,
    title: 'GNOME keyboard option (xkb)',
    subtitle: 'Built in, nothing to install: GNOME turns Caps Lock into the Hyper modifier (caps:hyper). In many keyboard layouts Hyper shares a modifier with Super, so GNOME takes ✦A and Super+A for the same shortcut. Tapping Caps Lock alone does nothing.',
  });
  xkbRow.set_subtitle_lines(0);
  const xkbBadge = box('horizontal', 0);
  xkbRow.add_suffix(xkbBadge);
  modes.add(xkbRow);
  prefs.add(modes);

  // Options
  const options = group({title: 'Options'});
  const escape = switchRow({
    title: 'Tap Caps Lock alone for Escape', subtitle: '',
    active: model.configuration.keyboard.capsLockAlone === 'escape', key: settingKey(CONFIG_KEYS.capsLockAlone),
    onChange: on => model.update(config => {
      config.keyboard.capsLockAlone = on ? 'escape' : 'nothing';
    }),
  });
  options.add(escape.row);
  const modifiers = comboRow({
    title: 'Hyper key sends', subtitle: '', items: MODIFIER_ITEMS, key: settingKey(CONFIG_KEYS.hyperModifiers),
    selected: model.configuration.keyboard.hyperModifiers.includes('cmd') ? 'hyper' : 'meh',
    onChange: id => model.update(config => {
      config.keyboard.hyperModifiers = id === 'hyper' ? ['ctrl', 'alt', 'shift', 'cmd'] : ['ctrl', 'alt', 'shift'];
    }),
  });
  options.add(modifiers.row);
  prefs.add(options);

  // Key repeat
  const repeat = setLinkedDescription(group({title: 'Key Repeat'}),
    'How long a held key waits before it repeats, and how fast it repeats then. Saved in config.json, so every computer you use Slated on gets the same, a Mac too. GNOME uses a change right away.');
  const setKeyRepeat = value => model.update(config => {
    config.keyboard = withKeyRepeat(config, value).keyboard;
  });
  const current = () => model.configuration.keyboard.keyRepeat ?? null;
  const repeatSwitch = switchRow({
    title: 'Set key repeat with Slated', subtitle: 'Off leaves GNOME’s own setting as it is.',
    active: !!current(), key: settingKey(CONFIG_KEYS.keyRepeat),
    onChange: on => setKeyRepeat(on ? (current() ?? computerKeyRepeat() ?? GNOME_DEFAULT_KEY_REPEAT) : null),
  });
  repeat.add(repeatSwitch.row);
  const delay = sliderRow({
    title: 'Delay until repeat', scale: KEY_REPEAT_RANGES.delay, spin: KEY_REPEAT_RANGES.delay, key: settingKey(CONFIG_KEYS.keyRepeatDelay),
    marks: [[KEY_REPEAT_RANGES.delay[0], 'Short'], [KEY_REPEAT_RANGES.delay[1], 'Long']],
    onChange: ms => setKeyRepeat({...(current() ?? GNOME_DEFAULT_KEY_REPEAT), delay: ms}),
  });
  repeat.add(delay.row);
  // The slider runs in repeats per second, faster to the right; the field is the interval in ms.
  const rate = sliderRow({
    title: 'Repeat rate', scale: RATE_RANGE, spin: KEY_REPEAT_RANGES.interval, key: settingKey(CONFIG_KEYS.keyRepeatInterval),
    marks: [[RATE_RANGE[0], 'Slow'], [RATE_RANGE[1], 'Fast']],
    toScale: repeatsPerSecond, fromScale: intervalForRate,
    onChange: ms => setKeyRepeat({...(current() ?? GNOME_DEFAULT_KEY_REPEAT), interval: ms}),
  });
  repeat.add(rate.row);
  const useComputer = new Adw.ActionRow({use_markup: false, title: 'Use this computer’s current setting'});
  useComputer.set_subtitle_lines(0);
  const useButton = new Gtk.Button({label: 'Use', valign: Gtk.Align.CENTER});
  useButton.connect('clicked', () => {
    const value = computerKeyRepeat();
    if (!value) {
      ctx.toast?.('Couldn’t read GNOME’s key repeat setting.');
      return;
    }
    setKeyRepeat(value);
    ctx.toast?.(`Key repeat set to ${delayLabel(value.delay)}, ${rateLabel(value.interval)}.`);
  });
  useComputer.add_suffix(useButton);
  repeat.add(useComputer);
  // A place to hold a key down; nothing typed here is kept or logged.
  const tryIt = noKey(new Adw.EntryRow({use_markup: false, title: 'Try it here: hold a key'}), 'a test field that isn\'t saved');
  repeat.add(tryIt);
  const repeatStatus = new Adw.ActionRow({use_markup: false, title: 'Status'});
  const repeatPill = box('horizontal', 0);
  repeatPill.set_valign(Gtk.Align.CENTER);
  repeatStatus.add_suffix(repeatPill);
  repeat.add(repeatStatus);
  prefs.add(repeat);

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
      else if (mode === 'keyd') holder.append(pill({label: 'Recommended', style: 'accent'}));
    }
    const keyd = model.running && hyper.mode === 'keyd';
    const rerun = 'keyd applies it: run linux/install.sh --hyper-keyd again after changing this.';
    setSubtitle(escape.row, xkb
      ? "Needs keyd: GNOME's keyboard option can't tell a tap from a hold."
      : keyd ? `A quick tap sends Escape; holding it is still Hyper. ${rerun}`
        : 'A quick tap sends Escape; holding it is still Hyper. On GNOME this needs keyd (see above).');
    const choice = keyboard.hyperModifiers.includes('cmd')
      ? 'All four, like the Mac\'s Hyper key.'
      : 'Meh leaves out Super, so ✦ shortcuts stay clear of GNOME\'s own Super shortcuts.';
    setSubtitle(modifiers.row, xkb
      ? "GNOME's keyboard option always sends the Hyper modifier; this applies with keyd and on the Mac."
      : keyd ? `${choice} ${rerun}` : choice);

    const keyRepeat = keyboard.keyRepeat ?? null;
    const shown = keyRepeat ?? computerKeyRepeat() ?? GNOME_DEFAULT_KEY_REPEAT;
    repeatSwitch.set(!!keyRepeat);
    delay.set(shown.delay);
    rate.set(shown.interval);
    setSubtitle(delay.row, delayLabel(shown.delay));
    setSubtitle(rate.row, rateLabel(shown.interval));
    delay.row.set_sensitive(!!keyRepeat);
    rate.row.set_sensitive(!!keyRepeat);
    const computer = computerKeyRepeat();
    useComputer.set_subtitle(computer ? `GNOME has ${delayLabel(computer.delay)}, ${rateLabel(computer.interval)}.` : 'GNOME’s setting can’t be read.');
    useButton.set_sensitive(!!computer);
    repeatPill.get_first_child() && repeatPill.remove(repeatPill.get_first_child());
    const line = keyRepeatStatusLine(keyRepeat, {running: model.running, keyRepeat: model.status.keyRepeat});
    repeatPill.append(pill(line));
    repeatStatus.set_subtitle(line.detail);
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
