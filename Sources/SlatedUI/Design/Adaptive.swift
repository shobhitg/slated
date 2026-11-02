import SwiftUI

/// How the main window adapts to its width, Apple-style, instead of clipping.
///
/// The window can be any width: a frame set through Accessibility (Slated's own ✦A/✦D, other window
/// managers) or by macOS tiling ignores the window's minimum size. Half of a 1512-pt MacBook screen
/// is 756 pt, half of a 1280-pt one 640. Every pane is laid out to work from `minimumSize` up; below
/// it the content keeps that size, anchored top-left, and scrolls (`MinimumSizeScroller`).
enum MainWindowLayout {
  /// The smallest size every pane is designed for, and the window's `contentMinSize`.
  static let minimumSize = CGSize(width: 640, height: 480)
  static let sidebarWidth: CGFloat = 224
  /// The icon-only sidebar.
  static let railWidth: CGFloat = 60
  /// Below this window width the sidebar collapses to icons (with tooltips).
  static let railBelowWindowWidth: CGFloat = 900
  /// Below this pane width headers put their subtitle on its own line and primary buttons get a short
  /// label ("New"), so nothing competes for the title row.
  static let compactHeaderBelowPaneWidth: CGFloat = 700
  /// A list + detail pane shows both side by side only when the detail keeps at least this much room;
  /// otherwise one at a time: the list, then the selected item with a back button.
  static let minimumDetailWidth: CGFloat = 460

  static func showsRail(windowWidth: CGFloat) -> Bool { windowWidth < railBelowWindowWidth }

  static func sidebarWidth(windowWidth: CGFloat) -> CGFloat {
    showsRail(windowWidth: windowWidth) ? railWidth : sidebarWidth
  }

  /// The width left for the selected pane, right of the sidebar and its hairline.
  static func paneWidth(windowWidth: CGFloat) -> CGFloat {
    max(windowWidth, minimumSize.width) - sidebarWidth(windowWidth: windowWidth) - 0.5
  }

  static func splitsListAndDetail(paneWidth: CGFloat, listWidth: CGFloat) -> Bool {
    paneWidth >= listWidth + 0.5 + minimumDetailWidth
  }
}

private struct PaneWidthKey: EnvironmentKey {
  static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
  /// The width of the area the selected pane has (the window minus the sidebar). Views adapt to it
  /// instead of measuring themselves, so a layout never flips back and forth while it settles.
  var paneWidth: CGFloat {
    get { self[PaneWidthKey.self] }
    set { self[PaneWidthKey.self] = newValue }
  }

  /// True where `PaneHeader` stacks its subtitle and primary buttons use short labels.
  var compactPane: Bool { paneWidth < MainWindowLayout.compactHeaderBelowPaneWidth }
}

/// Lays out `content` at the window's size, or at `MainWindowLayout.minimumSize` when the window is
/// smaller: then the content stays anchored top-left and scrolls, never centered and cut on both sides.
struct MinimumSizeScroller<Content: View>: View {
  @ViewBuilder var content: (CGSize) -> Content

  var body: some View {
    GeometryReader { proxy in
      let minimum = MainWindowLayout.minimumSize
      let size = proxy.size
      let axes: Axis.Set = [
        size.width < minimum.width - 0.5 ? .horizontal : [], size.height < minimum.height - 0.5 ? .vertical : [],
      ]
      if axes.isEmpty {
        content(size)
      } else {
        let fitted = CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
        ScrollView(axes) {
          content(fitted).frame(width: fitted.width, height: fitted.height)
        }
        .withoutScrollEdgeEffect()
      }
    }
  }
}

/// A list beside the selected item's detail when the pane is wide enough, or one at a time when it
/// isn't: the list, then (once something is selected) the detail under a back button that clears the
/// selection. The same in every list + detail pane (Windows, Hotstrings, Layouts).
struct ListDetail<List: View, Detail: View>: View {
  let listWidth: CGFloat
  /// Whether something is selected: in one column, that's what shows the detail.
  let hasSelection: Bool
  /// The back button's title, like "All Shortcuts".
  let backTitle: String
  let back: () -> Void
  @ViewBuilder var list: List
  @ViewBuilder var detail: Detail
  @Environment(\.paneWidth) private var paneWidth

  var body: some View {
    if MainWindowLayout.splitsListAndDetail(paneWidth: paneWidth, listWidth: listWidth) {
      HStack(spacing: 0) {
        list.frame(width: listWidth)
        Rectangle().fill(Theme.hairline).frame(width: 0.5)
        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else if hasSelection {
      VStack(spacing: 0) {
        BackBar(title: backTitle, action: back)
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      list.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// "‹ All Shortcuts" above a detail shown on its own. ⌘[ goes back too, as in Finder and Safari.
struct BackBar: View {
  let title: String
  let action: () -> Void

  var body: some View {
    HStack {
      Button(action: action) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
          Text(title).font(.system(size: 13))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back to the list (⌘[)")
      Spacer()
    }
    .padding(.horizontal, 16)
    .frame(height: 34)
    .background(Theme.paneBackground)
  }
}

/// A segmented control that becomes a pop-up menu when its segments don't fit the width it's given,
/// so a long option like "After a space or punctuation" is never cut mid-word.
struct FittingPicker<Value: Hashable, Options: View>: View {
  let title: String
  @Binding var selection: Value
  @ViewBuilder var options: Options

  init(_ title: String, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
    self.title = title
    self._selection = selection
    self.options = options()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      Picker(title, selection: $selection) { options }
        .pickerStyle(.segmented)
        .fixedSize()
      Picker(title, selection: $selection) { options }
        .pickerStyle(.menu)
        .fixedSize()
    }
    .labelsHidden()
  }
}

/// A pane header's main button ("New Hotstring"): the full title when there's room, "New" in a
/// compact pane, with the full title as its tooltip and accessibility label.
struct NewItemButton: View {
  let title: String
  var shortTitle = "New"
  let action: () -> Void
  @Environment(\.compactPane) private var compact

  var body: some View {
    Button(action: action) {
      Label(compact ? shortTitle : title, systemImage: "plus")
    }
    .buttonStyle(.gradient)
    .help(title)
    .accessibilityLabel(title)
  }
}
