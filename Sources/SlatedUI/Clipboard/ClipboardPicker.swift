import AppKit
import SlatedCore
import SwiftUI

/// State for the clipboard picker: a small list that opens where you're typing. Type to filter, ↑↓
/// and ↩ to paste, ⌘1–9 to pick, esc to close; a click pastes too (its panel, `ClipboardPickerPanel`,
/// handles those keys and clicks). Pinning, deleting and browsing the whole history live in Settings →
/// Clipboard.
@Observable
public final class ClipboardPickerModel {
  static let width: CGFloat = 320
  /// Rows shown before the list scrolls; also how many have a ⌘-number.
  static let visibleRows = 9
  static let filterHeight: CGFloat = 32
  static let textRowHeight: CGFloat = 26
  static let imageRowHeight: CGFloat = 36
  static let thumbnailHeight: CGFloat = 28
  static let listPadding: CGFloat = 5

  public var query = "" {
    // Text fields write the value back on focus; only a real change refilters.
    didSet { if query != oldValue { refilter(selectFirst: true) } }
  }
  public var selectedID: UUID? {
    didSet { if selectedID != oldValue { onPreviewChange?() } }
  }
  public private(set) var items: [ClipboardItem] = []
  /// Items matching the filter: pinned first, then newest first.
  public private(set) var results: [ClipboardItem] = []
  /// Whether Return pastes into the previous app (`clipboard.pasteAfterSelecting`) or only copies.
  public private(set) var pasteAfterSelecting = true
  /// The list's height, set when the picker opens so it doesn't resize as you type.
  private(set) var listHeight = textRowHeight
  /// Counts openings, so the view scrolls back to the top and focuses the filter.
  private(set) var openings = 0
  /// The app closes the picker when this runs (after picking, or on Escape).
  public var onClose: () -> Void = {}
  /// The image preview beside the picker should appear, move or go: the selection or its row moved.
  public var onPreviewChange: (() -> Void)?

  /// Rows' frames in the picker (top-left origin), as laid out; rows scrolled out of a lazy list drop out.
  @ObservationIgnored private(set) var rowFrames: [UUID: CGRect] = [:]
  /// Where the pointer was when a key moved the selection (or the picker opened): a row "hovered"
  /// under a pointer that hasn't moved since only scrolled there.
  @ObservationIgnored private var restingPointer: CGPoint?
  /// Display names by bundle id (a Launch Services lookup each), for image rows.
  @ObservationIgnored private var appNames: [String: String] = [:]
  private let services: any AppServices

  public init(services: any AppServices) {
    self.services = services
    reload()
  }

  /// Re-reads the history (a copy can arrive while the picker is open), keeping the selection.
  public func reload() {
    items = services.clipboardItems()
    pasteAfterSelecting = (try? services.loadConfiguration())?.clipboard.pasteAfterSelecting ?? true
    refilter(selectFirst: false)
  }

  /// Call each time the picker opens, with the pointer's location.
  public func resetForShowing(pointer: CGPoint? = nil) {
    query = ""
    reload()
    selectedID = results.first?.id
    restingPointer = pointer
    listHeight = Self.listHeight(for: results)
    openings += 1
  }

  /// The picker's size for the history it opened with.
  public var size: CGSize {
    CGSize(width: Self.width, height: Self.filterHeight + 0.5 + listHeight + 2 * Self.listPadding)
  }

  static func rowHeight(_ item: ClipboardItem) -> CGFloat { item.isImage ? imageRowHeight : textRowHeight }

  /// Room for the first nine rows (one row's worth when there are none), and half of the next when
  /// there are more, so the list shows it scrolls.
  static func listHeight(for rows: [ClipboardItem]) -> CGFloat {
    guard !rows.isEmpty else { return textRowHeight }
    let shown = rows.prefix(visibleRows).reduce(0) { $0 + rowHeight($1) }
    return shown + (rows.count > visibleRows ? textRowHeight / 2 : 0)
  }

  var selectedItem: ClipboardItem? { results.first { $0.id == selectedID } }

  /// The image shown larger beside the picker: the selected row's, when it's an image.
  public var previewItem: ClipboardItem? { selectedItem.flatMap { $0.isImage ? $0 : nil } }

  /// Where the preview's row is in the picker (top-left origin), once laid out.
  public var previewRowFrame: CGRect? { previewItem.flatMap { rowFrames[$0.id] } }

  /// The ⌘-number of the result at `index`: the first nine have one.
  func number(at index: Int) -> Int? { index < Self.visibleRows ? index + 1 : nil }

  func imageURL(_ image: ClipboardImage) -> URL? { services.clipboardImageURL(image) }

  func appName(_ bundleID: String) -> String {
    if let name = appNames[bundleID] { return name }
    let name = AppIcons.displayName(bundleID: bundleID, running: [])
    appNames[bundleID] = name
    return name
  }

  func moveSelection(by delta: Int, pointer: CGPoint? = nil) {
    if let pointer { restingPointer = pointer }
    guard !results.isEmpty else { return }
    let current = results.firstIndex { $0.id == selectedID } ?? -1
    selectedID = results[min(max(current + delta, 0), results.count - 1)].id
  }

  /// The pointer is over a row: it becomes the selection, so there's one highlight and ↩ pastes
  /// what's under the mouse. Not while the pointer rests where it was when a key moved the
  /// selection or the picker opened: the list moved under it, the mouse didn't.
  func hover(_ id: UUID, pointer: CGPoint?) {
    if let pointer, pointer == restingPointer { return }
    restingPointer = nil
    selectedID = id
  }

  func rowMoved(_ id: UUID, to frame: CGRect) {
    guard rowFrames[id] != frame else { return }
    rowFrames[id] = frame
    if id == selectedID && previewItem != nil { onPreviewChange?() }
  }

  func rowGone(_ id: UUID) { rowFrames[id] = nil }

  /// The row at `point` (top-left origin, in the picker), in the list's visible part: not the filter
  /// field, nor a row scrolled up under it.
  func row(at point: CGPoint) -> UUID? {
    guard point.y > Self.filterHeight, point.y < size.height else { return nil }
    return results.first { rowFrames[$0.id]?.contains(point) == true }?.id
  }

  /// Pastes the item (the selected one by default) into the app you were in, or only copies it with
  /// `pasteAfterSelecting` off.
  func paste(_ id: UUID? = nil) {
    guard let id = id ?? selectedID else { return }
    onClose()
    services.pasteClipboardItem(id: id)
  }

  /// ⌘1–9.
  func pick(number: Int) {
    guard number >= 1, number <= min(results.count, Self.visibleRows) else { return }
    paste(results[number - 1].id)
  }

  private func refilter(selectFirst: Bool) {
    results = ClipboardHistory(items: items).search(query)
    let shown = Set(results.map(\.id))
    rowFrames = rowFrames.filter { shown.contains($0.key) }
    if selectFirst || !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
  }
}

/// The picker: a filter field and one-line rows, an image as a thumbnail. Keyboard-first.
struct ClipboardPickerView: View {
  @Bindable var model: ClipboardPickerModel
  @FocusState private var filterFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      filter
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      list
    }
    .frame(width: model.size.width, height: model.size.height)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    .tint(Theme.accent)
    .onAppear { filterFocused = true }
    .onChange(of: model.openings) { filterFocused = true }
  }

  private var filter: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
      TextField("Filter", text: $model.query)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused($filterFocused)
      Text("⌘1–9 · esc")
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 11)
    .frame(height: ClipboardPickerModel.filterHeight)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
            PickerRow(
              item: item, number: model.number(at: index), selected: item.id == model.selectedID,
              imageURL: item.image.flatMap(model.imageURL), appName: model.appName
            )
            .id(item.id)
            .contentShape(Rectangle())
            .onHover { inside in
              if inside { model.hover(item.id, pointer: NSEvent.mouseLocation) }
            }
            .onGeometryChange(for: CGRect.self) {
              $0.frame(in: .global)
            } action: {
              model.rowMoved(item.id, to: $0)
            }
            .onDisappear { model.rowGone(item.id) }
          }
        }
        .padding(ClipboardPickerModel.listPadding)
      }
      .mask {
        // The half row below the ninth fades out: there's more further down.
        VStack(spacing: 0) {
          Rectangle()
          if model.results.count > ClipboardPickerModel.visibleRows {
            LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)
              .frame(height: 16)
          }
        }
      }
      .overlay {
        if model.results.isEmpty {
          Text(model.items.isEmpty ? "Nothing copied yet" : "No matches")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
      }
      .onAppear {
        if let id = model.selectedID { proxy.scrollTo(id) }
      }
      .onChange(of: model.selectedID) { _, id in
        if let id { proxy.scrollTo(id) }
      }
      .onChange(of: model.openings) {
        if let first = model.results.first?.id { proxy.scrollTo(first, anchor: .top) }
      }
    }
  }
}

/// One item on one line: its app's icon and text, or an image's thumbnail and size; a pin and the
/// ⌘-number at the end.
private struct PickerRow: View {
  let item: ClipboardItem
  let number: Int?
  let selected: Bool
  let imageURL: URL?
  let appName: (String) -> String

  var body: some View {
    HStack(spacing: 8) {
      if let image = item.image {
        let height = ClipboardPickerModel.thumbnailHeight
        ClipThumbnail(image: image, url: imageURL)
          .frame(width: ClipThumbnail.width(for: image, height: height), height: height)
        Text(
          ClipboardContent.imageTitle(
            image, app: item.sourceApp.map { appName($0) })
        )
        .font(.system(size: 13))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .lineLimit(1)
      } else {
        ClipSourceIcon(item: item, size: 16)
        ClipPreviewLine(item: item, fontSize: 13, inverted: selected)
      }
      Spacer(minLength: 4)
      if item.pinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(SettingsPane.clipboard.tint))
          .accessibilityLabel("Pinned")
      }
      if let number {
        Text("⌘\(number)")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
      }
    }
    .padding(.horizontal, 7)
    .frame(height: ClipboardPickerModel.rowHeight(item))
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent)
      }
    }
  }
}

/// The selected image, larger, for a small panel beside the picker: about 240 pt on its long side.
struct ClipboardImagePreview: View {
  let model: ClipboardPickerModel

  static let maxSide: CGFloat = 240
  static let padding: CGFloat = 8
  static let captionHeight: CGFloat = 19

  var body: some View {
    if let item = model.previewItem, let image = item.image {
      let fitted = Self.fittedSize(image)
      VStack(spacing: 0) {
        ClipThumbnail(
          image: image, url: model.imageURL(image), maxPixels: ClipboardThumbnails.previewPixels, cornerRadius: 6
        )
        .frame(width: fitted.width, height: fitted.height)
        Text(ClipboardContent.imageDetails(image))
          .font(.system(size: 10.5).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(height: Self.captionHeight, alignment: .bottom)
      }
      .padding(Self.padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
  }

  /// The image scaled to fit `maxSide`, never enlarged.
  static func fittedSize(_ image: ClipboardImage) -> CGSize {
    let width = CGFloat(max(image.width, 1))
    let height = CGFloat(max(image.height, 1))
    let scale = min(maxSide / width, maxSide / height, 1)
    return CGSize(width: max((width * scale).rounded(), 1), height: max((height * scale).rounded(), 1))
  }

  /// The preview panel's size: the fitted image, room for its caption, and padding.
  static func size(for image: ClipboardImage) -> CGSize {
    let fitted = fittedSize(image)
    return CGSize(width: max(fitted.width, 120) + 2 * padding, height: fitted.height + captionHeight + 2 * padding)
  }
}
