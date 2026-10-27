// The "running" pill at the top of the primary monitor while any automation runs, saying what runs
// and how to stop it, like the macOS AutomationIndicator. Styled like the action HUD
// (stylesheet.css: .slated-automation-*). It never takes input, and it stays above fullscreen games.

import Clutter from 'gi://Clutter';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {indicatorText} from './automation.js';

const TOP_MARGIN = 10;

export class AutomationIndicator {
  constructor() {
    this._actor = null;
    this._title = null;
    this._hint = null;
    this._dot = null;
  }

  /** The text currently shown, or null while hidden (tests and status). */
  get text() {
    return this._actor?.visible ? this._title.text : null;
  }

  /**
   * @param {object[]} active  Running automations ({title}).
   * @param {{stopLabel: string|null, visible: boolean}} options  `stopLabel` like "✦ Esc".
   */
  update(active, {stopLabel = null, visible = true} = {}) {
    if (!visible || active.length === 0) {
      this._hide();
      return;
    }
    this._ensureActor();
    this._title.text = indicatorText(active);
    this._hint.text = stopLabel ? `${stopLabel} to stop` : '';
    this._hint.visible = !!stopLabel;
    const wasVisible = this._actor.visible;
    this._actor.show();
    Main.uiGroup.set_child_above_sibling(this._actor, null);
    // Centered just below the top bar of the primary monitor.
    const area = Main.layoutManager.getWorkAreaForMonitor(Main.layoutManager.primaryIndex);
    const [, width] = this._actor.get_preferred_width(-1);
    this._actor.set_position(Math.round(area.x + (area.width - width) / 2), Math.round(area.y + TOP_MARGIN));
    if (!wasVisible) {
      this._dot.remove_all_transitions();
      this._dot.opacity = 255;
      this._dot.ease({opacity: 90, duration: 800, mode: Clutter.AnimationMode.EASE_IN_OUT_QUAD, repeatCount: -1, autoReverse: true});
    }
  }

  destroy() {
    if (this._actor) {
      this._dot?.remove_all_transitions();
      this._actor.destroy();
    }
    this._actor = this._title = this._hint = this._dot = null;
  }

  _ensureActor() {
    if (this._actor) return;
    this._actor = new St.BoxLayout({style_class: 'slated-automation-pill', reactive: false, can_focus: false, track_hover: false});
    this._dot = new St.Widget({style_class: 'slated-automation-dot', y_align: Clutter.ActorAlign.CENTER});
    this._title = new St.Label({style_class: 'slated-automation-title', y_align: Clutter.ActorAlign.CENTER});
    this._hint = new St.Label({style_class: 'slated-automation-hint', y_align: Clutter.ActorAlign.CENTER});
    this._actor.add_child(this._dot);
    this._actor.add_child(this._title);
    this._actor.add_child(this._hint);
    this._actor.hide();
    // Above windows (fullscreen ones too), like GNOME's on-screen displays.
    Main.uiGroup.add_child(this._actor);
  }

  _hide() {
    if (!this._actor) return;
    this._dot?.remove_all_transitions();
    this._actor.hide();
  }
}
