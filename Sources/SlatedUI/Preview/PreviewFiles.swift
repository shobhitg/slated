import CoreGraphics
import Foundation

/// Sample copied files for previews, snapshots and tests: written (not shipped) into a temporary
/// folder the first time they're asked for, so QuickLook has real files to thumbnail. `missing` is
/// never written: it stands for a file moved or deleted since it was copied.
enum PreviewFiles {
  private static let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SlatedPreviewFiles", isDirectory: true)

  /// A one-page report with a heading, text lines and a bar chart.
  static var report: String { path("Quarterly Report.pdf") }
  static var notes: String { path("Offsite notes.txt") }
  /// The sample photo, as a file.
  static var photo: String { path("Team Photo.png") }
  static var missing: String { directory.appendingPathComponent("Old Draft.pages").path }

  private static func path(_ name: String) -> String {
    let url = directory.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // Written to a temporary name and moved, so a parallel run never reads half a file.
      let partial = directory.appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
      if write(name, to: partial), (try? FileManager.default.moveItem(at: partial, to: url)) == nil {
        try? FileManager.default.removeItem(at: partial)
      }
    }
    return url.path
  }

  private static func write(_ name: String, to url: URL) -> Bool {
    switch (name as NSString).pathExtension {
    case "pdf": return writeReport(to: url)
    case "png":
      guard let photo = PreviewImages.url(for: PreviewImages.photo) else { return false }
      return (try? FileManager.default.copyItem(at: photo, to: url)) != nil
    default:
      let text = "Offsite notes\n\n- Agenda: roadmap, hiring, the Slated launch\n- Book the room by Friday\n"
      return FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
    }
  }

  /// A US Letter page: a colored heading bar, gray lines of "text" and a small bar chart.
  private static func writeReport(to url: URL) -> Bool {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let c = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
    c.beginPDFPage(nil)
    c.setFillColor(red: 0.42, green: 0.37, blue: 0.99, alpha: 1)
    c.fill(CGRect(x: 54, y: 680, width: 320, height: 40))
    for line in 0..<8 {
      c.setFillColor(red: 0.75, green: 0.75, blue: 0.8, alpha: 1)
      c.fill(CGRect(x: 54, y: 630 - CGFloat(line) * 22, width: line % 3 == 2 ? 300 : 504, height: 9))
    }
    let bars: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
      (120, (0.16, 0.62, 0.95)), (180, (0.42, 0.37, 0.99)), (150, (0.98, 0.55, 0.36)), (230, (0.19, 0.72, 0.35)),
    ]
    for (index, bar) in bars.enumerated() {
      c.setFillColor(red: bar.1.0, green: bar.1.1, blue: bar.1.2, alpha: 1)
      c.fill(CGRect(x: 90 + CGFloat(index) * 120, y: 120, width: 70, height: bar.0))
    }
    c.endPDFPage()
    c.closePDF()
    return true
  }
}
