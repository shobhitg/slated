// A pretend desktop for the Slate JavaScript engine: two screens (landscape and portrait), a window on
// each, two apps, and recordings of what scripts make the host do.

import {screens} from './fixtures.mjs';

export const LANDSCAPE_WINDOW = 1;
export const PORTRAIT_WINDOW = 2;

export class FakeHost {
  constructor() {
    this.screenList = screens;
    this.windowsByHandle = new Map([
      [LANDSCAPE_WINDOW, {handle: LANDSCAPE_WINDOW, title: 'Mail', frame: {x: 100, y: 100, width: 800, height: 600}, pid: 10, isMain: true}],
      [PORTRAIT_WINDOW, {handle: PORTRAIT_WINDOW, title: 'Docs', frame: {x: 2100, y: 300, width: 700, height: 900}, pid: 20, isMain: true}],
    ]);
    this.apps = [
      {pid: 10, name: 'Firefox', bundleID: 'firefox'},
      {pid: 20, name: 'Files', bundleID: 'org.gnome.Nautilus'},
    ];
    this.focused = LANDSCAPE_WINDOW;
    this.performed = [];
    this.frames = [];
    this.shells = [];
    this.logs = [];
  }

  focusedWindow() {
    return this.focused;
  }

  windowInfo(handle) {
    const w = this.windowsByHandle.get(handle);
    return w ? {...w, frame: {...w.frame}, isMinimizedOrHidden: false, isMovable: true, isResizable: true} : null;
  }

  windows(pid) {
    return [...this.windowsByHandle.values()].filter((w) => w.pid === pid).map((w) => w.handle);
  }

  runningApps() {
    return this.apps;
  }

  screens() {
    return this.screenList;
  }

  setFrame(rect, handle) {
    this.windowsByHandle.get(handle).frame = {...rect};
    this.frames.push([handle, {...rect}]);
    return true;
  }

  focus(handle) {
    this.focused = handle;
    return true;
  }

  perform(action, handle) {
    this.performed.push({action, window: handle});
    return true;
  }

  runShell(command, wait, path) {
    this.shells.push({command, wait, path});
    return wait ? 'output\n' : null;
  }

  log(message) {
    this.logs.push(message);
  }

  /** Clears recordings. */
  reset() {
    this.performed = [];
    this.frames = [];
    this.shells = [];
    this.logs = [];
  }
}
