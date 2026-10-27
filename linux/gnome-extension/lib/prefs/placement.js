// Where an action would put a sample window, for the live placement preview (port of
// Sources/SlatedUI/Model/PlacementCalculator.swift), and the math that fits the display
// arrangement into the preview's drawing area.
//
// Rects are top-left-origin global coordinates, like Mutter's frame rects and the engine's.
//
// Pure ES module.

import {isObject} from './util.js';
import {targetFrame, isNotImplemented, describeError} from './engine.js';
import {isWindowGeometry, resolveAction, kindById, kindOf, containsAutomation, containsWindowGeometry} from './actions.js';

/**
 * Displays to preview on when status.json doesn't list the real ones: a landscape main display
 * (with GNOME's 32 px top bar) and a portrait display to its right, so by-orientation actions show
 * both branches.
 */
export const SAMPLE_SCREENS = Object.freeze([
  Object.freeze({
    displayID: 1, name: 'Sample Display', isMain: true, scale: 1,
    frame: {x: 0, y: 0, width: 1920, height: 1080}, visibleFrame: {x: 0, y: 32, width: 1920, height: 1048},
  }),
  Object.freeze({
    displayID: 2, name: 'Sample Portrait Display', isMain: false, scale: 1,
    frame: {x: 1920, y: 0, width: 1080, height: 1920}, visibleFrame: {x: 1920, y: 0, width: 1080, height: 1920},
  }),
]);

export function mainScreen(screens) {
  return screens.find(s => s.isMain) ?? screens[0] ?? null;
}

/** Screens sorted the way Slate numbers them by default: left to right, then the lower one first. */
export function orderedLeftToRight(screens) {
  return [...screens].sort((a, b) => (a.frame.x !== b.frame.x ? a.frame.x - b.frame.x : b.frame.y - a.frame.y));
}

/**
 * The sample window: half the width and 60% of the height of a screen's visible frame, centered on
 * it. `screen` defaults to the main screen.
 */
export function sampleFrame(screens, screen = null) {
  const s = screen ?? mainScreen(screens);
  if (!s) return null;
  const v = s.visibleFrame;
  const width = Math.round(v.width * 0.5);
  const height = Math.round(v.height * 0.6);
  return {x: Math.round(v.x + v.width / 2 - width / 2), y: Math.round(v.y + v.height / 2 - height / 2), width, height};
}

/** Whether the editor shows a placement preview for this action. */
export function previews(action) {
  const a = resolveAction(action);
  // Automations that never touch a window (an auto-clicker, a macro of clicks) get no window preview.
  if (containsAutomation(a) && !containsWindowGeometry(a)) return false;
  if (a && (a.op === 'chain' || a.op === 'sequence')) return true;
  return isWindowGeometry(action);
}

function validFrame(frame) {
  return isObject(frame) && [frame.x, frame.y, frame.width, frame.height].every(Number.isFinite) &&
    frame.width > 0 && frame.height > 0;
}

/**
 * Places `action` for the preview.
 *
 * @returns {{sample: object, state: {kind: "placed", frame}|{kind: "unavailable", reason: string|null}|{kind: "nothing", message}}|null}
 *   null when there are no screens. `reason` is null while the engine's window math isn't
 *   implemented yet (shown as a quiet "Preview unavailable").
 * @param {object} options
 * @param {Array} options.screens ScreenInfo list
 * @param {object} [options.settings] Slate settings (config.json "settings")
 * @param {number} [options.step] for a chain, which press to preview (wraps around)
 * @param {number} [options.startScreen] index into `screens` of the screen the sample window starts on
 */
export function place(action, {screens, settings = {}, step = 0, startScreen = null}) {
  if (!screens?.length) return null;
  const start = startScreen !== null && screens[startScreen] ? screens[startScreen] : null;
  const sample = sampleFrame(screens, start);
  if (!sample) return null;
  return {sample, state: placementState(action, sample, screens, settings, step)};
}

function placementState(action, sample, screens, settings, step) {
  const context = frame => ({frame, screens, settings});
  try {
    const a = typeof action === 'string' ? resolveAction(action) : action;
    if (!a) return {kind: 'unavailable', reason: null};
    if (a.op === 'chain') {
      const ops = a.operations ?? [];
      if (!ops.length) return {kind: 'nothing', message: 'Add an operation to see where it puts the window.'};
      return placementState(ops[((step % ops.length) + ops.length) % ops.length], sample, screens, settings, 0);
    }
    if (a.op === 'sequence') {
      const steps = (a.steps ? a.steps.map(s => s.action) : (a.operations ?? [])).filter(isWindowGeometry);
      if (!steps.length) return {kind: 'nothing', message: 'None of these steps move the window.'};
      let frame = sample;
      for (const s of steps) frame = targetFrame(resolveAction(s), context(frame));
      return validFrame(frame) ? {kind: 'placed', frame} : {kind: 'unavailable', reason: 'The window would have no size.'};
    }
    if (!isWindowGeometry(a)) return {kind: 'nothing', message: kindById(kindOf(a))?.explanation ?? ''};
    const frame = targetFrame(a, context(sample));
    return validFrame(frame) ? {kind: 'placed', frame} : {kind: 'unavailable', reason: 'The window would have no size.'};
  } catch (error) {
    if (isNotImplemented(error)) return {kind: 'unavailable', reason: null};
    return {kind: 'unavailable', reason: describeError(error)};
  }
}

/** The union of the screens' frames. */
export function screensBounds(screens) {
  if (!screens.length) return {x: 0, y: 0, width: 1, height: 1};
  const minX = Math.min(...screens.map(s => s.frame.x));
  const minY = Math.min(...screens.map(s => s.frame.y));
  const maxX = Math.max(...screens.map(s => s.frame.x + s.frame.width));
  const maxY = Math.max(...screens.map(s => s.frame.y + s.frame.height));
  return {x: minX, y: minY, width: maxX - minX, height: maxY - minY};
}

/**
 * Fits the screens into a `width` × `height` drawing area (leaving `labelHeight` below for display
 * names), centered. Returns {scale, toCanvas(rect) → rect, fromCanvas(x, y) → point}.
 */
export function screenMap(screens, width, height, {padding = 8, labelHeight = 18} = {}) {
  const bounds = screensBounds(screens);
  const availableWidth = Math.max(width - padding * 2, 1);
  const availableHeight = Math.max(height - padding * 2 - labelHeight, 1);
  const scale = Math.min(availableWidth / bounds.width, availableHeight / bounds.height);
  const offsetX = padding + (availableWidth - bounds.width * scale) / 2;
  const offsetY = padding + (availableHeight - bounds.height * scale) / 2;
  return {
    scale,
    toCanvas: r => ({
      x: offsetX + (r.x - bounds.x) * scale, y: offsetY + (r.y - bounds.y) * scale,
      width: r.width * scale, height: r.height * scale,
    }),
    fromCanvas: (x, y) => ({x: bounds.x + (x - offsetX) / scale, y: bounds.y + (y - offsetY) / scale}),
  };
}

/** The index of the screen containing a global point, or -1. */
export function screenAt(screens, point) {
  return screens.findIndex(s => point.x >= s.frame.x && point.x < s.frame.x + s.frame.width &&
    point.y >= s.frame.y && point.y < s.frame.y + s.frame.height);
}

/** "960 × 1048 at 0, 32" for the preview caption. */
export function describeFrame(frame) {
  return `${Math.round(frame.width)} × ${Math.round(frame.height)} at ${Math.round(frame.x)}, ${Math.round(frame.y)}`;
}

/** Where each app's first window goes in a layout (one preview window per app). */
export function layoutPlacements(layout, {screens, settings = {}}) {
  const windows = [];
  let reason = null;
  (layout.apps ?? []).forEach((app, index) => {
    const op = app.operations?.[0];
    if (op === undefined) return;
    const placement = place(op, {screens, settings});
    if (!placement) return;
    if (placement.state.kind === 'placed') {
      windows.push({frame: placement.state.frame, label: app.app || 'App', hue: (0.70 + index * 0.13) % 1});
    } else if (placement.state.kind === 'unavailable') {
      reason ??= placement.state.reason;
    }
  });
  return {windows, reason};
}
