import SlatedCore
import SwiftUI

/// Keycap sizes, from list rows up to onboarding illustrations.
enum KeycapSize {
  case small, regular, large, hero

  var height: CGFloat {
    switch self {
    case .small: return 19
    case .regular: return 24
    case .large: return 44
    case .hero: return 68
    }
  }

  var fontSize: CGFloat {
    switch self {
    case .small: return 10.5
    case .regular: return 12.5
    case .large: return 20
    case .hero: return 30
    }
  }

  var radius: CGFloat {
    switch self {
    case .small: return 4.5
    case .regular: return 6
    case .large: return 10
    case .hero: return 15
    }
  }

  /// Depth of the keycap's bottom edge.
  var edge: CGFloat {
    switch self {
    case .small: return 1
    case .regular: return 1.5
    case .large: return 2.5
    case .hero: return 4
    }
  }

  var horizontalPadding: CGFloat {
    switch self {
    case .small: return 5
    case .regular: return 7
    case .large: return 12
    case .hero: return 18
    }
  }

  var spacing: CGFloat {
    switch self {
    case .small: return 2.5
    case .regular: return 3.5
    case .large: return 6
    case .hero: return 10
    }
  }
}

/// One physical-looking key: a soft gradient cap with a darker bottom edge.
struct Keycap: View {
  let label: String
  var size: KeycapSize = .regular
  /// Draws the label in the accent gradient (the ✦ Hyper key).
  var isAccent = false
  /// A word under the glyph on large keycaps ("control", "caps lock").
  var caption: String?
  var isPressed = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    VStack(spacing: size == .hero ? 4 : 1) {
      labelView
      if let caption, size == .large || size == .hero {
        Text(caption)
          .font(.system(size: size == .hero ? 11 : 8.5, weight: .medium))
          .foregroundStyle(Theme.keycapText.opacity(0.6))
      }
    }
    .padding(.horizontal, isSingleGlyph ? 0 : size.horizontalPadding)
    .frame(minWidth: size.height, minHeight: size.height)
    .background {
      ZStack {
        shape.fill(Theme.keycapEdge).offset(y: isPressed ? 0 : size.edge)
        shape.fill(LinearGradient(colors: [Theme.keycapTop, Theme.keycapBottom], startPoint: .top, endPoint: .bottom))
        shape.strokeBorder(
          isAccent ? AnyShapeStyle(Theme.accent.opacity(0.45)) : AnyShapeStyle(Theme.keycapStroke), lineWidth: 0.6)
      }
    }
    .offset(y: isPressed ? size.edge : 0)
    .padding(.bottom, size.edge)
  }

  private var isSingleGlyph: Bool { label.count == 1 }

  @ViewBuilder private var labelView: some View {
    let text = Text(label).font(.system(size: size.fontSize, weight: .medium, design: .rounded))
    if isAccent {
      text.foregroundStyle(Theme.accentGradient)
    } else {
      text.foregroundStyle(Theme.keycapText)
    }
  }
}

/// A key combination as a row of keycaps: `✦` `←`, or `⌃` `⌥` `⌘` `K`; modal keys come first.
struct KeyComboView: View {
  let combo: KeyCombo
  var modal: ModalKey?
  var size: KeycapSize = .regular

  var body: some View {
    HStack(spacing: size.spacing) {
      if let modal {
        keys(KeyComboView.caps(for: modal.keys))
        Image(systemName: "arrow.right")
          .font(.system(size: size.fontSize * 0.75, weight: .semibold))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 1)
          .padding(.bottom, size.edge)
      }
      keys(KeyComboView.caps(for: combo))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(KeyComboView.spoken(combo, modal: modal))
  }

  private func keys(_ caps: [Cap]) -> some View {
    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
      Keycap(label: cap.label, size: size, isAccent: cap.isHyper)
    }
  }

  struct Cap: Hashable {
    var label: String
    var isHyper = false
  }

  static func caps(for combo: KeyCombo) -> [Cap] {
    var caps: [Cap] = []
    if combo.modifiers.contains(.function) { caps.append(Cap(label: "fn")) }
    if combo.modifiers.isSuperset(of: .hyper) {
      caps.append(Cap(label: "✦", isHyper: true))
    } else {
      let order: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      for (modifier, glyph) in order where combo.modifiers.contains(modifier) { caps.append(Cap(label: glyph)) }
    }
    if !combo.key.isEmpty { caps.append(Cap(label: KeyNames.displayName(for: combo.key))) }
    return caps
  }

  /// "Hyper Left Arrow", "Control Option Command K".
  static func spoken(_ combo: KeyCombo, modal: ModalKey? = nil) -> String {
    func words(_ combo: KeyCombo) -> String {
      var parts: [String] = []
      if combo.modifiers.contains(.function) { parts.append("Function") }
      if combo.modifiers.isSuperset(of: .hyper) {
        parts.append("Hyper")
      } else {
        if combo.modifiers.contains(.control) { parts.append("Control") }
        if combo.modifiers.contains(.option) { parts.append("Option") }
        if combo.modifiers.contains(.shift) { parts.append("Shift") }
        if combo.modifiers.contains(.command) { parts.append("Command") }
      }
      let names = [
        "left": "Left Arrow", "right": "Right Arrow", "up": "Up Arrow", "down": "Down Arrow", "esc": "Escape",
      ]
      parts.append(names[combo.key] ?? KeyNames.displayName(for: combo.key))
      return parts.joined(separator: " ")
    }
    return (modal.map { words($0.keys) + ", then " } ?? "") + words(combo)
  }
}
