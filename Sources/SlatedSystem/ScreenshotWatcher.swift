import Darwin
import Foundation

/// Screenshots macOS saves as files: where they go and how to tell one. Every screenshot file carries
/// the `com.apple.metadata:kMDItemIsScreenCapture` extended attribute (Spotlight's
/// kMDItemIsScreenCapture), whatever its name, format or language.
public enum Screenshots {
  public static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
  /// The Screenshot app's preferences (`defaults read com.apple.screencapture`).
  public static let preferencesDomain = "com.apple.screencapture"

  /// The folder for screencapture's `location` preference, `~` expanded (a relative path is taken
  /// from home); ~/Desktop when it's unset or empty, as macOS does.
  public static func folder(location: String?, home: String) -> URL {
    let home = URL(fileURLWithPath: home, isDirectory: true)
    let location = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if location.isEmpty { return home.appendingPathComponent("Desktop", isDirectory: true) }
    if location == "~" { return home }
    if location.hasPrefix("~/") {
      return home.appendingPathComponent(String(location.dropFirst(2)), isDirectory: true).standardizedFileURL
    }
    if !location.hasPrefix("/") { return home.appendingPathComponent(location, isDirectory: true).standardizedFileURL }
    return URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
  }

  /// Where macOS saves screenshots now. Read afresh each time: Options → Save to in the Screenshot app
  /// changes it.
  public static func currentFolder(home: String = NSHomeDirectory()) -> URL {
    folder(location: UserDefaults(suiteName: preferencesDomain)?.string(forKey: "location"), home: home)
  }

  /// Whether the file carries the screenshot attribute. Only the attribute is read, not the file.
  public static func isScreenshot(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      return getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
  }
}

/// Why a screenshot folder can't be watched.
public enum ScreenshotFolderError: Error, Equatable, Sendable {
  /// macOS didn't allow Slated to see the folder (Privacy & Security → Files and Folders).
  case accessDenied
  case folderMissing
  case other(Int32)

  init(errno code: Int32) {
    switch code {
    case EPERM, EACCES: self = .accessDenied
    case ENOENT, ENOTDIR: self = .folderMissing
    default: self = .other(code)
    }
  }
}

/// Finds new screenshots in a folder: files created since `since` that carry the screenshot attribute,
/// each reported once, when complete. File-system logic only, driven by `ScreenshotWatcher`; tests call
/// `scan()` directly.
///
/// Complete means its name is final and its size held between two scans. screencapture may write a
/// hidden temporary file and rename it, and hidden files are skipped, so only the final name counts.
public struct ScreenshotScanner: Sendable {
  public let folder: URL
  public let since: Date
  /// Screenshots already reported, by inode: one renamed afterwards (in the Finder) isn't new.
  private var reported: Set<UInt64> = []
  /// Screenshots seen with this size by the last scan, by inode.
  private var growing: [UInt64: Int64] = [:]

  public init(folder: URL, since: Date) {
    self.folder = folder
    self.since = since
  }

  /// A screenshot was seen that isn't complete yet: scan again shortly.
  public var isWaiting: Bool { !growing.isEmpty }

  /// Lists the folder and returns the screenshots completed since the last scan, oldest first.
  public mutating func scan() throws(ScreenshotFolderError) -> [URL] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch {
      let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
      if let underlying, underlying.domain == NSPOSIXErrorDomain {
        throw ScreenshotFolderError(errno: Int32(underlying.code))
      }
      switch (error as NSError).code {
      case NSFileReadNoPermissionError: throw .accessDenied
      case NSFileReadNoSuchFileError, NSFileNoSuchFileError: throw .folderMissing
      default: throw .other(Int32((error as NSError).code))
      }
    }
    let start = since.timeIntervalSince1970
    var ready: [(url: URL, born: Double)] = []
    var stillGrowing: [UInt64: Int64] = [:]
    for name in names where !name.hasPrefix(".") {
      let url = folder.appendingPathComponent(name, isDirectory: false)
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
      let inode = UInt64(info.st_ino)
      let born = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
      guard !reported.contains(inode), born >= start, Screenshots.isScreenshot(url) else { continue }
      let size = Int64(info.st_size)
      if size > 0, growing[inode] == size {
        reported.insert(inode)
        ready.append((url, born))
      } else {
        stillGrowing[inode] = size
      }
    }
    growing = stillGrowing
    return ready.sorted { $0.born < $1.born }.map(\.url)
  }
}

/// Watches the screenshot folder and reports each new screenshot saved there, once complete. Reads
/// the folder only between `start()` and `stop()`: with the setting off it's never touched.
///
/// The folder is listed off the main thread: the first look at ~/Desktop makes macOS ask whether
/// Slated may see it, and the call waits for the answer. The location is re-read every few seconds, and
/// a folder that's missing or not allowed is tried again then, so granting access later just works.
public final class ScreenshotWatcher: @unchecked Sendable {
  public enum Status: Equatable, Sendable {
    case off
    case watching(URL)
    case accessDenied(URL)
    case folderMissing(URL)
  }

  public enum Event: Sendable {
    case screenshot(URL)
    case status(Status)
  }

  /// How long a folder change waits before a scan (screencapture writes, then renames), and between
  /// scans while a screenshot is still being written.
  static let settleDelay: DispatchTimeInterval = .milliseconds(300)
  static let locationInterval: DispatchTimeInterval = .seconds(5)

  private let folderProvider: @Sendable () -> URL
  private let deliver: @Sendable (Event) -> Void
  private let queue = DispatchQueue(label: "io.github.slated.screenshots", qos: .utility)

  // Only touched on `queue`.
  private var running = false
  private var status = Status.off
  private var scanner: ScreenshotScanner?
  private var source: DispatchSourceFileSystemObject?
  private var locationTimer: DispatchSourceTimer?
  private var scanScheduled = false
  private var since = Date()

  /// `folder` says where screenshots go (`Screenshots.currentFolder()`); `onEvent` runs on the main
  /// queue.
  public init(folder: @escaping @Sendable () -> URL, onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
    folderProvider = folder
    deliver = { event in DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } } }
  }

  deinit {
    source?.cancel()
    locationTimer?.cancel()
  }

  /// Starts watching; screenshots saved from now on are reported.
  public func start() {
    queue.async { [self] in
      guard !running else { return }
      running = true
      since = Date()
      watch(folderProvider())
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + Self.locationInterval, repeating: Self.locationInterval)
      timer.setEventHandler { [weak self] in self?.recheck() }
      timer.resume()
      locationTimer = timer
    }
  }

  /// Stops watching and closes the folder.
  public func stop() {
    queue.async { [self] in
      guard running else { return }
      running = false
      locationTimer?.cancel()
      locationTimer = nil
      closeFolder()
      set(.off)
    }
  }

  /// Waits for work already queued (tests).
  func sync() { queue.sync {} }

  // MARK: On the queue

  private func set(_ new: Status) {
    guard new != status else { return }
    status = new
    deliver(.status(new))
  }

  /// The location moved, or the folder couldn't be watched: try (again).
  private func recheck() {
    guard running else { return }
    let folder = folderProvider()
    if case .watching(let current) = status, current == folder { return }
    watch(folder)
  }

  private func watch(_ folder: URL) {
    closeFolder()
    let fd = open(folder.path, O_EVTONLY)
    guard fd >= 0 else {
      set(Self.status(for: ScreenshotFolderError(errno: errno), folder))
      return
    }
    // Opened before the first listing, so nothing saved in between goes unnoticed. The listing is
    // where macOS asks for access to a protected folder.
    var scanner = ScreenshotScanner(folder: folder, since: since)
    do {
      _ = try scanner.scan()
    } catch {
      close(fd)
      set(Self.status(for: error, folder))
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      if source.data.contains(.delete) || source.data.contains(.rename) {
        // The folder itself went or moved: look for it again.
        closeFolder()
        set(.folderMissing(folder))
        recheck()
      } else {
        scheduleScan()
      }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.source = source
    self.scanner = scanner
    set(.watching(folder))
    if scanner.isWaiting { scheduleScan() }
  }

  private func closeFolder() {
    source?.cancel()
    source = nil
    scanner = nil
    scanScheduled = false
  }

  private func scheduleScan() {
    guard !scanScheduled else { return }
    scanScheduled = true
    queue.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in self?.scan() }
  }

  private func scan() {
    scanScheduled = false
    guard running, var scanner else { return }
    do {
      let found = try scanner.scan()
      self.scanner = scanner
      for url in found { deliver(.screenshot(url)) }
      if scanner.isWaiting { scheduleScan() }
    } catch {
      closeFolder()
      set(Self.status(for: error, scanner.folder))
    }
  }

  private static func status(for error: ScreenshotFolderError, _ folder: URL) -> Status {
    error == .accessDenied ? .accessDenied(folder) : .folderMissing(folder)
  }
}
