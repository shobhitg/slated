// A plain GTK 4 window for the end-to-end tests to move around: `gjs -m test-window.js`.
// Its application id matches io.github.shobhitg.SlatedTest.desktop, which run.sh installs, so
// GNOME Shell knows it as an app.
//
// For the automation checks it records what reaches it in $HOME/test-window-events.json: mouse
// presses per button, and key presses and releases by key name. The first time it has focus it
// copies "Slated clipboard test" to the clipboard, for the clipboard history checks.

import Gdk from 'gi://Gdk?version=4.0';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';

const EVENTS = GLib.build_filenamev([GLib.get_home_dir(), 'test-window-events.json']);
const events = {buttons: {}, pressed: [], released: []};

function save() {
  GLib.file_set_contents(EVENTS, JSON.stringify(events));
}

const app = new Gtk.Application({application_id: 'io.github.shobhitg.SlatedTest'});
app.connect('activate', () => {
  const window = new Gtk.ApplicationWindow({
    application: app,
    title: 'Slated test window',
    default_width: 640,
    default_height: 480,
  });
  window.set_child(new Gtk.Label({label: 'Slated end-to-end test window', hexpand: true, vexpand: true}));

  const clicks = new Gtk.GestureClick({button: 0});
  clicks.connect('pressed', (gesture) => {
    const button = String(gesture.get_current_button());
    events.buttons[button] = (events.buttons[button] ?? 0) + 1;
    save();
  });
  window.add_controller(clicks);

  const keys = new Gtk.EventControllerKey();
  keys.connect('key-pressed', (_controller, keyval) => {
    events.pressed.push(Gdk.keyval_name(keyval));
    save();
    return false;
  });
  keys.connect('key-released', (_controller, keyval) => {
    events.released.push(Gdk.keyval_name(keyval));
    save();
  });
  window.add_controller(keys);

  let copied = false;
  window.connect('notify::is-active', () => {
    if (copied || !window.is_active) return;
    copied = true;
    window.get_clipboard().set('Slated clipboard test');
  });
  save();
  window.present();
});
app.run([]);
