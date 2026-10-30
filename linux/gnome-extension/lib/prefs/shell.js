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

const EXTENSIONS_IFACE = 'org.gnome.Shell.Extensions';
const properties = (method, parameters) => call('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', method, parameters);

/**
 * GNOME's Extensions switch (the Extensions app's main switch, org.gnome.shell disable-user-extensions
 * inverted): true or false, or null when GNOME Shell can't be reached. While it's off, no user
 * extension runs.
 */
export async function getUserExtensionsEnabled() {
  try {
    const [value] = await properties('Get', new GLib.Variant('(ss)', [EXTENSIONS_IFACE, 'UserExtensionsEnabled']));
    return typeof value === 'boolean' ? value : null;
  } catch {
    return null;
  }
}

/** Turns GNOME's Extensions switch on or off, as the Extensions app does. */
export async function setUserExtensionsEnabled(enabled) {
  await properties('Set', new GLib.Variant('(ssv)', [EXTENSIONS_IFACE, 'UserExtensionsEnabled', new GLib.Variant('b', enabled)]));
}

/** Where espanso may be when it isn't on the settings window's PATH (as the extension looks). */
const ESPANSO_DIRS = ['/usr/local/bin', '/usr/bin', '/snap/bin', '/var/lib/flatpak/exports/bin'];

/**
 * Whether espanso runs, from `espanso status` (it exits 0 only while espanso runs, as linux/install.sh
 * relies on). Resolves to true or false, or null when espanso can't be found or asked.
 */
export function espansoRunning(home) {
  return new Promise(resolve => {
    try {
      const binary = GLib.find_program_in_path('espanso')
        ?? [`${home}/.local/bin`, ...ESPANSO_DIRS].map(dir => `${dir}/espanso`).find(path => GLib.file_test(path, GLib.FileTest.IS_EXECUTABLE));
      if (!binary) {
        resolve(null);
        return;
      }
      const proc = Gio.Subprocess.new([binary, 'status'], Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
      proc.wait_async(null, (p, result) => {
        try {
          p.wait_finish(result);
          resolve(p.get_successful());
        } catch {
          resolve(null);
        }
      });
    } catch {
      resolve(null);
    }
  });
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
