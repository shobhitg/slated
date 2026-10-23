// Shell commands and URLs, for the `shell` and `open-url` actions and `slate.shell`.
//
// Commands run through `/bin/sh -c` in the given directory (home by default), like the macOS app.
// A command that doesn't wait is started and left alone (GLib reaps it). One that waits blocks GNOME
// Shell until it finishes, as Slate's `wait` did, so it is capped at a few seconds with coreutils'
// `timeout`; keep waiting commands quick.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {expandHome} from './util.js';

export const WAIT_LIMIT_SECONDS = 5;

/** Runs `command`; returns `{ok, output}` (output only when waiting) or `{ok: false, error}`. */
export function runShellCommand(command, {wait = false, path = null, home = GLib.get_home_dir()} = {}) {
  try {
    const flags = wait
      ? Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
      : Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE;
    const launcher = new Gio.SubprocessLauncher({flags});
    const directory = expandHome(path || '~', home);
    if (GLib.file_test(directory, GLib.FileTest.IS_DIR)) launcher.set_cwd(directory);
    if (!wait) {
      launcher.spawnv(['/bin/sh', '-c', command]);
      return {ok: true, output: null};
    }
    const timeout = GLib.find_program_in_path('timeout');
    const argv = timeout ? [timeout, String(WAIT_LIMIT_SECONDS), '/bin/sh', '-c', command] : ['/bin/sh', '-c', command];
    const proc = launcher.spawnv(argv);
    const [, stdout] = proc.communicate_utf8(null, null);
    return {ok: true, output: stdout ?? ''};
  } catch (e) {
    return {ok: false, error: e.message ?? String(e)};
  }
}

/** Opens a URL with the default app for its scheme. */
export function openURL(url) {
  if (!GLib.uri_parse_scheme(url)) return {ok: false, error: `Invalid URL ${url}`};
  try {
    Gio.AppInfo.launch_default_for_uri(url, global.create_app_launch_context(0, -1));
    return {ok: true};
  } catch (e) {
    return {ok: false, error: `Couldn't open ${url}: ${e.message}`};
  }
}
