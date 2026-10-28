import AppKit
import ImageIO
import SlatedCore
import SwiftUI

/// Downsampled copies of clipboard images, made off the main thread and kept in memory: a row never
/// decodes a whole screenshot, and the picker opens without waiting for any of them.
@MainActor
final class ClipboardThumbnails {
  static let shared = ClipboardThumbnails()

  /// Pixel sizes: rows (28 pt tall, at 2×) and the preview beside the picker (240 pt).
  static let rowPixels = 128
  static let previewPixels = 512

  private struct Key: Hashable {
    var file: String
    var maxPixels: Int
  }

  private var images: [Key: NSImage] = [:]
  /// Oldest first, to forget the least recently made beyond the limits.
  private var order: [Key] = []
  private var loading: [Key: Task<NSImage?, Never>] = [:]

  func cached(_ image: ClipboardImage, maxPixels: Int) -> NSImage? {
    images[Key(file: image.file, maxPixels: maxPixels)]
  }

  /// The image at `url` scaled to fit `maxPixels`, from memory or decoded in the background.
  func load(_ image: ClipboardImage, from url: URL, maxPixels: Int) async -> NSImage? {
    let key = Key(file: image.file, maxPixels: maxPixels)
    if let hit = images[key] { return hit }
    let task =
      loading[key]
      ?? Task {
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixels: maxPixels) }.value
        return decoded.map { NSImage(cgImage: $0.image, size: .zero) }
      }
    loading[key] = task
    let result = await task.value
    loading[key] = nil
    if let result { remember(result, as: key) }
    return result
  }

  /// Decodes now, on this thread: snapshots render in a single pass.
  func preload(_ image: ClipboardImage, from url: URL, maxPixels: Int) {
    let key = Key(file: image.file, maxPixels: maxPixels)
    guard images[key] == nil, let decoded = Self.decode(url, maxPixels: maxPixels) else { return }
    remember(NSImage(cgImage: decoded.image, size: .zero), as: key)
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
    .accessibilityLabel("Image, \(image.width) by \(image.height) pixels")
  }

  /// A row thumbnail's width at `height`: the image's shape, within reason (a panorama or a sliver
  /// still gets a sensible box).
  static func width(for image: ClipboardImage, height: CGFloat) -> CGFloat {
    let aspect = CGFloat(max(image.width, 1)) / CGFloat(max(image.height, 1))
    return min(max(height * aspect, height * 0.7), height * 1.8).rounded()
  }
}
