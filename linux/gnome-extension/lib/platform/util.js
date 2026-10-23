// Small pure helpers shared by Slated's GNOME runtime.
//
// No `gi://` imports here: the Node unit tests (linux/tests/extension) import this file directly.

/** Expands a leading `~` to `home`, like the macOS app's `SlatedPaths.expand`. */
export function expandHome(path, home) {
  if (typeof path !== 'string') return path;
  if (path === '~') return home;
  if (path.startsWith('~/')) return `${home}${path.slice(1)}`;
  return path;
}

/** The reverse of `expandHome`: `/home/me/.slate.js` → `~/.slate.js`. */
export function abbreviateHome(path, home) {
  if (typeof path !== 'string' || !home) return path;
  const root = home.endsWith('/') ? home.slice(0, -1) : home;
  if (path === root) return '~';
  if (path.startsWith(`${root}/`)) return `~${path.slice(root.length)}`;
  return path;
}

export function basename(path) {
  if (typeof path !== 'string') return '';
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path;
  const slash = trimmed.lastIndexOf('/');
  return slash >= 0 ? trimmed.slice(slash + 1) : trimmed;
}

export function dirname(path) {
  const slash = path.lastIndexOf('/');
  if (slash < 0) return '.';
  return slash === 0 ? '/' : path.slice(0, slash);
}

/** A copy of `value` whose object keys are sorted at every level (arrays keep their order). */
export function sortKeysDeep(value) {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  if (value !== null && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = sortKeysDeep(value[key]);
    return out;
  }
  return value;
}

/** JSON with sorted keys, so files and log lines are stable and diff well. */
export function stableStringify(value, indent) {
  return JSON.stringify(sortKeysDeep(value), null, indent);
}

export function truncate(text, length) {
  const s = String(text ?? '');
  return s.length > length ? s.slice(0, length) : s;
}

// --- Rects and screens ---------------------------------------------------------------------------

/** Snaps values that are within float noise of a whole number. */
function snap(value) {
  const rounded = Math.round(value);
  return Math.abs(value - rounded) < 1e-6 ? rounded : value;
}

/**
 * The smallest whole-number rect containing `rect` (CoreGraphics' `CGRect.integral`, which the macOS
 * app applies to every target frame).
 */
export function integralRect(rect) {
  const x0 = Math.floor(snap(rect.x));
  const y0 = Math.floor(snap(rect.y));
  const x1 = Math.ceil(snap(rect.x + rect.width));
  const y1 = Math.ceil(snap(rect.y + rect.height));
  return {x: x0, y: y0, width: Math.max(x1 - x0, 0), height: Math.max(y1 - y0, 0)};
}

export function intersectionArea(a, b) {
  const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

export function rectContainsPoint(rect, point) {
  return point.x >= rect.x && point.x < rect.x + rect.width && point.y >= rect.y && point.y < rect.y + rect.height;
}

export function rectsClose(a, b, tolerance = 1) {
  return (
    Math.abs(a.x - b.x) <= tolerance &&
    Math.abs(a.y - b.y) <= tolerance &&
    Math.abs(a.width - b.width) <= tolerance &&
    Math.abs(a.height - b.height) <= tolerance
  );
}

/** The screen holding the largest part of `rect`; the main screen (then the first) when none does. */
export function screenContaining(screens, rect) {
  let best = null;
  let bestArea = 0;
  if (rect) {
    for (const screen of screens) {
      const area = intersectionArea(screen.frame, rect);
      if (area > bestArea) {
        best = screen;
        bestArea = area;
      }
    }
  }
  return best ?? screens.find((s) => s.isMain) ?? screens[0] ?? null;
}

/**
 * Screens the way Slate numbers them by default (`orderScreensLeftToRight`): by the x of their
 * top-left corner, then, for the same x, the lower one first.
 */
export function orderedLeftToRight(screens) {
  return [...screens].sort((a, b) => (a.frame.x !== b.frame.x ? a.frame.x - b.frame.x : b.frame.y - a.frame.y));
}

export function isPortrait(screen) {
  return !!screen && screen.frame.height > screen.frame.width;
}

/** Slate's resolution notation for a screen's full frame, e.g. `1920x1080`. */
export function resolutionOf(screen) {
  return `${Math.trunc(screen.frame.width)}x${Math.trunc(screen.frame.height)}`;
}

// --- Slate `default` conditions ------------------------------------------------------------------

/**
 * Normalizes a display-default condition to `{count}` or `{resolutions}`. Accepts the plain forms and
 * Swift's synthesized enum coding (`{"count": {"_0": 2}}`), so it works whatever shape the core
 * decodes `defaults` into.
 */
export function normalizeCondition(raw) {
  if (raw === null || raw === undefined) return null;
  if (typeof raw === 'number') return {count: raw};
  if (Array.isArray(raw)) return {resolutions: raw.map(String)};
  if (typeof raw !== 'object') return null;
  const unwrap = (value) =>
    value !== null && typeof value === 'object' && !Array.isArray(value) && '_0' in value ? value._0 : value;
  if ('count' in raw) {
    const count = Number(unwrap(raw.count));
    return Number.isFinite(count) ? {count} : null;
  }
  if ('resolutions' in raw) {
    const list = unwrap(raw.resolutions);
    return Array.isArray(list) ? {resolutions: list.map(String)} : null;
  }
  if (raw.kind === 'count' && 'value' in raw) return {count: Number(raw.value)};
  if (raw.kind === 'resolutions' && Array.isArray(raw.value)) return {resolutions: raw.value.map(String)};
  return null;
}

export function conditionMatches(rawCondition, screens) {
  const condition = normalizeCondition(rawCondition);
  if (!condition) return false;
  if ('count' in condition) return screens.length === condition.count;
  const want = condition.resolutions.map((r) => r.toLowerCase().trim()).sort();
  const have = screens.map(resolutionOf).sort();
  return want.length === have.length && want.every((r, i) => r === have[i]);
}

/** A default's condition and target, whichever field names the core uses. */
export function defaultEntry(entry) {
  if (!entry || typeof entry !== 'object') return null;
  const condition = normalizeCondition(entry.condition ?? entry.screens ?? null);
  const target = entry.target ?? entry.name ?? null;
  return condition && typeof target === 'string' ? {condition, target} : null;
}

// --- Diagnostics ---------------------------------------------------------------------------------

/** "slate.js, line 3: message", like the Swift `Diagnostic.description`. */
export function diagnosticText(diagnostic) {
  if (typeof diagnostic === 'string') return diagnostic;
  const parts = [];
  if (diagnostic.file) parts.push(basename(diagnostic.file));
  if (diagnostic.line) parts.push(`line ${diagnostic.line}`);
  return parts.length ? `${parts.join(', ')}: ${diagnostic.message}` : String(diagnostic.message);
}

// --- Actions -------------------------------------------------------------------------------------

const GEOMETRY_OPS = new Set(['move', 'resize', 'push', 'nudge', 'throw', 'corner']);

/** True for operations that move or resize a window (and can be undone). */
export function isWindowGeometry(action) {
  if (!action || typeof action !== 'object') return false;
  if (GEOMETRY_OPS.has(action.op)) return true;
  if (action.op === 'by-orientation') return isWindowGeometry(action.landscape) && isWindowGeometry(action.portrait);
  return false;
}

/** The steps of a canonical `sequence` action as `{action, keepWindow}`. */
export function sequenceSteps(action) {
  if (Array.isArray(action.steps)) {
    return action.steps.map((step) =>
      step && typeof step === 'object' && 'action' in step
        ? {action: step.action, keepWindow: !!step.keepWindow}
        : {action: step, keepWindow: false},
    );
  }
  return (action.operations ?? []).map((op) => ({action: op, keepWindow: false}));
}

/** Normalizes Slate's app selectors: "current", "all", "all-but:Name", "Name" or ["A", "B"]. */
export function appSelector(value) {
  if (Array.isArray(value)) return {kind: 'apps', names: value.map(String)};
  const text = String(value ?? 'current');
  const lower = text.toLowerCase();
  if (lower === 'current') return {kind: 'current'};
  if (lower === 'all') return {kind: 'all'};
  if (lower.startsWith('all-but:')) return {kind: 'allBut', name: text.slice('all-but:'.length)};
  return {kind: 'apps', names: [text]};
}

/** Grid sizes per screen from either the canonical map (`{"0": {width, height}}`) or a list. */
export function gridSizes(grids) {
  if (Array.isArray(grids)) {
    return grids
      .filter((g) => g && typeof g === 'object')
      .map((g) => ({screen: String(g.screen), width: Number(g.width), height: Number(g.height)}));
  }
  if (grids && typeof grids === 'object') {
    return Object.keys(grids)
      .sort()
      .map((screen) => ({screen, width: Number(grids[screen]?.width), height: Number(grids[screen]?.height)}));
  }
  return [];
}

// --- The grid overlay ----------------------------------------------------------------------------

/** The grid size for a screen: the entry for its left-to-right index or its resolution, else 12×12. */
export function gridSizeFor(screen, index, sizes) {
  const entry = sizes.find((s) => s.screen === String(index) || s.screen === resolutionOf(screen));
  const clamp = (n) => (Number.isFinite(n) && n >= 1 ? Math.min(Math.trunc(n), 64) : 12);
  return {columns: clamp(entry?.width), rows: clamp(entry?.height)};
}

/** The frame a cell selection stands for on the real screen (the cells' share of the work area). */
export function gridTarget(visible, columns, rows, a, b) {
  const cw = visible.width / columns;
  const ch = visible.height / rows;
  const c0 = Math.min(a.col, b.col);
  const c1 = Math.max(a.col, b.col);
  const r0 = Math.min(a.row, b.row);
  const r1 = Math.max(a.row, b.row);
  return integralRect({
    x: visible.x + c0 * cw,
    y: visible.y + r0 * ch,
    width: (c1 - c0 + 1) * cw,
    height: (r1 - r0 + 1) * ch,
  });
}

/** The cell under a point in a grid of `columns`×`rows` cells filling `width`×`height`. */
export function gridCellAt(x, y, width, height, columns, rows) {
  const col = Math.min(Math.max(Math.floor((x / width) * columns), 0), columns - 1);
  const row = Math.min(Math.max(Math.floor((y / height) * rows), 0), rows - 1);
  return {col, row};
}

/** Slate read flags like Objective-C's `boolValue`. */
export function truthyText(text) {
  return !['', 'false', 'no', '0', 'off'].includes(String(text).trim().toLowerCase());
}
