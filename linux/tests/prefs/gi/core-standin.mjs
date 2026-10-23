// The engine as the UI smoke test sees it: the real lib/core, except that while its window math
// (targetFrame) is still a stub, moves and pushes get a simple stand-in frame, so the preview's
// drawing of placed windows runs too. Other operations still report "not implemented", so the
// "Preview unavailable" path runs as well. Once the engine implements targetFrame, this is a no-op.

import * as real from '../../../gnome-extension/lib/core/index.js';

export * from '../../../gnome-extension/lib/core/index.js';

function screenOf(frame, screens) {
  const cx = frame.x + frame.width / 2;
  const cy = frame.y + frame.height / 2;
  return screens.find(s => cx >= s.frame.x && cx < s.frame.x + s.frame.width && cy >= s.frame.y && cy < s.frame.y + s.frame.height)
    ?? screens.find(s => s.isMain) ?? screens[0];
}

export function targetFrame(action, context) {
  try {
    return real.targetFrame(action, context);
  } catch (error) {
    if (error?.kind !== 'notImplemented') throw error;
  }
  const v = screenOf(context.frame, context.screens).visibleFrame;
  const portrait = v.height > v.width;
  switch (action.op) {
  case 'by-orientation':
    return targetFrame(portrait ? action.portrait : action.landscape, context);
  case 'move':
    return {x: v.x, y: v.y, width: Math.round(v.width / 2), height: v.height};
  case 'push':
    return action.direction === 'right' ? {x: v.x + v.width / 2, y: v.y, width: v.width / 2, height: v.height}
      : {x: v.x, y: v.y, width: v.width / 2, height: v.height};
  default:
    throw new real.SlatedError('notImplemented', `Not implemented yet: targetFrame for ${action.op}`);
  }
}
