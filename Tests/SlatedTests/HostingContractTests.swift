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

/// An offscreen window hosting `view` the way `SlatedUI.makeMainWindow` does.
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

/// The first view of type `T` in `view`'s hierarchy, `view` included.
@MainActor private func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
  if let match = view as? T { return match }
  for subview in view.subviews {
    if let found = firstView(type, in: subview) { return found }
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

/// A key press or a click for the clipboard picker's panel. Rows are found by their laid-out frames.
private enum Input {
  case key(UInt16, String, NSEvent.ModifierFlags = [])
  case down(row: Int), up(row: Int)
  /// A point in the picker, top-left origin.
  case downAt(CGPoint), upAt(CGPoint)

  @MainActor func event(in panel: NSPanel, model: ClipboardPickerModel) -> NSEvent? {
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint?) -> NSEvent? {
      guard let point, let host = panel.contentView else { return nil }
      let location = host.convert(
        host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y), to: nil)
      return NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
    func center(_ row: Int) -> CGPoint? {
      model.rowFrames[model.results[row].id].map { CGPoint(x: $0.midX, y: $0.midY) }
    }
    switch self {
    case .key(let code, let characters, let flags):
      return NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    case .down(let row): return mouse(.leftMouseDown, center(row))
    case .up(let row): return mouse(.leftMouseUp, center(row))
    case .downAt(let point): return mouse(.leftMouseDown, point)
    case .upAt(let point): return mouse(.leftMouseUp, point)
    }
  }
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
      "the hotstring Try It field takes the hotkeys again when you come back to it, before you type",
      {
        try onMain {
          // A trigger that the first keystroke completes would otherwise expand for real in the field.
          let services = PreviewServices()
          let model = AppModel(services: services)
          let hotstring = Hotstring(trigger: "x", replacement: "expanded")
          let window = hostingWindow(TryItField(hotstring: hotstring).environment(model).frame(width: 420))
          let field = try require(textInput(in: try require(window.contentView)))
          window.makeFirstResponder(field)
          spin()
          expect(services.hotkeysSuspended, "focusing Try It suspends the real engine")

          // Switching to another app and back: the field still has focus.
          NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
          NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
          spin()
          expect(!services.hotkeysSuspended, "switching apps resumes the engine")
          NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
          NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
          spin()
          expect(services.hotkeysSuspended, "back in Slated, Try It suspends the engine again")

          // Closing Settings, another window coming forward meanwhile, then reopening Settings.
          window.close()
          spin()
          expect(!services.hotkeysSuspended, "closing Settings resumes the engine")
          let other = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 100), styleMask: [.titled],
            backing: .buffered, defer: true)
          other.isReleasedWhenClosed = false
          NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
          spin()
          expect(!services.hotkeysSuspended, "another window isn't Settings")
          window.makeKeyAndOrderFront(nil)
          NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
          spin()
          expect(window.firstResponder is NSText, "Try It still has the focus")
          expect(services.hotkeysSuspended, "reopening Settings at Try It suspends the engine again")
          window.close()
          spin()
          expect(!services.hotkeysSuspended)
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
          expect(model.selectedLayout == .slated(name: "Workshop", index: 0))
        }
      }
    ),
    (
      "typing a layout's name through other names takes none of their shortcuts along",
      {
        try onMain {
          /// Types `text` into the layout name field one character at a time, after `prepare`.
          @MainActor func type(_ text: String, in window: NSWindow, prepare: (NSTextView) -> Void) throws {
            let field = try require(textInput(in: try require(window.contentView)) as? NSTextField)
            window.makeFirstResponder(field)
            spin()
            prepare(try require(window.firstResponder as? NSTextView))
            for character in text {
              let editor = try require(window.firstResponder as? NSTextView, "the name field lost focus")
              editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
              spin(0.1)
            }
          }
          let hyper = { (key: String) in KeyCombo(key: key, modifiers: .hyper) }

          // Through a deleted layout's name, which its shortcut still applies.
          var model = AppModel(services: PreviewServices(scenario: .empty))
          model.configuration.layouts = [Layout(name: "Work"), Layout(name: "Work 2")]
          let workKey = HotkeyBinding(keys: hyper("1"), action: .layout(name: "Work"))
          let work2Key = HotkeyBinding(keys: hyper("2"), action: .layout(name: "Work 2"))
          model.configuration.bindings = [workKey, work2Key]
          model.deleteLayout("Work 2")
          model.selectedLayout = .slated(name: "Work")
          var window = hostingWindow(LayoutsPane().environment(model).frame(width: 900, height: 600))
          try type(" 2b", in: window) { $0.moveToEndOfDocument(nil) }
          expectEqual(model.configuration.layouts.map(\.name), ["Work 2b"])
          expectEqual(model.binding(workKey.id)?.action, .layout(name: "Work 2b"))
          // The deleted layout's shortcut stays on its name.
          expectEqual(model.binding(work2Key.id)?.action, .layout(name: "Work 2"))
          window.close()

          // Through a Slate file's layout name (the preview's ~/.slate.js has “Writing”).
          model = AppModel(services: PreviewServices())
          let writingKey = HotkeyBinding(keys: hyper("w"), action: .layout(name: "Writing"))
          model.configuration.bindings.append(writingKey)
          model.selectedLayout = .slated(name: "Coding")
          window = hostingWindow(LayoutsPane().environment(model).frame(width: 900, height: 600))
          try type("Writing Room", in: window) { $0.selectAll(nil) }
          expectEqual(model.configuration.layouts.map(\.name), ["Writing Room"])
          expectEqual(model.binding(writingKey.id)?.action, .layout(name: "Writing"))
          window.close()
        }
      }
    ),
    (
      "a layout name refused as another layout's is taken once that layout is gone",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          model.configuration.layouts = [Layout(name: "Work"), Layout(name: "Home")]
          model.selectedLayout = .slated(name: "Work")
          let window = hostingWindow(LayoutsPane().environment(model).frame(width: 900, height: 600))
          let field = try require(textInput(in: try require(window.contentView)) as? NSTextField)
          window.makeFirstResponder(field)
          spin()
          let editor = try require(window.firstResponder as? NSTextView)
          editor.selectAll(nil)
          editor.insertText("Home", replacementRange: NSRange(location: NSNotFound, length: 0))
          spin()
          expectEqual(model.configuration.layouts.map(\.name), ["Work", "Home"])
          // Deleted from the list's context menu while the field still holds the refused name.
          model.deleteLayout("Home")
          spin()
          expectEqual(field.stringValue, "Home")
          // What the field shows is the layout's name.
          expectEqual(model.configuration.layouts.map(\.name), ["Home"])
          window.close()
        }
      }
    ),
    (
      "a layout name typed while config.json can't be read goes back to the layout's name",
      {
        try onMain {
          let services = BreakableServices()
          let model = AppModel(services: services)  // the preview's one Slated layout, “Coding”
          model.selectedLayout = .slated(name: "Coding", index: 0)
          let window = hostingWindow(LayoutsPane().environment(model).frame(width: 900, height: 600))
          services.broken = true
          services.fileChanged()
          spin()
          let field = try require(textInput(in: try require(window.contentView)) as? NSTextField)
          window.makeFirstResponder(field)
          spin()
          let editor = try require(window.firstResponder as? NSTextView)
          editor.selectAll(nil)
          editor.insertText("Deep Work", replacementRange: NSRange(location: NSNotFound, length: 0))
          spin()
          // Refused (Settings is read-only meanwhile), and the field says so, as fields bound to the model do.
          expectEqual(model.configuration.layouts.map(\.name), ["Coding"])
          expectEqual(field.stringValue, "Coding")
          window.close()
        }
      }
    ),
    (
      "a shortcut behind a modal key can be a plain key in the editor",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          let modal = ModalKey(keys: KeyCombo(key: "e", modifiers: .control))
          let binding = HotkeyBinding(keys: KeyCombo(key: ""), modal: modal, action: .undo)
          model.configuration.bindings = [binding]
          model.recordShortcutFor = binding.id  // the keys recorder starts when the editor appears
          let editor = BindingEditor(binding: try require(model.bindingBinding(binding.id)))
          let window = hostingWindow(editor.environment(model).frame(width: 700, height: 900))
          expect(services.hotkeysSuspended, "the keys recorder is recording")
          NSApp.sendEvent(try require(keyDown(49, in: window)))  // Space, no modifiers
          spin()
          // Only live after ⌃E, so a plain key never gets in the way of typing (the validator and the
          // engine agree).
          expectEqual(model.binding(binding.id)?.keys, KeyCombo(key: "space"))
          window.close()
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
    (
      "the shortcut recorder records F18 as F18 when Caps Lock isn't the Hyper key",
      {
        try onMain {
          // Nothing remaps Caps Lock then, so F18 is a real F18 key (an extended keyboard, a layer).
          for requiresModifier in [true, false] {
            let services = PreviewServices()
            let model = AppModel(services: services)
            model.configuration.keyboard.capsLock = .off
            let box = ComboBox()
            let recorder = ShortcutRecorder(combo: box.binding, requiresModifier: requiresModifier, autoStart: true)
            let window = hostingWindow(recorder.environment(model).frame(width: 420))
            NSApp.sendEvent(try require(keyDown(KeyEventMapping.hyperKeyCode, in: window)))  // F18
            spin()
            expectEqual(box.combo, KeyCombo(key: "f18"))
            expect(!services.hotkeysSuspended, "recording stops once a shortcut is accepted")
            window.close()
          }
        }
      }
    ),
    (
      "Settings → General shows any undo history size config.json can hold",
      {
        try onMain {
          // Int(_:) traps on most of these, and showing the pane used to. A hand edit can hold them, and
          // so can config.json after importing a Slate config (`config undoMaxStackSize 1e20`).
          // The stepper works from 1 to 50, so one click from any of them lands in that range.
          let clicks: [(value: SettingValue, up: Bool, then: Double)] = [
            (.number(1e20), false, 49), (.number(.infinity), false, 49), (.string("inf"), false, 49),
            (.number(100), false, 49), (.number(.nan), true, 11), (.number(20.9), true, 21),
            (.number(-.infinity), true, 2), (.number(-1e20), true, 2),
          ]
          for click in clicks {
            let model = AppModel(services: PreviewServices(scenario: .empty))
            model.configuration.settings["undoMaxStackSize"] = click.value
            let window = hostingWindow(GeneralPane().environment(model).frame(width: 760, height: 1400))
            // SwiftUI's Stepper is an NSStepper that reports each click as a step from 0.
            let stepper = try require(firstView(NSStepper.self, in: try require(window.contentView)), "no stepper")
            stepper.doubleValue += click.up ? stepper.increment : -stepper.increment
            expect(stepper.sendAction(stepper.action, to: stepper.target))
            spin(0.1)
            expectEqual(model.configuration.settings["undoMaxStackSize"], .number(click.then))
            window.close()
          }
        }
      }
    ),
    (
      "Settings → Automation's indicator preview is the island while it's on, else the pill",
      {
        try onMain {
          // Running automations show in the island, which is on by default; the pill only without it.
          let subtitle = AutomationIndicatorPreview.settingSubtitle
          expect(subtitle.contains("notch island") && subtitle.contains("pill"), subtitle)
          // The preview draws the island's black shape, or the pill's light one (in light mode).
          @MainActor func topCenter(inIsland: Bool) throws -> NSColor {
            let preview = AutomationIndicatorPreview(stop: KeyCombo(key: "esc", modifiers: .hyper), inIsland: inIsland)
            let host = NSHostingView(rootView: preview.environment(\.colorScheme, .light))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let bitmap = try require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.usingColorSpace(.sRGB))
          }
          let island = try topCenter(inIsland: true)
          expect(island.brightnessComponent < 0.1 && island.alphaComponent > 0.9, "island: \(island)")
          let pill = try topCenter(inIsland: false)
          expect(pill.brightnessComponent > 0.9, "pill: \(pill)")
        }
      }
    ),
    (
      "the main window's sidebar is ordinary views with a row per pane: no split view, glass or toolbar",
      {
        try onMain {
          // The author's window showed an empty sidebar (its rows still took clicks) with SwiftUI's
          // title in the title bar. It was a NavigationSplitView, whose sidebar macOS 26 hosts in Liquid
          // Glass that the window server draws. Now it's a plain list in the window's own view tree.
          _ = NSApplication.shared
          let model = AppModel(services: PreviewServices())
          let window = SlatedUI.makeMainWindow(model: model)
          window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
          window.orderFrontRegardless()
          spin()
          defer { window.close() }
          let content = try require(window.contentView)
          expect(window.toolbar == nil, "SwiftUI installed a toolbar: \(String(describing: window.toolbar))")
          expectEqual(window.title, "Slated")
          let table = try require(firstView(NSTableView.self, in: content), "no sidebar list")
          var ancestors: [String] = []
          var view = table.superview
          while let current = view, current !== content {
            ancestors.append(String(describing: type(of: current)))
            expect(!current.isHidden && current.alphaValue == 1, "hidden: \(type(of: current))")
            view = current.superview
          }
          let drawnElsewhere = ancestors.filter {
            $0.contains("SplitView") || $0.contains("Glass") || $0.contains("VisualEffect")
          }
          expect(drawnElsewhere.isEmpty, "sidebar inside \(drawnElsewhere)")
          // The header row, then a row per pane, each on screen below the title bar.
          let panes = SettingsSidebar.sections(showingGetStarted: false).joined().count
          expectEqual(table.numberOfRows, panes + SettingsSidebar.sections(showingGetStarted: false).count + 1)
          let visible = window.contentLayoutRect
          var paneRows = 0
          for row in 0..<table.numberOfRows {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false), rowView.frame.height > 1 else {
              continue  // section headers have no height
            }
            let frame = rowView.convert(rowView.bounds, to: nil)
            expect(visible.contains(frame) && !rowView.isHidden, "row \(row) at \(frame), visible \(visible)")
            if row > 0 { paneRows += 1 }
          }
          expectEqual(paneRows, panes)
        }
      }
    ),
    (
      "the sidebar's rows are painted by ordinary drawing (the glass sidebar drew nothing here)",
      {
        try onMain {
          // Drawn the way `make snapshots` draws (a borderless offscreen window and cacheDisplay; under
          // a title bar macOS 26 captures nothing): each row starts with a colored icon tile. The
          // NavigationSplitView's glass sidebar came out empty here, rows and all.
          _ = NSApplication.shared
          let size = SlatedUI.mainWindowSize
          let host = NSHostingView(rootView: SlatedUI.makeMainView(model: AppModel(services: PreviewServices())))
          host.sizingOptions = []
          host.frame = CGRect(origin: .zero, size: size)
          let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
          window.contentView = host
          window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
          window.orderFrontRegardless()
          spin(0.6)
          defer { window.close() }
          let bitmap = try require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let scale = Double(bitmap.pixelsWide) / size.width
          // Strongly colored pixels in each pane row's icon column, rows counted top to bottom.
          var coloredRows = 0
          var inRow = false
          for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            var colored = 0
            for x in stride(from: Int(12 * scale), to: Int(48 * scale), by: 2) {
              guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
              if color.saturationComponent > 0.4 && color.brightnessComponent > 0.35 { colored += 1 }
            }
            if colored > 3 && !inRow { coloredRows += 1 }
            inRow = colored > 3
          }
          // The brand mark in the header, then one icon tile per pane.
          expect(
            coloredRows >= SettingsSidebar.sections(showingGetStarted: false).joined().count,
            "icon rows drawn: \(coloredRows)")
        }
      }
    ),
    (
      "the clipboard picker's panel handles its keys and clicks itself, before the filter field",
      {
        try onMain {
          // Scenarios: what's sent, then which result (by index) is pasted and whether it closed.
          let scenarios: [(String, [Input], Int?, Bool)] = [
            ("return", [.key(36, "\r")], 0, true),
            ("keypad enter", [.key(76, "\u{3}")], 0, true),
            ("down, return", [.key(125, "\u{F701}"), .key(36, "\r")], 1, true),
            ("⌘2", [.key(19, "2", .command)], 1, true),
            ("click on the second row", [.down(row: 1), .up(row: 1)], 1, true),
            ("press on one row, release on another", [.down(row: 0), .up(row: 1)], nil, false),
            ("click in the filter field", [.downAt(CGPoint(x: 60, y: 10)), .upAt(CGPoint(x: 60, y: 10))], nil, false),
            ("escape", [.key(53, "\u{1B}")], nil, true),
            ("typing", [.key(0, "a")], nil, false),
          ]
          for (name, inputs, pastedIndex, closes) in scenarios {
            let services = PreviewServices()
            let model = ClipboardPickerModel(services: services)
            var closed = 0
            model.onClose = { closed += 1 }
            model.resetForShowing()
            let panel = SlatedUI.makeClipboardPickerPanel(model: model)
            panel.setFrame(NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: model.size), display: true)
            panel.orderFrontRegardless()
            spin()
            let results = model.results
            expect(results.count >= 2, "\(name): the sample history has rows")
            for input in inputs { panel.sendEvent(try require(input.event(in: panel, model: model))) }
            spin(0.1)
            let expected = pastedIndex.map { [results[$0].id] } ?? []
            expect(services.pastedClipboardItems == expected, "\(name): pasted \(services.pastedClipboardItems)")
            expect(closed == (closes ? 1 : 0), "\(name): closed \(closed) times")
            panel.close()
          }
        }
      }
    ),
  ])
