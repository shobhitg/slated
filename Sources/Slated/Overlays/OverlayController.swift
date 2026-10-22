import AppKit
import SlatedCore
import SlatedSystem
import SwiftUI

/// Slate's two interactive overlays:
/// - **Window hints**: a letter on every visible window; press it to focus that window.
/// - **Grid**: a miniature grid of each screen; drag across cells to place the focused window.
///
/// Escape (or clicking elsewhere) dismisses either.
final class OverlayController: OverlayPresenting {
  /// Moves a window (with undo) — provided by the action runner.
  var place: ((AXWindow, CGRect) -> Void)?

  private var panels: [NSPanel] = []
  private var keyMonitor: Any?
  private var clickMonitor: Any?
  private var hintTargets: [String: AXWindow] = [:]
  private var previousApp: NSRunningApplication?

  // MARK: Hints

  func showHints(characters: String) {
    dismiss()
    previousApp = NSWorkspace.shared.frontmostApplication
    let letters = characters.uppercased().map(String.init)
    let windows = Accessibility.allWindows().filter { $0.frame != nil }
    for (letter, window) in zip(letters, windows) {
      guard let frame = window.frame else { continue }
      hintTargets[letter.lowercased()] = window
      let size = CGSize(width: 96, height: 96)
      let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
      let icon = window.app?.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
      let panel = makePanel(topLeftFrame: CGRect(origin: origin, size: size))
      panel.contentView = NSHostingView(rootView: HintBubble(letter: letter, icon: icon))
      panels.append(panel)
    }
    guard !panels.isEmpty else { return }
    present { [weak self] event in
      guard let self else { return }
      let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
      if let window = self.hintTargets[key] {
        self.dismiss(restoreFocus: false)
        window.focus()
      } else {
        self.dismiss()
      }
    }
  }

  // MARK: Grid

  func showGrid(padding: Int, grids: [GridScreen], window: AXWindow?) {
    dismiss()
    guard let window, let windowFrame = window.frame else { return }
    previousApp = NSWorkspace.shared.frontmostApplication
    let screens = Screens.current()
    let ordered = screens.orderedLeftToRight()
    for screen in screens {
      let index = ordered.firstIndex(of: screen) ?? 0
      let config = grids.first { $0.screen == String(index) || $0.screen == screen.resolution }
      let columns = max(config?.width ?? 12, 1)
      let rows = max(config?.height ?? 12, 1)
      // A miniature of the screen, centered on it, like Slate's grid.
      let visible = screen.visibleFrame
      let scale = min(560 / visible.width, 420 / visible.height, 0.4)
      let size = CGSize(width: visible.width * scale + 32, height: visible.height * scale + 56)
      let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
      let panel = makePanel(topLeftFrame: frame)
      let view = GridView(
        screen: screen, columns: columns, rows: rows, padding: CGFloat(padding), windowFrame: windowFrame,
        title: "\(window.app?.localizedName ?? "Window") — \(columns)×\(rows)")
      view.onSelect = { [weak self] target in
        self?.dismiss(restoreFocus: false)
        self?.place?(window, target)
        window.focus()
      }
      panel.contentView = Self.wrapInMaterial(view)
      panels.append(panel)
    }
    present { [weak self] _ in self?.dismiss() }
  }

  // MARK: Plumbing

  private func present(onKey: @escaping (NSEvent) -> Void) {
    NSApp.activate()
    for panel in panels {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.12
        panel.animator().alphaValue = 1
      }
    }
    panels.first?.makeKey()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      onKey(event)
      return nil
    }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
  }

  func dismiss(restoreFocus: Bool = true) {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    keyMonitor = nil
    clickMonitor = nil
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
    hintTargets.removeAll()
    if restoreFocus { previousApp?.activate() }
    previousApp = nil
  }

  private func makePanel(topLeftFrame: CGRect) -> NSPanel {
    let panel = OverlayPanel(
      contentRect: Screens.appKitRect(fromTopLeft: topLeftFrame), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isReleasedWhenClosed = false
    return panel
  }

  private static func wrapInMaterial(_ content: NSView) -> NSView {
    let effect = NSVisualEffectView()
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 18
    effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      content.topAnchor.constraint(equalTo: effect.topAnchor),
      content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    return effect
  }
}

/// Borderless panels can't become key by default; overlays need keyboard input.
private final class OverlayPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

// MARK: - Hint bubble

private struct HintBubble: View {
  let letter: String
  let icon: NSImage

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
              LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
              lineWidth: 2))
      Text(letter)
        .font(.system(size: 44, weight: .bold, design: .rounded))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Image(nsImage: icon)
        .resizable()
        .frame(width: 26, height: 26)
        .padding(8)
    }
    .frame(width: 96, height: 96)
  }
}

// MARK: - Grid view

/// Draws the cell grid and handles drag selection. Coordinates inside are flipped (top-left).
private final class GridView: NSView {
  var onSelect: ((CGRect) -> Void)?

  private let screen: ScreenInfo
  private let columns: Int
  private let rows: Int
  private let padding: CGFloat
  private let windowFrame: CGRect
  private let title: String
  private var anchor: (col: Int, row: Int)?
  private var current: (col: Int, row: Int)?

  init(screen: ScreenInfo, columns: Int, rows: Int, padding: CGFloat, windowFrame: CGRect, title: String) {
    self.screen = screen
    self.columns = columns
    self.rows = rows
    self.padding = padding
    self.windowFrame = windowFrame
    self.title = title
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var isFlipped: Bool { true }

  private var area: CGRect {
    CGRect(x: 16, y: 40, width: bounds.width - 32, height: bounds.height - 56)
  }

  private func cellRect(col: Int, row: Int) -> CGRect {
    let w = area.width / CGFloat(columns)
    let h = area.height / CGFloat(rows)
    return CGRect(x: area.minX + CGFloat(col) * w, y: area.minY + CGFloat(row) * h, width: w, height: h)
      .insetBy(dx: padding / 2, dy: padding / 2)
  }

  private func cell(at point: CGPoint) -> (col: Int, row: Int) {
    let col = Int((point.x - area.minX) / (area.width / CGFloat(columns)))
    let row = Int((point.y - area.minY) / (area.height / CGFloat(rows)))
    return (min(max(col, 0), columns - 1), min(max(row, 0), rows - 1))
  }

  /// Selected cell range → frame on the real screen (top-left coordinates).
  private func targetFrame(_ a: (col: Int, row: Int), _ b: (col: Int, row: Int)) -> CGRect {
    let visible = screen.visibleFrame
    let cw = visible.width / CGFloat(columns)
    let ch = visible.height / CGFloat(rows)
    let c0 = min(a.col, b.col)
    let c1 = max(a.col, b.col)
    let r0 = min(a.row, b.row)
    let r1 = max(a.row, b.row)
    return CGRect(
      x: visible.minX + CGFloat(c0) * cw, y: visible.minY + CGFloat(r0) * ch,
      width: CGFloat(c1 - c0 + 1) * cw, height: CGFloat(r1 - r0 + 1) * ch
    ).integral
  }

  override func draw(_ dirtyRect: NSRect) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
    ]
    NSString(string: title).draw(at: CGPoint(x: 18, y: 14), withAttributes: attributes)

    let selection = anchor.flatMap { a in current.map { (a, $0) } }
    let visible = screen.visibleFrame
    for row in 0..<rows {
      for col in 0..<columns {
        let rect = cellRect(col: col, row: row)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let selected =
          selection.map { s in
            (min(s.0.col, s.1.col)...max(s.0.col, s.1.col)).contains(col)
              && (min(s.0.row, s.1.row)...max(s.0.row, s.1.row)).contains(row)
          } ?? false
        if selected {
          NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        } else {
          NSColor.labelColor.withAlphaComponent(0.08).setFill()
        }
        path.fill()
      }
    }
    // Where the window is now, as an outline.
    if visible.intersects(windowFrame) {
      let sx = area.width / visible.width
      let sy = area.height / visible.height
      let r = CGRect(
        x: area.minX + (windowFrame.minX - visible.minX) * sx, y: area.minY + (windowFrame.minY - visible.minY) * sy,
        width: windowFrame.width * sx, height: windowFrame.height * sy
      ).intersection(area)
      let outline = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
      outline.lineWidth = 2
      NSColor.controlAccentColor.setStroke()
      outline.stroke()
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    anchor = cell(at: point)
    current = anchor
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    current = cell(at: convert(event.locationInWindow, from: nil))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let anchor else { return }
    let end = cell(at: convert(event.locationInWindow, from: nil))
    onSelect?(targetFrame(anchor, end))
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
