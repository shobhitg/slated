import Foundation

/// Which of Slated's keyboard features run right now, given the configuration and what the app is
/// doing. Pure, so the rules are tested:
///
/// - **Recording a shortcut** in Settings (or the hotstring Try It field having focus): no shortcut or
///   hotstring may fire, so the keys reach the field. The Hyper key keeps working, though: Caps Lock
///   stays mapped to F18 and the event tap still adds the Hyper modifiers, or holding Caps Lock would
///   record a plain Caps Lock instead of ✦.
/// - **Pause Slated**: everything is off, and Caps Lock is a plain Caps Lock again.
public struct LiveTriggers: Hashable, Sendable {
  /// Caps Lock is mapped to F18, and the event tap adds the Hyper modifiers while it's held.
  public var hyperKey: Bool
  /// Typed triggers expand.
  public var hotstrings: Bool
  /// Shortcuts fire: registered hotkeys, and the Hyper combos and mouse buttons the event tap catches.
  public var shortcuts: Bool

  public init(_ configuration: SlatedConfiguration, paused: Bool, recording: Bool) {
    hyperKey = configuration.keyboard.capsLock == .hyper && !paused
    hotstrings =
      configuration.general.hotstringsEnabled && configuration.hotstrings.contains(where: \.enabled) && !paused
      && !recording
    shortcuts = !paused && !recording
  }
}
