import AppKit
import SlatedCore
import SwiftUI

/// Entry points for the app target.
///
/// Create one `AppModel` with your `AppServices` implementation and share it between all windows:
///
/// ```swift
/// let model = AppModel(services: liveServices)
///
/// // The main window: keep it around and re-show it.
/// let window = SlatedUI.makeMainWindow(model: model)
/// model.prepareToShowMainWindow(wasOpen: window.isVisible)  // Get Started or Overview
/// window.makeKeyAndOrderFront(nil); NSApp.activate()
/// ```
///
/// The `make…View` functions return the bare SwiftUI views for hosting yourself; the window helper
/// applies the window chrome these views are designed for. Call `model.saveNow()` before quitting so
/// a pending edit isn't lost.
@MainActor
public enum SlatedUI {
  public static let mainWindowSize = CGSize(width: 1080, height: 720)

  // MARK: Views

  /// The main window's content: a sidebar of panes (Get Started first during setup) and the selected
  /// pane. Size it at least 940 × 620.
  public static func makeMainView(model: AppModel) -> some View {
    SettingsView(model: model)
  }

  // MARK: AppKit hosting

  /// The ready-to-show main window, titled "Slated": transparent title bar with the sidebar running to
  /// the top, resizable, frame remembered between launches. Not released on close, so keep a
  /// reference and show it again.
  public static func makeMainWindow(model: AppModel) -> NSWindow {
    let controller = NSHostingController(rootView: makeMainView(model: model))
    controller.sizingOptions = [.minSize]
    // The window's title and toolbar stay as set here: no SwiftUI toolbar takes over the title bar.
    controller.sceneBridgingOptions = []
    let window = NSWindow(contentViewController: controller)
    window.title = "Slated"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.setContentSize(mainWindowSize)
    window.center()
    window.setFrameAutosaveName("SlatedSettingsWindow")
    return window
  }

  /// The clipboard picker's view, for snapshots; the app shows `makeClipboardPickerPanel`.
  public static func makeClipboardPickerView(model: ClipboardPickerModel) -> some View {
    ClipboardPickerView(model: model)
  }

  /// The clipboard picker in its panel, which handles its keys and clicks. Size it to `model.size`
  /// where you're typing and show it with `orderFrontRegardless()` and `makeKey()`, without activating
  /// Slated: the app you were in stays active, so the paste lands there. The model's `onClose` asks
  /// the app to close it. Call `model.resetForShowing(pointer:)` each time it opens.
  public static func makeClipboardPickerPanel(model: ClipboardPickerModel) -> NSPanel {
    ClipboardPickerPanel(model: model)
  }

  /// The picker's selected image, larger, for a small panel beside the picker that never takes focus.
  /// `model.onPreviewChange` says when to show, move or hide it.
  public static func makeClipboardImagePreview(model: ClipboardPickerModel) -> some View {
    ClipboardImagePreview(model: model)
  }

  /// The preview panel's size for the picker's selected image; nil when there's nothing to preview.
  public static func clipboardImagePreviewSize(model: ClipboardPickerModel) -> CGSize? {
    model.previewItem?.image.map(ClipboardImagePreview.size(for:))
  }

  /// The notch island. Host it in a borderless, transparent panel pinned to the top center of the
  /// display (the island draws itself top-aligned and centered, so the panel can be larger than it).
  public static func makeIslandView(model: IslandModel) -> some View {
    IslandView(model: model)
  }

  // MARK: Snapshots

  /// Decodes the history's images for rows and previews now: snapshots render in a single pass, before
  /// a lazy load would finish.
  @_spi(Snapshots) public static func preloadClipboardImages(services: any AppServices) {
    for image in services.clipboardItems().compactMap(\.image) {
      guard let url = services.clipboardImageURL(image) else { continue }
      ClipboardThumbnails.shared.preload(image, from: url, maxPixels: ClipboardThumbnails.rowPixels)
      ClipboardThumbnails.shared.preload(image, from: url, maxPixels: ClipboardThumbnails.previewPixels)
    }
  }

  /// The sheet a recipe card opens (normally in a popover, which snapshots can't capture).
  @_spi(Snapshots) public static func makeRecipeSheet(model: AppModel, recipeID: String) -> some View {
    Group {
      if let recipe = AutomationRecipes.recipe(recipeID) {
        RecipeSheet(recipe: recipe) {}
      }
    }
    .environment(model)
    .tint(Theme.accent)
    .background(Theme.cardBackground)
  }
}

@_spi(Snapshots) extension AppModel {
  /// Adds a recipe's binding, as its card would.
  public func addRecipe(id: String, keys: KeyCombo?) {
    if let recipe = AutomationRecipes.recipe(id) { addRecipe(recipe, keys: keys) }
  }
}
