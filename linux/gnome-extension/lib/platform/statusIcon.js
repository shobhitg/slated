// Slated's icon in GNOME's top bar: the Mac's menu bar icon (AppDelegate's status item). A click opens
// Slated's settings window; a right click (or Ctrl+click, or a touch) shows a short menu with the
// Mac's commands that apply on GNOME, under the same names. The icon changes while Slated is paused
// or needs attention, and the menu says why. `general.showStatusIcon` (Settings → General) hides it.
//
// Left out from the Mac's menu: Grant Accessibility Access (GNOME asks for no permission), Import
// Slate Config (a dialog: it's in the settings window) and Quit (the Extensions app turns Slated off).

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

/** The menu's items, named as on the Mac. */
export const MENU_ITEMS = Object.freeze({
  open: 'Open Slated',
  hyper: 'Caps Lock → Hyper Key',
  pause: 'Pause Slated',
  reload: 'Reload Configuration',
  config: 'Open Config File',
  settings: 'Open Settings File',
  log: 'Show Log',
});

const MAX_WARNING = 90;

/**
 * What needs attention, one line each, for the menu (the Mac lists its warnings there too).
 * @param {{loadError: string|null, hotkeys: object}} state  hotkeys: status.json's map
 */
export function statusWarnings({loadError = null, hotkeys = {}} = {}) {
  const warnings = [];
  if (loadError) {
    const text = String(loadError).split('\n')[0];
    warnings.push(text.length > MAX_WARNING ? `${text.slice(0, MAX_WARNING - 1)}…` : text);
  }
  const failed = Object.values(hotkeys).filter((s) => String(s).startsWith('failed')).length;
  if (failed) {
    warnings.push(`${failed === 1 ? '1 shortcut' : `${failed} shortcuts`} couldn't be registered: GNOME or another app uses the keys`);
  }
  return warnings;
}

/** Which icon shows: paused before a warning, as the Mac shows its pause icon. */
export function iconName({paused = false, warnings = []} = {}) {
  if (paused) return 'slated-paused-symbolic';
  return warnings.length ? 'slated-warning-symbolic' : 'slated-symbolic';
}

/** The menu's first line, which isn't a command. */
export function headerText({paused = false} = {}) {
  return paused ? 'Slated is paused' : 'Slated is running';
}

export class StatusIcon {
  /**
   * @param {object} options
   * @param {string} options.iconDir  The extension's icons folder.
   * @param {string} options.role  The status area's key for it (the extension's uuid).
   * @param {object} options.commands  {open(reason), toggleHyper(on), togglePause(on), reload(),
   *   openConfig(), openSettings(), showLog()}
   */
  constructor({iconDir, role, commands}) {
    this._iconDir = iconDir;
    this._commands = commands;
    this._iconShown = null;
    this._updating = false;

    this._button = new PanelMenu.Button(0.5, 'Slated', false);
    this._icon = new St.Icon({style_class: 'system-status-icon'});
    this._button.add_child(this._icon);
    // Before PanelMenu.Button's own handler, which opens the menu on any press.
    this._button.connect('event', (_actor, event) => this._onEvent(event));

    const menu = this._button.menu;
    this._header = new PopupMenu.PopupMenuItem('', {reactive: false, can_focus: false});
    menu.addMenuItem(this._header);
    this._warnings = new PopupMenu.PopupMenuSection();
    menu.addMenuItem(this._warnings);
    menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
    this._addItem(MENU_ITEMS.open, () => commands.open('menu'));
    this._hyper = new PopupMenu.PopupSwitchMenuItem(MENU_ITEMS.hyper, false);
    this._hyper.connect('toggled', (_item, on) => this._updating || commands.toggleHyper(on));
    menu.addMenuItem(this._hyper);
    this._pause = new PopupMenu.PopupSwitchMenuItem(MENU_ITEMS.pause, false);
    this._pause.connect('toggled', (_item, on) => this._updating || commands.togglePause(on));
    menu.addMenuItem(this._pause);
    menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
    this._addItem(MENU_ITEMS.reload, () => commands.reload());
    this._addItem(MENU_ITEMS.config, () => commands.openConfig());
    this._addItem(MENU_ITEMS.settings, () => commands.openSettings());
    this._addItem(MENU_ITEMS.log, () => commands.showLog());
    menu.connect('open-state-changed', (_menu, open) => open && commands.menuOpened?.());

    Main.panel.addToStatusArea(role, this._button);
    this.update({});
  }

  _addItem(text, run) {
    const item = new PopupMenu.PopupMenuItem(text);
    item.connect('activate', () => run());
    this._button.menu.addMenuItem(item);
    return item;
  }

  /** A plain click opens Slated; anything else goes on to PanelMenu.Button, which opens the menu. */
  _onEvent(event) {
    const type = event.type();
    if (type !== Clutter.EventType.BUTTON_PRESS && type !== Clutter.EventType.BUTTON_RELEASE) return Clutter.EVENT_PROPAGATE;
    const ctrl = (event.get_state() & Clutter.ModifierType.CONTROL_MASK) !== 0;
    if (event.get_button() !== Clutter.BUTTON_PRIMARY || ctrl) return Clutter.EVENT_PROPAGATE;
    if (type === Clutter.EventType.BUTTON_RELEASE) this._commands.open('status_icon');
    return Clutter.EVENT_STOP;
  }

  /** @param {{paused?: boolean, hyperOn?: boolean, warnings?: string[]}} state */
  update({paused = false, hyperOn = false, warnings = []}) {
    const name = iconName({paused, warnings});
    if (name !== this._iconShown) {
      this._icon.gicon = new Gio.FileIcon({file: Gio.File.new_for_path(`${this._iconDir}/${name}.svg`)});
      this._iconShown = name;
    }
    this._header.label.text = headerText({paused});
    this._warnings.removeAll();
    for (const warning of warnings) {
      this._warnings.addMenuItem(new PopupMenu.PopupMenuItem(`⚠ ${warning}`, {reactive: false, can_focus: false}));
    }
    // Setting the switches isn't a click: don't run the commands.
    this._updating = true;
    try {
      this._hyper.setToggleState(hyperOn);
      this._pause.setToggleState(paused);
    } finally {
      this._updating = false;
    }
  }

  /** The icon's file name, for tests and status. */
  get iconName() {
    return this._iconShown;
  }

  destroy() {
    this._button?.destroy();
    this._button = null;
  }
}
