import Foundation

/// The notch island: a black capsule that grows out of the MacBook notch (or hangs from the top
/// center of displays without one) to show running automations, the active modal key, a cheat sheet
/// of shortcuts and brief feedback.
public struct IslandSettings: Hashable, Sendable {
  /// Off: no island. Action feedback and the automation indicator fall back to the classic pills.
  public var enabled: Bool
  /// Hold the Hyper key, or press a modal key, for `cheatSheetDelay` seconds to see its shortcuts.
  public var cheatSheet: Bool
  public var cheatSheetDelay: Double
  /// Briefly show why a shortcut didn't work ("No focused window to move").
  public var showFailures: Bool

  public init(enabled: Bool = true, cheatSheet: Bool = true, cheatSheetDelay: Double = 0.5, showFailures: Bool = true) {
    self.enabled = enabled
    self.cheatSheet = cheatSheet
    self.cheatSheetDelay = cheatSheetDelay
    self.showFailures = showFailures
  }
}

extension IslandSettings: Codable {
  private enum Key: String, CodingKey { case enabled, cheatSheet, cheatSheetDelay, showFailures }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let d = IslandSettings()
    self.init(
      enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
      cheatSheet: try c.decodeIfPresent(Bool.self, forKey: .cheatSheet) ?? d.cheatSheet,
      cheatSheetDelay: try c.decodeIfPresent(Double.self, forKey: .cheatSheetDelay) ?? d.cheatSheetDelay,
      showFailures: try c.decodeIfPresent(Bool.self, forKey: .showFailures) ?? d.showFailures)
  }
}
