import Foundation

/// Everything the frame math needs to know about the focused window and the displays.
public struct WindowContext: Sendable {
  /// The window's current frame (top-left global coordinates).
  public var frame: CGRect
  /// All displays in OS order (the main display first).
  public var screens: [ScreenInfo]
  public var settings: SlateSettings

  public init(frame: CGRect, screens: [ScreenInfo], settings: SlateSettings = .init()) {
    self.frame = frame
    self.screens = screens
    self.settings = settings
  }
}

/// Pure geometry for Slate's window operations: given a window and the screens, where should the
/// window go? No Accessibility calls happen here, so all of it is unit-testable.
public enum FrameCalculator {
  /// Target frame for `move`, `resize`, `push`, `nudge`, `throw` and `corner`.
  /// Throws for operations that are not window geometry.
  public static func targetFrame(for action: Action, in context: WindowContext) throws -> CGRect {
    throw SlatedError.notImplemented("FrameCalculator.targetFrame(\(action.name))")
  }
}

/// Resolves Slate screen references against the current displays.
public enum ScreenResolver {
  /// The screen `ref` points to, relative to the screen holding `windowFrame`. `nil` ref means the
  /// window's own screen.
  public static func screen(
    for ref: ScreenRef?, windowFrame: CGRect, screens: [ScreenInfo], settings: SlateSettings = .init()
  ) -> ScreenInfo? {
    guard let ref else { return screens.screen(containing: windowFrame) }
    let ordered = screens.orderedLeftToRight()
    switch ref {
    case .index(let i):
      let list = settings.orderScreensLeftToRight ? ordered : screens
      return list.indices.contains(i) ? list[i] : nil
    case .orderedIndex(let i):
      return ordered.indices.contains(i) ? ordered[i] : nil
    default:
      return nil
    }
  }
}
