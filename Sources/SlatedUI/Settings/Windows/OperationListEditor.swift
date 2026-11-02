import SlatedCore
import SwiftUI

/// The operations of a chain: each press runs the next one.
struct OperationListEditor: View {
  @Binding var operations: [Action]
  var depth: Int
  var isChain = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(spacing: 0) {
        ForEach(Array(operations.enumerated()), id: \.offset) { index, operation in
          if index > 0 { CardDivider(inset: 44) }
          StepRow(
            index: index, count: operations.count, action: binding(index), depth: depth,
            caption: isChain ? "Press \(index + 1)" : nil,
            onMove: { offset in move(index, by: offset) }, onDelete: { operations.remove(at: index) }
          )
          .configKeyBase { $0.item(index) }
        }
      }
      .wellStyle()
      AddStepMenu { operations.append($0) }
    }
  }

  private func binding(_ index: Int) -> Binding<Action> {
    Binding(
      get: { operations.indices.contains(index) ? operations[index] : .undo },
      set: { if operations.indices.contains(index) { operations[index] = $0 } })
  }

  private func move(_ index: Int, by offset: Int) {
    let target = index + offset
    guard operations.indices.contains(target) else { return }
    operations.swapAt(index, target)
  }
}

/// The steps of a sequence, each optionally kept on the window the sequence started with.
struct SequenceEditor: View {
  @Binding var steps: [SequenceStep]
  var depth: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      let schedule = MacroSchedule(steps: steps.map(\.action))
      if steps.contains(where: { $0.action.containsAutomation }), schedule.duration > 0 {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: "timeline.selection").font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(Theme.accent)
            Text("Timeline").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(ActionDescriber.seconds(schedule.duration)) in all")
              .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
          }
          MacroTimeline(schedule: schedule)
        }
        .padding(12)
        .wellStyle()
      }
      // As the encoder writes it: plain operations unless a step keeps the window.
      let plain = steps.allSatisfy { !$0.keepWindow }
      VStack(spacing: 0) {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          // "Same window" only means something for steps that act on windows.
          if index > 0 && (step.action.containsAutomation || isInput(step.action)) {
            CardDivider(inset: 44)
          } else if index > 0 {
            HStack(spacing: 6) {
              Rectangle().fill(Theme.hairline).frame(height: 0.5)
              Toggle(isOn: keepWindow(index)) {
                Text("Same window as the step before").font(.system(size: 11))
              }
              .toggleStyle(.checkbox)
              .controlSize(.small)
              .fixedSize()
              .help("Slate's “>” separator: run on the window that was focused when this run of steps began.")
              .configField(ConfigKeys.Action.keepWindow)
              .configKeyBase { $0.appending(ConfigKeys.Action.steps).item(index) }
              Rectangle().fill(Theme.hairline).frame(width: 12, height: 0.5)
            }
            .padding(.leading, 44)
            .padding(.vertical, 2)
          }
          StepRow(
            index: index, count: steps.count, action: action(index), depth: depth, caption: "Step \(index + 1)",
            onMove: { offset in move(index, by: offset) }, onDelete: { steps.remove(at: index) }
          )
          .configKeyBase { base in
            plain
              ? base.appending(ConfigKeys.Action.operations).item(index)
              : base.appending(ConfigKeys.Action.steps).item(index).appending(ConfigKeys.Action.action)
          }
        }
      }
      .wellStyle()
      AddStepMenu { steps.append(SequenceStep($0)) }
    }
  }

  private func action(_ index: Int) -> Binding<Action> {
    Binding(
      get: { steps.indices.contains(index) ? steps[index].action : .undo },
      set: { if steps.indices.contains(index) { steps[index].action = $0 } })
  }

  /// Steps that type, press keys or open things rather than acting on a window.
  private func isInput(_ action: Action) -> Bool {
    switch action {
    case .keystroke, .insertText, .openURL, .shell, .clipboardHistory: return true
    default: return false
    }
  }

  private func keepWindow(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { steps.indices.contains(index) ? steps[index].keepWindow : false },
      set: { if steps.indices.contains(index) { steps[index].keepWindow = $0 } })
  }

  private func move(_ index: Int, by offset: Int) {
    let target = index + offset
    guard steps.indices.contains(target) else { return }
    steps.swapAt(index, target)
  }
}

/// One operation in a chain or sequence, with an inline editor in a popover.
private struct StepRow: View {
  let index: Int
  let count: Int
  @Binding var action: Action
  let depth: Int
  var caption: String?
  let onMove: (Int) -> Void
  let onDelete: () -> Void
  @State private var editing = false

  var body: some View {
    HStack(spacing: 10) {
      Text("\(index + 1)")
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(Theme.accentGradient, in: Circle())
      ActionGlyph(action: action, width: 26, height: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(ActionDescriber.title(action)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
        Text(ActionDescriber.detail(action))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
      Menu {
        Button("Move Up") { onMove(-1) }.disabled(index == 0)
        Button("Move Down") { onMove(1) }.disabled(index == count - 1)
        Divider()
        Button("Remove", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis")
      }
      .accessibilityLabel("Options for step \(index + 1)")
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

/// Adds a step: any window preset, or a few common non-window operations.
private struct AddStepMenu: View {
  let add: (Action) -> Void

  var body: some View {
    Menu {
      ForEach(WindowPreset.Group.allCases) { group in
        Section(group.rawValue) {
          ForEach(WindowPresets.all.filter { $0.group == group }) { preset in
            Button(preset.title) { add(preset.action) }
          }
        }
      }
      Section("Mouse & Keys") {
        Button("Click Left") { add(.click(.left, count: 1)) }
        Button("Click Right") { add(.click(.right, count: 1)) }
        Button("Press W Down") { add(.press(.key(KeyCombo(key: "w")), phase: .down)) }
        Button("Release W") { add(.press(.key(KeyCombo(key: "w")), phase: .up)) }
        Button("Press a Key…") { add(.keystroke(KeyCombo(key: "e"))) }
        Button("Wait Half a Second") { add(.wait(0.5)) }
        Button("Wait 1 Second") { add(.wait(1)) }
      }
      Section("Other") {
        Button("Focus Window to the Left") { add(.focus(.left)) }
        Button("Focus App…") { add(.focusApp("")) }
        Button("Undo") { add(.undo) }
      }
    } label: {
      Label("Add Step", systemImage: "plus.circle.fill")
        .font(.system(size: 12, weight: .medium))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}
