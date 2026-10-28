import AppKit
import SlatedCore

/// The current displays, converted to Slated's top-left-origin coordinates.
@MainActor
public enum Screens {
  /// All displays in OS order; the first one holds the menu bar.
  public static func current() -> [ScreenInfo] {
    let screens = NSScreen.screens
    // AppKit puts (0,0) at the bottom-left of the primary display with y growing up; Accessibility
    // puts (0,0) at its top-left with y growing down. The primary display's height links the two.
    guard let primaryHeight = screens.first?.frame.height else { return [] }
    return screens.enumerated().map { index, screen in
      ScreenInfo(
        displayID: displayID(of: screen),
        name: screen.localizedName,
        frame: flip(screen.frame, primaryHeight: primaryHeight),
        visibleFrame: flip(screen.visibleFrame, primaryHeight: primaryHeight),
        isMain: index == 0,
        scale: screen.backingScaleFactor)
    }
  }

  /// Converts an AppKit rect (one of our windows' frames) to top-left-origin coordinates.
  public static func topLeftRect(fromAppKit rect: NSRect) -> CGRect {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return rect }
    return flip(rect, primaryHeight: primaryHeight)
  }

  /// The mouse pointer, in top-left-origin coordinates.
  public static func pointerLocation() -> CGPoint {
    let point = NSEvent.mouseLocation
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return point }
    return CGPoint(x: point.x, y: primaryHeight - point.y)
  }

  /// Converts a top-left-origin rect back to AppKit coordinates (for positioning our own windows).
  public static func appKitRect(fromTopLeft rect: CGRect) -> NSRect {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return rect }
    return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  /// The AppKit screen for a display ID.
  public static func nsScreen(for displayID: UInt32) -> NSScreen? {
    NSScreen.screens.first { Self.displayID(of: $0) == displayID }
  }

  static func flip(_ rect: NSRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  static func displayID(of screen: NSScreen) -> UInt32 {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }
}
