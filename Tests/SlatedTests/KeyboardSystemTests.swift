import AppKit
import Foundation

@testable import SlatedCore
@testable import SlatedSystem
@testable import SlatedUI

// Key repeat on the Mac, the Caps Lock lock under the Hyper key, and the menu bar icon behind the
// notch: the logic, with stand-ins for the system. Nothing here writes the real defaults, runs
// `hidutil property --set` or touches the real Caps Lock.

/// A Mac's key repeat in memory: the global defaults (ticks) and the HID event system (ns).
private final class FakeMac {
  var defaults: (initial: Int?, repeat: Int?) = (nil, nil)
  var live: (initial: Int64, repeat: Int64)? = (200_000_000, 16_666_666)
  /// hidutil changes the live values (false: macOS keeps the old ones until the next login).
  var liveWritable = true
  var defaultsWritable = true
  var defaultsWrites: [MacKeyRepeatTicks] = []
  var liveWrites: [(Int64, Int64)] = []

  var io: MacKeyRepeat.IO {
    MacKeyRepeat.IO(
      readDefaults: { self.defaults },
      writeDefaults: { ticks in
        self.defaultsWrites.append(ticks)
        guard self.defaultsWritable else { return false }
        self.defaults = (ticks.initial, ticks.repeat)
        return true
      },
      readLive: { self.live },
      writeLive: { initial, repeatNs in
        self.liveWrites.append((initial, repeatNs))
        if self.liveWritable { self.live = (initial, repeatNs) }
        return true
      })
  }
}

/// The Caps Lock lock in memory.
private final class FakeLock {
  var on: Bool? = false
  var refuses = false
  var turnOffCalls = 0

  var lock: CapsLockLock {
    CapsLockLock(
      isOn: { self.on },
      turnOff: {
        self.turnOffCalls += 1
        if !self.refuses { self.on = false }
        return !self.refuses
      })
  }
}

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

let macKeyRepeatTests = Suite(
  "MacKeyRepeat",
  [
    (
      "captures the saved defaults: the author's 12 and 1 ticks are 200 and 17 ms",
      {
        let mac = FakeMac()
        mac.defaults = (12, 1)
        expectEqual(MacKeyRepeat(io: mac.io).current(), KeyRepeat(delay: 200, interval: 17))
      }
    ),
    (
      "a default that was never set is read from the live value (macOS's default)",
      {
        let mac = FakeMac()
        mac.defaults = (nil, 2)
        mac.live = (MacKeyRepeatTicks.nanoseconds(ticks: 15), MacKeyRepeatTicks.nanoseconds(ticks: 6))
        expectEqual(MacKeyRepeat(io: mac.io).current(), KeyRepeat(delay: 250, interval: 33))
        mac.live = nil
        expectEqual(MacKeyRepeat(io: mac.io).current(), nil)
      }
    ),
    (
      "applies in both places and says it's live when the read-back matches",
      {
        let mac = FakeMac()
        mac.defaults = (25, 6)
        let result = MacKeyRepeat(io: mac.io).apply(KeyRepeat(delay: 200, interval: 17))
        expectEqual(result.state, .applied)
        expectEqual(mac.defaultsWrites, [MacKeyRepeatTicks(initial: 12, repeat: 1)])
        // Already live (the fake starts at 200 ms / 1 tick): hidutil isn't run.
        expect(mac.liveWrites.isEmpty)
        expect(result.wroteDefaults && !result.wroteLive)
      }
    ),
    (
      "sets the live values in nanoseconds as macOS does",
      {
        let mac = FakeMac()
        mac.defaults = (12, 1)
        mac.live = (MacKeyRepeatTicks.nanoseconds(ticks: 25), MacKeyRepeatTicks.nanoseconds(ticks: 6))
        let result = MacKeyRepeat(io: mac.io).apply(KeyRepeat(delay: 200, interval: 17))
        expectEqual(result.state, .applied)
        expectEqual(mac.liveWrites.count, 1)
        expectEqual(mac.liveWrites.first?.0, 200_000_000)
        expectEqual(mac.liveWrites.first?.1, 16_666_666)
        expect(mac.defaultsWrites.isEmpty)
      }
    ),
    (
      "when macOS keeps the old live values, the change waits for a new login",
      {
        let mac = FakeMac()
        mac.defaults = (25, 6)
        mac.live = (MacKeyRepeatTicks.nanoseconds(ticks: 25), MacKeyRepeatTicks.nanoseconds(ticks: 6))
        mac.liveWritable = false
        let result = MacKeyRepeat(io: mac.io).apply(KeyRepeat(delay: 200, interval: 17))
        expectEqual(result.state, .afterLogout)
        expectEqual(mac.defaults.initial, 12)
        // Unreadable live values can't be confirmed either.
        mac.live = nil
        expectEqual(MacKeyRepeat(io: mac.io).apply(KeyRepeat(delay: 200, interval: 17)).state, .afterLogout)
      }
    ),
    (
      "a setting that can't be saved fails, and the live values are left alone",
      {
        let mac = FakeMac()
        mac.defaults = (25, 6)
        mac.live = (MacKeyRepeatTicks.nanoseconds(ticks: 25), MacKeyRepeatTicks.nanoseconds(ticks: 6))
        mac.defaultsWritable = false
        let result = MacKeyRepeat(io: mac.io).apply(KeyRepeat(delay: 200, interval: 17))
        guard case .failed = result.state else { throw TestFailure(description: "expected a failure") }
        expect(mac.liveWrites.isEmpty)
      }
    ),
    (
      "nothing is written when the Mac already repeats this way",
      {
        let mac = FakeMac()
        mac.defaults = (12, 1)
        // 205 ms is 12.3 ticks and 16 ms 0.96: the same 12 and 1 ticks.
        let result = MacKeyRepeat(io: mac.io).apply(KeyRepeat(delay: 205, interval: 16))
        expectEqual(result, MacKeyRepeat.Result(state: .applied, wroteDefaults: false, wroteLive: false))
      }
    ),
    (
      "hidutil's argument and output",
      {
        expectEqual(
          MacKeyRepeat.settingJSON(initial: 200_000_000, repeat: 16_666_666),
          #"{"HIDInitialKeyRepeat":200000000,"HIDKeyRepeat":16666666}"#)
        expectEqual(MacKeyRepeat.parseNumber("16666666\n"), 16_666_666)
        expectEqual(MacKeyRepeat.parseNumber("(null)\n"), nil)
        expectEqual(MacKeyRepeat.parseNumber(nil), nil)
      }
    ),
  ])

let capsLockLockTests = Suite(
  "CapsLockLock",
  [
    (
      "a lock that's off is left alone",
      {
        let fake = FakeLock()
        expectEqual(fake.lock.clearIfOn(), .wasOff)
        expectEqual(fake.turnOffCalls, 0)
      }
    ),
    (
      "a lock that's on is turned off",
      {
        let fake = FakeLock()
        fake.on = true
        expectEqual(fake.lock.clearIfOn(), .cleared)
        expectEqual(fake.on, false)
      }
    ),
    (
      "a lock that can't be turned off or read is a failure",
      {
        let fake = FakeLock()
        fake.on = true
        fake.refuses = true
        expectEqual(fake.lock.clearIfOn(), .failed)
        fake.on = nil
        expectEqual(fake.lock.clearIfOn(), .failed)
      }
    ),
  ])

/// The author's MacBook: a 1512 pt wide built-in display whose notch spans x 663–848.
private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let leftArea = CGRect(x: 0, y: 950, width: 663, height: 32)
private let rightArea = CGRect(x: 848, y: 950, width: 664, height: 32)

let menuBarTests = Suite(
  "MenuBar",
  [
    (
      "the notch is between the unobscured areas",
      {
        expectEqual(
          MenuBarPlacement.notch(screenFrame: builtIn, topLeftArea: leftArea, topRightArea: rightArea), 663...848)
        expectEqual(MenuBarPlacement.notch(screenFrame: builtIn, topLeftArea: nil, topRightArea: nil), nil)
      }
    ),
    (
      "the icon at x 744–768 is behind the notch; one to its right isn't",
      {
        func behind(_ x: CGFloat, width: CGFloat = 24, y: CGFloat = 0) -> Bool {
          MenuBarPlacement.isBehindNotch(
            itemFrame: CGRect(x: x, y: y, width: width, height: 24), screenFrame: builtIn, topLeftArea: leftArea,
            topRightArea: rightArea)
        }
        expect(behind(744))
        expect(!behind(1300))
        expect(!behind(600))
        // Mostly visible: less than half behind the notch.
        expect(!behind(840))
        expect(behind(826))
        // Not in the menu bar at all.
        expect(!behind(744, y: 500))
        expect(!behind(744, width: 0))
      }
    ),
    (
      "a display without a notch, or the built-in display to the left of the main one",
      {
        let external = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        expect(
          !MenuBarPlacement.isBehindNotch(
            itemFrame: CGRect(x: 1270, y: 0, width: 24, height: 24), screenFrame: external, topLeftArea: nil,
            topRightArea: nil))
        // The areas may be given relative to the screen: only their widths count.
        let left = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        expect(
          MenuBarPlacement.isBehindNotch(
            itemFrame: CGRect(x: -1512 + 744, y: 0, width: 24, height: 24), screenFrame: left, topLeftArea: leftArea,
            topRightArea: rightArea))
        expect(
          !MenuBarPlacement.isBehindNotch(
            itemFrame: CGRect(x: 744, y: 0, width: 24, height: 24), screenFrame: left, topLeftArea: leftArea,
            topRightArea: rightArea))
      }
    ),
    (
      "the icon's variants: paused, then modal, then a warning",
      {
        try onMain {
          expectEqual(StatusGlyph.variant(paused: false, modal: false, warnings: []), .normal)
          expectEqual(StatusGlyph.variant(paused: false, modal: false, warnings: ["x"]), .warning)
          expectEqual(StatusGlyph.variant(paused: false, modal: true, warnings: ["x"]), .modal)
          expectEqual(StatusGlyph.variant(paused: true, modal: true, warnings: ["x"]), .paused)
          for glyph in StatusGlyph.allCases {
            let image = glyph.image()
            expect(image.isTemplate)
            expectEqual(image.size, NSSize(width: 16, height: 16))
            expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
          }
        }
      }
    ),
    (
      "what needs attention, as on GNOME",
      {
        try onMain {
          let long = String(repeating: "x", count: 120)
          let warnings = StatusGlyph.warnings(
            loadError: "config.json: bad\nmore", hotkeys: ["a": .active, "b": .failed("taken"), "c": .failed("taken")],
            conflicts: ["Slate is running"])
          expectEqual(
            warnings,
            [
              "config.json: bad", "2 shortcuts couldn't be registered: macOS or another app uses the keys",
              "Slate is running",
            ])
          expectEqual(
            StatusGlyph.warnings(loadError: long, hotkeys: [:], conflicts: []).first?.count, 90)
          expectEqual(StatusGlyph.warnings(loadError: nil, hotkeys: ["a": .duplicate], conflicts: []), [])
        }
      }
    ),
    (
      "the notice shows while the icon is behind the notch, until dismissed",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          expect(!model.showsMenuBarNotice)
          services.setMenuBarIcon(.behindNotch)
          model.refresh()
          expect(model.showsMenuBarNotice)
          model.dismissMenuBarNotice()
          expect(!model.showsMenuBarNotice)
          // Shown again later, then hidden again: said again.
          services.setMenuBarIcon(.shown)
          services.setMenuBarIcon(.behindNotch)
          model.refresh()
          expect(model.showsMenuBarNotice)
          services.setMenuBarIcon(.off)
          model.refresh()
          expect(!model.showsMenuBarNotice)
          expect(MenuBarText.message.contains("Dock icon opens this window"))
        }
      }
    ),
  ])

let uiKeyRepeatTests = Suite(
  "UI.keyRepeat",
  [
    (
      "the switch starts from this Mac's setting; off removes it",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          services.systemKeyRepeat = KeyRepeat(delay: 250, interval: 33)
          let model = AppModel(services: services)
          expect(!model.keyRepeatEnabled)
          expectEqual(model.keyRepeatStatus, .off)
          model.keyRepeatEnabled = true
          expectEqual(model.configuration.keyboard.keyRepeat, KeyRepeat(delay: 250, interval: 33))
          expectEqual(model.keyRepeatStatus, .saving)
          model.keyRepeatEnabled = false
          expectEqual(model.configuration.keyboard.keyRepeat, nil)
          services.systemKeyRepeat = nil
          model.keyRepeatEnabled = true
          expectEqual(model.configuration.keyboard.keyRepeat, AppModel.fallbackKeyRepeat)
        }
      }
    ),
    (
      "Use this Mac's current setting",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          model.configuration.keyboard.keyRepeat = KeyRepeat(delay: 600, interval: 100)
          services.systemKeyRepeat = KeyRepeat(delay: 200, interval: 17)
          model.useCurrentKeyRepeat()
          expectEqual(model.configuration.keyboard.keyRepeat, KeyRepeat(delay: 200, interval: 17))
        }
      }
    ),
    (
      "the status line and Overview's log-out notice",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          expectEqual(model.keyRepeatStatus, .applied)
          expect(!model.showsKeyRepeatLogoutNotice)
          services.setKeyRepeatState(.afterLogout)
          model.refresh()
          expectEqual(model.keyRepeatStatus, .afterLogout)
          expect(model.showsKeyRepeatLogoutNotice)
          model.dismissKeyRepeatLogoutNotice()
          expect(!model.showsKeyRepeatLogoutNotice)
          // A new setting that also waits for a login says so again.
          model.configuration.keyboard.keyRepeat = KeyRepeat(delay: 300, interval: 17)
          model.saveNow()
          model.refresh()
          expect(model.showsKeyRepeatLogoutNotice)
        }
      }
    ),
    (
      "labels: 200 ms, and the rate the Mac really applies",
      {
        try onMain {
          let setting = KeyRepeat(delay: 200, interval: 17)
          expectEqual(setting.delayLabel, "200 ms")
          expectEqual(setting.rateLabel, "60 per second (17 ms)")
          expectEqual(KeyRepeat(delay: 200, interval: 33).rateLabel, "30 per second (33 ms)")
        }
      }
    ),
  ])

// macOS's own key repeat values, read (never written) on this Mac.
let keyRepeatContractTests = Suite(
  "macOSContract.keyRepeat",
  [
    (
      "the defaults are 1/60 s ticks of the HID event system's nanoseconds",
      {
        let io = MacKeyRepeat.IO.system
        let defaults = io.readDefaults()
        guard let live = io.readLive() else { throw TestFailure(description: "hidutil printed no HIDKeyRepeat") }
        // macOS sets whole ticks: within a nanosecond of n × 1e9 / 60.
        for ns in [live.initial, live.repeat] {
          let ticks = MacKeyRepeatTicks.ticks(nanoseconds: ns)
          expect(abs(MacKeyRepeatTicks.nanoseconds(ticks: ticks) - ns) <= 1, "\(ns) ns isn't a whole tick")
        }
        // The same numbers unless a change is waiting for the next login.
        if let initial = defaults.initial, let repeatTicks = defaults.repeat {
          let liveTicks = MacKeyRepeatTicks(nanoseconds: live.initial, repeat: live.repeat)
          if liveTicks != MacKeyRepeatTicks(initial: initial, repeat: repeatTicks) {
            print("    note: defaults \(initial)/\(repeatTicks) ticks, live \(liveTicks): a change waits for a login")
          }
        }
      }
    ),
    (
      "CFPreferences reads what `defaults read -g` prints",
      {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "-g", "KeyRepeat"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let viaDefaults =
          process.terminationStatus == 0 ? Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        expectEqual(MacKeyRepeat.IO.system.readDefaults().repeat, viaDefaults)
      }
    ),
  ])
