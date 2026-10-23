import Foundation

/// A display as Slated sees it.
///
/// All rects use **top-left-origin global coordinates** (the Accessibility/CoreGraphics convention):
/// `(0, 0)` is the top-left corner of the primary display and `y` grows downward. AppKit's
/// bottom-left `NSScreen` frames are converted once, at the system boundary.
public struct ScreenInfo: Hashable, Sendable, Codable {
  /// `CGDirectDisplayID` of the display.
  public var displayID: UInt32
  /// Human-readable name, e.g. "Built-in Retina Display".
  public var name: String
  /// Full display bounds.
  public var frame: CGRect
  /// Bounds minus the menu bar and Dock. Slate's `screenOrigin*`/`screenSize*` refer to this rect.
  public var visibleFrame: CGRect
  /// True for the display that holds the menu bar (Slate's "main" screen, OS index 0).
  public var isMain: Bool
  /// Backing scale factor (2 on Retina).
  public var scale: Double

  public init(
    displayID: UInt32, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool,
    scale: Double = 2
  ) {
    self.displayID = displayID
    self.name = name
    self.frame = frame
    self.visibleFrame = visibleFrame
    self.isMain = isMain
    self.scale = scale
  }

  /// Width × height of the full frame in points, Slate's resolution notation (e.g. "1680x1050").
  public var resolution: String { "\(Int(frame.width))x\(Int(frame.height))" }

  public var isPortrait: Bool { frame.height > frame.width }
}

extension Array where Element == ScreenInfo {
  /// Screens sorted the way Slate numbers them by default (`orderScreensLeftToRight`): by the x of
  /// their top-left corner, then, for screens with the same x, the lower one first (Slate's order).
  public func orderedLeftToRight() -> [ScreenInfo] {
    sorted { (a: ScreenInfo, b: ScreenInfo) -> Bool in
      if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
      return a.frame.minY > b.frame.minY
    }
  }

  /// The screen that contains the largest part of `rect`, falling back to the main screen.
  public func screen(containing rect: CGRect) -> ScreenInfo? {
    var best: (screen: ScreenInfo, area: CGFloat)?
    for screen in self {
      let overlap = screen.frame.intersection(rect)
      guard !overlap.isNull else { continue }
      let area = overlap.width * overlap.height
      if area > (best?.area ?? 0) { best = (screen, area) }
    }
    return best?.screen ?? first(where: \.isMain) ?? first
  }
}
