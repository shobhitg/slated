import SwiftUI

/// The main window's root: a sidebar of panes and the selected pane.
///
/// A plain stack rather than a `NavigationSplitView`: on macOS 26 that sidebar is Liquid Glass, which
/// the window server draws, and it showed up empty in a real window (its rows still took clicks).
/// Ordinary views look the same on every macOS, and drawing the window offscreen shows what the
/// screen shows, so tests and `make snapshots` can check it.
struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    // Any width works: macOS tiling and Accessibility frames ignore the window's minimum size.
    MinimumSizeScroller { size in
      let rail = MainWindowLayout.showsRail(windowWidth: size.width)
      HStack(spacing: 0) {
        SettingsSidebar(rail: rail)
          .frame(width: MainWindowLayout.sidebarWidth(windowWidth: size.width))
          .background(Theme.sidebarBackground)
        Rectangle().fill(Theme.hairline).frame(width: 0.5)
        detail
          .environment(\.paneWidth, MainWindowLayout.paneWidth(windowWidth: size.width))
      }
    }
    .environment(model)
    .fileLinkHandler(model)
    .tint(Theme.accent)
  }

  private var detail: some View {
    VStack(spacing: 0) {
      if let error = model.loadError {
        LoadErrorBanner(message: error)
      } else if !model.conflict.isEmpty {
        ConflictBanner()
      }
      pane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Theme.paneBackground)
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        ToastView(toast: toast)
          .padding(.bottom, 18)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .id(toast.id)
      }
    }
    .animation(Theme.spring, value: model.toast)
  }

  @ViewBuilder private var pane: some View {
    switch model.selectedPane {
    case .getStarted: GetStartedPane()
    case .overview: OverviewPane()
    case .windows: WindowsPane()
    case .hotstrings: HotstringsPane()
    case .clipboard: ClipboardPane()
    case .automation: AutomationPane()
    case .keyboard: KeyboardPane()
    case .layouts: LayoutsPane()
    case .slate: SlateCompatibilityPane()
    case .general: GeneralPane()
    case .about: AboutPane()
    }
  }
}

/// Shown above every pane when config.json or settings.json can't be read: saving is paused so Slated never
/// overwrites a file the user is in the middle of editing.
private struct LoadErrorBanner: View {
  let message: String
  @Environment(AppModel.self) private var model

  var body: some View {
    Notice(
      style: .error, title: "Slated can't read \(model.unreadableFileName)",
      message:
        "\(message)\nSettings are read-only until the file is fixed, so nothing in it is lost. Slated loads it as soon as it can read it."
    ) {
      HStack(spacing: 8) {
        Button("Reveal in Finder") { model.revealConfigurationFile() }
        Button("Reload") { model.reload() }
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
    .padding(.horizontal, Theme.paneHorizontalPadding)
    .padding(.top, 16)
  }
}

/// The scrolling, centered column most panes use.
struct PaneScroll<Content: View>: View {
  var maxWidth: CGFloat = 780
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.sectionSpacing) { content }
        .padding(.horizontal, Theme.paneHorizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
  }
}
