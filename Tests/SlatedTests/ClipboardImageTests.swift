import AppKit
import Foundation
import ImageIO
import SlatedCore
import UniformTypeIdentifiers

@testable import SlatedSystem

// Copied images: what the watcher reports, how they're stored (private files named by content hash),
// cleaned up, and put back on a pasteboard. Only private pasteboards and temporary folders are used.

/// A small PNG (or TIFF) of `width`×`height` pixels, filled with one color so bytes differ by color.
func sampleImageData(width: Int = 40, height: Int = 30, red: CGFloat = 0.4, type: UTType = .png) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(red: red, green: 0.3, blue: 0.9, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

private func temporaryStore(maxBytes: Int = ClipboardImageStore.defaultMaxBytes) -> ClipboardImageStore {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("slated-images-\(UUID().uuidString)/clipboard-images", isDirectory: true)
  return ClipboardImageStore(directory: directory, maxBytes: maxBytes)
}

private func permissions(_ url: URL) -> Int? {
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

private final class ImageCopies: @unchecked Sendable {
  var list: [PasteboardWatcher.Copy] = []
}

let clipboardImageTests = Suite(
  "ClipboardImages",
  [
    (
      "an image copied without text is reported with its bytes; a copy with text is text",
      {
        MainActor.assumeIsolated {
          let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.test.\(UUID().uuidString)"))
          defer { pasteboard.releaseGlobally() }
          let watcher = PasteboardWatcher(pasteboard: pasteboard)
          let copies = ImageCopies()
          watcher.onCopy = { copies.list.append($0) }
          let png = sampleImageData()
          pasteboard.clearContents()
          pasteboard.setData(png, forType: .png)
          watcher.poll()
          expectEqual(copies.list.last?.image, PasteboardWatcher.CopiedImage(data: png, type: .png))
          expect(copies.list.last?.text == nil)

          let tiff = sampleImageData(type: .tiff)
          pasteboard.clearContents()
          pasteboard.setData(tiff, forType: .tiff)
          watcher.poll()
          expectEqual(copies.list.last?.image?.type, .tiff)

          // Cells from a spreadsheet: text plus a picture of them. History keeps the text.
          pasteboard.clearContents()
          pasteboard.setString("A1\tB1", forType: .string)
          pasteboard.setData(png, forType: .png)
          watcher.poll()
          expectEqual(copies.list.last?.text, "A1\tB1")
          expect(copies.list.last?.image == nil)
          expectEqual(copies.list.count, 3)
        }
      }
    ),
    (
      "an image is stored once, privately, under its content hash, with its pixel size",
      {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        let png = sampleImageData(width: 40, height: 30)
        guard case .saved(let image) = store.save(.init(data: png, type: .png)) else {
          return expect(false, "not saved")
        }
        expectEqual(image.width, 40)
        expectEqual(image.height, 30)
        expectEqual(image.bytes, png.count)
        expect(image.file.hasSuffix(".png"))
        expectEqual(image.file.count, 64 + 4)  // SHA-256 in hex
        expectEqual(permissions(store.url(for: image)), 0o600)
        expectEqual(permissions(store.directory), 0o700)
        expectEqual(store.save(.init(data: png, type: .png)), .saved(image))  // the same bytes: the same file
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1)

        guard case .saved(let tiff) = store.save(.init(data: sampleImageData(type: .tiff), type: .tiff)) else {
          return expect(false, "TIFF not saved")
        }
        expect(tiff.file.hasSuffix(".tiff"))
        expectEqual(store.load(tiff)?.type, .tiff)
        expectEqual(store.load(image), PasteboardWatcher.CopiedImage(data: png, type: .png))
      }
    ),
    (
      "too large or unreadable images aren't stored",
      {
        let png = sampleImageData(width: 64, height: 48)
        let small = temporaryStore(maxBytes: png.count - 1)
        defer { try? FileManager.default.removeItem(at: small.directory.deletingLastPathComponent()) }
        expectEqual(small.save(.init(data: png, type: .png)), .tooLarge(bytes: png.count, width: 64, height: 48))
        expectEqual(small.save(.init(data: Data("not an image".utf8), type: .png)), .failed(bytes: 12))
        expect(!FileManager.default.fileExists(atPath: small.directory.path))
      }
    ),
    (
      "files the history no longer names are deleted, and nothing else in the folder",
      {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
        var history = ClipboardHistory()
        var files: [String] = []
        for red in [0.1, 0.5, 0.9] {
          guard case .saved(let image) = store.save(.init(data: sampleImageData(red: red), type: .png)) else {
            return expect(false, "not saved")
          }
          history.add(image: image, at: Date(), limit: 10)
          files.append(image.file)
        }
        let other = store.directory.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: other)
        history.remove(id: try require(history.items.first { $0.image?.file == files[1] }).id)
        expectEqual(store.removeFiles(except: history.imageFiles), 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path))
        expectEqual(left, [files[0], files[2], "notes.txt"])
        store.remove([files[0], "../escape.png", "notes.txt"])
        expectEqual(
          Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path)), [files[2], "notes.txt"])
      }
    ),
    (
      "picking an image puts its bytes back on the pasteboard, readable as an image",
      {
        try MainActor.assumeIsolated {
          let store = temporaryStore()
          defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
          let png = sampleImageData(width: 20, height: 10)
          guard case .saved(let image) = store.save(.init(data: png, type: .png)) else {
            return expect(false, "not saved")
          }
          let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.test.\(UUID().uuidString)"))
          defer { pasteboard.releaseGlobally() }
          pasteboard.setString("older text", forType: .string)
          PasteboardWatcher.write(try require(store.load(image)), to: pasteboard)
          expectEqual(pasteboard.data(forType: .png), png)
          expect(pasteboard.string(forType: .string) == nil, "the old text is gone")
          expectEqual(NSImage(pasteboard: pasteboard)?.representations.first?.pixelsWide, 20)
          try FileManager.default.removeItem(at: store.url(for: image))
          expect(store.load(image) == nil, "a missing file can't be pasted")
        }
      }
    ),
  ])
