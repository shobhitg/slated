import AppKit
import SlatedCore
import SwiftUI

// Wherever the window names one of Slated's files (config.json, settings.json, config.v1.json,
// ~/.config/slated, ~/.slate.js, ~/.slate), the name opens it. Sentences go through `LinkedText`, whose
// links are `slated-file://…` URLs that `fileLinkHandler()` (on the window's root) routes to
// `AppModel.openLink`; a key's file name under a setting is a `FileNameLink`. The shared components
// (PaneHeader, SettingsCard, SettingRow, Notice…) show their text as `LinkedText`, and
// FileLinkCoverageTests fails when a pane shows a file's name some other way.

/// Text whose file names are links that open them. Without a file name in it, it's plain `Text`.
struct LinkedText: View {
  let text: String
  /// The one file the whole text links to (a file's full path), instead of the names found in it.
  var link: FileLink?
  /// Underlines the links, for text already in the accent color ("Updated from config.json").
  var underline = false
  @Environment(AppModel.self) private var model: AppModel?

  init(_ text: String, underline: Bool = false) {
    self.text = text
    self.underline = underline
  }

  /// `text` as one link to `link`, e.g. the file's full path.
  init(_ text: String, link: FileLink) {
    self.text = text
    self.link = link
  }

  var body: some View {
    let segments = link.map { [FileLinkSegment.link(text, $0)] } ?? FileLink.segments(in: text, linked: isLinked)
    let shown = Text(Self.attributed(segments, underline: underline))
    if let link {
      shown.help("Open \(link.name)")
    } else {
      shown
    }
  }

  /// A Slate file is a link while Slated finds a Slate config (`FileLink.isLinked`).
  private func isLinked(_ link: FileLink) -> Bool {
    link.isLinked(slateFound: model.map { $0.slateConfigPath != nil } ?? true)
  }

  static func attributed(_ segments: [FileLinkSegment], underline: Bool = false) -> AttributedString {
    var out = AttributedString()
    for segment in segments {
      var run = AttributedString(segment.text)
      if case .link(_, let link) = segment {
        run.link = link.url
        if underline { run.swiftUI.underlineStyle = .single }
      }
      out += run
    }
    return out
  }
}

/// A file's name as a small link, for the start of a key's caption: the accent color, underlined under
/// the pointer, the pointing hand, a tooltip.
struct FileNameLink: View {
  let link: FileLink
  @Environment(AppModel.self) private var model: AppModel?
  @State private var hovering = false

  var body: some View {
    Button {
      model?.openFileLink(link)
    } label: {
      Text(verbatim: link.name)
        .underline(hovering)
        .foregroundStyle(Theme.accent)
    }
    .buttonStyle(.plain)
    .modifier(LinkPointer(hovering: $hovering))
    .help("Open \(link.name)")
    .accessibilityLabel("Open \(link.name)")
    .accessibilityAddTraits(.isLink)
  }
}

/// The pointing hand over a link, and whether the pointer is there.
private struct LinkPointer: ViewModifier {
  @Binding var hovering: Bool

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    } else {
      content.onHover { inside in
        hovering = inside
        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
      }
    }
  }
}

extension View {
  /// Routes the file links in this view's text to the model; any other link opens as usual.
  func fileLinkHandler(_ model: AppModel) -> some View {
    environment(\.openURL, OpenURLAction { url in model.openLink(url) ? .handled : .systemAction })
  }
}
