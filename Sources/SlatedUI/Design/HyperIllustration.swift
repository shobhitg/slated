import SlatedCore
import SwiftUI

/// ⇪ → ⌃⌥⇧⌘: Caps Lock turning into the Hyper key. Gently animates a key press when `animates`.
struct HyperIllustration: View {
  /// Which modifiers Hyper sends (⌃⌥⇧⌘, or ⌃⌥⇧ for Meh).
  var modifiers: Modifiers = .hyper
  var isOn = true
  var animates = true
  var size: KeycapSize = .large
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pressed = false

  var body: some View {
    HStack(alignment: .center, spacing: size == .hero ? 22 : 16) {
      Keycap(label: "⇪", size: size == .hero ? .hero : .large, caption: "caps lock", isPressed: pressed)
      Image(systemName: "arrow.right")
        .font(.system(size: size == .hero ? 18 : 14, weight: .semibold))
        .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentGradientHorizontal) : AnyShapeStyle(.tertiary))
      HStack(spacing: size.spacing) {
        ForEach(Self.keys, id: \.glyph) { key in
          let included = modifiers.contains(key.modifier)
          Keycap(
            label: key.glyph, size: size, isAccent: isOn && included, caption: key.name, isPressed: pressed && included
          )
          .opacity(included ? 1 : 0.3)
          .overlay {
            if !included {
              Rectangle().fill(Theme.critical.opacity(0.6)).frame(height: 1.5).rotationEffect(.degrees(-35))
                .padding(.horizontal, 6)
            }
          }
        }
      }
      .padding(10)
      .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Theme.accent.opacity(isOn ? (pressed ? 0.16 : 0.08) : 0.03))
          .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .strokeBorder(Theme.accent.opacity(isOn ? 0.25 : 0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          )
      }
      .shadow(color: Theme.accent.opacity(isOn && pressed ? 0.35 : 0), radius: 14)
    }
    .saturation(isOn ? 1 : 0.2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Caps Lock becomes \(modifiers == .meh ? "Control Option Shift" : "Control Option Shift Command")"
    )
    .task(id: animates && isOn && !reduceMotion) {
      guard animates, isOn, !reduceMotion else {
        pressed = false
        return
      }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pressed = true }
        try? await Task.sleep(for: .seconds(0.7))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pressed = false }
      }
    }
  }

  private struct Key {
    var glyph: String
    var name: String
    var modifier: Modifiers
  }

  private static let keys = [
    Key(glyph: "⌃", name: "control", modifier: .control), Key(glyph: "⌥", name: "option", modifier: .option),
    Key(glyph: "⇧", name: "shift", modifier: .shift), Key(glyph: "⌘", name: "command", modifier: .command),
  ]
}
