import AppKit
import CryptoKit
import ImageIO
import SlatedCore
import UniformTypeIdentifiers

/// Copied images on disk, one file each, named by the SHA-256 of their bytes: the same image copied
/// twice is one file. The folder is readable only by you (0700, files 0600): a screenshot can be as
/// private as any text.
public struct ClipboardImageStore: Sendable {
  public let directory: URL
  /// Bigger images aren't kept: a 5K screenshot as PNG is a few MB, an uncompressed TIFF of it 60.
  public let maxBytes: Int

  public static let defaultMaxBytes = 20 * 1024 * 1024

  public init(directory: URL, maxBytes: Int = Self.defaultMaxBytes) {
    self.directory = directory
    self.maxBytes = maxBytes
  }

  public enum SaveResult: Equatable, Sendable {
    case saved(ClipboardImage)
    /// Over `maxBytes`. The pixel size when the data says it (for the log).
    case tooLarge(bytes: Int, width: Int?, height: Int?)
    /// Not an image ImageIO can read, or the file couldn't be written.
    case failed(bytes: Int)
  }

  /// Writes the image, unless the same bytes are already there, and describes it for the history.
  public func save(_ image: PasteboardWatcher.CopiedImage) -> SaveResult {
    let data = image.data
    let size = Self.pixelSize(of: data)
    guard data.count <= maxBytes else {
      return .tooLarge(bytes: data.count, width: size?.width, height: size?.height)
    }
    guard let size, size.width > 0, size.height > 0 else { return .failed(bytes: data.count) }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let file = "\(hash).\(image.type == .png ? "png" : "tiff")"
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      return .failed(bytes: data.count)
    }
    let path = directory.appendingPathComponent(file).path
    if !fm.fileExists(atPath: path) {
      guard fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        return .failed(bytes: data.count)
      }
    }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return .saved(ClipboardImage(file: file, width: size.width, height: size.height, bytes: data.count))
  }

  /// Copies a screenshot saved as a file into the store, as a copied image, named after the file; the
  /// file itself is only read. PNG and TIFF keep their bytes; other formats ImageIO reads (JPEG, HEIC,
  /// GIF) are stored as PNG, the type every app pastes. Bigger than `maxBytes`: not read at all.
  public func saveScreenshot(at url: URL) -> SaveResult {
    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard bytes <= maxBytes else {
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
      let size = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
      return .tooLarge(
        bytes: bytes, width: (size?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        height: (size?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
    }
    guard let data = try? Data(contentsOf: url), let copied = Self.pasteable(data) else {
      return .failed(bytes: bytes)
    }
    let result = save(copied)
    guard case .saved(var image) = result else { return result }
    image.name = url.lastPathComponent
    return .saved(image)
  }

  /// The image as PNG or TIFF bytes; nil when ImageIO can't read it.
  static func pasteable(_ data: Data) -> PasteboardWatcher.CopiedImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source)
    else { return nil }
    switch type as String {
    case UTType.png.identifier: return .init(data: data, type: .png)
    case UTType.tiff.identifier: return .init(data: data, type: .tiff)
    default:
      let png = NSMutableData()
      guard CGImageSourceGetCount(source) > 0,
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImageFromSource(destination, source, 0, nil)
      return CGImageDestinationFinalize(destination) ? .init(data: png as Data, type: .png) : nil
    }
  }

  public func url(for image: ClipboardImage) -> URL { directory.appendingPathComponent(image.file) }

  /// The image as it goes back on the pasteboard; nil when its file is gone.
  public func load(_ image: ClipboardImage) -> PasteboardWatcher.CopiedImage? {
    guard let data = try? Data(contentsOf: url(for: image)) else { return nil }
    return PasteboardWatcher.CopiedImage(data: data, type: image.file.hasSuffix(".png") ? .png : .tiff)
  }

  /// Deletes these files (their items were deleted, pruned, pushed out or cleared).
  public func remove(_ files: some Sequence<String>) {
    for file in files where Self.isImageFile(file) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }
  }

  /// Deletes every image file the history doesn't refer to: left behind by a crash, or by an older
  /// history file. Returns how many went.
  @discardableResult
  public func removeFiles(except keep: Set<String>) -> Int {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let orphans = files.filter { Self.isImageFile($0) && !keep.contains($0) }
    remove(orphans)
    return orphans.count
  }

  /// Only names this store writes, so nothing else in the folder is ever deleted.
  static func isImageFile(_ name: String) -> Bool {
    !name.contains("/") && !name.hasPrefix(".") && (name.hasSuffix(".png") || name.hasSuffix(".tiff"))
  }

  /// Pixel size from the image's header, without decoding it.
  static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else { return nil }
    return (width, height)
  }
}
