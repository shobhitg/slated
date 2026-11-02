import Foundation

/// How a held key repeats: `delay` milliseconds before the first repeat, then one every `interval`
/// milliseconds. config.json's `keyboard.keyRepeat`; when it's absent Slated leaves the computer's own
/// setting alone.
///
/// Milliseconds because both systems can say them: GNOME stores milliseconds, and the Mac's 1/60 s
/// ticks convert (see `macTicks`). Values outside the ranges are clamped into them, as reading the file
/// and the UI's sliders do, so a typo can't make the keyboard unusable (a 0 ms interval repeats as fast
/// as the system can).
public struct KeyRepeat: Hashable, Sendable {
  /// How long a key must be held before it repeats. macOS's own slider stops at 15 ticks (250 ms).
  public static let delayRange = 100...2000
  /// The time between repeats. macOS's slider stops at 2 ticks (33 ms); 1 tick is about 17 ms.
  public static let intervalRange = 15...500

  public var delay: Int {
    didSet { delay = Self.clamp(delay, to: Self.delayRange) }
  }
  public var interval: Int {
    didSet { interval = Self.clamp(interval, to: Self.intervalRange) }
  }

  public init(delay: Int, interval: Int) {
    self.delay = Self.clamp(delay, to: Self.delayRange)
    self.interval = Self.clamp(interval, to: Self.intervalRange)
  }

  /// Repeats per second at `interval`.
  public var repeatsPerSecond: Double { 1000 / Double(interval) }

  static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }
}

extension KeyRepeat: Codable {
  private enum Key: String, CodingKey { case delay, interval }

  /// Both fields are required: half a setting can't be applied.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    self.init(delay: try c.decode(Int.self, forKey: .delay), interval: try c.decode(Int.self, forKey: .interval))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(delay, forKey: .delay)
    try c.encode(interval, forKey: .interval)
  }
}

// MARK: - The Mac's units

/// The Mac keeps key repeat in two places, in two units:
/// - the global defaults `InitialKeyRepeat` and `KeyRepeat`, the saved setting macOS reads at login,
///   in ticks of 1/60 s (12 ticks = 200 ms; 1 tick ≈ 16.7 ms, not the often quoted 15 ms);
/// - the HID event system's live `HIDInitialKeyRepeat` and `HIDKeyRepeat`, in nanoseconds.
///
/// Measured on macOS 26: `InitialKeyRepeat` 12 with `HIDInitialKeyRepeat` 200000000, and `KeyRepeat`
/// 1 with `HIDKeyRepeat` 16666666 (a contract test checks the relationship).
public struct MacKeyRepeatTicks: Hashable, Sendable {
  public static let perSecond = 60

  /// `InitialKeyRepeat`.
  public var initial: Int
  /// `KeyRepeat`.
  public var `repeat`: Int

  public init(initial: Int, repeat: Int) {
    self.initial = initial
    self.repeat = `repeat`
  }

  /// Ticks for milliseconds: at least 1 (0 would mean no wait at all).
  public static func ticks(milliseconds: Int) -> Int {
    max(1, Int((Double(milliseconds) * Double(perSecond) / 1000).rounded()))
  }

  public static func milliseconds(ticks: Int) -> Int {
    Int((Double(ticks) * 1000 / Double(perSecond)).rounded())
  }

  /// What the HID event system holds for ticks, as macOS itself sets it (16666666 for 1 tick).
  public static func nanoseconds(ticks: Int) -> Int64 {
    Int64(ticks) * 1_000_000_000 / Int64(perSecond)
  }

  /// The nearest whole tick for a live value (whatever set it).
  public static func ticks(nanoseconds: Int64) -> Int {
    Int((Double(nanoseconds) * Double(perSecond) / 1e9).rounded())
  }

  /// The HID event system's values: (`HIDInitialKeyRepeat`, `HIDKeyRepeat`) in nanoseconds.
  public var nanoseconds: (initial: Int64, repeat: Int64) {
    (Self.nanoseconds(ticks: initial), Self.nanoseconds(ticks: `repeat`))
  }

  public init(nanoseconds initial: Int64, repeat: Int64) {
    self.init(initial: Self.ticks(nanoseconds: initial), repeat: Self.ticks(nanoseconds: `repeat`))
  }
}

extension KeyRepeat {
  /// The Mac's ticks for this setting.
  public var macTicks: MacKeyRepeatTicks {
    MacKeyRepeatTicks(
      initial: MacKeyRepeatTicks.ticks(milliseconds: delay), repeat: MacKeyRepeatTicks.ticks(milliseconds: interval))
  }

  /// The setting the Mac's ticks give, rounded to whole milliseconds and clamped into range.
  public init(macTicks ticks: MacKeyRepeatTicks) {
    self.init(
      delay: MacKeyRepeatTicks.milliseconds(ticks: ticks.initial),
      interval: MacKeyRepeatTicks.milliseconds(ticks: ticks.repeat))
  }

  /// The same setting as the Mac applies it, in whole ticks: what the UI shows on the Mac (1 tick is
  /// 60 per second, though it's saved as 17 ms).
  public var macEffectiveInterval: Double { Double(macTicks.repeat) * 1000 / Double(MacKeyRepeatTicks.perSecond) }

  /// Whether Slated should read the computer's key repeat into config.json: once per computer (so
  /// turning the switch off sticks), and only while config.json has none.
  public static func shouldCapture(configured: KeyRepeat?, capturedBefore: Bool) -> Bool {
    configured == nil && !capturedBefore
  }
}

/// What applying a key repeat setting did, for the UI and the log.
public enum KeyRepeatState: Hashable, Sendable {
  /// The keyboard repeats this way now.
  case applied
  /// Saved, but the system uses it only after the user logs out and back in (macOS when its live
  /// setting couldn't be changed).
  case afterLogout
  /// It couldn't even be saved.
  case failed(String)
}
