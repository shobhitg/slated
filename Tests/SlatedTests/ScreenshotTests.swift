import AppKit
import Darwin
import Foundation
import SlatedCore
import UniformTypeIdentifiers

@testable import SlatedSystem

// Screenshots saved as files, and files copied in the Finder. Everything happens in temporary folders
// with files these tests make (the screenshot attribute set with setxattr) and on private pasteboards:
// the real Desktop, screenshots and clipboard are never touched.

private func temporaryFolder() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("slated-shots-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Writes `data` at `url`, marked as a screenshot the way screencapture marks one.
@discardableResult
private func writeScreenshot(_ url: URL, data: Data = sampleImageData(), marked: Bool = true) -> URL {
  FileManager.default.createFile(atPath: url.path, contents: data)
  if marked { markAsScreenshot(url) }
  return url
}

private func markAsScreenshot(_ url: URL) {
  let value = try! PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
  let result = value.withUnsafeBytes { bytes in
    setxattr(url.path, Screenshots.attribute, bytes.baseAddress, bytes.count, 0, 0)
  }
  precondition(result == 0, "setxattr failed")
}

/// Scans until the scanner has nothing in progress (at most a few times).
private func settle(_ scanner: inout ScreenshotScanner) throws -> [URL] {
  var found: [URL] = []
  for _ in 0..<4 {
    found += try scanner.scan()
    if !scanner.isWaiting { break }
  }
  return found
}

/// Runs the main run loop until `done` or `seconds` pass: the watcher reports on the main queue.
@MainActor private func waitFor(_ seconds: Double = 5, _ done: () -> Bool) {
  let deadline = Date().addingTimeInterval(seconds)
  while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

private final class Events: @unchecked Sendable {
  var shots: [URL] = []
  var statuses: [ScreenshotWatcher.Status] = []
  var folderReads = 0
}

let screenshotTests = Suite(
  "Screenshots",
  [
    (
      "the screenshot folder follows screencapture's location, with ~ expanded, else ~/Desktop",
      {
        let home = "/Users/someone"
        expectEqual(Screenshots.folder(location: nil, home: home).path, "/Users/someone/Desktop")
        expectEqual(Screenshots.folder(location: "  ", home: home).path, "/Users/someone/Desktop")
        expectEqual(Screenshots.folder(location: "~/Pictures/Shots", home: home).path, "/Users/someone/Pictures/Shots")
        expectEqual(Screenshots.folder(location: "~", home: home).path, "/Users/someone")
        expectEqual(Screenshots.folder(location: "/Volumes/Work/Shots/", home: home).path, "/Volumes/Work/Shots")
        expectEqual(Screenshots.folder(location: "Documents", home: home).path, "/Users/someone/Documents")
      }
    ),
    (
      "a new file with the screenshot attribute is found once it's complete; others are ignored",
      {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var scanner = ScreenshotScanner(folder: folder, since: Date().addingTimeInterval(-1))
        expectEqual(try scanner.scan(), [])
        let shot = writeScreenshot(folder.appendingPathComponent("Screenshot 2026-10-30 at 09.41.12.png"))
        writeScreenshot(folder.appendingPathComponent("photo.png"), marked: false)
        // First seen: not reported until a second look finds it the same size.
        expectEqual(try scanner.scan(), [])
        expect(scanner.isWaiting)
        expectEqual(try scanner.scan().map(\.lastPathComponent), [shot.lastPathComponent])
        expect(!scanner.isWaiting)
        expectEqual(try scanner.scan(), [])  // reported once
      }
    ),
    (
      "a screenshot older than the watch, or a hidden one, is ignored; one still growing waits",
      {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = writeScreenshot(folder.appendingPathComponent("Screenshot old.png"))
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        writeScreenshot(folder.appendingPathComponent(".Screenshot temp.png"))
        var scanner = ScreenshotScanner(folder: folder, since: Date().addingTimeInterval(-60))
        expectEqual(try settle(&scanner), [])

        let growing = writeScreenshot(folder.appendingPathComponent("Screenshot growing.png"), data: Data())
        expectEqual(try scanner.scan(), [])
        expectEqual(try scanner.scan(), [])  // an empty file isn't complete
        let handle = try FileHandle(forWritingTo: growing)
        try handle.write(contentsOf: sampleImageData())
        try handle.close()
        expectEqual(try scanner.scan(), [])  // it grew since the last look
        expectEqual(try scanner.scan().map(\.lastPathComponent), ["Screenshot growing.png"])
      }
    ),
    (
      "a screenshot renamed into place is found under its final name, and renaming it later isn't new",
      {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var scanner = ScreenshotScanner(folder: folder, since: Date().addingTimeInterval(-1))
        let temporary = writeScreenshot(folder.appendingPathComponent(".Screenshot 2026-10-30 at 09.41.12.png"))
        expectEqual(try settle(&scanner), [])
        let final = folder.appendingPathComponent("Screenshot 2026-10-30 at 09.41.12.png")
        try FileManager.default.moveItem(at: temporary, to: final)
        expectEqual(try settle(&scanner).map(\.lastPathComponent), [final.lastPathComponent])
        try FileManager.default.moveItem(at: final, to: folder.appendingPathComponent("Renamed.png"))
        expectEqual(try settle(&scanner), [])
      }
    ),
    (
      "a missing folder is reported as missing",
      {
        var scanner = ScreenshotScanner(folder: temporaryFolder().appendingPathComponent("nope"), since: Date())
        do {
          _ = try scanner.scan()
          expect(false, "a missing folder can't be listed")
        } catch let error as ScreenshotFolderError {
          expectEqual(error, .folderMissing)
        }
      }
    ),
    (
      "the watcher reports a screenshot saved while it runs, and never looks at the folder unless started",
      {
        try MainActor.assumeIsolated {
          let folder = temporaryFolder()
          defer { try? FileManager.default.removeItem(at: folder) }
          let events = Events()
          let watcher = ScreenshotWatcher(
            folder: {
              events.folderReads += 1
              return folder
            },
            onEvent: { event in
              switch event {
              case .screenshot(let url): events.shots.append(url)
              case .status(let status): events.statuses.append(status)
              }
            })
          // The setting off: the watcher isn't started, and the folder is never read.
          writeScreenshot(folder.appendingPathComponent("Screenshot before.png"))
          RunLoop.main.run(until: Date().addingTimeInterval(0.2))
          watcher.sync()
          expectEqual(events.folderReads, 0)
          expect(events.statuses.isEmpty)

          watcher.start()
          waitFor { !events.statuses.isEmpty }
          expectEqual(events.statuses, [.watching(folder)])
          // As screencapture saves: a hidden file, renamed when it's done.
          let temporary = writeScreenshot(folder.appendingPathComponent(".Screenshot new.png"))
          try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent("Screenshot new.png"))
          waitFor { !events.shots.isEmpty }
          expectEqual(events.shots.map(\.lastPathComponent), ["Screenshot new.png"])

          watcher.stop()
          waitFor { events.statuses.last == .off }
          let reads = events.folderReads
          writeScreenshot(folder.appendingPathComponent("Screenshot after.png"))
          RunLoop.main.run(until: Date().addingTimeInterval(0.8))
          expectEqual(events.shots.count, 1)  // nothing is reported once stopped
          expectEqual(events.folderReads, reads)
          expectEqual(events.statuses, [.watching(folder), .off])
        }
      }
    ),
    (
      "the watcher says when the folder is missing, and picks it up once it's there",
      {
        try MainActor.assumeIsolated {
          let parent = temporaryFolder()
          defer { try? FileManager.default.removeItem(at: parent) }
          let folder = parent.appendingPathComponent("Screenshots")
          let events = Events()
          let watcher = ScreenshotWatcher(folder: { folder }) { event in
            if case .status(let status) = event { events.statuses.append(status) }
          }
          watcher.start()
          waitFor { !events.statuses.isEmpty }
          expectEqual(events.statuses, [.folderMissing(folder)])
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          waitFor(8) { events.statuses.count > 1 }
          expectEqual(events.statuses.last, .watching(folder))
          watcher.stop()
          watcher.sync()
        }
      }
    ),
    (
      "a screenshot file is copied into the store with its name; too large is skipped unread",
      {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardImageStore(directory: folder.appendingPathComponent("store"), maxBytes: 4_000)
        let png = sampleImageData(width: 40, height: 30)
        let shot = writeScreenshot(folder.appendingPathComponent("Screenshot 1.png"), data: png)
        guard case .saved(let image) = store.saveScreenshot(at: shot) else { return expect(false, "saved") }
        expectEqual(image.name, "Screenshot 1.png")
        expectEqual([image.width, image.height, image.bytes], [40, 30, png.count])
        expectEqual(try Data(contentsOf: store.url(for: image)), png)  // PNG bytes are kept as they are
        expect(FileManager.default.fileExists(atPath: shot.path), "the screenshot itself is left alone")

        // A JPEG screenshot is kept as PNG, which every app pastes.
        let jpeg = writeScreenshot(
          folder.appendingPathComponent("Screenshot 2.jpg"), data: sampleImageData(red: 0.8, type: .jpeg))
        guard case .saved(let converted) = store.saveScreenshot(at: jpeg) else { return expect(false, "converted") }
        expect(converted.file.hasSuffix(".png"))
        expectEqual(converted.name, "Screenshot 2.jpg")

        let big = writeScreenshot(
          folder.appendingPathComponent("Screenshot big.png"), data: sampleImageData(width: 900, height: 900))
        guard case .tooLarge(let bytes, let width, _) = store.saveScreenshot(at: big) else {
          return expect(false, "too large")
        }
        expect(bytes > 4_000)
        expectEqual(width, 900)
        let junk = writeScreenshot(folder.appendingPathComponent("Screenshot junk.png"), data: Data("not an image".utf8))
        expectEqual(store.saveScreenshot(at: junk), .failed(bytes: 12))
      }
    ),
  ])

let clipboardFilesTests = Suite(
  "ClipboardFiles",
  [
    (
      "files copied in the Finder are a files copy: their URLs, without the names or the icon picture",
      {
        MainActor.assumeIsolated {
          let folder = temporaryFolder()
          defer { try? FileManager.default.removeItem(at: folder) }
          let a = folder.appendingPathComponent("Report.pdf")
          let b = folder.appendingPathComponent("Notes.txt")
          for url in [a, b] { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
          let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.test.\(UUID().uuidString)"))
          defer { pasteboard.releaseGlobally() }
          let watcher = PasteboardWatcher(pasteboard: pasteboard)
          let copies = ImageCopiesForFiles()
          watcher.onCopy = { copies.list.append($0) }

          // As the Finder copies two files: a file URL each, plus their names and an icon on the first.
          pasteboard.clearContents()
          let first = NSPasteboardItem()
          first.setString(a.absoluteString, forType: .fileURL)
          first.setString("Report.pdf\rNotes.txt", forType: .string)
          first.setData(sampleImageData(type: .tiff), forType: .tiff)
          let second = NSPasteboardItem()
          second.setString(b.absoluteString, forType: .fileURL)
          pasteboard.writeObjects([first, second])
          watcher.poll()
          expectEqual(copies.list.last?.files?.map(\.path), [a.path, b.path])
          expect(copies.list.last?.text == nil && copies.list.last?.image == nil)

          // A web link (as a browser copies one) is text, not a file.
          pasteboard.clearContents()
          let link = NSPasteboardItem()
          link.setString("https://example.com/a.pdf", forType: .URL)
          link.setString("https://example.com/a.pdf", forType: .string)
          pasteboard.writeObjects([link])
          watcher.poll()
          expect(copies.list.last?.files == nil)
          expectEqual(copies.list.last?.text, "https://example.com/a.pdf")
        }
      }
    ),
    (
      "files go back on the pasteboard as file URLs; moved or deleted ones are left out",
      {
        MainActor.assumeIsolated {
          let folder = temporaryFolder()
          defer { try? FileManager.default.removeItem(at: folder) }
          let kept = folder.appendingPathComponent("Kept.txt")
          FileManager.default.createFile(atPath: kept.path, contents: Data("x".utf8))
          let gone = folder.appendingPathComponent("Gone.txt").path
          let inMissingFolder = folder.appendingPathComponent("Nope/Gone.txt").path
          expectEqual(ClipboardFiles.existing([kept.path, gone, inMissingFolder]), [kept.path])
          expect(!ClipboardFiles.isMissing(folder.path), "a folder is there too")

          let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.test.\(UUID().uuidString)"))
          defer { pasteboard.releaseGlobally() }
          PasteboardWatcher.write(files: [kept, folder], to: pasteboard)
          expectEqual(PasteboardWatcher.fileURLs(on: pasteboard).map(\.path), [kept.path, folder.path])
          expect(pasteboard.types?.contains(.fileURL) == true)
        }
      }
    ),
  ])

private final class ImageCopiesForFiles: @unchecked Sendable {
  var list: [PasteboardWatcher.Copy] = []
}
