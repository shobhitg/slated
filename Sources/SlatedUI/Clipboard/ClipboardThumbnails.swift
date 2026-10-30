import AppKit
import ImageIO
import QuickLookThumbnailing
import SlatedCore
import SwiftUI
import UniformTypeIdentifiers

/// Downsampled copies of clipboard images, and thumbnails of copied files, made off the main thread
/// and kept in memory: a row never decodes a whole screenshot, and the picker opens without waiting
/// for any of them.
@MainActor
final class ClipboardThumbnails {
  static let shared = ClipboardThumbnails()

  /// Pixel sizes: rows (28 pt tall, at 2×) and the preview beside the picker (240 pt).
  static let rowPixels = 128
  static let previewPixels = 512

  /// An image in the clipboard images folder (its file name) or a copied file (its path).
  private struct Key: Hashable {
    var source: String
    var maxPixels: Int

    static func image(_ image: ClipboardImage, _ maxPixels: Int) -> Key {
      Key(source: image.file, maxPixels: maxPixels)
    }
    /// Paths start with "/", which an image's file name never does.
    static func file(_ path: String, _ maxPixels: Int) -> Key { Key(source: path, maxPixels: maxPixels) }
  }

  private var images: [Key: NSImage] = [:]
  /// Oldest first, to forget the least recently made beyond the limits.
  private var order: [Key] = []
  private var loading: [Key: Task<NSImage?, Never>] = [:]

  func cached(_ image: ClipboardImage, maxPixels: Int) -> NSImage? { images[.image(image, maxPixels)] }

  func cached(file path: String, maxPixels: Int) -> NSImage? { images[.file(path, maxPixels)] }

  /// The image at `url` scaled to fit `maxPixels`, from memory or decoded in the background.
  func load(_ image: ClipboardImage, from url: URL, maxPixels: Int) async -> NSImage? {
    await load(.image(image, maxPixels)) {
      let decoded = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixels: maxPixels) }.value
      return decoded.map { NSImage(cgImage: $0.image, size: .zero) }
    }
  }

  /// A copied file's QuickLook thumbnail (a picture's or a document's first page, else its icon),
  /// fitting `maxPixels`; NSWorkspace's icon when QuickLook has none.
  func load(file path: String, maxPixels: Int) async -> NSImage? {
    await load(.file(path, maxPixels)) {
      let request = Self.request(path, maxPixels: maxPixels)
      let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
      return thumbnail?.nsImage ?? Self.icon(path)
    }
  }

  private func load(_ key: Key, make: @escaping @MainActor () async -> NSImage?) async -> NSImage? {
    if let hit = images[key] { return hit }
    let task = loading[key] ?? Task { await make() }
    loading[key] = task
    let result = await task.value
    loading[key] = nil
    if let result { remember(result, as: key) }
    return result
  }

  /// Decodes now, on this thread: snapshots render in a single pass.
  func preload(_ image: ClipboardImage, from url: URL, maxPixels: Int) {
    let key = Key.image(image, maxPixels)
    guard images[key] == nil, let decoded = Self.decode(url, maxPixels: maxPixels) else { return }
    remember(NSImage(cgImage: decoded.image, size: .zero), as: key)
  }

  /// Makes a file's thumbnail now, waiting for QuickLook (snapshots).
  func preload(file path: String, maxPixels: Int) {
    let key = Key.file(path, maxPixels)
    guard images[key] == nil else { return }
    let done = DispatchSemaphore(value: 0)
    let box = ImageBox()
    QLThumbnailGenerator.shared.generateBestRepresentation(for: Self.request(path, maxPixels: maxPixels)) {
      thumbnail, _ in
      box.cgImage = thumbnail?.cgImage
      done.signal()
    }
    _ = done.wait(timeout: .now() + 5)
    let image = box.cgImage.map { NSImage(cgImage: $0, size: .zero) } ?? Self.icon(path)
    remember(image, as: key)
  }

  /// QuickLook's answer, handed from its queue to the waiting main thread.
  nonisolated private final class ImageBox: @unchecked Sendable {
    var cgImage: CGImage?
  }

  private func remember(_ image: NSImage, as key: Key) {
    images[key] = image
    order.removeAll { $0 == key }
    order.append(key)
    // Row thumbnails are small (a history's worth is a few MB); previews are big, so only a few stay.
    let limit = key.maxPixels > Self.rowPixels ? 6 : 400
    let sameSize = order.filter { $0.maxPixels == key.maxPixels }
    for old in sameSize.dropLast(limit) {
      images[old] = nil
      order.removeAll { $0 == old }
    }
  }

  private struct Decoded: @unchecked Sendable {
    let image: CGImage
  }

  nonisolated private static func decode(_ url: URL, maxPixels: Int) -> Decoded? {
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
    let thumbnail: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary).map(Decoded.init)
  }

  nonisolated private static func request(_ path: String, maxPixels: Int) -> QLThumbnailGenerator.Request {
    let side = CGFloat(maxPixels) / 2
    return QLThumbnailGenerator.Request(
      fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side), scale: 2,
      representationTypes: .all)
  }

  /// The Finder's icon for the file, or for its kind when it's gone (a missing path would get a blank
  /// document).
  static func icon(_ path: String) -> NSImage {
    if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
    let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
    return NSWorkspace.shared.icon(for: path.hasSuffix("/") ? .folder : type)
  }
}

/// A clipboard image, aspect-fit and rounded, loaded lazily: a quiet placeholder until it's ready.
struct ClipThumbnail: View {
  let image: ClipboardImage
  let url: URL?
  var maxPixels = ClipboardThumbnails.rowPixels
  var cornerRadius: CGFloat = 4
  @State private var loaded: NSImage?

  var body: some View {
    let shown = loaded ?? ClipboardThumbnails.shared.cached(image, maxPixels: maxPixels)
    Group {
      if let shown {
        Image(nsImage: shown)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
      } else {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(Theme.well)
          .overlay(Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.tertiary))
          .aspectRatio(CGFloat(max(image.width, 1)) / CGFloat(max(image.height, 1)), contentMode: .fit)
      }
    }
    .task(id: image.file) {
      guard shown == nil, let url else { return }
      loaded = await ClipboardThumbnails.shared.load(image, from: url, maxPixels: maxPixels)
    }
    .accessibilityLabel(image.name ?? "Image, \(image.width) by \(image.height) pixels")
  }

  /// A row thumbnail's width at `height`: the image's shape, within reason (a panorama or a sliver
  /// still gets a sensible box).
  static func width(for image: ClipboardImage, height: CGFloat) -> CGFloat {
    let aspect = CGFloat(max(image.width, 1)) / CGFloat(max(image.height, 1))
    return min(max(height * aspect, height * 0.7), height * 1.8).rounded()
  }
}

/// A copied file's thumbnail, aspect-fit in its frame: QuickLook's (a picture, a document's first
/// page) or the file's icon. Its kind's icon while loading, and for a file that's gone.
struct ClipFileThumbnail: View {
  let path: String
  var maxPixels = ClipboardThumbnails.rowPixels
  /// Moved or deleted: the kind's icon, nothing to load.
  var missing = false
  @State private var loaded: NSImage?

  var body: some View {
    let shown =
      missing
      ? ClipboardThumbnails.icon(path)
      : loaded ?? ClipboardThumbnails.shared.cached(file: path, maxPixels: maxPixels)
    Group {
      if let shown {
        Image(nsImage: shown)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        Image(nsImage: ClipboardThumbnails.icon(path)).resizable().aspectRatio(contentMode: .fit).opacity(0.5)
      }
    }
    .task(id: path) {
      guard !missing, shown == nil else { return }
      loaded = await ClipboardThumbnails.shared.load(file: path, maxPixels: maxPixels)
    }
    .accessibilityHidden(true)
  }
}
