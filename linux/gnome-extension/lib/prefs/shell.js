// Talking to GNOME Shell and the session from the preferences window (GJS), over D-Bus:
// GNOME Shell's org.gnome.Shell.Extensions interface (the same calls `gnome-extensions info`,
// `enable` and `disable` make), and the session manager for "Log Out…".

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

function call(bus, path, iface, method, parameters, timeout = 3000) {
  return new Promise((resolve, reject) => {
    Gio.DBus.session.call(bus, path, iface, method, parameters, null, Gio.DBusCallFlags.NONE, timeout, null,
      (connection, result) => {
        try {
          resolve(connection.call_finish(result).recursiveUnpack());
        } catch (error) {
          reject(error);
        }
      });
  });
}

const shell = (method, parameters) =>
  call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell.Extensions', method, parameters);

/**
 * GNOME Shell's info about an extension: a plain object ({} when the shell doesn't know it, as after
 * a fresh install on Wayland), or null when the shell can't be reached.
 */
export async function getExtensionInfo(uuid) {
  try {
    const [info] = await shell('GetExtensionInfo', new GLib.Variant('(s)', [uuid]));
    return info ?? {};
  } catch {
    return null;
  }
}

/** Enables or disables the extension. Resolves to true when GNOME Shell accepted the change. */
export async function setExtensionEnabled(uuid, enabled) {
  const [ok] = await shell(enabled ? 'EnableExtension' : 'DisableExtension', new GLib.Variant('(s)', [uuid]));
  return ok === true;
}

/** Opens GNOME's own log-out confirmation (the session manager's Logout with mode 0). */
export async function requestLogout() {
  await call('org.gnome.SessionManager', '/org/gnome/SessionManager', 'org.gnome.SessionManager', 'Logout',
    new GLib.Variant('(u)', [0]), 60000);
}
