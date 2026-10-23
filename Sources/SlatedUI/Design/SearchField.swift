import SwiftUI

/// A compact, rounded search field that lives inside list headers (⌘F focuses it).
struct SearchField: View {
  let prompt: String
  @Binding var text: String
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused($focused)
        .onExitCommand { text = "" }
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 30)
    .background(Theme.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.wellStroke, lineWidth: focused ? 1.2 : 0.8)
    )
    .animation(Theme.snappy, value: focused)
    .background {
      Button("Find") { focused = true }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
    }
  }
}
