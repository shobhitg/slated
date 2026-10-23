// Displays as the core's ScreenInfo: `frame` is the monitor's geometry and `visibleFrame` its work area
// (without the top bar and docks), both in Mutter's logical, top-left-origin stage coordinates, the
// same space as window frame rects.
//
// "OS order" (what the core calls the screens' natural order) is the primary monitor first, then the
// others by Mutter's monitor index, mirroring macOS, where the main display comes first.

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const rect = (r) => ({x: r.x, y: r.y, width: r.width, height: r.height});

export function currentScreens() {
  const display = global.display;
  const count = display.get_n_monitors();
  const primary = display.get_primary_monitor();
  const workspace = global.workspace_manager.get_active_workspace();
  const screens = [];
  for (let i = 0; i < count; i++) {
    screens.push({
      displayID: i,
      name: `Monitor ${i + 1}`,
      frame: rect(display.get_monitor_geometry(i)),
      visibleFrame: rect(workspace.get_work_area_for_monitor(i)),
      isMain: i === primary,
      scale: display.get_monitor_scale(i),
    });
  }
  return screens.sort((a, b) => Number(b.isMain) - Number(a.isMain) || a.displayID - b.displayID);
}

/** Calls `onChange` when monitors are added, removed or rearranged. */
export class MonitorWatcher {
  constructor(onChange) {
    this._id = Main.layoutManager.connect('monitors-changed', () => onChange());
  }

  destroy() {
    if (this._id) Main.layoutManager.disconnect(this._id);
    this._id = 0;
  }
}
