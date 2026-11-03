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
  /// Copied files no longer where they were copied from, by item: checked when the picker opens.
  private(set) var missingFiles: [UUID: Set<String>] = [:]
  /// Secrets shown with their eye button, until the picker closes.
  private(set) var revealed: Set<UUID> = []
  /// ⌥ is held: the selected row shows its secret while it is. The panel reports it.
  public var optionHeld = false
  /// The eye buttons' frames in the picker (top-left origin), so the panel can tell a click on one from
  /// a click that pastes the row.
  @ObservationIgnored private(set) var eyeFrames: [UUID: CGRect] = [:]
  /// Picking files that are all gone: the alert sound (tests stay quiet).
  @ObservationIgnored var beep: () -> Void = { NSSound.beep() }
  private let services: any AppServices

  public init(services: any AppServices) {
    self.services = services
    reload()
  }

  /// Re-reads the history (a copy can arrive while the picker is open), keeping the selection.
  public func reload() {
    items = services.clipboardItems()
    pasteAfterSelecting = (try? services.loadConfiguration())?.clipboard.pasteAfterSelecting ?? true
    var missing: [UUID: Set<String>] = [:]
    for item in items where item.isFiles {
      let gone = Set((item.files ?? []).filter(services.clipboardFileMissing))
      if !gone.isEmpty { missing[item.id] = gone }
    }
    missingFiles = missing
    refilter(selectFirst: false)
  }

  /// Every one of the item's files is gone: there's nothing to paste.
  public func isUnavailable(_ item: ClipboardItem) -> Bool {
    guard item.isFiles, let files = item.files, let gone = missingFiles[item.id] else { return false }
    return files.allSatisfy(gone.contains)
  }

  /// Call each time the picker opens, with the pointer's location and whether ⌥ is down already.
  public func resetForShowing(pointer: CGPoint? = nil, optionHeld: Bool = false) {
    query = ""
    revealed = []
    self.optionHeld = optionHeld
    reload()
    selectedID = results.first?.id
    restingPointer = pointer
    listHeight = Self.listHeight(for: results)
    openings += 1
  }

  // MARK: Secrets

  /// Whether the row shows dots instead of the item's text: a secret, unless its eye was clicked or ⌥
  /// is held while it's selected.
  public func isMasked(_ item: ClipboardItem) -> Bool {
    item.isSecret && !revealed.contains(item.id) && !(optionHeld && item.id == selectedID)
  }

  /// The eye button: shows the secret until the picker closes, or hides it again.
  public func toggleReveal(_ id: UUID) {
    if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
  }

  /// Whether any result is a secret, for the hint about ⌥.
  var hasSecrets: Bool { results.contains(where: \.isSecret) }

  func eyeMoved(_ id: UUID, to frame: CGRect?) { eyeFrames[id] = frame }

  /// The secret whose eye button is at `point` (top-left origin, in the picker), in the list's visible part.
  func eye(at point: CGPoint) -> UUID? {
    guard point.y > Self.filterHeight, point.y < size.height else { return nil }
    return results.first { $0.isSecret && eyeFrames[$0.id]?.insetBy(dx: -3, dy: -3).contains(point) == true }?.id
  }

  /// The picker's size for the history it opened with.
  public var size: CGSize {
    CGSize(width: Self.width, height: Self.filterHeight + 0.5 + listHeight + 2 * Self.listPadding)
  }

  /// Images are taller; text and files (a small thumbnail beside the name) are one line.
  static func rowHeight(_ item: ClipboardItem) -> CGFloat { item.isImage ? imageRowHeight : textRowHeight }
  /// As wide as a text row's app icon, so names line up with text; a page gets a little more height.
  static let fileThumbnailSize = CGSize(width: 16, height: 20)

  /// Room for the first nine rows (one row's worth when there are none), and half of the next when
  /// there are more, so the list shows it scrolls.
  static func listHeight(for rows: [ClipboardItem]) -> CGFloat {
    guard !rows.isEmpty else { return textRowHeight }
    let shown = rows.prefix(visibleRows).reduce(0) { $0 + rowHeight($1) }
    return shown + (rows.count > visibleRows ? textRowHeight / 2 : 0)
  }

  var selectedItem: ClipboardItem? { results.first { $0.id == selectedID } }

  /// The item shown larger beside the picker: the selected row's, when it's an image or files.
  public var previewItem: ClipboardItem? { selectedItem.flatMap { $0.isImage || $0.isFiles ? $0 : nil } }

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
  /// `pasteAfterSelecting` off. Files that were all moved or deleted can't be: the picker stays open
  /// (the app logs the attempt and leaves the clipboard alone).
  func paste(_ id: UUID? = nil) {
    guard let id = id ?? selectedID else { return }
    if let item = items.first(where: { $0.id == id }), isUnavailable(item) {
      services.pasteClipboardItem(id: id)
      beep()
      return
    }
    onClose()
    services.pasteClipboardItem(id: id)
  }

  /// ⌘1–9.
  func pick(number: Int) {
    guard number >= 1, number <= min(results.count, Self.visibleRows) else { return }
    paste(results[number - 1].id)
  }

  private func refilter(selectFirst: Bool) {
    // A secret matches only by its app's name, never its text.
    results = ClipboardHistory(items: items).search(query, appName: appName)
    let shown = Set(results.map(\.id))
    rowFrames = rowFrames.filter { shown.contains($0.key) }
    eyeFrames = eyeFrames.filter { shown.contains($0.key) }
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
      Text(model.hasSecrets ? "⌥ show · ⌘1–9 · esc" : "⌘1–9 · esc")
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
              imageURL: item.image.flatMap(model.imageURL), unavailable: model.isUnavailable(item),
              masked: model.isMasked(item), appName: model.appName,
              eyeMoved: { model.eyeMoved(item.id, to: $0) }
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

/// One item on one line: its app's icon and text, an image's thumbnail and name or size, or a file's
/// thumbnail and name; a pin and the ⌘-number at the end.
private struct PickerRow: View {
  let item: ClipboardItem
  let number: Int?
  let selected: Bool
  let imageURL: URL?
  /// Files that were all moved or deleted: dimmed, and said so.
  let unavailable: Bool
  /// A secret showing dots (`ClipboardPickerModel.isMasked`).
  let masked: Bool
  let appName: (String) -> String
  /// Where the eye button is (top-left origin, in the picker), so the panel can route its clicks.
  let eyeMoved: (CGRect?) -> Void

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
        .truncationMode(image.name == nil ? .tail : .middle)
      } else if let files = item.files, item.isFiles {
        ClipFileThumbnail(path: files.first ?? "", missing: unavailable)
          .frame(
            width: ClipboardPickerModel.fileThumbnailSize.width, height: ClipboardPickerModel.fileThumbnailSize.height
          )
          .opacity(unavailable ? 0.5 : 1)
        ClipFilesLine(files: files, fontSize: 13, inverted: selected)
          .opacity(unavailable ? 0.55 : 1)
        if unavailable {
          Text(ClipboardContent.movedOrDeleted)
            .font(.system(size: 11))
            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
        }
      } else if item.isSecret {
        ClipSourceIcon(item: item, size: 16)
        if masked {
          MaskedLine(fontSize: 13, inverted: selected)
          // Dots alone don't say which secret it is: the app it came from does.
          if let app = item.sourceApp {
            Text(appName(app))
              .font(.system(size: 11.5))
              .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
              .lineLimit(1)
          }
        } else {
          ClipPreviewLine(item: item, fontSize: 13, inverted: selected, revealed: true)
        }
      } else {
        ClipSourceIcon(item: item, size: 16)
        ClipPreviewLine(item: item, fontSize: 13, inverted: selected)
      }
      Spacer(minLength: 4)
      if item.isSecret {
        // Clicks reach it through the panel (`ClipboardPickerModel.eye(at:)`), which handles the rows'.
        Image(systemName: masked ? "eye" : "eye.slash")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            eyeMoved($0)
          }
          .onDisappear { eyeMoved(nil) }
          .help(masked ? "Show (or hold ⌥)" : "Hide")
          .accessibilityLabel(masked ? "Show" : "Hide")
      }
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

/// The selected image or file, larger, for a small panel beside the picker: an image about 240 pt on
/// its long side, a file's QuickLook thumbnail in a square with its name, kind and size.
struct ClipboardImagePreview: View {
  let model: ClipboardPickerModel

  static let maxSide: CGFloat = 240
  static let padding: CGFloat = 8
  static let captionHeight: CGFloat = 19
  /// A file's thumbnail box, and the two caption lines under it.
  static let fileSide: CGFloat = 180
  static let fileCaptionHeight: CGFloat = 38

  var body: some View {
    if let item = model.previewItem {
      Group {
        if let image = item.image {
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
        } else if let files = item.files {
          filePreview(files, missing: model.missingFiles[item.id] ?? [])
        }
      }
      .padding(Self.padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
  }

  private func filePreview(_ files: [String], missing: Set<String>) -> some View {
    // The first file still there; if none is, the first one's kind.
    let shown = files.first { !missing.contains($0) } ?? files.first ?? ""
    let gone = files.allSatisfy(missing.contains)
    let title = ClipboardContent.filesTitle(files)
    return VStack(spacing: 0) {
      ClipFileThumbnail(path: shown, maxPixels: ClipboardThumbnails.previewPixels, missing: gone)
        .frame(width: Self.fileSide - 20, height: Self.fileSide - 20)
        .frame(width: Self.fileSide, height: Self.fileSide)
        .opacity(gone ? 0.5 : 1)
      VStack(spacing: 2) {
        (Text(title.name).fontWeight(.medium) + Text(title.more.map { "  \($0)" } ?? "").foregroundColor(.secondary))
          .font(.system(size: 11.5))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(ClipboardContent.filesDetails(files, missing: missing))
          .font(.system(size: 10.5).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: Self.fileSide, height: Self.fileCaptionHeight, alignment: .bottom)
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

  /// The panel's size for an item: an image's, or the square for files; nil for text.
  static func size(for item: ClipboardItem) -> CGSize? {
    if let image = item.image { return size(for: image) }
    guard item.isFiles else { return nil }
    return CGSize(width: fileSide + 2 * padding, height: fileSide + fileCaptionHeight + 2 * padding)
  }
}
