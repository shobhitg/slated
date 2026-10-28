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
/// // Settings (menu bar "Open Settings…"): keep the window around and re-show it.
/// let settings = SlatedUI.makeSettingsWindow(model: model)
/// model.selectedPane = .windows           // optional: open a specific pane
/// settings.makeKeyAndOrderFront(nil); NSApp.activate()
///
/// // First run.
/// let onboarding = SlatedUI.makeOnboardingWindow(model: model) { onboarding.close() }
///
/// // Menu bar popover.
/// popover.contentViewController = SlatedUI.makeMenuBarViewController(
///   model: model, actions: MenuBarActions(openSettings: showSettings, quit: { NSApp.terminate(nil) }))
/// popover.behavior = .transient
/// ```
///
/// The `make…View` functions return the bare SwiftUI views for hosting yourself; the window and
/// view-controller helpers apply the window chrome these views are designed for. Call
/// `model.saveNow()` before quitting so a pending edit isn't lost.
@MainActor
public enum SlatedUI {
  public static let settingsWindowSize = CGSize(width: 1080, height: 720)
  public static let onboardingWindowSize = CGSize(width: 680, height: 600)
  public static let menuBarWidth: CGFloat = 340

  // MARK: Views

  /// The settings window's content: a `NavigationSplitView` of panes. Size it at least 940 × 620.
  public static func makeSettingsView(model: AppModel) -> some View {
    SettingsView(model: model)
  }

  /// The first-run flow. `onFinish` runs when the user completes or skips it; close the window
  /// there. `openSettings`, if given, adds an "Open Settings" button to the last step.
  public static func makeOnboardingView(
    model: AppModel, openSettings: (() -> Void)? = nil, onFinish: @escaping () -> Void
  ) -> some View {
    OnboardingView(model: model, openSettings: openSettings, onFinish: onFinish)
  }

  /// The menu bar popover's content: status, switches, last action and errors, app commands.
  public static func makeMenuBarView(model: AppModel, actions: MenuBarActions) -> some View {
    MenuBarView(model: model, actions: actions)
  }

  // MARK: AppKit hosting

  /// A ready-to-show settings window: transparent title bar with the sidebar running to the top
  /// (as in System Settings), resizable, frame remembered between launches. Not released on close,
  /// so keep a reference and show it again.
  public static func makeSettingsWindow(model: AppModel) -> NSWindow {
    let controller = NSHostingController(rootView: makeSettingsView(model: model))
    controller.sizingOptions = [.minSize]
    let window = NSWindow(contentViewController: controller)
    window.title = "Slated Settings"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.setContentSize(settingsWindowSize)
    window.center()
    window.setFrameAutosaveName("SlatedSettingsWindow")
    return window
  }

  /// A fixed-size, centered onboarding window with no visible title bar.
  public static func makeOnboardingWindow(
    model: AppModel, openSettings: (() -> Void)? = nil, onFinish: @escaping () -> Void
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: onboardingWindowSize),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(
      rootView: makeOnboardingView(model: model, openSettings: openSettings, onFinish: onFinish))
    window.setContentSize(onboardingWindowSize)
    window.title = "Welcome to Slated"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }

  /// The menu bar popover's content view controller. Its preferred content size follows the
  /// SwiftUI content, so the popover resizes as rows appear and disappear.
  public static func makeMenuBarViewController(model: AppModel, actions: MenuBarActions) -> NSViewController {
    let controller = NSHostingController(rootView: makeMenuBarView(model: model, actions: actions))
    controller.sizingOptions = [.preferredContentSize]
    return controller
  }

  /// The clipboard picker. Host it in a small floating panel of `model.size` where you're typing; the
  /// model's `onClose` asks the app to close it. Call `model.resetForShowing(pointer:)` each time it
  /// opens.
  public static func makeClipboardPickerView(model: ClipboardPickerModel) -> some View {
    ClipboardPickerView(model: model)
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

  @_spi(Snapshots) public static func makeSettingsView(model: AppModel, layout: SettingsLayout) -> some View {
    SettingsView(model: model, layout: layout)
  }

  @_spi(Snapshots) public static func makeOnboardingView(model: AppModel, step: OnboardingStep) -> some View {
    OnboardingView(model: model, initialStep: step, openSettings: {}, onFinish: {})
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

/// What the menu bar popover asks the app to do.
public struct MenuBarActions {
  /// Show (and activate) the settings window.
  public var openSettings: @MainActor () -> Void
  /// Quit Slated. Call `model.saveNow()` first.
  public var quit: @MainActor () -> Void
  /// Show the onboarding flow again (offered when Accessibility permission is missing). Optional.
  public var showOnboarding: (@MainActor () -> Void)?
  /// Close the popover, before the clipboard switcher opens in its own panel. Optional.
  public var dismiss: (@MainActor () -> Void)?

  public init(
    openSettings: @escaping @MainActor () -> Void, quit: @escaping @MainActor () -> Void,
    showOnboarding: (@MainActor () -> Void)? = nil, dismiss: (@MainActor () -> Void)? = nil
  ) {
    self.openSettings = openSettings
    self.quit = quit
    self.showOnboarding = showOnboarding
    self.dismiss = dismiss
  }
}
