import AppKit
import SlatedUI
import SwiftUI

/// Hosts the clipboard switcher in a floating panel centered on the screen with the pointer.
final class ClipboardPanel: NSObject, NSWindowDelegate {
  private let model: ClipboardSwitcherModel
  private var panel: NSPanel?
  /// Called whenever the panel closes (picked, escaped or clicked away).
  var didClose: (() -> Void)?

  init(services: any AppServices) {
    model = ClipboardSwitcherModel(services: services)
    super.init()
    model.onClose = { [weak self] in self?.close() }
  }

  func show() {
    model.resetForShowing()
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    if let visible = screen?.visibleFrame {
      let size = panel.frame.size
      panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1))
    }
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }

  func refresh() {
    if panel?.isVisible == true { model.reload() }
  }

  func close() {
    guard panel?.isVisible == true else { return }
    panel?.orderOut(nil)
    didClose?()
  }

  /// Clicking anywhere else closes the switcher, like Spotlight.
  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  private func makePanel() -> NSPanel {
    let host = NSHostingView(rootView: SlatedUI.makeClipboardSwitcherView(model: model))
    host.frame.size = host.fittingSize
    let panel = SwitcherPanel(
      contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.contentView = host
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    return panel
  }
}

/// Borderless panels can't become key by default; the switcher needs the keyboard.
private final class SwitcherPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}
