import Foundation
import SlatedCore

let keyRepeatTests = Suite(
  "KeyRepeat",
  [
    (
      "the Mac's ticks are 1/60 s: 12 ticks is 200 ms, 1 tick is 17 ms",
      {
        expectEqual(MacKeyRepeatTicks.milliseconds(ticks: 12), 200)
        expectEqual(MacKeyRepeatTicks.milliseconds(ticks: 1), 17)
        expectEqual(MacKeyRepeatTicks.milliseconds(ticks: 2), 33)
        expectEqual(MacKeyRepeatTicks.ticks(milliseconds: 200), 12)
        expectEqual(MacKeyRepeatTicks.ticks(milliseconds: 17), 1)
        expectEqual(MacKeyRepeatTicks.ticks(milliseconds: 33), 2)
        // Never 0 ticks: that would mean no wait at all.
        expectEqual(MacKeyRepeatTicks.ticks(milliseconds: 15), 1)
        expectEqual(MacKeyRepeatTicks.ticks(milliseconds: 0), 1)
      }
    ),
    (
      "the HID event system's nanoseconds match what macOS sets for the ticks",
      {
        // Measured on macOS 26: InitialKeyRepeat 12 = 200000000 ns, KeyRepeat 1 = 16666666 ns.
        expectEqual(MacKeyRepeatTicks.nanoseconds(ticks: 12), 200_000_000)
        expectEqual(MacKeyRepeatTicks.nanoseconds(ticks: 1), 16_666_666)
        expectEqual(MacKeyRepeatTicks.ticks(nanoseconds: 16_666_666), 1)
        expectEqual(MacKeyRepeatTicks.ticks(nanoseconds: 16_666_667), 1)
        expectEqual(MacKeyRepeatTicks.ticks(nanoseconds: 200_000_000), 12)
        let ticks = MacKeyRepeatTicks(nanoseconds: 200_000_000, repeat: 16_666_666)
        expectEqual(ticks, MacKeyRepeatTicks(initial: 12, repeat: 1))
        expectEqual(ticks.nanoseconds.initial, 200_000_000)
        expectEqual(ticks.nanoseconds.repeat, 16_666_666)
      }
    ),
    (
      "a setting read from the Mac's ticks gives the same ticks back",
      {
        for initial in 1...120 {
          let ticks = MacKeyRepeatTicks(initial: initial, repeat: min(initial, 30))
          let setting = KeyRepeat(macTicks: ticks)
          let inRange =
            KeyRepeat.delayRange.contains(MacKeyRepeatTicks.milliseconds(ticks: initial))
            && KeyRepeat.intervalRange.contains(MacKeyRepeatTicks.milliseconds(ticks: ticks.repeat))
          if inRange { expectEqual(setting.macTicks, ticks) }
        }
        let author = KeyRepeat(macTicks: MacKeyRepeatTicks(initial: 12, repeat: 1))
        expectEqual(author, KeyRepeat(delay: 200, interval: 17))
      }
    ),
    (
      "values outside the ranges are clamped",
      {
        expectEqual(KeyRepeat(delay: 0, interval: 1), KeyRepeat(delay: 100, interval: 15))
        expectEqual(KeyRepeat(delay: 99_999, interval: 9_999), KeyRepeat(delay: 2000, interval: 500))
        var setting = KeyRepeat(delay: 200, interval: 17)
        setting.delay = 50
        setting.interval = 1000
        expectEqual(setting.delay, 100)
        expectEqual(setting.interval, 500)
        // A Mac set below its own slider (InitialKeyRepeat 2 = 33 ms) reads as the fastest Slated allows.
        expectEqual(KeyRepeat(macTicks: MacKeyRepeatTicks(initial: 2, repeat: 1)).delay, 100)
      }
    ),
    (
      "the Mac shows the rate it really applies: 17 ms is 1 tick, 60 per second",
      {
        let setting = KeyRepeat(delay: 200, interval: 17)
        expectEqual(Int(setting.macEffectiveInterval.rounded()), 17)
        expectEqual(Int((1000 / setting.macEffectiveInterval).rounded()), 60)
        expectEqual(Int(setting.repeatsPerSecond.rounded()), 59)
      }
    ),
    (
      "config.json: written only when set, clamped when read, both fields required",
      {
        var config = SlatedConfiguration()
        let empty = String(decoding: try config.encodedConfigFile(), as: UTF8.self)
        expect(!empty.contains("keyRepeat"))
        config.keyboard.keyRepeat = KeyRepeat(delay: 200, interval: 17)
        let data = try config.encodedConfigFile()
        expect(String(decoding: data, as: UTF8.self).contains("\"delay\" : 200"))
        expectEqual(try SlatedConfiguration.decode(from: data).keyboard.keyRepeat, KeyRepeat(delay: 200, interval: 17))
        let clamped = try SlatedConfiguration.decode(
          from: Data(#"{"keyboard": {"keyRepeat": {"delay": 5, "interval": 9000}}}"#.utf8))
        expectEqual(clamped.keyboard.keyRepeat, KeyRepeat(delay: 100, interval: 500))
        expectThrows { _ = try SlatedConfiguration.decode(from: Data(#"{"keyboard": {"keyRepeat": {"delay": 5}}}"#.utf8)) }
        let null = try SlatedConfiguration.decode(from: Data(#"{"keyboard": {"keyRepeat": null}}"#.utf8))
        expectEqual(null.keyboard.keyRepeat, nil)
      }
    ),
    (
      "the computer's setting is captured once, and only while config.json has none",
      {
        expect(KeyRepeat.shouldCapture(configured: nil, capturedBefore: false))
        expect(!KeyRepeat.shouldCapture(configured: nil, capturedBefore: true))
        expect(!KeyRepeat.shouldCapture(configured: KeyRepeat(delay: 200, interval: 17), capturedBefore: false))
      }
    ),
  ])
