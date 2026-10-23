// Shell commands and URLs, for the `shell` and `open-url` actions and `slate.shell`.
//
// Commands run through `/bin/sh -c` in the given directory (home by default), like the macOS app.
// GNOME Shell must never block, so:
// - the `shell` action's `wait` doesn't block either: the command starts, and the steps after it in a
//   sequence or layout run once it exits (or after a time limit; the command is never killed);
// - only `slate.shell(command, true)` blocks, because the script needs the output right away. It is
//   capped at a few seconds with coreutils' `timeout`, which stops the command then.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {expandHome} from './util.js';

/** How long `slate.shell(…, true)` may block GNOME Shell. */
export const SCRIPT_WAIT_LIMIT_SECONDS = 3;

function launcherFor(path, home, flags) {
  const launcher = new Gio.SubprocessLauncher({flags});
  const directory = expandHome(path || '~', home);
  if (GLib.file_test(directory, GLib.FileTest.IS_DIR)) launcher.set_cwd(directory);
  return launcher;
}

/**
 * Starts `command` without blocking. Returns `{ok, exited}` (`exited` settles when the process ends)
 * or `{ok: false, error}`.
 */
export function startShellCommand(command, {path = null, home = GLib.get_home_dir()} = {}) {
  try {
    const launcher = launcherFor(path, home, Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
    const proc = launcher.spawnv(['/bin/sh', '-c', command]);
    const exited = new Promise((resolve) => {
      proc.wait_async(null, (p, result) => {
        try {
          p.wait_finish(result);
        } catch {
          // Reaped either way.
        }
        resolve();
      });
    });
    return {ok: true, exited};
  } catch (e) {
    return {ok: false, error: e.message ?? String(e)};
  }
}

/** Runs `command` and returns its output, blocking at most SCRIPT_WAIT_LIMIT_SECONDS. */
export function runShellCommandSync(command, {path = null, home = GLib.get_home_dir()} = {}) {
  try {
    const launcher = launcherFor(path, home, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
    const timeout = GLib.find_program_in_path('timeout');
    const argv = timeout ? [timeout, String(SCRIPT_WAIT_LIMIT_SECONDS), '/bin/sh', '-c', command] : ['/bin/sh', '-c', command];
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
