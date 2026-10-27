import AppKit
import SlatedCore
import SwiftUI

/// State for the clipboard switcher panel (Keyboard Maestro's clipboard history switcher).
@Observable
public final class ClipboardSwitcherModel {
  public var query = "" {
    // Text fields write the value back on focus; only a real change moves the selection.
    didSet { if query != oldValue { selectedID = results.first?.id } }
  }
  public var selectedID: UUID?
  public private(set) var items: [ClipboardItem] = []
  /// Whether Return pastes into the previous app (`clipboard.pasteAfterSelecting`) or only copies.
  public private(set) var pasteAfterSelecting = true
  /// The app closes the panel when this runs (after pasting or copying, or on Escape).
  public var onClose: () -> Void = {}
  /// "Now" for grouping and ages, fixed while the panel is open so rows don't regroup under you.
  private(set) var now = Date()
  private let services: any AppServices

  public init(services: any AppServices) {
    self.services = services
    reload()
  }

  /// Re-reads the history; call each time the panel opens.
  public func reload() {
    items = services.clipboardItems()
    pasteAfterSelecting = (try? services.loadConfiguration())?.clipboard.pasteAfterSelecting ?? true
    if selectedID == nil || !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
  }

  public func resetForShowing() {
    query = ""
    now = Date()
    reload()
    selectedID = results.first?.id
  }

  /// Matching items in display order: pinned first, then newest first.
  var results: [ClipboardItem] { ClipboardHistory(items: items).search(query) }

  /// `results` grouped under Pinned, Today, Yesterday…
  var sections: [(section: ClipboardSection, items: [ClipboardItem])] { ClipboardSection.group(results, now: now) }

  var selectedItem: ClipboardItem? { results.first { $0.id == selectedID } }

  /// The ⌘-number that picks an item (the first nine results), if it has one.
  func number(of id: UUID) -> Int? {
    guard let index = results.prefix(9).firstIndex(where: { $0.id == id }) else { return nil }
    return index + 1
  }

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
    let wasSelected = id == selectedID
    services.deleteClipboardItem(id: id)
    reload()
    // Deleting another row (from its menu) leaves the selection, and so what ↩ pastes, alone.
    guard wasSelected else { return }
    let remaining = results
    selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
  }
}

/// The switcher: a search field, results grouped by when they were copied, and a preview of the
/// selected item with where and when it came from. Keyboard-first: ↑↓, ↩ paste, ⌘C copy, ⌘1–9
/// pick, ⌘P pin, ⌘⌫ delete, esc close.
struct ClipboardSwitcherView: View {
  @Bindable var model: ClipboardSwitcherModel
  @FocusState private var searchFocused: Bool

  static let size = CGSize(width: 780, height: 480)

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      if model.results.isEmpty {
        emptyState
      } else {
        HStack(spacing: 0) {
          list
            .frame(width: 330)
          Rectangle().fill(Theme.hairline).frame(width: 0.5)
          if let item = model.selectedItem {
            ClipPreviewPane(item: item, now: model.now)
              .id(item.id)
          } else {
            Spacer()
          }
        }
      }
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      footer
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(.regularMaterial)
    .background(Theme.paneBackground.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    .tint(Theme.accent)
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

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "list.clipboard.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
      TextField("Search clipboard history", text: $model.query)
        .textFieldStyle(.plain)
        .font(.system(size: 17))
        .focused($searchFocused)
      if !model.query.isEmpty {
        Button {
          model.query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
      Text(countText)
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.well, in: Capsule())
    }
    .padding(.horizontal, 16)
    .frame(height: 58)
  }

  private var countText: String {
    let shown = model.results.count
    if model.query.isEmpty { return shown == 1 ? "1 item" : "\(shown) items" }
    return "\(shown) of \(model.items.count)"
  }

  // MARK: List

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
          ForEach(model.sections, id: \.section) { group in
            Text(group.section.title)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 10)
              .padding(.top, group.section == model.sections.first?.section ? 2 : 10)
              .padding(.bottom, 3)
            ForEach(group.items) { item in
              SwitcherRow(
                item: item, number: model.number(of: item.id), selected: item.id == model.selectedID, now: model.now
              )
              .id(item.id)
              .contentShape(Rectangle())
              .onTapGesture { model.selectedID = item.id }
              .simultaneousGesture(TapGesture(count: 2).onEnded { model.paste(item.id) })
              .contextMenu {
                Button(model.pasteAfterSelecting ? "Paste" : "Copy") { model.paste(item.id) }
                Button("Copy") { model.copy(item.id) }
                Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item.id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
              }
            }
          }
        }
        .padding(8)
      }
      .scrollContentBackground(.hidden)
      .onChange(of: model.selectedID) { _, id in
        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
      }
    }
  }

  // MARK: Empty

  private var emptyState: some View {
    VStack(spacing: 16) {
      if model.items.isEmpty {
        ClipboardStackArt(items: [])
          .frame(width: 210, height: 90)
      } else {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 26, weight: .medium))
          .foregroundStyle(Theme.accentGradient)
          .frame(width: 60, height: 60)
          .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
      }
      VStack(spacing: 5) {
        Text(model.items.isEmpty ? "Nothing copied yet" : "No matches for “\(model.query)”")
          .font(.system(size: 15, weight: .semibold))
        Text(
          model.items.isEmpty
            ? "Copy text in any app and it shows up here, ready to paste again."
            : "Try fewer or different words. Search ignores case and accents."
        )
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 16) {
      Group {
        hint(["↩"], model.pasteAfterSelecting ? "Paste" : "Copy", primary: true)
        hint(["⌘", "C"], "Copy")
        hint(["⌘", "1–9"], "Pick")
        hint(["⌘", "P"], model.selectedItem?.pinned == true ? "Unpin" : "Pin")
        hint(["⌘", "⌫"], "Delete")
      }
      .opacity(model.results.isEmpty ? 0.35 : 1)
      Spacer()
      hint(["esc"], "Close")
    }
    .padding(.horizontal, 16)
    .frame(height: 40)
  }

  private func hint(_ keys: [String], _ label: String, primary: Bool = false) -> some View {
    HStack(spacing: 5) {
      HStack(spacing: 2) {
        ForEach(keys, id: \.self) { Keycap(label: $0, size: .small) }
      }
      Text(label)
        .font(.system(size: 11.5, weight: primary ? .semibold : .regular))
        .foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
  }
}

/// One result: source app, a one-line preview, and its ⌘-number or age.
private struct SwitcherRow: View {
  let item: ClipboardItem
  let number: Int?
  let selected: Bool
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      ClipSourceIcon(item: item, size: 22)
      ClipPreviewLine(item: item, fontSize: 13, inverted: selected)
        .frame(maxWidth: .infinity, alignment: .leading)
      if item.pinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(SettingsPane.clipboard.tint))
      }
      if selected, let number {
        Text("⌘\(number)")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.9))
      } else {
        Text(ClipboardContent.shortAge(of: item.copiedAt, now: now))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 36)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Theme.accentGradientHorizontal)
          .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
      }
    }
  }
}

/// The selected item in full: its text (monospaced when it looks like code), a swatch for colors,
/// and where and when it was copied.
private struct ClipPreviewPane: View {
  let item: ClipboardItem
  let now: Date

  var body: some View {
    let kind = ClipboardContent.kind(of: item.text)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        ClipKindBadge(kind: kind)
        if item.pinned {
          Label("Pinned", systemImage: "pin.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(SettingsPane.clipboard.tint)
        }
        Spacer()
      }
      .padding(.horizontal, 18)
      .padding(.top, 14)
      .padding(.bottom, 10)
      ScrollView {
        content(kind)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, 18)
          .padding(.top, 4)
          .padding(.bottom, 14)
      }
      .scrollContentBackground(.hidden)
      Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, 18)
      details
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
  }

  @ViewBuilder private func content(_ kind: ClipboardContentKind) -> some View {
    switch kind {
    case .color:
      let hex = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      VStack(alignment: .leading, spacing: 12) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(swatchColor(hex))
          .frame(height: 120)
          .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
          .shadow(color: swatchColor(hex).opacity(0.4), radius: 12, y: 4)
        Text(hex.uppercased()).font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
        if let rgba = ClipboardContent.rgba(hex) {
          Text("rgb(\(Int(rgba.red * 255)), \(Int(rgba.green * 255)), \(Int(rgba.blue * 255)))")
            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    case .link:
      let link = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      VStack(alignment: .leading, spacing: 8) {
        if let host = ClipboardContent.host(of: link) {
          HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentGradient)
            Text(host).font(.system(size: 17, weight: .semibold))
          }
        }
        Text(link)
          .font(.system(size: 13))
          .foregroundStyle(Theme.accent)
          .textSelection(.enabled)
      }
    default:
      Text(item.text)
        .font(kind.isMonospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 14))
        .lineSpacing(kind.isMonospaced ? 2 : 3)
        .textSelection(.enabled)
        .padding(kind == .code ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          if kind == .code {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well)
              .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.wellStroke))
          }
        }
    }
  }

  private var details: some View {
    let stats = ClipboardContent.stats(item.text)
    return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
      GridRow {
        label("Source")
        HStack(spacing: 6) {
          if let app = item.sourceApp {
            AppIconView(bundleID: app, size: 15)
            Text(AppIcons.displayName(bundleID: app, running: [])).lineLimit(1)
          } else {
            Text("Unknown app").foregroundStyle(.secondary)
          }
        }
      }
      GridRow {
        label("Copied")
        HStack(spacing: 4) {
          Text(item.copiedAt, format: .dateTime.weekday(.abbreviated).hour().minute())
          Text("·").foregroundStyle(.tertiary)
          Text(item.copiedAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
        }
      }
      GridRow {
        label("Content")
        Text(
          "\(stats.characters.formatted()) character\(stats.characters == 1 ? "" : "s") · \(stats.words.formatted()) word\(stats.words == 1 ? "" : "s")"
            + (stats.lines > 1 ? " · \(stats.lines) lines" : "")
        )
        .monospacedDigit()
      }
    }
    .font(.system(size: 12))
  }

  private func label(_ text: String) -> some View {
    Text(text).foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
  }

  private func swatchColor(_ hex: String) -> Color {
    guard let rgba = ClipboardContent.rgba(hex) else { return .gray }
    return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
  }
}
