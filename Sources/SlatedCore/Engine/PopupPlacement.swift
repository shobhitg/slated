import CoreGraphics

/// Where a small panel goes next to something on screen: the clipboard picker under the text caret,
/// and its image preview beside the picker. Top-left-origin global coordinates, like the rest of
/// SlatedCore; the app converts the result to AppKit's once.
public enum PopupPlacement {
  /// A panel of `size` just below `anchor` (the caret, or the pointer as an empty rect), left edges
  /// aligned. Above the anchor when there's no room below; kept inside `visibleFrame` either way.
  public static func below(_ anchor: CGRect, size: CGSize, in visibleFrame: CGRect, gap: CGFloat = 4) -> CGRect {
    var y = anchor.maxY + gap
    if y + size.height > visibleFrame.maxY {
      let above = anchor.minY - gap - size.height
      // Neither fits (a tall panel, a short screen): the side with more room, then clamped.
      if above >= visibleFrame.minY || anchor.minY - visibleFrame.minY > visibleFrame.maxY - anchor.maxY {
        y = above
      }
    }
    return clamp(CGRect(x: anchor.minX, y: y, width: size.width, height: size.height), to: visibleFrame)
  }

  /// A panel of `size` beside `target` (the picker), its top level with `row`'s top: to the right, or
  /// to the left when there's no room on the right; kept inside `visibleFrame`.
  public static func beside(
    _ target: CGRect, alignedWith row: CGRect, size: CGSize, in visibleFrame: CGRect, gap: CGFloat = 6
  ) -> CGRect {
    var x = target.maxX + gap
    if x + size.width > visibleFrame.maxX {
      let left = target.minX - gap - size.width
      if left >= visibleFrame.minX || target.minX - visibleFrame.minX > visibleFrame.maxX - target.maxX { x = left }
    }
    return clamp(CGRect(x: x, y: row.minY, width: size.width, height: size.height), to: visibleFrame)
  }

  /// `rect` moved (not resized) inside `bounds`; its top-left corner wins when it's bigger.
  public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
    var rect = rect
    rect.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
    rect.origin.y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
    return rect
  }

  /// The screen showing `anchor`: the one containing its center, else the closest one.
  public static func screen(for anchor: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
    let center = CGPoint(x: anchor.midX, y: anchor.midY)
    if let containing = screens.first(where: { $0.frame.contains(center) }) { return containing }
    return screens.min { distance(center, $0.frame) < distance(center, $1.frame) }
  }

  /// Whether a rectangle an app reported for its caret or focused element can place a panel: finite,
  /// not empty, on a screen, and (for an element) no taller than `maxHeight`, since a whole editor or
  /// web page says little about where you're typing. Apps that don't really support the question
  /// answer with zero rects or rects far off screen.
  public static func isUsable(_ rect: CGRect, maxHeight: CGFloat = .infinity, on screens: [CGRect]) -> Bool {
    guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
      rect.width >= 0, rect.height > 0, rect.height <= maxHeight
    else { return false }
    // A caret is often zero wide; give it a point so it can intersect.
    let probe = CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
    return screens.contains { $0.intersects(probe) }
  }

  private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return dx * dx + dy * dy
  }
}
