// Named window placements offered in the binding editor: the same presets as the macOS app
// (Sources/SlatedUI/Model/WindowPresets.swift), with the screen region each covers for its glyph.
//
// Pure ES module.

import {deepEqual} from './util.js';
import {newId} from './ids.js';
import {canonicalAction} from './engine.js';

export const PRESET_GROUPS = [
  {id: 'halves', title: 'Halves'},
  {id: 'quarters', title: 'Quarters'},
  {id: 'thirds', title: 'Thirds'},
  {id: 'center', title: 'Center & Fill'},
  {id: 'screens', title: 'Displays'},
];

const move = (x, y, width, height) => ({op: 'move', x, y, width, height});
const rect = (x, y, width, height) => ({x, y, width, height});
const corner = (direction) => ({op: 'corner', direction, width: 'screenSizeX/2', height: 'screenSizeY/2'});

function preset(id, title, group, region, icon, action, aliases = []) {
  return Object.freeze({id, title, group, region, icon, action, aliases});
}

/** Every preset, in display order. `region` is in unit screen coordinates (top-left origin). */
export const PRESETS = Object.freeze([
  // Halves
  preset('left-half', 'Left Half', 'halves', rect(0, 0, 0.5, 1), null,
    move('screenOriginX', 'screenOriginY', 'screenSizeX/2', 'screenSizeY'),
    [{op: 'push', direction: 'left', style: 'bar-resize:screenSizeX/2'}]),
  preset('right-half', 'Right Half', 'halves', rect(0.5, 0, 0.5, 1), null,
    move('screenOriginX+screenSizeX/2', 'screenOriginY', 'screenSizeX/2', 'screenSizeY'),
    [{op: 'push', direction: 'right', style: 'bar-resize:screenSizeX/2'}]),
  preset('top-half', 'Top Half', 'halves', rect(0, 0, 1, 0.5), null,
    move('screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY/2'),
    [{op: 'push', direction: 'up', style: 'bar-resize:screenSizeY/2'}]),
  preset('bottom-half', 'Bottom Half', 'halves', rect(0, 0.5, 1, 0.5), null,
    move('screenOriginX', 'screenOriginY+screenSizeY/2', 'screenSizeX', 'screenSizeY/2'),
    [{op: 'push', direction: 'down', style: 'bar-resize:screenSizeY/2'}]),
  // Quarters
  preset('top-left', 'Top Left', 'quarters', rect(0, 0, 0.5, 0.5), null,
    move('screenOriginX', 'screenOriginY', 'screenSizeX/2', 'screenSizeY/2'), [corner('top-left')]),
  preset('top-right', 'Top Right', 'quarters', rect(0.5, 0, 0.5, 0.5), null,
    move('screenOriginX+screenSizeX/2', 'screenOriginY', 'screenSizeX/2', 'screenSizeY/2'), [corner('top-right')]),
  preset('bottom-left', 'Bottom Left', 'quarters', rect(0, 0.5, 0.5, 0.5), null,
    move('screenOriginX', 'screenOriginY+screenSizeY/2', 'screenSizeX/2', 'screenSizeY/2'), [corner('bottom-left')]),
  preset('bottom-right', 'Bottom Right', 'quarters', rect(0.5, 0.5, 0.5, 0.5), null,
    move('screenOriginX+screenSizeX/2', 'screenOriginY+screenSizeY/2', 'screenSizeX/2', 'screenSizeY/2'),
    [corner('bottom-right')]),
  // Thirds
  preset('left-third', 'Left Third', 'thirds', rect(0, 0, 1 / 3, 1), null,
    move('screenOriginX', 'screenOriginY', 'screenSizeX/3', 'screenSizeY')),
  preset('center-third', 'Center Third', 'thirds', rect(1 / 3, 0, 1 / 3, 1), null,
    move('screenOriginX+screenSizeX/3', 'screenOriginY', 'screenSizeX/3', 'screenSizeY')),
  preset('right-third', 'Right Third', 'thirds', rect(2 / 3, 0, 1 / 3, 1), null,
    move('screenOriginX+screenSizeX*2/3', 'screenOriginY', 'screenSizeX/3', 'screenSizeY')),
  preset('left-two-thirds', 'Left Two Thirds', 'thirds', rect(0, 0, 2 / 3, 1), null,
    move('screenOriginX', 'screenOriginY', 'screenSizeX*2/3', 'screenSizeY')),
  preset('right-two-thirds', 'Right Two Thirds', 'thirds', rect(1 / 3, 0, 2 / 3, 1), null,
    move('screenOriginX+screenSizeX/3', 'screenOriginY', 'screenSizeX*2/3', 'screenSizeY')),
  // Center & fill
  preset('center', 'Center', 'center', rect(0.25, 0.22, 0.5, 0.56), null,
    move('screenOriginX+(screenSizeX-windowSizeX)/2', 'screenOriginY+(screenSizeY-windowSizeY)/2', 'windowSizeX',
      'windowSizeY')),
  preset('center-large', 'Center Large', 'center', rect(1 / 6, 1 / 6, 2 / 3, 2 / 3), null,
    move('screenOriginX+screenSizeX/6', 'screenOriginY+screenSizeY/6', 'screenSizeX*2/3', 'screenSizeY*2/3')),
  preset('almost-maximize', 'Almost Maximize', 'center', rect(0.06, 0.06, 0.88, 0.88), null,
    move('screenOriginX+screenSizeX/20', 'screenOriginY+screenSizeY/20', 'screenSizeX*0.9', 'screenSizeY*0.9')),
  preset('maximize', 'Maximize', 'center', rect(0, 0, 1, 1), null,
    move('screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY'),
    [{op: 'corner', direction: 'top-left', width: 'screenSizeX', height: 'screenSizeY'}]),
  // Displays
  preset('throw-next', 'Next Display', 'screens', null, 'go-last-symbolic', {op: 'throw', screen: 'next'}),
  preset('throw-previous', 'Previous Display', 'screens', null, 'go-first-symbolic', {op: 'throw', screen: 'previous'}),
  preset('throw-next-max', 'Next Display, Maximized', 'screens', null, 'view-fullscreen-symbolic',
    {op: 'throw', screen: 'next', width: 'screenSizeX', height: 'screenSizeY'}),
]);

export function presetById(id) {
  const found = PRESETS.find(p => p.id === id);
  if (!found) throw new Error(`No preset "${id}"`);
  return found;
}

/** Canonical form for comparison; actions the engine can't read compare as they are. */
function comparable(action) {
  try {
    return canonicalAction(action);
  } catch {
    return action;
  }
}

/** The preset an action corresponds to (any spelling of it), or null. */
export function matchingPreset(action) {
  if (action === undefined || action === null) return null;
  const target = comparable(action);
  return PRESETS.find(p => deepEqual(target, p.action) || p.aliases.some(alias => deepEqual(target, alias))) ?? null;
}

export function presetMatches(presetEntry, action) {
  const target = comparable(action);
  return deepEqual(target, presetEntry.action) || presetEntry.aliases.some(alias => deepEqual(target, alias));
}

/** Default operations for a new Chain: cycle left half → left third → left two-thirds. */
export function defaultChain() {
  return ['left-half', 'left-third', 'left-two-thirds'].map(id => structuredCopy(presetById(id).action));
}

/** Default steps for a new Sequence: move to the next display, then maximize there. */
export function defaultSequence() {
  return [structuredCopy(presetById('throw-next').action), structuredCopy(presetById('maximize').action)];
}

function structuredCopy(value) {
  return JSON.parse(JSON.stringify(value));
}

/** The small starter set offered when Slated has no bindings of its own (as on macOS). */
export function starterBindings(makeId = newId) {
  const pairs = [
    ['left', 'left-half'], ['right', 'right-half'], ['up', 'top-half'], ['down', 'bottom-half'],
    ['return', 'maximize'], ['c', 'center'], ['n', 'throw-next'], ['z', 'undo'],
  ];
  return pairs.map(([key, id]) => {
    if (id === 'undo') return {id: makeId(), name: 'Undo', keys: `hyper+${key}`, action: {op: 'undo'}, enabled: true};
    const p = presetById(id);
    return {id: makeId(), name: p.title, keys: `hyper+${key}`, action: structuredCopy(p.action), enabled: true};
  });
}
