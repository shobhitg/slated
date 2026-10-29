import AppKit
import SwiftUI

/// The clipboard picker's panel. It takes the keyboard without activating Slated, the way Spotlight
/// does, so the app you were typing in stays active and the paste lands there.
///
/// Keys and clicks are handled here, in AppKit, before SwiftUI sees them: a focused text field keeps
/// Return and the arrows from SwiftUI's key handlers, and a list in a window of an inactive app treats
/// the first click as activation and drops it. Both left the picker ignoring Return and clicks.
final class ClipboardPickerPanel: NSPanel {
  private let model: ClipboardPickerModel
  /// The row a click went down on: the click pastes it if it comes up on the same row.
  private var pressedRow: UUID?

  init(model: ClipboardPickerModel) {
    self.model = model
    super.init(
      contentRect: NSRect(origin: .zero, size: model.size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    becomesKeyOnlyIfNeeded = false
    acceptsMouseMovedEvents = true
    contentView = NSHostingView(rootView: ClipboardPickerView(model: model))
  }

  /// Borderless panels can't become key by default; the picker needs the keyboard.
  override var canBecomeKey: Bool { true }

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .keyDown:
      if handleKey(event) { return }
    case .leftMouseDown:
      pressedRow = row(under: event)
      if pressedRow != nil { return }
    case .leftMouseUp:
      let pressed = pressedRow
      pressedRow = nil
      if let pressed {
        if row(under: event) == pressed { model.paste(pressed) }
        return
      }
    case .mouseMoved:
      if let id = row(under: event) { model.hover(id, pointer: NSEvent.mouseLocation) }
    default:
      break
    }
    super.sendEvent(event)
  }

  /// ↑↓ move the selection, ↩ and ⌘1–9 paste, esc closes. Anything else is typing for the filter, and
  /// so are these keys while an input method is composing.
  private func handleKey(_ event: NSEvent) -> Bool {
    if (firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch event.keyCode {
    case 36, 76: model.paste()  // Return, keypad Enter
    case 53: model.onClose()  // Escape
    case 125: model.moveSelection(by: 1, pointer: NSEvent.mouseLocation)
    case 126: model.moveSelection(by: -1, pointer: NSEvent.mouseLocation)
    default:
      guard modifiers.contains(.command), let n = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
        (1...9).contains(n)
      else { return false }
      model.pick(number: n)
    }
    return true
  }

  /// The row under a mouse event, in the list's visible part.
  private func row(under event: NSEvent) -> UUID? {
    guard let host = contentView else { return nil }
    let point = host.convert(event.locationInWindow, from: nil)
    return model.row(at: host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y))
  }
}
