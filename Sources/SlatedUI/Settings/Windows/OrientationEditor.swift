import SlatedCore
import SwiftUI

/// Edits an action that depends on the display's orientation: one operation for landscape
/// displays, another for portrait ones (SlatedCore's `Action.byOrientation`). Each branch opens a
/// full nested `ActionEditor`.
struct OrientationEditor: View {
  @Binding var landscape: Action
  @Binding var portrait: Action
  var depth = 0

  var body: some View {
    VStack(spacing: 0) {
      OrientationBranch(title: "Landscape displays", symbol: "rectangle", action: $landscape, depth: depth)
      CardDivider(inset: 44)
      OrientationBranch(title: "Portrait displays", symbol: "rectangle.portrait", action: $portrait, depth: depth)
    }
    .wellStyle()
  }
}

private struct OrientationBranch: View {
  let title: String
  let symbol: String
  @Binding var action: Action
  let depth: Int
  @State private var editing = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.accentGradient)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          ActionGlyph(action: action, width: 22, height: 15)
          Text(ActionDescriber.title(action)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
        }
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
  }
}
