// A brief, unobtrusive pill near the bottom of the primary monitor confirming what just happened
// ("Left half · Firefox"), when `general.showActionHUD` is on. A port of the macOS ActionHUD.

import Clutter from 'gi://Clutter';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const VISIBLE_MS = 900;
const FADE_MS = 250;
const BOTTOM_MARGIN = 72;

export class ActionHUD {
  constructor() {
    this._actor = null;
    this._label = null;
  }

  show(message) {
    if (!this._actor) {
      this._actor = new St.BoxLayout({style_class: 'slated-hud', reactive: false, can_focus: false, track_hover: false});
      this._actor.add_child(new St.Icon({icon_name: 'view-grid-symbolic', style_class: 'slated-hud-icon', y_align: Clutter.ActorAlign.CENTER}));
      this._label = new St.Label({style_class: 'slated-hud-label', y_align: Clutter.ActorAlign.CENTER});
      this._actor.add_child(this._label);
      // Above windows, like GNOME's own on-screen displays; never takes input.
      Main.uiGroup.add_child(this._actor);
    }
    this._label.text = message;
    this._actor.remove_all_transitions();
    this._actor.opacity = 255;
    this._actor.show();
    Main.uiGroup.set_child_above_sibling(this._actor, null);

    const area = Main.layoutManager.getWorkAreaForMonitor(Main.layoutManager.primaryIndex);
    const [, width] = this._actor.get_preferred_width(-1);
    const [, height] = this._actor.get_preferred_height(width);
    this._actor.set_position(Math.round(area.x + (area.width - width) / 2), Math.round(area.y + area.height - height - BOTTOM_MARGIN));

    this._actor.ease({
      opacity: 0,
      delay: VISIBLE_MS,
      duration: FADE_MS,
      mode: Clutter.AnimationMode.EASE_OUT_QUAD,
      onComplete: () => this._actor?.hide(),
    });
  }

  destroy() {
    if (this._actor) {
      this._actor.remove_all_transitions();
      this._actor.destroy();
    }
    this._actor = null;
    this._label = null;
  }
}
