import CoreGraphics

/// Whether Slated's menu bar icon sits behind a MacBook's camera notch, where nobody can see it.
///
/// When the menu bar is full, macOS lays the icons out right to left and puts the ones that don't fit
/// wherever they land, including behind the notch. Measured on a 1512 pt wide built-in display: the
/// notch spans x 663–848 (between `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`), and
/// Slated's icon landed at x 744–768.
///
/// Rects are in top-left-origin global coordinates (SlatedCore's convention; `Screens.topLeftRect`
/// converts AppKit's). The notch is worked out from the unobscured areas' widths, which don't depend
/// on whether they're given relative to the screen.
public enum MenuBarPlacement {
  /// The notch's horizontal span on a screen, or nil for a screen without one.
  /// - Parameters:
  ///   - topLeftArea: `NSScreen.auxiliaryTopLeftArea`: the menu bar left of the notch.
  ///   - topRightArea: `NSScreen.auxiliaryTopRightArea`: the menu bar right of it.
  public static func notch(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?) -> ClosedRange<CGFloat>? {
    guard let left = topLeftArea, let right = topRightArea, left.width > 0, right.width > 0 else { return nil }
    let minX = screenFrame.minX + left.width
    let maxX = screenFrame.maxX - right.width
    return minX < maxX ? minX...maxX : nil
  }

  /// Whether an icon at `itemFrame` (its status bar button's window) is at least half behind the
  /// notch of the screen it's on. An icon on another screen, or in a menu bar without a notch, isn't.
  public static func isBehindNotch(
    itemFrame: CGRect, screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?
  ) -> Bool {
    guard itemFrame.width > 0,
      let notch = notch(screenFrame: screenFrame, topLeftArea: topLeftArea, topRightArea: topRightArea)
    else { return false }
    // In this screen's menu bar: the top strip, as tall as the unobscured areas (at least 24 pt).
    let barHeight = max(topLeftArea?.height ?? 0, topRightArea?.height ?? 0, 24)
    let inTopStrip = abs(itemFrame.midY - (screenFrame.minY + barHeight / 2)) <= barHeight
    guard inTopStrip, screenFrame.minX...screenFrame.maxX ~= itemFrame.midX else { return false }
    let overlap = min(itemFrame.maxX, notch.upperBound) - max(itemFrame.minX, notch.lowerBound)
    return overlap >= itemFrame.width / 2
  }
}
