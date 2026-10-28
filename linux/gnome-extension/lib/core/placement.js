// Where a small panel goes next to something on screen: the clipboard picker under the text caret,
// and its image preview beside the picker (port of PopupPlacement.swift). Top-left-origin global
// coordinates, like the rest of the core; GNOME Shell's stage uses the same space.
//
// Rects follow CoreGraphics: min/max/width/height are standardized (a negative size counts from the
// other edge), a point on a rect's maximum edge isn't inside it, and rects that only touch don't
// intersect. The golden vectors in fixtures/placement.json pin this to what macOS does.

const minX = (r) => Math.min(r.x, r.x + r.width);
const maxX = (r) => Math.max(r.x, r.x + r.width);
const minY = (r) => Math.min(r.y, r.y + r.height);
const maxY = (r) => Math.max(r.y, r.y + r.height);
const width = (r) => Math.abs(r.width);
const height = (r) => Math.abs(r.height);

// Swift's max and min (which differ from Math's only for NaN and signed zeros).
const max = (x, y) => (y >= x ? y : x);
const min = (x, y) => (y < x ? y : x);

/** CGRectContainsPoint: the minimum edges are inside, the maximum edges aren't. */
const contains = (r, x, y) => x >= minX(r) && x < maxX(r) && y >= minY(r) && y < maxY(r);

/** CGRectIntersectsRect: an overlap without area (rects sharing an edge) doesn't count. */
function intersects(a, b) {
  const x1 = max(minX(a), minX(b));
  const x2 = min(maxX(a), maxX(b));
  const y1 = max(minY(a), minY(b));
  const y2 = min(maxY(a), maxY(b));
  return x2 > x1 && y2 > y1;
}

/** Squared distance from a point to a rect (0 inside it or on its edges). */
function distance(x, y, r) {
  const dx = max(max(minX(r) - x, 0), x - maxX(r));
  const dy = max(max(minY(r) - y, 0), y - maxY(r));
  return dx * dx + dy * dy;
}

export const PopupPlacement = Object.freeze({
  /**
   * A panel of `size` ({width, height}) just below `anchor` (the caret, or the pointer as an empty
   * rect), left edges aligned. Above the anchor when there's no room below; kept inside
   * `visibleFrame` either way.
   */
  below(anchor, size, visibleFrame, gap = 4) {
    let y = maxY(anchor) + gap;
    if (y + size.height > maxY(visibleFrame)) {
      const above = minY(anchor) - gap - size.height;
      // Neither fits (a tall panel, a short screen): the side with more room, then clamped.
      if (above >= minY(visibleFrame) || minY(anchor) - minY(visibleFrame) > maxY(visibleFrame) - maxY(anchor)) y = above;
    }
    return PopupPlacement.clamp({x: minX(anchor), y, width: size.width, height: size.height}, visibleFrame);
  },

  /**
   * A panel of `size` beside `target` (the picker), its top level with `row`'s top: to the right, or
   * to the left when there's no room on the right; kept inside `visibleFrame`.
   */
  beside(target, row, size, visibleFrame, gap = 6) {
    let x = maxX(target) + gap;
    if (x + size.width > maxX(visibleFrame)) {
      const left = minX(target) - gap - size.width;
      if (left >= minX(visibleFrame) || minX(target) - minX(visibleFrame) > maxX(visibleFrame) - maxX(target)) x = left;
    }
    return PopupPlacement.clamp({x, y: minY(row), width: size.width, height: size.height}, visibleFrame);
  },

  /** `rect` moved (not resized) inside `bounds`; its top-left corner wins when it's bigger. */
  clamp(rect, bounds) {
    return {
      x: max(minX(bounds), min(minX(rect), maxX(bounds) - width(rect))),
      y: max(minY(bounds), min(minY(rect), maxY(bounds) - height(rect))),
      width: rect.width,
      height: rect.height,
    };
  },

  /** The screen (a ScreenInfo) showing `anchor`: the one containing its center, else the closest one. */
  screen(anchor, screens) {
    const x = minX(anchor) + width(anchor) / 2;
    const y = minY(anchor) + height(anchor) / 2;
    const containing = screens.find((s) => contains(s.frame, x, y));
    if (containing) return containing;
    let closest = null;
    let best = Infinity;
    for (const s of screens) {
      const d = distance(x, y, s.frame);
      if (closest === null || d < best) {
        closest = s;
        best = d;
      }
    }
    return closest;
  },

  /**
   * Whether a rect an app reported for its caret or focused element can place a panel: finite, not
   * empty, on one of `screens` (rects), and no taller than `maxHeight` (for an element: a whole
   * editor says little about where you're typing). Apps that don't really support the question
   * answer with zero rects or rects far off screen.
   */
  isUsable(rect, screens, {maxHeight = Infinity} = {}) {
    const [x, y, w, h] = [minX(rect), minY(rect), width(rect), height(rect)];
    if (![x, y, w, h].every(Number.isFinite) || !(w >= 0) || !(h > 0) || !(h <= maxHeight)) return false;
    // A caret is often zero wide; give it a point so it can intersect.
    const probe = {x, y, width: max(w, 1), height: h};
    return screens.some((s) => intersects(s, probe));
  },
});
