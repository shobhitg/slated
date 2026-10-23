import AppKit
import SlatedCore
import SwiftUI

/// State for the clipboard switcher panel (Keyboard Maestro's clipboard history switcher).
@Observable
public final class ClipboardSwitcherModel {
  public var query = "" {
    didSet { selectedID = results.first?.id }
  }
  public var selectedID: UUID?
  public private(set) var items: [ClipboardItem] = []
  /// The app closes the panel when this runs (after pasting or copying, or on Escape).
  public var onClose: () -> Void = {}
  private let services: any AppServices

  public init(services: any AppServices) {
    self.services = services
    reload()
  }

  /// Re-reads the history; call each time the panel opens.
  public func reload() {
    items = services.clipboardItems()
    if selectedID == nil || !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
  }

  public func resetForShowing() {
    query = ""
    reload()
    selectedID = results.first?.id
  }

  var results: [ClipboardItem] { ClipboardHistory(items: items).search(query) }

  func moveSelection(by delta: Int) {
    let list = results
    guard !list.isEmpty else { return }
    let current = list.firstIndex { $0.id == selectedID } ?? -1
    selectedID = list[min(max(current + delta, 0), list.count - 1)].id
  }

  func paste(_ id: UUID? = nil) {
    guard let id = id ?? selectedID else { return }
    onClose()
    services.pasteClipboardItem(id: id)
  }

  func copy(_ id: UUID? = nil) {
    guard let id = id ?? selectedID else { return }
    onClose()
    services.copyClipboardItem(id: id)
  }

  func pick(number: Int) {
    let list = results
    guard number >= 1, number <= list.count else { return }
    paste(list[number - 1].id)
  }

  func togglePin(_ id: UUID? = nil) {
    guard let id = id ?? selectedID else { return }
    services.togglePinClipboardItem(id: id)
    reload()
  }

  func delete(_ id: UUID? = nil) {
    guard let id = id ?? selectedID else { return }
    let list = results
    let index = list.firstIndex { $0.id == id } ?? 0
    services.deleteClipboardItem(id: id)
    reload()
    let remaining = results
    selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
  }
}

/// The switcher: search field, numbered results, keyboard-first.
struct ClipboardSwitcherView: View {
  @Bindable var model: ClipboardSwitcherModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.5)
      if model.results.isEmpty {
        emptyState
      } else {
        list
      }
      Divider().opacity(0.5)
      footer
    }
    .frame(width: 600, height: 460)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
    .onAppear { searchFocused = true }
    .onKeyPress(.upArrow) {
      model.moveSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      model.moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.return) {
      model.paste()
      return .handled
    }
    .onKeyPress(.escape) {
      model.onClose()
      return .handled
    }
    .onKeyPress(phases: .down) { press in
      guard press.modifiers.contains(.command) else { return .ignored }
      switch press.characters {
      case "c":
        model.copy()
        return .handled
      case "p":
        model.togglePin()
        return .handled
      case "\u{8}", "\u{7F}":
        model.delete()
        return .handled
      default:
        if let n = Int(press.characters), (1...9).contains(n) {
          model.pick(number: n)
          return .handled
        }
        return .ignored
      }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "list.clipboard")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Theme.accentGradient)
      TextField("Search clipboard history", text: $model.query)
        .textFieldStyle(.plain)
        .font(.system(size: 16))
        .focused($searchFocused)
      Text("\(model.results.count)")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
            ClipboardRow(item: item, number: index < 9 ? index + 1 : nil, selected: item.id == model.selectedID)
              .id(item.id)
              .contentShape(Rectangle())
              .onTapGesture { model.paste(item.id) }
              .onHover { if $0 { model.selectedID = item.id } }
              .contextMenu {
                Button("Paste") { model.paste(item.id) }
                Button("Copy") { model.copy(item.id) }
                Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item.id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
              }
          }
        }
        .padding(8)
      }
      .onChange(of: model.selectedID) { _, id in
        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: model.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(.secondary)
      Text(model.items.isEmpty ? "Nothing copied yet" : "No matches")
        .font(.system(size: 15, weight: .semibold))
      Text(model.items.isEmpty ? "Copy something and it will show up here." : "Try fewer or different words.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack(spacing: 14) {
      hint("↩", "Paste")
      hint("⌘C", "Copy")
      hint("⌘1–9", "Pick")
      hint("⌘P", "Pin")
      hint("⌘⌫", "Delete")
      Spacer()
      hint("esc", "Close")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      Text(key)
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
      Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }
}

private struct ClipboardRow: View {
  let item: ClipboardItem
  let number: Int?
  let selected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      AppIcon(bundleID: item.sourceApp)
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 3) {
        Text(preview)
          .font(.system(size: 13))
          .lineLimit(2)
          .foregroundStyle(selected ? Color.white : Color.primary)
        HStack(spacing: 6) {
          if item.pinned {
            Label("Pinned", systemImage: "pin.fill").labelStyle(.titleAndIcon)
          }
          Text(item.copiedAt, format: .relative(presentation: .named))
          Text("·")
          Text(lengthDescription)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
      }
      Spacer(minLength: 8)
      if let number {
        Text("⌘\(number)")
          .font(.system(size: 10.5, weight: .semibold, design: .rounded))
          .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear)))
  }

  private var preview: String {
    let collapsed = item.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    return collapsed.count > 240 ? String(collapsed.prefix(240)) + "…" : collapsed
  }

  private var lengthDescription: String {
    let lines = item.text.split(whereSeparator: \.isNewline).count
    return lines > 1 ? "\(lines) lines" : "\(item.text.count) characters"
  }
}

private struct AppIcon: View {
  let bundleID: String?

  var body: some View {
    if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
    } else {
      Image(systemName: "doc.on.clipboard").resizable().scaledToFit().padding(4).foregroundStyle(.secondary)
    }
  }
}
