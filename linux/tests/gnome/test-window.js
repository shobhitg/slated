// A plain GTK 4 window for the end-to-end tests to move around: `gjs -m test-window.js`.
// Its application id matches io.github.shobhit_aida.SlatedTest.desktop, which run.sh installs, so
// GNOME Shell knows it as an app.

import Gtk from 'gi://Gtk?version=4.0';

const app = new Gtk.Application({application_id: 'io.github.shobhit_aida.SlatedTest'});
app.connect('activate', () => {
  const window = new Gtk.ApplicationWindow({
    application: app,
    title: 'Slated test window',
    default_width: 640,
    default_height: 480,
  });
  window.set_child(new Gtk.Label({label: 'Slated end-to-end test window'}));
  window.present();
});
app.run([]);
