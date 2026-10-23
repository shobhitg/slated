// Shared test data: a landscape main screen with GNOME's top bar, and a portrait screen to its right.

export const landscape = Object.freeze({
  displayID: 0,
  name: 'Monitor 1',
  frame: {x: 0, y: 0, width: 1920, height: 1080},
  visibleFrame: {x: 0, y: 32, width: 1920, height: 1048},
  isMain: true,
  scale: 1,
});

export const portrait = Object.freeze({
  displayID: 1,
  name: 'Monitor 2',
  frame: {x: 1920, y: 0, width: 1080, height: 1920},
  visibleFrame: {x: 1920, y: 0, width: 1080, height: 1920},
  isMain: false,
  scale: 1,
});

export const screens = [landscape, portrait];

export const leftHalf = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'};
export const rightHalf = {op: 'move', x: 'screenOriginX+screenSizeX/2', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'};
export const topHalf = {op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/2'};

/** GLib timeouts with virtual time, like timers.js `Timers` (timeout, clear, advance). */
export class FakeTimers {
  constructor() {
    this.now = 0;
    this.sources = new Map();
    this.next = 1;
  }
  timeout(ms, callback) {
    const id = this.next++;
    this.sources.set(id, {due: this.now + Math.max(0, Math.round(ms)), callback});
    return id;
  }
  idle(callback) {
    return this.timeout(0, callback);
  }
  clear(id) {
    if (id) this.sources.delete(id);
    return 0;
  }
  get pending() {
    return this.sources.size;
  }
  /** Moves time forward `ms`, running timeouts as they come due (in order). */
  advance(ms) {
    const end = this.now + ms;
    for (;;) {
      const due = [...this.sources.entries()].filter(([, s]) => s.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
      if (!due) break;
      this.now = due[1].due;
      this.sources.delete(due[0]);
      due[1].callback();
    }
    this.now = end;
  }
}

/** A recording EventLog stand-in. */
export class MemoryLog {
  constructor() {
    this.events = [];
  }
  record(event, data = {}, level = 'info') {
    this.events.push({event, data, level});
  }
  notice(event, data = {}) {
    this.record(event, data, 'notice');
  }
  error(event, message, data = {}) {
    this.record(event, {...data, message}, 'error');
  }
  named(event) {
    return this.events.filter((e) => e.event === event);
  }
}
