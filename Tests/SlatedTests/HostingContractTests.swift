import AppKit
import Foundation
import SwiftUI

@testable import SlatedCore
@testable import SlatedUI

// How SwiftUI behaves when hosted in Slated's windows, checked with real (offscreen) windows.
//
// The settings window is created once and only ordered out when closed (`isReleasedWhenClosed =
// false`), so its views stay alive. Views that suspend Slated's hotkeys must not rely on focus
// changes or `onDisappear` to resume them: closing the window or switching apps produces neither.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

/// Lets SwiftUI lay out, run appear handlers and deliver state changes.
@MainActor private func spin(_ seconds: Double = 0.3) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// An offscreen window hosting `view` the way `SlatedUI.makeSettingsWindow` does.
@MainActor private func hostingWindow(_ view: some View) -> NSWindow {
  _ = NSApplication.shared
  let window = NSWindow(contentViewController: NSHostingController(rootView: view))
  window.styleMask = [.titled, .closable, .resizable]
  window.isReleasedWhenClosed = false
  window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
  window.orderFrontRegardless()
  spin()
  return window
}

/// The first editable text view in `view`'s hierarchy (SwiftUI's TextField is an NSTextField).
@MainActor private func textInput(in view: NSView) -> NSView? {
  if let field = view as? NSTextField, field.isEditable { return field }
  if let text = view as? NSTextView, text.isEditable { return text }
  for subview in view.subviews {
    if let found = textInput(in: subview) { return found }
  }
  return nil
}

/// Every label, title and string value in the accessibility tree under `root`: what VoiceOver can
/// read, and a way to check a view's text without pixels.
@MainActor private func accessibilityTexts(in root: NSView) -> [String] {
  var texts: [String] = []
  var pending: [Any] = [root]
  var visited = 0
  while let element = pending.popLast(), visited < 20_000 {
    visited += 1
    guard let node = element as? NSAccessibilityProtocol else { continue }
    let candidates: [String?] = [
      node.accessibilityLabel(), node.accessibilityTitle(), node.accessibilityValue() as? String,
    ]
    texts += candidates.compactMap { $0 }.filter { !$0.isEmpty }
    pending += node.accessibilityChildren()?.reversed() ?? []
  }
  return texts
}

/// Records what a hosted view sees.
@MainActor private final class EventRecorder {
  var events: [String] = []
}

/// Storage for a recorder's `combo` binding.
@MainActor private final class ComboBox {
  var combo = KeyCombo(key: "")
  var binding: Binding<KeyCombo> { Binding(get: { self.combo }, set: { self.combo = $0 }) }
}

/// A key press as AppKit delivers it to the app (and so to the recorder's local event monitor).
@MainActor private func keyDown(_ keyCode: UInt16, in window: NSWindow, _ flags: NSEvent.ModifierFlags = []) -> NSEvent?
{
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
}

private let probeNotification = Notification.Name("SlatedTests.hostingProbe")

private struct FocusProbe: View {
  let recorder: EventRecorder
  @FocusState private var focused: Bool
  @State private var text = ""
  @State private var pings = 0

  var body: some View {
    TextField("Probe", text: $text)
      .focused($focused)
      .onAppear { DispatchQueue.main.async { focused = true } }
      .onChange(of: focused) { _, value in recorder.events.append("focused \(value)") }
      .onDisappear { recorder.events.append("disappeared") }
      .onReceive(NotificationCenter.default.publisher(for: probeNotification)) { _ in pings += 1 }
      .onChange(of: pings) { _, value in recorder.events.append("pinged \(value)") }
      .frame(width: 300, height: 80)
  }
}

let uiHostingContractTests = Suite(
  "UIHostingContract",
  [
    (
      "hosted views expose no accessibility tree here, so labels need a real Mac with VoiceOver",
      {
        try onMain {
          // Probed for icon-only buttons (xmark, ellipsis, chevron, function…): nothing comes back,
          // not even plain text. If this starts failing, accessibility labels can be tested here.
          let window = hostingWindow(
            VStack {
              Text("Marker")
              Button {
              } label: {
                Image(systemName: "xmark")
              }
              .accessibilityLabel("Remove Safari")
            }
            .frame(width: 200, height: 100))
          expectEqual(accessibilityTexts(in: try require(window.contentView)), [])
          window.close()
        }
      }
    ),
    (
      "closing a reused window keeps focus and skips onDisappear, but notifications still arrive",
      {
        try onMain {
          let recorder = EventRecorder()
          let window = hostingWindow(FocusProbe(recorder: recorder))
          expectEqual(recorder.events, ["focused true"])
          recorder.events = []
          window.close()
          spin()
          // What a view sees when the settings window closes: nothing.
          expectEqual(recorder.events, [])
          expect(window.firstResponder is NSText, "the field keeps its window's focus")
          // So views must listen for the app or window going away themselves; that works.
          NotificationCenter.default.post(name: probeNotification, object: nil)
          spin()
          expectEqual(recorder.events, ["pinged 1"])
        }
      }
    ),
    (
      "the hotstring Try It field gives the hotkeys back when you switch apps or close Settings",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          let hotstring = Hotstring(trigger: ";x", replacement: "expanded")
          let window = hostingWindow(TryItField(hotstring: hotstring).environment(model).frame(width: 420))
          let field = try require(textInput(in: try require(window.contentView)))
          window.makeFirstResponder(field)
          spin()
          expect(services.hotkeysSuspended, "focusing Try It suspends the real engine")

          // Switching to another app: hotstrings and hotkeys must work there.
          NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
          spin()
          expect(!services.hotkeysSuspended, "switching apps resumes the engine")

          // Back in the field, typing suspends the engine again.
          let editor = try require(window.firstResponder as? NSTextView)
          editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
          spin()
          expect(services.hotkeysSuspended, "typing in Try It again suspends the engine")

          // Closing Settings with the field still focused.
          window.close()
          spin()
          expect(!services.hotkeysSuspended, "closing Settings resumes the engine")
        }
      }
    ),
    (
      "typing a layout's name keeps the name field focused",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          model.configuration.layouts = [Layout(name: "Work"), Layout(name: "Home")]
          model.selectedLayout = .slated(name: "Work")
          let window = hostingWindow(LayoutsPane().environment(model).frame(width: 900, height: 600))
          let field = try require(textInput(in: try require(window.contentView)) as? NSTextField)
          expectEqual(field.stringValue, "Work")
          window.makeFirstResponder(field)
          spin()
          try require(window.firstResponder as? NSTextView).moveToEndOfDocument(nil)
          for character in "shop" {
            let editor = try require(window.firstResponder as? NSTextView, "the name field lost focus")
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.1)
          }
          expectEqual(model.configuration.layouts.map(\.name), ["Workshop", "Home"])
          expect(model.selectedLayout == .slated(name: "Workshop"))
        }
      }
    ),
    (
      "the shortcut recorder reads Caps Lock as the Hyper key's modifiers, Meh included",
      {
        try onMain {
          for hyperModifiers in [Modifiers.hyper, .meh] {
            let services = PreviewServices()
            let model = AppModel(services: services)
            model.configuration.keyboard.hyperModifiers = hyperModifiers
            let box = ComboBox()
            let window = hostingWindow(
              ShortcutRecorder(combo: box.binding, autoStart: true).environment(model).frame(width: 420))
            expect(services.hotkeysSuspended, "recording suspends Slated's hotkeys")
            NSApp.sendEvent(try require(keyDown(KeyEventMapping.hyperKeyCode, in: window)))  // Caps Lock, as F18
            NSApp.sendEvent(try require(keyDown(123, in: window)))  // ←
            spin()
            // What the Hyper key will send for Caps Lock + ←, so the shortcut fires.
            expectEqual(box.combo, KeyCombo(key: "left", modifiers: hyperModifiers))
            expect(!services.hotkeysSuspended, "recording stops once a shortcut is accepted")
            window.close()
          }
        }
      }
    ),
  ])
