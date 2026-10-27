import SlatedCore
import SwiftUI

/// A monospaced field for a Slate expression, checked as you type, with a menu of variables.
struct ExpressionField: View {
  let label: String
  @Binding var text: String
  /// Accepts `+10%` / `-100` (resize and nudge).
  var relative = false
  @Environment(AppModel.self) private var model
  @FocusState private var focused: Bool

  var body: some View {
    let result = ExpressionCheck.check(text, relative: relative, variables: sampleVariables)
    let invalid = result.message != nil || result == .empty
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(label)
          .font(.system(size: 10.5, weight: .bold, design: .rounded))
          .foregroundStyle(.secondary)
          .frame(minWidth: 14)
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 16)
        TextField(relative ? "+10%" : "screenSizeX/2", text: $text)
          .textFieldStyle(.plain)
          .font(.system(size: 12, design: .monospaced))
          .focused($focused)
        if case .valid(let value?) = result {
          Text(verbatim: "= \(Int(value.rounded()))")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        VariableMenu { insertion in text += insertion }
      }
      .padding(.horizontal, 9)
      .frame(height: 30)
      .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(borderColor(invalid: invalid), lineWidth: focused || invalid ? 1.2 : 0.8)
      )
      .animation(Theme.snappy, value: focused)
      if let message = result.message ?? (result == .empty ? "Required" : nil) {
        Text(message)
          .font(.system(size: 11))
          .foregroundStyle(Theme.critical)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label) expression")
  }

  private func borderColor(invalid: Bool) -> Color {
    if invalid { return Theme.critical.opacity(0.7) }
    return focused ? Theme.accent.opacity(0.7) : Theme.wellStroke
  }

  private var sampleVariables: [String: Double] {
    guard let screen = model.mainScreen, let window = PlacementCalculator.sampleFrame(screens: model.screens) else {
      return [:]
    }
    return ExpressionCheck.sampleVariables(screen: screen.visibleFrame, window: window)
  }
}

/// Inserts Slate's expression variables and functions.
private struct VariableMenu: View {
  let insert: (String) -> Void

  var body: some View {
    Menu {
      Section("Screen (visible area)") {
        ForEach(["screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY"], id: \.self) { name in
          Button(name) { insert(name) }
        }
      }
      Section("Window") {
        ForEach(["windowTopLeftX", "windowTopLeftY", "windowSizeX", "windowSizeY"], id: \.self) { name in
          Button(name) { insert(name) }
        }
      }
      Section("Functions") {
        ForEach(["min", "max", "floor", "ceiling", "abs", "sqrt"], id: \.self) { name in
          Button("\(name)(…)") { insert("\(name)(") }
        }
      }
    } label: {
      Image(systemName: "function")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Insert a variable or function")
    .accessibilityLabel("Insert a variable or function")
  }
}
