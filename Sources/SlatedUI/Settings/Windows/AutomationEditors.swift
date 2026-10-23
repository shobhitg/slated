import SlatedCore
import SwiftUI

/// Left / Right / Middle.
struct MouseButtonPicker: View {
  @Binding var button: MouseButton

  var body: some View {
    Picker("Button", selection: $button) {
      Text("Left").tag(MouseButton.left)
      Text("Right").tag(MouseButton.right)
      Text("Middle").tag(MouseButton.middle)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
  }
}

/// Chooses a mouse button or records a key.
struct SyntheticInputPicker: View {
  @Binding var input: SyntheticInput

  private var isMouse: Binding<Bool> {
    Binding(
      get: { if case .mouse = input { return true } else { return false } },
      set: { mouse in input = mouse ? .mouse(.right) : .key(KeyCombo(key: "w")) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      LabeledField("Input", labelWidth: 56) {
        Picker("Input", selection: isMouse) {
          Label("Mouse", systemImage: "computermouse").tag(true)
          Label("Key", systemImage: "keyboard").tag(false)
        }
        .labelsHidden().pickerStyle(.segmented).fixedSize()
      }
      switch input {
      case .mouse(let button):
        LabeledField("Button", labelWidth: 56) {
          MouseButtonPicker(button: Binding(get: { button }, set: { input = .mouse($0) }))
        }
      case .key(let combo):
        LabeledField("Key", labelWidth: 56) {
          ShortcutRecorder(combo: Binding(get: { combo }, set: { input = .key($0) }), requiresModifier: false)
        }
      }
    }
  }
}

/// A number of seconds, edited in seconds with a sensible floor.
struct SecondsField: View {
  @Binding var seconds: Double
  var minimum: Double

  var body: some View {
    HStack(spacing: 6) {
      TextField("0.1", value: $seconds, format: .number.precision(.fractionLength(0...3)))
        .textFieldStyle(.roundedBorder)
        .frame(width: 80)
        .onChange(of: seconds) { _, value in if value < minimum { seconds = minimum } }
      Text("seconds").font(.system(size: 12)).foregroundStyle(.secondary)
      Text("(\(ActionDescriber.seconds(seconds)))").font(.system(size: 11)).foregroundStyle(.tertiary)
    }
  }
}

/// The action an auto-repeat runs, with a nested editor in a popover.
struct RepeatedActionRow: View {
  @Binding var action: Action
  var depth: Int
  @State private var editing = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: ActionKind(action).symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.accentGradient)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text("Repeats").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        Text(ActionDescriber.title(action)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
      }
      Spacer(minLength: 6)
      Button("Edit") { editing = true }
        .buttonStyle(.soft)
        .controlSize(.small)
        .popover(isPresented: $editing, arrowEdge: .trailing) {
          ScrollView {
            ActionEditor(action: $action, depth: depth + 1)
              .padding(18)
          }
          .frame(width: 500, height: 480)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .wellStyle()
  }
}
