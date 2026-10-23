// Window geometry for Slate's operations (port of FrameCalculator.swift, ScreenResolver.swift and
// Screen.swift's helpers).
//
// All rects are {x, y, width, height} in top-left-origin global coordinates (y grows down), like
// Mutter's frame rects. Screens are {displayID, name, frame, visibleFrame, isMain, scale} in OS order;
// `visibleFrame` excludes panels and docks (Mutter's work area), and Slate's screen variables
// (screenOriginX…) describe it. Like Slate, every variable is a whole number (truncated toward zero).
//
// Slate applied an operation in two steps: resize, read back the size the window actually took, then
// place it for that size. To do the same, apply `targetFrame`'s size, then move to
// `targetOrigin(action, context, actualSize)`, then set the size again.

import {decodeAction} from './config.js';
import {invalidExpression, invalidSyntax, screenNotFound, SlatedError} from './errors.js';
import {evaluateExpression} from './expression.js';
import {barResizeExpression, readSettings, screenRefFromSlate, screenRefToSlate} from './model.js';
import {nudgeExpression, resizeAmount} from './slateSyntax.js';
import {parseInt64} from './text.js';

// --- Rectangles (CGRect semantics: min/max/width are standardized) --------------------------------------

const minX = (r) => Math.min(r.x, r.x + r.width);
const maxX = (r) => Math.max(r.x, r.x + r.width);
const minY = (r) => Math.min(r.y, r.y + r.height);
const maxY = (r) => Math.max(r.y, r.y + r.height);
const width = (r) => Math.abs(r.width);
const height = (r) => Math.abs(r.height);
const midX = (r) => (minX(r) + maxX(r)) / 2;
const midY = (r) => (minY(r) + maxY(r)) / 2;

function intersection(a, b) {
  const x1 = Math.max(minX(a), minX(b));
  const x2 = Math.min(maxX(a), maxX(b));
  const y1 = Math.max(minY(a), minY(b));
  const y2 = Math.min(maxY(a), maxY(b));
  if (x1 > x2 || y1 > y2) return null;
  return {x: x1, y: y1, width: x2 - x1, height: y2 - y1};
}

const sameRect = (a, b) => a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;

/** Value equality of two screens, like Swift's synthesized `==`. */
function sameScreen(a, b) {
  return (
    a === b ||
    (a.displayID === b.displayID &&
      a.name === b.name &&
      sameRect(a.frame, b.frame) &&
      sameRect(a.visibleFrame, b.visibleFrame) &&
      a.isMain === b.isMain &&
      (a.scale ?? 2) === (b.scale ?? 2))
  );
}

/** "1680x1050": the full frame's size, Slate's resolution notation. */
export const screenResolution = (s) => `${Math.trunc(width(s.frame))}x${Math.trunc(height(s.frame))}`;
export const isPortrait = (s) => height(s.frame) > width(s.frame);

/**
 * Screens in Slate's default numbering (`orderScreensLeftToRight`): by the x of their top-left
 * corner, then, for screens with the same x, the lower one first.
 */
export function orderedLeftToRight(screens) {
  return [...screens].sort((a, b) => {
    if (minX(a.frame) !== minX(b.frame)) return minX(a.frame) - minX(b.frame);
    return minY(b.frame) - minY(a.frame);
  });
}

/** The screen holding the largest part of `rect`, falling back to the main screen, then the first. */
export function screenContaining(screens, rect) {
  let best = null;
  for (const screen of screens) {
    const overlap = intersection(screen.frame, rect);
    if (overlap === null) continue;
    const area = overlap.width * overlap.height;
    if (area > (best?.area ?? 0)) best = {screen, area};
  }
  return best?.screen ?? screens.find((s) => s.isMain) ?? screens[0] ?? null;
}

// --- Screen references ---------------------------------------------------------------------------------

function parseRef(ref) {
  if (ref === null || ref === undefined) return null;
  if (typeof ref === 'number' || typeof ref === 'bigint') {
    if (typeof ref === 'number' && !Number.isInteger(ref)) throw invalidSyntax(`Invalid screen reference "${ref}"`);
    return {kind: 'index', index: ref};
  }
  if (typeof ref === 'object') return ref;
  const parsed = screenRefFromSlate(String(ref));
  if (parsed === null) throw invalidSyntax(`Invalid screen reference "${ref}"`);
  return parsed;
}

function screenAt(index, list) {
  return typeof index === 'number' && index >= 0 && index < list.length ? list[index] : null;
}

function resolve(ref, windowFrame, screens, settings) {
  const current = screenContaining(screens, windowFrame);
  if (current === null) return null;
  if (ref === null) return current;
  const fallback = settings.defaultToCurrentScreen ? current : null;
  const missing = (index) => (index == -1 ? current : index < -1 ? null : fallback); // eslint-disable-line eqeqeq
  switch (ref.kind) {
    case 'index': {
      const list = settings.orderScreensLeftToRight ? orderedLeftToRight(screens) : screens;
      return screenAt(ref.index, list) ?? missing(ref.index);
    }
    case 'ordered':
      return screenAt(ref.index, orderedLeftToRight(screens)) ?? missing(ref.index);
    case 'resolution':
      return screens.find((s) => screenResolution(s) === `${ref.width}x${ref.height}`) ?? fallback;
    case 'relative':
      return neighbor(current, ref.direction, screens);
    default: {
      const index = screens.findIndex((s) => sameScreen(s, current));
      if (index < 0) return current;
      const step = ref.kind === 'next' ? 1 : screens.length - 1;
      return screens[(index + step) % screens.length];
    }
  }
}

/**
 * The screen a Slate screen reference points to, relative to the screen holding the window (the one
 * with the largest share of it). A null ref means the window's own screen; null when nothing matches.
 * - an index ("0", 1): left-to-right position (`orderScreensLeftToRight`, the default) or OS order;
 *   -1 is the window's screen;
 * - "ordered:N": always left to right; "1680x1050": the first screen of that full size;
 * - "left"/"right"/"up"/"down": the screen across that edge (or the nearest one in that direction);
 * - "next"/"previous": OS order, wrapping around.
 * When an index or resolution matches no screen, `defaultToCurrentScreen` picks the window's screen.
 * @param {string|number|null} ref
 * @param {{frame: Object, screens: Object[], settings?: Object}} context
 */
export function resolveScreen(ref, context) {
  return resolve(parseRef(ref), context.frame, context.screens ?? [], readSettings(context.settings ?? {}));
}

/** The screen next to `current` in `direction` (see ScreenResolver.neighbor). */
function neighbor(current, direction, screens) {
  const frame = current.frame;
  let strip;
  switch (direction) {
    case 'right': strip = {x: maxX(frame), y: minY(frame), width: 1, height: height(frame)}; break;
    case 'left': strip = {x: minX(frame) - 1, y: minY(frame), width: 1, height: height(frame)}; break;
    case 'up': strip = {x: minX(frame), y: minY(frame) - 1, width: width(frame), height: 1}; break;
    default: strip = {x: minX(frame), y: maxY(frame), width: width(frame), height: 1};
  }
  let best = null;
  for (const screen of screens) {
    if (sameScreen(screen, current)) continue;
    const overlap = intersection(screen.frame, strip);
    if (overlap === null) continue;
    const area = overlap.width * overlap.height;
    if (area > (best?.area ?? 0)) best = {screen, area};
  }
  if (best !== null) return best.screen;

  let nearest = null;
  for (const screen of screens) {
    if (sameScreen(screen, current)) continue;
    const other = screen.frame;
    let beyond;
    let offset;
    switch (direction) {
      case 'right': beyond = minX(other) >= maxX(frame); offset = Math.abs(midY(other) - midY(frame)); break;
      case 'left': beyond = maxX(other) <= minX(frame); offset = Math.abs(midY(other) - midY(frame)); break;
      case 'up': beyond = maxY(other) <= minY(frame); offset = Math.abs(midX(other) - midX(frame)); break;
      default: beyond = minY(other) >= maxY(frame); offset = Math.abs(midX(other) - midX(frame));
    }
    if (!beyond) continue;
    const gap = distance(frame, other);
    if (nearest !== null && (nearest.gap < gap || (nearest.gap === gap && nearest.offset <= offset))) continue;
    nearest = {screen, gap, offset};
  }
  return nearest?.screen ?? null;
}

function distance(a, b) {
  const dx = Math.max(0, Math.max(minX(b) - maxX(a), minX(a) - maxX(b)));
  const dy = Math.max(0, Math.max(minY(b) - maxY(a), minY(a) - maxY(b)));
  return Math.sqrt(dx * dx + dy * dy);
}

// --- Variables ---------------------------------------------------------------------------------------

/** Slate's expression variables for one evaluation; like Slate, each is a whole number. */
function variables(screen, window, newSize) {
  const visible = screen.visibleFrame;
  const values = {
    screenOriginX: Math.trunc(minX(visible)),
    screenOriginY: Math.trunc(minY(visible)),
    screenSizeX: Math.trunc(width(visible)),
    screenSizeY: Math.trunc(height(visible)),
    windowTopLeftX: Math.trunc(minX(window)),
    windowTopLeftY: Math.trunc(minY(window)),
    windowSizeX: Math.trunc(width(window)),
    windowSizeY: Math.trunc(height(window)),
    newWindowSizeX: Math.trunc(newSize.width),
    newWindowSizeY: Math.trunc(newSize.height),
  };
  return {...values, values, evaluate: (expression) => evaluateExpression(expression, values)};
}

// --- Plans -------------------------------------------------------------------------------------------

function contextParts(context) {
  return {frame: context.frame, screens: context.screens ?? [], settings: readSettings(context.settings ?? {})};
}

function targetScreen(ref, ctx) {
  const parsed = ref === undefined ? null : screenRefFromSlate(ref);
  const screen = resolve(parsed, ctx.frame, ctx.screens, ctx.settings);
  if (screen === null) throw screenNotFound(parsed === null ? 'current' : screenRefToSlate(parsed));
  return screen;
}

/** Slate's `move`, which push, nudge, throw and corner are built on. */
function movePlan(x, y, w, h, ref, ctx) {
  const screen = targetScreen(ref, ctx);
  const window = ctx.frame;
  const before = variables(screen, window, {width: window.width, height: window.height});
  const size = {width: w(before), height: h(before)};
  return {
    size,
    origin: (actual) => {
      const after = variables(screen, window, actual);
      return {x: x(after), y: y(after)};
    },
  };
}

function pushPlan(direction, style, ref, ctx) {
  let w = (v) => v.windowSizeX;
  let h = (v) => v.windowSizeY;
  let x;
  let y;
  const centerX = (v) => v.screenOriginX + (v.screenSizeX - v.windowSizeX) / 2;
  const centerY = (v) => v.screenOriginY + (v.screenSizeY - v.windowSizeY) / 2;
  const rightX = (v) => v.screenOriginX + v.screenSizeX - v.windowSizeX;
  const bottomY = (v) => v.screenOriginY + v.screenSizeY - v.windowSizeY;
  const expression = barResizeExpression(style);
  const kind = expression === null ? style : 'bar-resize';
  switch (`${direction} ${kind}`) {
    case 'up none': [x, y] = [(v) => v.windowTopLeftX, (v) => v.screenOriginY]; break;
    case 'up center': [x, y] = [centerX, (v) => v.screenOriginY]; break;
    case 'up bar': [x, y, w] = [(v) => v.screenOriginX, (v) => v.screenOriginY, (v) => v.screenSizeX]; break;
    case 'up bar-resize':
      [x, y, w, h] = [(v) => v.screenOriginX, (v) => v.screenOriginY, (v) => v.screenSizeX, (v) => v.evaluate(expression)];
      break;
    case 'down none': [x, y] = [(v) => v.windowTopLeftX, bottomY]; break;
    case 'down center': [x, y] = [centerX, bottomY]; break;
    case 'down bar': [x, y, w] = [(v) => v.screenOriginX, bottomY, (v) => v.screenSizeX]; break;
    case 'down bar-resize':
      x = (v) => v.screenOriginX;
      y = (v) => v.screenOriginY + v.screenSizeY - v.evaluate(expression);
      [w, h] = [(v) => v.screenSizeX, (v) => v.evaluate(expression)];
      break;
    case 'left none': [x, y] = [(v) => v.screenOriginX, (v) => v.windowTopLeftY]; break;
    case 'left center': [x, y] = [(v) => v.screenOriginX, centerY]; break;
    case 'left bar': [x, y, h] = [(v) => v.screenOriginX, (v) => v.screenOriginY, (v) => v.screenSizeY]; break;
    case 'left bar-resize':
      [x, y, w, h] = [(v) => v.screenOriginX, (v) => v.screenOriginY, (v) => v.evaluate(expression), (v) => v.screenSizeY];
      break;
    case 'right none': [x, y] = [rightX, (v) => v.windowTopLeftY]; break;
    case 'right center': [x, y] = [rightX, centerY]; break;
    case 'right bar': [x, y, h] = [rightX, (v) => v.screenOriginY, (v) => v.screenSizeY]; break;
    default:
      x = (v) => v.screenOriginX + v.screenSizeX - v.evaluate(expression);
      y = (v) => v.screenOriginY;
      [w, h] = [(v) => v.evaluate(expression), (v) => v.screenSizeY];
  }
  return movePlan(x, y, w, h, ref, ctx);
}

function resizePlan(widthText, heightText, anchor, ctx) {
  const window = ctx.frame;
  let base;
  const screen = screenContaining(ctx.screens, window);
  if (ctx.settings.resizePercentOf === 'screenSize') {
    if (screen === null) throw screenNotFound('current');
    base = {width: screen.visibleFrame.width, height: screen.visibleFrame.height};
  } else {
    base = {width: window.width, height: window.height};
  }
  const vars = screen === null ? null : variables(screen, window, {width: window.width, height: window.height});
  const newWidth = resized(width(window), widthText, base.width, vars);
  const newHeight = resized(height(window), heightText, base.height, vars);
  const size = {width: newWidth, height: newHeight};
  if (newWidth === window.width && newHeight === window.height) {
    return {size, origin: () => ({x: window.x, y: window.y})}; // Slate doesn't touch an unchanged window.
  }
  return {
    size,
    origin: (actual) => {
      const right = Math.trunc(minX(window) + width(window) - actual.width);
      const bottom = Math.trunc(minY(window) + height(window) - actual.height);
      switch (anchor) {
        case 'top-right': return {x: right, y: Math.trunc(minY(window))};
        case 'bottom-left': return {x: Math.trunc(minX(window)), y: bottom};
        case 'bottom-right': return {x: right, y: bottom};
        default: return {x: window.x, y: window.y};
      }
    },
  };
}

/** One `resize` dimension: `+10%`/`-10%` of `base`, `+100`/`-100` points, a signed expression, or an absolute size. */
function resized(current, value, base, vars) {
  const amount = resizeAmount(value);
  const wholeBase = Math.trunc(base);
  const magnitude = () => {
    const whole = parseInt64(amount.magnitude);
    if (whole !== null) return Number(whole);
    if (vars === null) throw screenNotFound('current');
    try {
      return vars.evaluate(amount.magnitude);
    } catch (e) {
      if (e instanceof SlatedError) throw invalidExpression(`Invalid resize amount "${value}": ${e.message}`);
      throw e;
    }
  };
  if (amount.sign !== null) {
    const change = amount.isPercent ? Math.trunc((amount.sign * wholeBase * magnitude()) / 100) : amount.sign * magnitude();
    return Math.trunc(current + change);
  }
  const size = amount.isPercent ? (wholeBase * magnitude()) / 100 : magnitude();
  return Math.trunc(size);
}

function plan(action, ctx) {
  const a = action;
  switch (a.op) {
    case 'by-orientation': {
      const screen = screenContaining(ctx.screens, ctx.frame);
      return plan(screen !== null && isPortrait(screen) ? a.portrait : a.landscape, ctx);
    }
    case 'move':
      return movePlan((v) => v.evaluate(a.x), (v) => v.evaluate(a.y), (v) => v.evaluate(a.width), (v) => v.evaluate(a.height), a.screen, ctx);
    case 'resize':
      return resizePlan(a.width, a.height, a.anchor ?? 'top-left', ctx);
    case 'push':
      return pushPlan(a.direction, a.style ?? 'none', a.screen, ctx);
    case 'nudge': {
      // Slate builds the new corner as text: windowTopLeftX + amount, % meaning a share of the screen (or window).
      const percentOf = ctx.settings.nudgePercentOf === 'windowSize' ? 'windowSize' : 'screenSize';
      const xExpression = `windowTopLeftX${nudgeExpression(a.x, 'X', percentOf)}`;
      const yExpression = `windowTopLeftY${nudgeExpression(a.y, 'Y', percentOf)}`;
      return movePlan((v) => v.evaluate(xExpression), (v) => v.evaluate(yExpression), (v) => v.windowSizeX, (v) => v.windowSizeY, undefined, ctx);
    }
    case 'throw':
      return movePlan(
        (v) => v.screenOriginX,
        (v) => v.screenOriginY,
        (v) => (a.width === undefined ? v.windowSizeX : v.evaluate(a.width)),
        (v) => (a.height === undefined ? v.windowSizeY : v.evaluate(a.height)),
        a.screen,
        ctx,
      );
    case 'corner': {
      const w = (v) => (a.width === undefined ? v.windowSizeX : v.evaluate(a.width));
      const h = (v) => (a.height === undefined ? v.windowSizeY : v.evaluate(a.height));
      const left = (v) => v.screenOriginX;
      const right = (v) => v.screenOriginX + v.screenSizeX - w(v);
      const top = (v) => v.screenOriginY;
      const bottom = (v) => v.screenOriginY + v.screenSizeY - h(v);
      const [x, y] = {
        'top-left': [left, top],
        'top-right': [right, top],
        'bottom-left': [left, bottom],
        'bottom-right': [right, bottom],
      }[a.direction];
      return movePlan(x, y, w, h, a.screen, ctx);
    }
    default:
      throw invalidSyntax(`"${a.op}" doesn't move or resize a window`);
  }
}

/**
 * Target frame for move, resize, push, nudge, throw, corner and by-orientation, assuming the window
 * takes the requested size.
 * @param {Object|string} action canonical Action JSON (or any form decodeAction accepts)
 * @param {{frame: Object, screens: Object[], settings?: Object}} context
 * @returns {{x: number, y: number, width: number, height: number}}
 * @throws {SlatedError} screenNotFound when the operation names a screen that doesn't exist (leave the
 *   window alone), invalidExpression for a bad expression, invalidSyntax for other operations.
 */
export function targetFrame(action, context) {
  const p = plan(decodeAction(action), contextParts(context));
  const origin = p.origin(p.size);
  return {x: origin.x, y: origin.y, width: p.size.width, height: p.size.height};
}

/**
 * The top-left corner once the window has been resized and turned out `actualSize` (apps with
 * minimum sizes). Resize anchors and newWindowSizeX/newWindowSizeY depend on it.
 * @returns {{x: number, y: number}}
 */
export function targetOrigin(action, context, actualSize) {
  return plan(decodeAction(action), contextParts(context)).origin(actualSize);
}
