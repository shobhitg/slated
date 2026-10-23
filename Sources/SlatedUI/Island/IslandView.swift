import SlatedCore
import SwiftUI

/// The notch island: a black shape that grows out of the notch (or hangs from the top edge of a
/// display without one) and morphs between the model's presentations.
struct IslandView: View {
  let model: IslandModel

  var body: some View {
    let presentation = model.presentation
    let geometry = model.geometry
    let size = model.size
    let radii = IslandLayout.radii(for: presentation, geometry: geometry)
    ZStack(alignment: .top) {
      IslandShape(topRadius: radii.top, bottomRadius: radii.bottom)
        .fill(Color.black)
        .shadow(color: .black.opacity(presentation.isExpanded ? 0.45 : 0), radius: 24, y: 12)
      IslandContent(model: model, presentation: presentation)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radii.bottom, bottomTrailingRadius: radii.bottom))
    }
    .frame(width: size.width + 2 * radii.top, height: size.height)
    .opacity(presentation == .hidden && geometry.notch == nil ? 0 : 1)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: presentation)
    .animation(.spring(response: 0.42, dampingFraction: 0.8), value: size)
    .environment(\.colorScheme, .dark)
  }
}

/// A notch-like outline: square across the top edge with small concave flares at the top corners,
/// straight sides and rounded bottom corners.
struct IslandShape: Shape {
  var topRadius: CGFloat
  var bottomRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topRadius, bottomRadius) }
    set {
      topRadius = newValue.first
      bottomRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let t = min(topRadius, rect.width / 4, rect.height / 2)
    let b = max(0, min(bottomRadius, rect.height - t, (rect.width - 2 * t) / 2))
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
    path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

private struct IslandContent: View {
  let model: IslandModel
  let presentation: IslandPresentation

  var body: some View {
    ZStack(alignment: .top) {
      switch presentation {
      case .hidden:
        Color.clear
      case .banner(let banner):
        // The same banner again (a repeating shortcut) stays put; a different one crossfades.
        BannerView(banner: banner, geometry: model.geometry)
          .id(banner)
          .transition(.islandContent)
      case .automations(let expanded):
        if expanded {
          AutomationDetail(model: model).transition(.islandContent)
        } else {
          AutomationCompact(automations: model.automations, geometry: model.geometry).transition(.islandContent)
        }
      case .modal(let sheet, let expanded):
        if expanded {
          CheatSheetView(sheet: sheet, geometry: model.geometry, highlighted: model.highlightedItem)
            .transition(.islandContent)
        } else {
          ModalCompact(sheet: sheet, geometry: model.geometry).transition(.islandContent)
        }
      case .cheatSheet(let sheet):
        CheatSheetView(sheet: sheet, geometry: model.geometry, highlighted: model.highlightedItem)
          .transition(.islandContent)
      }
    }
  }
}

extension AnyTransition {
  /// Content fades in once the shape has started to grow, and out quickly before it shrinks.
  fileprivate static var islandContent: AnyTransition {
    .asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.easeOut(duration: 0.22).delay(0.1)),
      removal: .opacity.animation(.easeIn(duration: 0.1)))
  }
}

// MARK: - Banner

private struct BannerView: View {
  let banner: IslandModel.Banner
  let geometry: IslandGeometry

  var body: some View {
    VStack(spacing: 0) {
      if geometry.notch != nil { Color.clear.frame(height: geometry.band) }
      row
        .padding(.horizontal, IslandLayout.sheetPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private var row: some View {
    switch banner {
    case .done(let feedback):
      HStack(spacing: 10) {
        if let region = feedback.region {
          RegionGlyph(region: region, width: 26, height: 17)
        } else {
          Image(systemName: feedback.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accentGradient)
            .frame(width: 26)
        }
        HStack(spacing: 6) {
          Text(feedback.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
          if let app = feedback.app {
            Text("·").foregroundStyle(.white.opacity(0.35))
            Text(app)
              .font(.system(size: 13))
              .foregroundStyle(.white.opacity(0.6))
          }
        }
        .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
    case .failed(let message):
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.caution)
        Text(message)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

// MARK: - Automations

private struct AutomationCompact: View {
  let automations: [ActiveAutomation]
  let geometry: IslandGeometry

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 6) {
        PulsingDot()
        if automations.count > 1 {
          Text("\(automations.count)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
        } else {
          Image(systemName: automationSymbol(automations.first))
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
        }
      }
      .frame(width: IslandLayout.wing, height: geometry.band)
      Spacer(minLength: 0)
      if let oldest = automations.min(by: { $0.startedAt < $1.startedAt }) {
        ElapsedText(since: oldest.startedAt)
          .font(.system(size: 12, weight: .semibold).monospacedDigit())
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: IslandLayout.wing, height: geometry.band)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(automations.count == 1 ? "Automation running" : "\(automations.count) automations running")
  }
}

private struct AutomationDetail: View {
  let model: IslandModel

  var body: some View {
    let automations = model.automations.sorted { $0.startedAt < $1.startedAt }
    VStack(spacing: 0) {
      Color.clear.frame(height: IslandLayout.topInset(model.geometry))
      VStack(spacing: 0) {
        ForEach(automations.prefix(IslandLayout.maxAutomationRows)) { automation in
          AutomationRow(automation: automation)
            .frame(height: IslandLayout.automationRow)
        }
        if automations.count > IslandLayout.maxAutomationRows {
          Text("+\(automations.count - IslandLayout.maxAutomationRows) more")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: IslandLayout.automationRow)
        }
      }
      HStack(spacing: 10) {
        Button {
          model.onStop?()
        } label: {
          Label(automations.count > 1 ? "Stop All" : "Stop", systemImage: "stop.fill")
        }
        .buttonStyle(IslandStopButtonStyle())
        if let stop = model.stopShortcut {
          HStack(spacing: 6) {
            Text("or press")
              .font(.system(size: 11.5))
              .foregroundStyle(.white.opacity(0.5))
            KeyComboView(combo: stop, size: .small)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(height: IslandLayout.automationFooter)
    }
    .padding(.horizontal, IslandLayout.sheetPadding)
  }
}

private struct AutomationRow: View {
  let automation: ActiveAutomation

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle().fill(Theme.critical.opacity(0.2))
        Image(systemName: automationSymbol(automation))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.critical)
      }
      .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(automation.title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(detail(at: context.date))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private func detail(at date: Date) -> String {
    var parts: [String] = []
    if let trigger = automation.trigger {
      parts.append(trigger.hasPrefix("hotkey ") ? KeyCombo(string: String(trigger.dropFirst(7)))?.display() ?? trigger : trigger)
    }
    if !automation.id.hasPrefix("hold:") {
      parts.append(automation.repetitions == 1 ? "1 time" : "\(automation.repetitions) times")
    }
    parts.append(ElapsedText.format(date.timeIntervalSince(automation.startedAt)))
    return parts.joined(separator: " · ")
  }
}

private func automationSymbol(_ automation: ActiveAutomation?) -> String {
  guard let automation else { return "repeat" }
  if automation.id.hasPrefix("hold:mouse") { return "computermouse.fill" }
  if automation.id.hasPrefix("hold:") { return "keyboard.fill" }
  return automation.title.contains("Click") ? "cursorarrow.click.2" : "repeat"
}

/// "0:42", "12:05", "1:02:03", updated every second.
private struct ElapsedText: View {
  let since: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(Self.format(context.date.timeIntervalSince(since)))
    }
  }

  static func format(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (h, m, s) = (total / 3600, (total / 60) % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}

private struct PulsingDot: View {
  @State private var pulsing = false

  var body: some View {
    ZStack {
      Circle()
        .fill(Theme.critical.opacity(0.45))
        .frame(width: 13, height: 13)
        .scaleEffect(pulsing ? 1 : 0.4)
        .opacity(pulsing ? 0 : 1)
      Circle()
        .fill(Theme.critical)
        .frame(width: 7, height: 7)
    }
    .frame(width: 13, height: 13)
    .onAppear {
      withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulsing = true }
    }
  }
}

private struct IslandStopButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Theme.critical.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
      .contentShape(Capsule())
  }
}

// MARK: - Modal keys and the cheat sheet

private struct ModalCompact: View {
  let sheet: CheatSheet
  let geometry: IslandGeometry

  var body: some View {
    HStack(spacing: 0) {
      Image(systemName: "command.square.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.accentGradient)
        .frame(width: IslandLayout.wing, height: geometry.band)
      Spacer(minLength: 0)
      Text(sheet.title)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: IslandLayout.wing, height: geometry.band)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Modal key \(sheet.title) is active")
  }
}

private struct CheatSheetView: View {
  let sheet: CheatSheet
  let geometry: IslandGeometry
  let highlighted: String?

  var body: some View {
    let columns = IslandLayout.sheetGrid(sheet).columns
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: IslandLayout.topInset(geometry))
      header.frame(height: IslandLayout.sheetHeader)
      ForEach(sheet.sections) { section in
        if sheet.sections.count > 1 {
          Text(section.title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.4))
            .frame(height: IslandLayout.sheetSectionHeader, alignment: .bottomLeading)
            .padding(.bottom, 2)
            .frame(height: IslandLayout.sheetSectionHeader)
        }
        let rows = stride(from: 0, to: section.items.count, by: columns).map {
          Array(section.items[$0..<min($0 + columns, section.items.count)])
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          HStack(spacing: 0) {
            ForEach(row) { item in
              CheatSheetCell(item: item, isHighlighted: item.id == highlighted)
                .frame(width: IslandLayout.sheetColumnWidth, height: IslandLayout.sheetRow, alignment: .leading)
            }
          }
        }
      }
    }
    .padding(.horizontal, IslandLayout.sheetPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(spacing: 8) {
      if sheet.isHyper {
        Keycap(label: "✦", size: .small, isAccent: true)
        Text("Hyper")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
      } else {
        Keycap(label: sheet.title, size: .small, isAccent: true)
        Text("then")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
      }
      Text(sheet.items.count == 1 ? "1 shortcut" : "\(sheet.items.count) shortcuts")
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.45))
      Spacer(minLength: 8)
      Text(sheet.isHyper ? "Release Caps Lock to close" : "Press a key, or esc to cancel")
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.4))
    }
  }
}

private struct CheatSheetCell: View {
  let item: CheatSheet.Item
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: 8) {
      Keycap(label: item.label, size: .small)
        .frame(width: 30)
      Group {
        if let region = item.region {
          RegionGlyph(region: region, width: 21, height: 14)
        } else {
          Image(systemName: item.symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.accentGradient)
            .frame(width: 21, height: 14)
        }
      }
      Text(item.title)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.86))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 6)
    }
    .padding(.leading, 4)
    .frame(maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Theme.accent.opacity(isHighlighted ? 0.35 : 0))
        .padding(.trailing, 6)
    }
    .animation(.easeOut(duration: 0.18), value: isHighlighted)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(item.label): \(item.title)")
  }
}
