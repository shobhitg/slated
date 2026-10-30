// Opening Slated's settings window (the extension's preferences) from GNOME Shell: the top-bar icon
// and its menu, and Get Started a few seconds after the first login, as the Mac app opens its window
// on Get Started at launch until setup is done.
//
// GNOME Shell shows extension preferences in a separate process (org.gnome.Shell.Extensions), which
// shows one preferences window at a time and doesn't bring an open one forward when asked again. So
// an open Slated window is found among the windows (titled with the extension's name, from that
// process) and activated; only otherwise is GNOME asked to open one.

import {allWindows} from './windows.js';

/** The class or app id of the process that shows extension preferences ("gjs" on some builds). */
const PREFS_PROCESS = /shell\.extensions|^gjs$/i;

/** Whether `window` is Slated's settings window: its title is the extension's name, from that process. */
export function isSettingsWindow(window, title) {
  try {
    if (window.get_title() !== title) return false;
    const ids = [window.get_wm_class?.(), window.get_gtk_application_id?.(), window.get_sandboxed_app_id?.()];
    return ids.some((id) => typeof id === 'string' && PREFS_PROCESS.test(id));
  } catch {
    return false;
  }
}

/** Slated's open settings window, or null. */
export function findSettingsWindow(title, windows = allWindows()) {
  return windows.find((window) => isSettingsWindow(window, title)) ?? null;
}

/** settings-window.json's text → whether Get Started is finished (a missing or broken file: not yet). */
export function setupFinished(text) {
  try {
    return JSON.parse(text ?? 'null')?.setupFinished === true;
  } catch {
    return false;
  }
}

/**
 * Whether to open Get Started now: setup isn't finished, and Slated hasn't opened it yet in this GNOME
 * Shell session (so closing it isn't undone by the next screen unlock, which restarts the extension).
 */
export function shouldOfferGetStarted({stateText, alreadyOpened, locked = false}) {
  return !alreadyOpened && !locked && !setupFinished(stateText);
}
