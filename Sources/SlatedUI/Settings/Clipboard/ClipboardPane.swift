import SlatedCore
import SwiftUI

/// Clipboard history (Keyboard Maestro's clipboard switcher): the switch and shortcut, how much to
/// keep, privacy, and the history itself to search and browse, with pin, copy and delete. The picker
/// (⇧⌘V) only picks.
struct ClipboardPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    let enabled = model.configuration.clipboard.enabled
    PaneScroll {
      PaneHeader(
        pane: .clipboard, subtitle: "Everything you copy, a keystroke away: search it, pin favorites, paste it again.")
      ClipboardHero()
      Group {
        ShortcutCard()
        HistoryCard()
        PrivacyCard()
      }
      .disabled(!enabled)
      .opacity(enabled ? 1 : 0.55)
      RecentItems()
    }
  }
}

// MARK: - Hero

private struct ClipboardHero: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let settings = model.configuration.clipboard
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Clipboard History").font(.system(size: 16, weight: .semibold))
        let pill = status
        StatusPill(text: pill.text, color: pill.color)
        Spacer(minLength: 12)
        Toggle(
          "Clipboard history",
          isOn: Binding(get: { settings.enabled }, set: { model.configuration.clipboard.enabled = $0 })
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }
      heroBody(settings)
    }
    .padding(18)
    .background {
      ZStack {
        Theme.cardBackground
        RadialGradient(
          colors: [SettingsPane.clipboard.tint.opacity(0.13), .clear], center: .topTrailing, startRadius: 10,
          endRadius: 360)
        RadialGradient(
          colors: [Theme.accentStops[0].opacity(0.08), .clear], center: .bottomLeading, startRadius: 10, endRadius: 280)
      }
      .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardStroke))
    .shadow(color: Theme.cardShadow, radius: 10, y: 3)
  }

  private func heroBody(_ settings: ClipboardSettings) -> some View {
    HStack(alignment: .center, spacing: 18) {
      VStack(alignment: .leading, spacing: 10) {
        if settings.enabled, let shortcut = settings.shortcut {
          HStack(spacing: 8) {
            Text("Press").font(.system(size: 13)).foregroundStyle(.secondary)
            KeyComboView(combo: shortcut)
            Text("in any app to bring it back.").font(.system(size: 13)).foregroundStyle(.secondary)
          }
        }
        Text(summary)
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          if settings.enabled {
            Button {
              model.showClipboardHistory()
            } label: {
              Label("Open Picker", systemImage: "list.clipboard")
            }
            .buttonStyle(.gradient)
          } else {
            Button("Turn On Clipboard History") { model.configuration.clipboard.enabled = true }
              .buttonStyle(.gradient)
          }
          Text(statsLine).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
      }
      Spacer(minLength: 8)
      ClipboardStackArt(items: model.clipboardItems)
        .frame(width: 210, height: 96)
        .padding(.trailing, 4)
    }
  }

  private var status: (text: String, color: Color) {
    if !model.configuration.clipboard.enabled { return ("Off", Theme.neutral) }
    if model.runtimeStatus.paused { return ("Paused", Theme.neutral) }
    if case .failed? = model.status(ofBuiltIn: .clipboard) { return ("Shortcut failed", Theme.critical) }
    return ("Recording", Theme.positive)
  }

  private var summary: String {
    let settings = model.configuration.clipboard
    guard settings.enabled else {
      return
        "Turn it on and Slated remembers the last \(settings.maxItems) things you copy, text and images, ready to paste again. Passwords are never recorded."
    }
    let paste =
      settings.pasteAfterSelecting
      ? "It opens where you're typing: type to filter, then press Return to paste."
      : "It opens where you're typing: type to filter, then press Return to copy, ready to paste yourself."
    return settings.shortcut == nil
      ? "There's no shortcut, so open it from the menu bar or with a binding that runs Clipboard History. \(paste)"
      : paste
  }

  private var statsLine: String {
    let count = model.clipboardItems.count
    let pinned = model.pinnedClipboardCount
    guard count > 0 else { return "Nothing saved yet" }
    return "\(count) item\(count == 1 ? "" : "s")" + (pinned > 0 ? " · \(pinned) pinned" : "")
  }
}

// MARK: - Settings cards

private struct ShortcutCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    SettingsCard(title: "Shortcut", symbol: "command") {
      VStack(alignment: .leading, spacing: 0) {
        SettingRow(
          title: "Open the picker",
          subtitle: "Works in any app. Clear it to open the picker only from the menu bar.",
          symbol: "list.clipboard", tint: SettingsPane.clipboard.tint
        ) {
          OptionalShortcutRecorder(
            combo: $model.configuration.clipboard.shortcut, defaultCombo: ClipboardSettings().shortcut)
        }
        let conflicts = model.otherUses(ofBuiltIn: .clipboard)
        if !conflicts.isEmpty {
          Label(
            "Also used by \(ListFormatter.localizedString(byJoining: conflicts)), which wins over this shortcut.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 11.5))
          .foregroundStyle(Theme.caution)
          .padding(.leading, 54)
          .padding(.trailing, 16)
          .padding(.bottom, 10)
        } else if case .failed(let reason)? = model.status(ofBuiltIn: .clipboard) {
          Label(reason, systemImage: "xmark.octagon.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.critical)
            .padding(.leading, 54)
            .padding(.trailing, 16)
            .padding(.bottom, 10)
        }
      }
      CardDivider(inset: 54)
      ToggleRow(
        title: "Paste after picking",
        subtitle:
          "Pick an item and Slated pastes it into the app you were using. Off: it's only copied, ready for you to paste.",
        symbol: "doc.on.clipboard.fill", tint: Color(hex: 0x2F7BF5),
        isOn: $model.configuration.clipboard.pasteAfterSelecting)
    }
  }
}

private struct HistoryCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    SettingsCard(
      title: "History", symbol: "clock.arrow.circlepath",
      footer: "Pinned items are never forgotten, pushed out or cleared."
    ) {
      SettingRow(
        title: "Remember up to", subtitle: "The oldest items make room for new ones.",
        symbol: "square.stack.3d.up.fill",
        tint: Color(hex: 0x7A5AF8)
      ) {
        Picker("Remember up to", selection: $model.configuration.clipboard.maxItems) {
          ForEach(choices(ClipboardOptions.maxItems, current: model.configuration.clipboard.maxItems), id: \.self) {
            Text("\($0) items").tag($0)
          }
        }
        .labelsHidden()
        .fixedSize()
      }
      CardDivider(inset: 54)
      SettingRow(
        title: "Forget items after", subtitle: "Older items are removed, so history doesn't pile up.",
        symbol: "calendar.badge.clock", tint: Color(hex: 0xF08A24)
      ) {
        Picker("Forget items after", selection: $model.configuration.clipboard.retentionDays) {
          ForEach(retentionChoices, id: \.self) { Text(ClipboardOptions.retentionTitle($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
      }
      CardDivider(inset: 54)
      ToggleRow(
        title: "Keep history across restarts",
        subtitle: "Saved only on this Mac, in a file only you can read. Off: history starts fresh each launch.",
        symbol: "internaldrive.fill", tint: Color(hex: 0x14A89A), isOn: $model.configuration.clipboard.persist)
    }
  }

  private func choices(_ values: [Int], current: Int) -> [Int] {
    values.contains(current) ? values : (values + [current]).sorted()
  }

  /// Days, with "forever" (0) last.
  private var retentionChoices: [Int] {
    let current = model.configuration.clipboard.retentionDays
    let days = ClipboardOptions.retentionDays.filter { $0 > 0 }
    let withCurrent = current > 0 && !days.contains(current) ? (days + [current]).sorted() : days
    return withCurrent + [0]
  }
}

private struct PrivacyCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    SettingsCard(
      title: "Privacy", symbol: "lock.shield",
      footer: "Clipboard history never leaves this Mac. Slated's log notes that something was copied, never what."
    ) {
      ToggleRow(
        title: "Ignore passwords and other concealed items",
        subtitle:
          "Password managers mark what they copy as concealed or temporary. Slated skips those, so passwords never land in your history.",
        symbol: "key.fill", tint: Color(hex: 0x30B85A), isOn: $model.configuration.clipboard.ignoreConcealed)
      CardDivider(inset: 54)
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          IconTile(symbol: "hand.raised.fill", tint: Color(hex: 0xE5484D), size: 26)
          VStack(alignment: .leading, spacing: 2) {
            Text("Never record copies from").font(.system(size: 13, weight: .medium))
            Text("Anything copied in these apps stays out of your history.")
              .font(.system(size: 11.5)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if !model.missingDefaultExclusions.isEmpty {
            Button("Restore Defaults") { model.restoreDefaultExclusions() }
              .buttonStyle(.link)
              .font(.system(size: 12))
              .help("Add back the password managers Slated excludes by default")
          }
        }
        BundleChips(
          ids: $model.configuration.clipboard.excludedApps,
          emptyText: "Every app's copies are recorded. Add the apps you'd rather keep out.",
          sections: exclusionSections, addTitle: "Add App"
        )
        .padding(.leading, 38)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  private var exclusionSections: [AppChoiceSection] {
    let candidates = model.excludableApps
    return [
      AppChoiceSection(title: "Password Managers", apps: candidates.filter(\.isDefault)),
      AppChoiceSection(title: "Running Apps", apps: candidates.filter { !$0.isDefault }),
    ]
  }
}

// MARK: - Recent items

private struct RecentItems: View {
  @Environment(AppModel.self) private var model
  @State private var confirmClear = false
  @State private var search = ""
  @State private var showAll = false

  private let limit = 8

  var body: some View {
    let items = model.clipboardItems
    // A search lists every match, pinned first; without one, the newest few until "Show All".
    let matches = search.isEmpty ? items : ClipboardHistory(items: items).search(search)
    let shown = search.isEmpty && !showAll ? Array(items.prefix(limit)) : matches
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Items", symbol: "clock") {
        if !items.isEmpty {
          HStack(spacing: 8) {
            Button("Clear History…") { confirmClear = true }
              .buttonStyle(.soft)
              .controlSize(.small)
              .disabled(items.count == model.pinnedClipboardCount)
              .help("Remove everything except pinned items")
            Button {
              model.showClipboardHistory()
            } label: {
              Label("Open Picker", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.soft)
            .controlSize(.small)
            .disabled(!model.configuration.clipboard.enabled)
          }
        }
      }
      if items.isEmpty {
        EmptyStateView(
          symbol: "list.clipboard", title: "Nothing copied yet",
          message: emptyMessage
        )
        .cardStyle(padding: 0)
      } else {
        VStack(spacing: 0) {
          if items.count > limit {
            SearchField(prompt: "Search clipboard history", text: $search)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
            CardDivider(inset: 0)
          }
          if shown.isEmpty {
            Text("No text matches “\(search)”. Images aren't searched.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 18)
          }
          LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
              if index > 0 { CardDivider(inset: 56) }
              RecentClipRow(item: item)
            }
          }
          if search.isEmpty && items.count > limit {
            CardDivider(inset: 0)
            Button(showAll ? "Show Fewer" : "Show All \(items.count) Items") {
              withAnimation(Theme.snappy) { showAll.toggle() }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
          }
        }
        .cardStyle(padding: 0)
      }
    }
    .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
      Button("Clear History", role: .destructive) { model.clearClipboardHistory() }
    } message: {
      Text(
        model.pinnedClipboardCount > 0
          ? "Everything except your \(model.pinnedClipboardCount) pinned item\(model.pinnedClipboardCount == 1 ? "" : "s") is removed."
          : "Everything in the history is removed.")
    }
  }

  private var emptyMessage: String {
    let settings = model.configuration.clipboard
    guard settings.enabled else { return "Clipboard history is off, so nothing is being recorded." }
    let open = settings.shortcut.map { " Press \($0.display()) to bring it back." } ?? ""
    return "Copy some text or an image in any app and it shows up here.\(open)"
  }
}

/// One item: source app (an image's thumbnail), preview, age, and pin, copy and delete.
private struct RecentClipRow: View {
  let item: ClipboardItem
  @Environment(AppModel.self) private var model
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 12) {
      if let image = item.image {
        ClipThumbnail(image: image, url: model.clipboardImageURL(image))
          .frame(width: 26, height: 26)
      } else {
        ClipSourceIcon(item: item, size: 26)
      }
      VStack(alignment: .leading, spacing: 2) {
        ClipPreviewLine(item: item, fontSize: 12.5)
        HStack(spacing: 5) {
          if item.pinned {
            Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .bold))
              .foregroundStyle(SettingsPane.clipboard.tint)
          }
          Text(meta).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      HStack(spacing: 2) {
        iconButton(
          item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin" : "Pin",
          tint: item.pinned ? SettingsPane.clipboard.tint : nil
        ) {
          model.togglePinClipboardItem(item.id)
        }
        iconButton("doc.on.doc", help: "Copy to the clipboard") { model.copyClipboardItem(item.id) }
        iconButton("trash", help: "Delete from history") { model.deleteClipboardItem(item.id) }
      }
      .opacity(hovering ? 1 : 0.7)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(hovering ? Theme.well : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .contextMenu {
      Button("Copy") { model.copyClipboardItem(item.id) }
      Button(item.pinned ? "Unpin" : "Pin") { model.togglePinClipboardItem(item.id) }
      Divider()
      Button("Delete", role: .destructive) { model.deleteClipboardItem(item.id) }
    }
  }

  private var meta: String {
    var parts: [String] = []
    if let app = item.sourceApp { parts.append(model.appName(bundleID: app)) }
    parts.append(item.copiedAt.formatted(.relative(presentation: .named)))
    if let image = item.image {
      parts.append(Int64(image.bytes).formatted(.byteCount(style: .file)))
      return parts.joined(separator: " · ")
    }
    let kind = ClipboardContent.kind(of: item.text)
    if kind != .text { parts.append(kind.title) }
    let stats = ClipboardContent.stats(item.text)
    if stats.lines > 1 { parts.append("\(stats.lines) lines") }
    return parts.joined(separator: " · ")
  }

  private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .frame(width: 26, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(help)
    .accessibilityLabel(help)
  }
}
