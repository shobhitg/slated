// A shortcut recorder row: click, then press a shortcut.
//
// While recording, a key controller in the capture phase on the window receives every key first,
// and the window asks the compositor to inhibit system shortcuts (Gdk.Toplevel), so combinations
// GNOME or Slated itself already use reach the recorder instead of running. (The first time, GNOME
// asks whether to allow that.) Holding Caps Lock records ✦ (Hyper) in both Hyper modes: GNOME's
// caps:hyper option reports the Hyper modifier, keyd sends all four of Ctrl, Alt, Shift and Super.
// The recorder also tracks which modifier keys are down: where Hyper shares Super's modifier, the
// key held (Hyper_L or Super_L/R) tells ✦ from Super. Esc cancels; Backspace clears when the row
// allows an empty shortcut.

import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import Gtk from 'gi://Gtk';

import {
  keyNameFromGdk, isModifierKeyName, modifiersFromState, modifiersFromHeldKeys, isAcceptableGlobalShortcut, formatKeyCombo,
  keyLabel, keysCombo,
} from '../keys.js';
import {keycaps, box, label, icon} from './widgets.js';

const MASKS = {
  SHIFT: Gdk.ModifierType.SHIFT_MASK, CONTROL: Gdk.ModifierType.CONTROL_MASK, ALT: Gdk.ModifierType.ALT_MASK,
  SUPER: Gdk.ModifierType.SUPER_MASK, HYPER: Gdk.ModifierType.HYPER_MASK, META: Gdk.ModifierType.META_MASK,
};

export class ShortcutRecorder {
  /**
   * @param {object} options
   * @param {string} options.title the row title
   * @param {string} options.keys the current config string ("hyper+a"; "" for none)
   * @param {(keys: string) => void} options.onChange called with the new config string
   * @param {boolean} [options.requiresModifier] global shortcuts need Ctrl, Alt or Super
   * @param {boolean} [options.allowClear] Backspace clears the shortcut
   * @param {(recording: boolean) => void} [options.onRecording]
   * @param {string} [options.plainKeyHint] added when a key without Ctrl, Alt or Super is refused
   */
  constructor({title, keys, onChange, requiresModifier = true, allowClear = false, onRecording = () => {}, subtitle = '', plainKeyHint = ''}) {
    this.keys = keys ?? '';
    this.onChange = onChange;
    /** Global shortcuts need Ctrl, Alt or Super; one limited to some apps doesn't (settable). */
    this.requiresModifier = requiresModifier;
    this.plainKeyHint = plainKeyHint;
    this.allowClear = allowClear;
    this.onRecording = onRecording;
    this.baseSubtitle = subtitle;
    this.recording = false;
    this.controller = null;
    this.window = null;
    this.held = new Set();

    this.row = new Adw.ActionRow({use_markup: false, title, subtitle});
    this.button = new Gtk.Button({valign: Gtk.Align.CENTER, css_classes: ['slated-recorder']});
    this.button.connect('clicked', () => (this.recording ? this.stop() : this.start()));
    this.row.add_suffix(this.button);
    this.row.set_activatable_widget(this.button);
    this._render();
  }

  /** Shows a new value (from the model); ignored while recording. */
  set(keys) {
    if (this.recording || keys === this.keys) return;
    this.keys = keys ?? '';
    this._render();
  }

  _render(live = null) {
    const content = box('horizontal', 8);
    if (this.recording) {
      content.append(icon('media-record-symbolic', {classes: ['slated-error-text']}));
      if (live && live.length) content.append(keycaps({key: '', modifiers: live}));
      else content.append(label('Press a shortcut…', {classes: ['dim-label']}));
      content.append(label('Esc to cancel', {classes: ['dim-label', 'caption']}));
    } else if (!keysCombo(this.keys).key) {
      content.append(icon('media-record-symbolic'));
      content.append(label('Record Shortcut'));
    } else {
      content.append(keycaps(this.keys));
    }
    this.button.set_child(content);
    this.button.set_tooltip_text(this.recording ? 'Press the keys, or Esc to cancel' : 'Click, then press the keys you want to use');
  }

  _hint(text) {
    this.row.set_subtitle(text ?? this.baseSubtitle);
    if (text) this.row.add_css_class('slated-invalid');
    else this.row.remove_css_class('slated-invalid');
  }

  start() {
    if (this.recording) return;
    const root = this.button.get_root();
    if (!root) return;
    this.recording = true;
    this.window = root;
    this.button.add_css_class('recording');
    this._hint(null);
    this.held = new Set();
    this.controller = new Gtk.EventControllerKey({propagation_phase: Gtk.PropagationPhase.CAPTURE});
    this.controller.connect('key-pressed', (controller, keyval, keycode, state) => this._keyPressed(controller, keyval, keycode, state));
    this.controller.connect('key-released', (controller, keyval) => {
      this.held.delete(Gdk.keyval_name(keyval) ?? '');
      if (this.recording) this._render(modifiersFromHeldKeys(this.held));
    });
    this.controller.connect('modifiers', (controller, state) => {
      this._render(this._live(state));
      return false;
    });
    root.add_controller(this.controller);
    this._inhibit(true);
    this._render([]);
    this.onRecording(true);
  }

  stop() {
    if (!this.recording) return;
    this.recording = false;
    this.button.remove_css_class('recording');
    if (this.controller && this.window) this.window.remove_controller(this.controller);
    this.controller = null;
    this.held.clear();
    this._inhibit(false);
    this.window = null;
    this._render();
    this.onRecording(false);
  }

  _inhibit(on) {
    try {
      const surface = this.button.get_native()?.get_surface();
      if (!surface || !('inhibit_system_shortcuts' in surface)) return;
      if (on) surface.inhibit_system_shortcuts(null);
      else surface.restore_system_shortcuts();
    } catch (error) {
      console.warn(`Slated: couldn't ${on ? 'inhibit' : 'restore'} system shortcuts: ${error.message}`);
    }
  }

  /** The modifiers to show while recording: the keys held, else the state (keys held before recording began). */
  _live(state) {
    const fromKeys = modifiersFromHeldKeys(this.held);
    return fromKeys.length ? fromKeys : modifiersFromState(state, MASKS, this.held);
  }

  _keyPressed(controller, keyval, keycode, state) {
    const rawName = Gdk.keyval_name(keyval) ?? '';
    if (isModifierKeyName(rawName)) {
      this.held.add(rawName);
      this._render(this._live(state));
      return true;
    }
    // The key's name without Shift (so Shift+1 records as 1), in the active layout group.
    let base = keyval;
    try {
      const [ok, translated] = Gdk.Display.get_default().translate_key(keycode, 0, controller.get_group());
      if (ok && translated) base = translated;
    } catch {
      base = Gdk.keyval_to_lower(keyval);
    }
    const name = Gdk.keyval_name(base) ?? '';
    if (isModifierKeyName(name)) return true;
    const modifiers = modifiersFromState(state, MASKS, this.held);
    if (name === 'Escape' && !modifiers.length) {
      this.stop();
      return true;
    }
    if (this.allowClear && name === 'BackSpace' && !modifiers.length) {
      this.keys = '';
      this.stop();
      this.onChange('');
      return true;
    }
    const code = Gdk.keyval_to_unicode(base);
    const key = keyNameFromGdk(name, code ? String.fromCodePoint(code) : '');
    if (!key) {
      this._hint("That key can't be part of a shortcut.");
      return true;
    }
    const combo = {key, modifiers};
    if (this.requiresModifier && !isAcceptableGlobalShortcut(combo)) {
      this._hint(`Add Ctrl, Alt or Super, or hold Caps Lock for ✦. On its own, ${keyLabel(key)} would get in the way of typing.${this.plainKeyHint ? ` ${this.plainKeyHint}` : ''}`);
      return true;
    }
    this.keys = formatKeyCombo(combo);
    this._hint(null);
    this.stop();
    this.onChange(this.keys);
    return true;
  }
}
