import Foundation

/// The timing rules of an auto-repeat: how long until the next run, and whether there is one.
/// Pure, so the app's timer code stays trivial and the rules are tested.
public struct RepeatSchedule: Hashable, Sendable {
  /// Seconds between runs (at least 0.01: 100 runs a second).
  public let interval: Double
  /// Total runs before it stops by itself; nil runs until stopped.
  public let times: Int?
  /// Each interval varies randomly by up to this fraction (0…0.5).
  public let jitter: Double

  public init(interval: Double, times: Int? = nil, jitter: Double = 0) {
    self.interval = max(interval.isFinite ? interval : 0.1, 0.01)
    self.times = times.map { max($0, 1) }
    self.jitter = min(max(jitter.isFinite ? jitter : 0, 0), 0.5)
  }

  /// Whether another run should follow after `runs` runs so far.
  public func shouldRunAgain(afterRuns runs: Int) -> Bool {
    guard let times else { return true }
    return runs < times
  }

  /// The wait before the next run. `random` is a uniform value in 0…1 (injected for tests).
  public func nextInterval(random: Double) -> Double {
    let r = min(max(random, 0), 1)
    return max(0.01, interval * (1 - jitter + 2 * jitter * r))
  }
}
