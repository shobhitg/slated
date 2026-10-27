import AppKit
import SlatedCore
import SwiftUI

/// Click, then press a shortcut. Global hotkeys, Hyper and hotstrings are suspended while recording
/// so the shortcut reaches this field instead of triggering an action.
///
/// Holding Caps Lock records ✦ (Hyper) even while the Hyper event tap is suspended: the recorder
/// reads F18, Caps Lock's remapped key, as the Hyper key's modifiers itself (⌃⌥⇧⌘, or ⌃⌥⇧ when
/// set to Meh). Esc cancels. Pressing the middle or a side
/// mouse button over the window records Mouse 3/4/5 when `allowsMouseButtons`.
struct ShortcutRecorder: View {
  @Binding var combo: KeyCombo
  /// Global shortcuts need a modifier; "Press Keys" actions may send any key on its own.
  var requiresModifier = true
  /// Accepts the middle and side mouse buttons (triggers can be mouse buttons; keys to send can't).
  var allowsMouseButtons = true
  /// Starts recording as soon as the field appears (new bindings).
  var autoStart = false
  /// Added to the "needs a modifier" hint, e.g. how to allow plain keys.
  var plainKeyHint: String?

  @Environment(AppModel.self) private var model
  @State private var monitor = KeyEventMonitor()
  @State private var isRecording = false
  @State private var held: Modifiers = []
  @State private var hyperHeld = false
  @State private var hint: String?
  @State private var stoppedAt = Date.distantPast
  @State private var confirmed = false
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: toggle) { field }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(combo.key.isEmpty ? "Record shortcut" : "Shortcut \(KeyComboView.spoken(combo))")
        .accessibilityHint("Click, then press the keys you want to use.")
      if let hint {
        Label(hint, systemImage: "exclamationmark.circle.fill")
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.caution)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(Theme.snappy, value: hint)
    .animation(Theme.snappy, value: isRecording)
    .onAppear { if autoStart { start() } }
    .onDisappear { stop() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
  }

  private var field: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return HStack(spacing: 8) {
      if isRecording {
        Image(systemName: "record.circle.fill")
          .font(.system(size: 13))
          .foregroundStyle(Theme.critical)
          .symbolEffect(.pulse, options: .repeating)
        let live = KeyCombo(key: "", modifiers: hyperHeld ? held.union(hyperModifiers) : held)
        if live.modifiers.isEmpty {
          Text(allowsMouseButtons ? "Press keys or a side button…" : "Type a shortcut…").foregroundStyle(.secondary)
        } else {
          KeyComboView(combo: live)
        }
        Spacer(minLength: 8)
        Keycap(label: "esc", size: .small)
        Text("to cancel").font(.system(size: 11)).foregroundStyle(.tertiary)
      } else if combo.key.isEmpty {
        Image(systemName: "record.circle").font(.system(size: 13, weight: .medium))
        Text("Record Shortcut").fontWeight(.medium)
        Spacer(minLength: 8)
      } else {
        KeyComboView(combo: combo)
        Spacer(minLength: 8)
        if confirmed {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Theme.positive)
            .transition(.scale.combined(with: .opacity))
        } else if hovering {
          Text("Click to change").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
      }
    }
    .font(.system(size: 12.5))
    .foregroundStyle(combo.key.isEmpty && !isRecording ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
    .padding(.horizontal, 10)
    .frame(minWidth: 230, minHeight: 38)
    .background(isRecording ? Theme.cardBackground : Theme.well, in: shape)
    .overlay(
      shape.strokeBorder(
        isRecording ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.wellStroke),
        lineWidth: isRecording ? 1.5 : 0.8)
    )
    .shadow(color: Theme.accent.opacity(isRecording ? 0.3 : 0), radius: 8)
    .contentShape(shape)
  }

  private func toggle() {
    if isRecording {
      stop()
    } else if Date().timeIntervalSince(stoppedAt) > 0.3 {
      // A click outside the field already stopped recording; don't restart on the same click.
      start()
    }
  }

  private func start() {
    guard !isRecording else { return }
    isRecording = true
    held = []
    hyperHeld = false
    hint = nil
    model.beginHotkeySuspension()
    monitor.start { event in handle(event) }
  }

  private func stop() {
    guard isRecording else { return }
    isRecording = false
    monitor.stop()
    model.endHotkeySuspension()
    held = []
    hyperHeld = false
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .leftMouseDown:
      stop()
      stoppedAt = Date()
      return event
    case .otherMouseDown:
      return recordMouse(event)
    case .flagsChanged:
      held = KeyEventMapping.modifiers(event.modifierFlags)
      return nil
    case .keyUp:
      if event.keyCode == KeyEventMapping.hyperKeyCode { hyperHeld = false }
      return nil
    case .keyDown:
      return record(event)
    default:
      return event
    }
  }

  private func record(_ event: NSEvent) -> NSEvent? {
    // F18 is Caps Lock only while Caps Lock is the Hyper key (`hidutil` remaps it then). Otherwise it's
    // a real F18 key, say on an extended keyboard or a keyboard layer, and records as itself.
    if event.keyCode == KeyEventMapping.hyperKeyCode, model.hyperKeyEnabled {
      hyperHeld = true
      return nil
    }
    let modifiers = KeyEventMapping.modifiers(
      event.modifierFlags, hyperHeld: hyperHeld, hyperModifiers: hyperModifiers)
    if event.keyCode == KeyEventMapping.escapeKeyCode, modifiers.isEmpty {
      stop()
      return nil
    }
    guard let key = KeyEventMapping.keyName(for: event) else {
      hint = "That key can't be part of a shortcut."
      return nil
    }
    let candidate = KeyCombo(key: key, modifiers: modifiers)
    if requiresModifier, !ShortcutRules.isAcceptableGlobalShortcut(candidate) {
      // Caps Lock only adds modifiers while it's the Hyper key.
      let capsLock =
        model.hyperKeyEnabled ? ", or hold Caps Lock for \(KeyCombo(key: "", modifiers: hyperModifiers).display())" : ""
      hint =
        "Add ⌃, ⌥ or ⌘\(capsLock). On its own, \(KeyNames.displayName(for: key)) would get in the way of typing."
        + (plainKeyHint.map { " \($0)" } ?? "")
      return nil
    }
    accept(candidate)
    return nil
  }

  /// Middle and side buttons (AppKit numbers them 2, 3, 4) record as Mouse 3, 4 and 5.
  private func recordMouse(_ event: NSEvent) -> NSEvent? {
    guard allowsMouseButtons else {
      hint = "Mouse buttons can't be sent as keys. Press a key instead."
      return nil
    }
    guard let key = KeyEventMapping.mouseButtonName(for: event.buttonNumber) else { return event }
    let modifiers = KeyEventMapping.modifiers(
      event.modifierFlags, hyperHeld: hyperHeld, hyperModifiers: hyperModifiers)
    accept(KeyCombo(key: key, modifiers: modifiers))
    return nil
  }

  /// What holding Caps Lock adds: ⌃⌥⇧⌘, or ⌃⌥⇧ when the Hyper key is set to Meh.
  private var hyperModifiers: Modifiers { model.configuration.keyboard.hyperModifiers }

  private func accept(_ candidate: KeyCombo) {
    combo = candidate
    hint = nil
    stop()
    withAnimation(Theme.snappy) { confirmed = true }
    Task {
      try? await Task.sleep(for: .seconds(1.4))
      withAnimation(Theme.snappy) { confirmed = false }
    }
  }
}

/// A shortcut that can be turned off (`nil`): the recorder, a button to clear it, and one to go
/// back to the default. For Slated's built-in shortcuts (clipboard history, stop automations).
struct OptionalShortcutRecorder: View {
  @Binding var combo: KeyCombo?
  let defaultCombo: KeyCombo?

  var body: some View {
    HStack(spacing: 8) {
      ShortcutRecorder(
        combo: Binding(get: { combo ?? KeyCombo(key: "") }, set: { combo = $0.key.isEmpty ? nil : $0 }))
      if combo != nil {
        Button {
          withAnimation(Theme.snappy) { combo = nil }
        } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Turn this shortcut off")
        .accessibilityLabel("Clear shortcut")
      }
      if let defaultCombo, combo != defaultCombo {
        Button("Use \(defaultCombo.display())") { withAnimation(Theme.snappy) { combo = defaultCombo } }
          .buttonStyle(.link)
          .font(.system(size: 12))
          .fixedSize()
      }
    }
  }
}
