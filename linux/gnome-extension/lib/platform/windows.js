// Windows and apps through Mutter and GNOME Shell: the focused window, frames, moving, focusing,
// stacking order on the active workspace, and app ids via Shell.WindowTracker.
//
// Frames are Mutter "frame rects" (the visible window, without client-side shadows), the rect
// `move_resize_frame` takes, in logical top-left-origin coordinates.

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {intersectionArea} from './util.js';

const MANAGED_TYPES = [Meta.WindowType.NORMAL, Meta.WindowType.DIALOG, Meta.WindowType.MODAL_DIALOG, Meta.WindowType.UTILITY];

/** Windows Slated arranges: regular windows and dialogs, not panels, menus or the desktop. */
export function isManaged(window) {
  if (!window) return false;
  try {
    if (window.is_override_redirect()) return false;
    return MANAGED_TYPES.includes(window.get_window_type());
  } catch {
    return false;
  }
}

export function focusedWindow() {
  const window = global.display.get_focus_window();
  return isManaged(window) ? window : null;
}

export function frameOf(window) {
  const r = window.get_frame_rect();
  return {x: r.x, y: r.y, width: r.width, height: r.height};
}

/** False once the window has closed (Mutter drops its actor when it unmanages the window). */
export function isAlive(window) {
  if (!window) return false;
  return global.get_window_actors().some((actor) => actor.get_meta_window() === window);
}

// GNOME 49 reworked maximizing: get_maximized() (flags) gave way to is_maximized() and
// get_maximize_flags(), and unmaximize() lost its MaximizeFlags argument. GNOME 46–48 need the flags.
export function isMaximized(window) {
  if (typeof window.get_maximize_flags === 'function') return window.get_maximize_flags() !== 0;
  if (typeof window.get_maximized === 'function') return window.get_maximized() !== 0;
  if (typeof window.is_maximized === 'function') return window.is_maximized();
  return !!(window.maximized_horizontally || window.maximized_vertically);
}

export function unmaximize(window) {
  if (!isMaximized(window)) return;
  const legacy = typeof window.get_maximized === 'function';
  try {
    if (legacy) window.unmaximize(Meta.MaximizeFlags.BOTH);
    else window.unmaximize();
  } catch {
    if (legacy) window.unmaximize();
    else window.unmaximize(Meta.MaximizeFlags.BOTH);
  }
}

export function allowsMove(window) {
  return typeof window.allows_move === 'function' ? window.allows_move() : true;
}

/**
 * Moves and resizes a window's frame. Leaves fullscreen and maximized (or half-tiled) states first,
 * since Mutter keeps those windows where they are. Wayland apps resize asynchronously; callers check
 * the result a moment later.
 */
export function moveResize(window, rect) {
  if (!allowsMove(window)) return false;
  if (window.is_fullscreen()) window.unmake_fullscreen();
  unmaximize(window);
  const target = {x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)};
  // Moving first helps windows that change monitors (scales can differ). Otherwise skip it: on Wayland
  // it would send an extra configure with the window's old (e.g. maximized) size.
  const monitor = monitorIndexFor(target);
  if (monitor >= 0 && monitor !== window.get_monitor()) window.move_frame(true, target.x, target.y);
  window.move_resize_frame(true, target.x, target.y, target.width, target.height);
  return true;
}

/** The monitor holding most of `rect`, or -1. */
function monitorIndexFor(rect) {
  const display = global.display;
  let best = -1;
  let bestArea = 0;
  for (let i = 0; i < display.get_n_monitors(); i++) {
    const area = intersectionArea(display.get_monitor_geometry(i), rect);
    if (area > bestArea) {
      best = i;
      bestArea = area;
    }
  }
  return best;
}

export function activate(window) {
  Main.activateWindow(window);
}

/** Windows on the active workspace (all monitors), top of the stack first. */
export function stackedWindows({includeMinimized = false} = {}) {
  const workspace = global.workspace_manager.get_active_workspace();
  const windows = workspace.list_windows().filter((w) => isManaged(w) && (includeMinimized || !w.minimized));
  return global.display.sort_windows_by_stacking(windows).reverse();
}

/** Every managed window on every workspace. */
export function allWindows() {
  return global.display.list_all_windows().filter(isManaged);
}

// --- Apps ----------------------------------------------------------------------------------------

export function appOf(window) {
  if (!window) return null;
  try {
    return Shell.WindowTracker.get_default().get_window_app(window);
  } catch {
    return null;
  }
}

/**
 * A stable id for logs and app filters: the desktop file id without ".desktop" ("org.gnome.Terminal",
 * "firefox"), else the window's application id or WM class.
 */
export function appId(app, window = null) {
  if (app && !app.is_window_backed()) return app.get_id().replace(/\.desktop$/, '');
  const w = window ?? app?.get_windows()[0] ?? null;
  return w?.get_gtk_application_id?.() || w?.get_sandboxed_app_id?.() || w?.get_wm_class?.() || app?.get_id() || 'unknown';
}

export function appName(app, window = null) {
  if (app) return app.get_name();
  return window?.get_wm_class?.() ?? '';
}

/** Running apps with windows; the focused app first. */
export function runningApps() {
  const focused = Shell.WindowTracker.get_default().focus_app;
  const apps = Shell.AppSystem.get_default()
    .get_running()
    .filter((app) => app.get_windows().some(isManaged));
  return focused && apps.includes(focused) ? [focused, ...apps.filter((a) => a !== focused)] : apps;
}

/**
 * Whether `name` refers to `app`: its display name ("Terminal"), desktop id with or without
 * ".desktop", the last part of a reverse-DNS id ("Nautilus"), or a window's WM class. Case-insensitive,
 * so Slate configs that name macOS apps by their display name keep working where names match.
 */
export function appMatches(app, name) {
  const wanted = String(name).trim().toLowerCase();
  if (!wanted) return false;
  const candidates = new Set();
  const add = (value) => value && candidates.add(String(value).toLowerCase());
  add(app.get_name());
  const id = app.get_id();
  add(id);
  add(id.replace(/\.desktop$/, ''));
  add(id.replace(/\.desktop$/, '').split('.').pop());
  for (const window of app.get_windows()) add(window.get_wm_class());
  add(appId(app));
  return candidates.has(wanted);
}

/** The app's windows on the active workspace, most recently used first. */
export function appWindows(app) {
  const workspace = global.workspace_manager.get_active_workspace();
  return app.get_windows().filter((w) => isManaged(w) && !w.minimized && w.located_on_workspace(workspace));
}

export function isMainWindow(window) {
  const app = appOf(window);
  return !!app && app.get_windows()[0] === window;
}

// GNOME has no app hiding; Slate's hide/show minimize and restore all of an app's windows.
export function hideApp(app) {
  for (const window of app.get_windows()) if (isManaged(window) && !window.minimized) window.minimize();
}

export function showApp(app) {
  for (const window of app.get_windows()) if (isManaged(window) && window.minimized) window.unminimize();
  app.activate();
}

export function isAppHidden(app) {
  const windows = app.get_windows().filter(isManaged);
  return windows.length > 0 && windows.every((w) => w.minimized);
}

export function activateApp(app) {
  for (const window of app.get_windows()) if (isManaged(window) && window.minimized) window.unminimize();
  app.activate();
}
