import AppKit
import Foundation
import SlatedCore
import SlatedSystem

// macOS behaviors the app's runtime is built around, checked on this Mac. Each one explains a design
// choice; if one starts failing after a macOS update, revisit that choice.

private final class Counter: @unchecked Sendable {
  var value = 0
}

private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("SlatedContract-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func spinMainRunLoop(_ seconds: TimeInterval = 0.3) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let macOSContractTests = Suite(
  "macOSContract",
  [
    (
      "a watcher on config.json's folder misses saves made in place (so ConfigStore also polls)",
      {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file, options: .atomic)
        let fd = open(folder.path, O_EVTONLY)
        expect(fd >= 0)
        let events = Counter()
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { events.value += 1 }
        source.setCancelHandler { close(fd) }
        source.resume()
        defer { source.cancel() }
        spinMainRunLoop()

        // nano, Sublime Text and `>` in a shell truncate and rewrite the same file.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("{\"a\":1}".utf8))
        try handle.close()
        spinMainRunLoop()
        expectEqual(events.value, 0)

        // Most editors write a new file and rename it over the old one: that the folder does see.
        try Data("{\"a\":2}".utf8).write(to: file, options: .atomic)
        spinMainRunLoop()
        expect(events.value > 0)
      }
    ),
    (
      "an atomic save replaces a symlink with a file (so ConfigStore saves to the link's target)",
      {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("dotfiles-config.json")
        let link = folder.appendingPathComponent("config.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try Data("new".utf8).write(to: link.resolvingSymlinksInPath(), options: .atomic)
        expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        expectEqual(try String(contentsOf: target, encoding: .utf8), "new")

        try Data("newer".utf8).write(to: link, options: .atomic)
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        expectEqual(type, .typeRegular)
        expectEqual(try String(contentsOf: target, encoding: .utf8), "new")
      }
    ),
    (
      "Carbon refuses a hotkey only when Slated itself registered it already (so failures say so)",
      {
        try MainActor.assumeIsolated {
          let center = HotKeyCenter.shared
          // macOS's own shortcuts (here the screenshot one) register fine: they compete for the key
          // press, so registering can't tell that another app or macOS uses a shortcut.
          let screenshot = try center.register(KeyCombo(key: "3", modifiers: [.command, .shift])) { _ in }
          center.unregister(screenshot)
          let combo = KeyCombo(key: "f19", modifiers: [.control, .option, .shift, .command])
          let first = try center.register(combo) { _ in }
          defer { center.unregister(first) }
          do throws(HotKeyCenter.RegistrationError) {
            let second = try center.register(combo) { _ in }
            center.unregister(second)
            expect(false, "the same combo registered twice")
          } catch {
            expect(error.description.hasPrefix("Another Slated shortcut already uses"), error.description)
          }
        }
      }
    ),
    (
      "a block observer is removed from its own center, whichever center removes it",
      {
        let name = Notification.Name("SlatedContractProbe")
        let calls = Counter()
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
          calls.value += 1
        }
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        NotificationCenter.default.post(name: name, object: nil)
        expectEqual(calls.value, 0)
        NotificationCenter.default.removeObserver(token)
      }
    ),
  ])
