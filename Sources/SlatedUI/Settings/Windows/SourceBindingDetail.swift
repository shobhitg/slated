import SlatedCore
import SwiftUI

/// A read-only binding from a Slate file, with "Copy into Slated" when its action is static.
struct SourceBindingDetail: View {
  let source: SlateSource
  let binding: SourceBinding
  @Environment(AppModel.self) private var model

  var body: some View {
    let state = model.state(for: binding)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header(state)
        if let explanation = state.explanation {
          Notice(style: state == .duplicate ? .warning : .error, title: state.pill.text, message: explanation)
        }
        if let action = binding.action, PlacementCalculator.previews(action) {
          PlacementPreviewCard(action: action)
        }
        SettingsCard(title: "Defined In", symbol: "doc.text") {
          FactRow(label: "File", value: source.displayName, monospaced: true)
          CardDivider()
          HStack {
            Text("Keys").foregroundStyle(.secondary)
            Spacer()
            KeyComboView(combo: binding.keys, modal: binding.modal, size: .small)
          }
          .font(.system(size: 13))
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          if let modal = binding.modal {
            CardDivider()
            FactRow(
              label: "Modal key",
              value: "Press \(modal.keys.display()) first" + (modal.toggle ? ", stays on until pressed again" : ""))
          }
          CardDivider()
          FactRow(label: "Operation", value: binding.summary, monospaced: true)
          CardDivider()
          HStack {
            Spacer()
            Button("Reveal in Finder") { model.revealFile(atPath: source.path) }
              .buttonStyle(.soft)
              .controlSize(.small)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
        }
        copyCard
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
  }

  private func header(_ state: BindingState) -> some View {
    HStack(alignment: .center, spacing: 12) {
      if let action = binding.action {
        ActionGlyph(action: action, width: 40, height: 28)
      } else {
        Image(systemName: "curlybraces")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 40, height: 28)
          .background(Theme.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(binding.action.map(ActionDescriber.title) ?? "JavaScript Function")
          .font(.system(size: 19, weight: .bold))
          .tracking(-0.2)
        HStack(spacing: 8) {
          StatusPill(text: "Read-only", color: Theme.neutral, symbol: "lock.fill")
          let pill = state.pill
          StatusPill(text: pill.text, color: pill.color, symbol: pill.symbol)
          KeyComboView(combo: binding.keys, modal: binding.modal, size: .small)
        }
      }
      Spacer()
    }
  }

  @ViewBuilder private var copyCard: some View {
    if binding.action != nil {
      HStack(alignment: .center, spacing: 14) {
        IconTile(symbol: "square.and.arrow.down.on.square", tint: SettingsPane.slate.tint, size: 32)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.isCopied(binding) ? "Already in Slated" : "Make it editable")
            .font(.system(size: 13, weight: .semibold))
          Text(
            model.isCopied(binding)
              ? "Slated has its own copy of this shortcut. Remove this one from \(source.fileName) to avoid a duplicate."
              : "Copy this shortcut into Slated to change its keys or action here. Then remove it from \(source.fileName) so the two don't collide."
          )
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Copy into Slated") { model.copyIntoSlated(binding) }
          .buttonStyle(.gradient)
          .disabled(model.isCopied(binding))
      }
      .cardStyle()
    } else {
      Notice(
        style: .info, title: "This shortcut runs JavaScript",
        message:
          "Slated can't show or copy what a function does. Edit it in \(source.displayName); Slated reloads the file when it changes.",
        symbol: "curlybraces")
    }
  }
}
