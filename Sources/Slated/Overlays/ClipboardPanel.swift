import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI
import SwiftUI

/// Hosts the clipboard picker in a small floating panel just below where you're typing (the caret,
/// the focused field, or the pointer), and a larger preview of a selected image beside it.
final class ClipboardPanel: NSObject, NSWindowDelegate {
  private let model: ClipboardPickerModel
  private var panel: NSPanel?
  private var preview: NSPanel?
  /// Called whenever the panel closes (picked, escaped or clicked away), with whether a click into
  /// one of Slated's own windows closed it.
  var didClose: ((_ intoSlatedWindow: Bool) -> Void)?

  init(services: any AppServices) {
    model = ClipboardPickerModel(services: services)
    super.init()
    model.onClose = { [weak self] in self?.close() }
    model.onPreviewChange = { [weak self] in self?.placePreview() }
  }

  /// Opens the picker below `anchor` (above it when there's no room), on that anchor's screen.
  /// `anchor` is in top-left-origin global coordinates; an empty rect for the pointer.
  func show(at anchor: CGRect) {
    model.resetForShowing(pointer: NSEvent.mouseLocation)
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let size = model.size
    let frame =
      PopupPlacement.screen(for: anchor, in: Screens.current())
      .map { PopupPlacement.below(anchor, size: size, in: $0.visibleFrame) }
      ?? CGRect(origin: anchor.origin, size: size)
    panel.setFrame(Screens.appKitRect(fromTopLeft: frame), display: true)
    // Key without activating Slated: activating from a hotkey can be refused while you're typing in
    // another app, which left the picker without the keyboard and its first click.
    panel.orderFrontRegardless()
    panel.makeKey()
    placePreview()
  }

  func refresh() {
    if panel?.isVisible == true { model.reload() }
  }

  func close() { close(intoSlatedWindow: false) }

  private func close(intoSlatedWindow: Bool) {
    guard panel?.isVisible == true else { return }
    preview?.orderOut(nil)
    panel?.orderOut(nil)
    didClose?(intoSlatedWindow)
  }

  /// Clicking anywhere else closes the picker, like a menu. A click into Slated's own window makes
  /// that window key by now.
  func windowDidResignKey(_ notification: Notification) {
    let key = NSApp.keyWindow
    close(intoSlatedWindow: key != nil && key !== panel)
  }

  /// Shows the selected image larger beside the picker, level with its row (with the picker's top
  /// until the row is laid out), or hides the preview when the selection isn't an image.
  private func placePreview() {
    guard let panel, panel.isVisible, let size = SlatedUI.clipboardImagePreviewSize(model: model) else {
      preview?.orderOut(nil)
      return
    }
    let preview = self.preview ?? makePreview()
    self.preview = preview
    let picker = Screens.topLeftRect(fromAppKit: panel.frame)
    let row = model.previewRowFrame?.offsetBy(dx: picker.minX, dy: picker.minY) ?? picker
    let visible = PopupPlacement.screen(for: picker, in: Screens.current())?.visibleFrame ?? picker
    let frame = PopupPlacement.beside(picker, alignedWith: row, size: size, in: visible)
    preview.setFrame(Screens.appKitRect(fromTopLeft: frame), display: true)
    preview.orderFront(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = SlatedUI.makeClipboardPickerPanel(model: model)
    configure(panel)
    panel.delegate = self
    return panel
  }

  /// A panel that never takes focus or clicks: the picker keeps the keyboard and the mouse.
  private func makePreview() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = NSHostingView(rootView: SlatedUI.makeClipboardImagePreview(model: model))
    configure(panel)
    panel.ignoresMouseEvents = true
    return panel
  }

  private func configure(_ panel: NSPanel) {
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
  }
}
