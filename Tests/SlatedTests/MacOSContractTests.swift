import AppKit
import Foundation

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
    (
      "clipboard search folds what the GNOME port folds: Grapheme_Extend dropped, few precomposed characters split",
      {
        // The rules linux/gnome-extension/lib/core/clipboard.js follows, checked on every scalar. The
        // golden vectors in fixtures/clipboard.json pin individual cases.
        func finds(_ text: String, _ query: String) -> Bool {
          text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func ignored(_ scalar: Unicode.Scalar) -> Bool {
          scalar.properties.isGraphemeExtend || (0x1F3FB...0x1F3FF).contains(scalar.value)
        }
        var wrong: [String] = []
        var checked = (singletons: 0, precomposed: 0)
        for value in UInt32(0xA0)...0x10FFFF {
          guard let scalar = Unicode.Scalar(value), scalar.properties.generalCategory != .unassigned,
            scalar.properties.generalCategory != .privateUse
          else { continue }
          let c = String(Character(scalar))
          let nfd = c.decomposedStringWithCanonicalMapping
          // (Swift's == compares canonically equivalent strings as equal, so compare scalars.)
          let decomposes = !nfd.unicodeScalars.elementsEqual(c.unicodeScalars)
          if nfd.unicodeScalars.count == 1 && decomposes && !ignored(scalar) {
            // A singleton (CJK compatibility ideographs, Ω, K…) is always replaced.
            checked.singletons += 1
            if !finds(nfd, c + "\u{308}") { wrong.append(String(format: "singleton %04X", value)) }
            continue
          }
          // Separately written, it's ignored exactly when it's Grapheme_Extend (or a skin tone). ("q" and
          // "z" have no precomposed forms with marks, so they never combine with it.)
          if !decomposes && finds("q" + c + "z", "qz") != ignored(scalar) {
            wrong.append(String(format: "ignored %04X", value))
          }
          // Precomposed, it's split into base and marks only when the base is below U+0510.
          let marks = nfd.unicodeScalars.filter(ignored)
          let base = String(String.UnicodeScalarView(nfd.unicodeScalars.filter { !ignored($0) }))
          guard !marks.isEmpty, !base.isEmpty else { continue }
          checked.precomposed += 1
          if finds(c, base) != (nfd.unicodeScalars.first!.value < 0x510) {
            wrong.append(String(format: "precomposed %04X", value))
          }
        }
        expectEqual(wrong, [])
        expect(checked.singletons > 1000 && checked.precomposed > 1000, "\(checked)")
        // A canonically equivalent spelling matches, also with the text's extra marks left out.
        expect(finds("\u{304B}\u{3099}", "\u{304C}") && finds("\u{304C}", "\u{304B}\u{3099}"))
        expect(finds("\u{FB2A}\u{309A}", "\u{5E9}\u{5C1}") && !finds("\u{FB2A}", "\u{5E9}\u{5C1}\u{309A}"))
        expect(!finds("\u{304C}", "\u{304B}") && !finds("\u{304B}", "\u{304C}"))
      }
    ),
  ])
