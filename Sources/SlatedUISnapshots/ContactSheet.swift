import AppKit

/// Lays rendered snapshots out on one labeled page, for reviewing a whole run at a glance.
enum ContactSheet {
  static func write(_ images: [(name: String, image: NSBitmapImageRep)], columns: Int, cellWidth: CGFloat, to url: URL)
    throws
  {
    guard !images.isEmpty else { return }
    let padding: CGFloat = 16
    let label: CGFloat = 22
    // Large shots shrink to the cell; small ones (the menu bar) keep their real size.
    let widths = images.map { min(cellWidth, $0.image.size.width) }
    let heights = zip(images, widths).map { $1 * $0.image.size.height / $0.image.size.width }
    let rows = (images.count + columns - 1) / columns
    let rowHeights = (0..<rows).map { row in
      heights[(row * columns)..<min((row + 1) * columns, heights.count)].max() ?? 0
    }
    let size = CGSize(
      width: CGFloat(columns) * (cellWidth + padding) + padding,
      height: rowHeights.reduce(0) { $0 + $1 + label + padding } + padding)
    let sheet = Renderer.bitmap(size: size, scale: 1)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.42, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    var top = padding  // measured from the top; AppKit draws from the bottom
    for row in 0..<rows {
      for column in 0..<columns {
        let index = row * columns + column
        guard index < images.count else { break }
        let x = padding + CGFloat(column) * (cellWidth + padding)
        (images[index].name as NSString).draw(
          at: NSPoint(x: x, y: size.height - top - 16),
          withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        let rect = NSRect(
          x: x, y: size.height - top - label - heights[index], width: widths[index], height: heights[index])
        images[index].image.draw(
          in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      top += rowHeights[row] + label + padding
    }
    NSGraphicsContext.restoreGraphicsState()
    try Renderer.writePNG(sheet, to: url)
  }
}
