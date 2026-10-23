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
