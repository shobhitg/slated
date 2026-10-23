import SlatedCore
import SwiftUI

/// Every reusable component on one page, for design review in UI snapshots.
///
/// The screen preview here uses a hand-computed frame, so the placed-window styling can be
/// reviewed before SlatedCore's frame math exists.
@_spi(Snapshots) public struct ComponentGallery: View {
  @State private var model = AppModel(services: PreviewServices())

  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      section("Brand & icons") {
        HStack(spacing: 18) {
          SlatedMark(size: 64, glow: true)
          SlatedMark(size: 32)
          ForEach(SettingsPane.allCases) { pane in
            IconTile(symbol: pane.symbol, tint: pane.tint, size: 28, gradient: pane == .overview)
          }
        }
      }
      section("Keycaps") {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 16) {
            KeyComboView(combo: KeyCombo(key: "left", modifiers: .hyper), size: .small)
            KeyComboView(combo: KeyCombo(key: "k", modifiers: [.control, .option, .command]), size: .small)
            KeyComboView(combo: KeyCombo(key: "space", modifiers: .meh))
            KeyComboView(
              combo: KeyCombo(key: "1"), modal: ModalKey(keys: KeyCombo(key: "f4", modifiers: [.control])))
            KeyComboView(combo: KeyCombo(key: "return", modifiers: .hyper))
          }
          HStack(alignment: .bottom, spacing: 10) {
            Keycap(label: "⇪", size: .large, caption: "caps lock")
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.bottom, 16)
            Keycap(label: "✦", size: .large, isAccent: true, caption: "hyper")
            Keycap(label: "⌃", size: .large, caption: "control")
            Keycap(label: "⌥", size: .large, caption: "option", isPressed: true)
            Keycap(label: "⇧", size: .hero)
          }
        }
      }
      section("Status") {
        HStack(spacing: 8) {
          StatusPill(text: "Active", color: Theme.positive)
          StatusPill(text: "Duplicate", color: Theme.caution, symbol: "exclamationmark.triangle.fill")
          StatusPill(text: "Failed", color: Theme.critical, symbol: "xmark.octagon.fill")
          StatusPill(text: "Off", color: Theme.neutral)
          StatusPill(text: "Read-only", color: Theme.neutral, symbol: "lock.fill")
          TriggerChip(trigger: ";shrug")
          StatusDot(color: Theme.positive)
          StatusDot(color: Theme.caution)
        }
      }
      section("Buttons") {
        HStack(spacing: 10) {
          Button("Grant Access") {}.buttonStyle(.gradientLarge)
          Button("Continue") {}.buttonStyle(.gradient)
          Button("Not Now") {}.buttonStyle(.softLarge)
          Button("Details") {}.buttonStyle(.soft)
          Button("Disabled") {}.buttonStyle(.gradient).disabled(true)
        }
      }
      section("Presets") {
        HStack(spacing: 8) {
          ForEach(WindowPresets.all.filter { $0.region != nil }) { preset in
            RegionGlyph(region: preset.region!, width: 30, height: 20, highlighted: preset.id == "left-half")
          }
        }
      }
      section("Screen preview (sample frame)") {
        let screens = PreviewData.screens
        let main = screens[0].visibleFrame
        let target = CGRect(x: main.minX, y: main.minY, width: main.width / 2, height: main.height)
        HStack(spacing: 16) {
          ScreenPreview(screens: screens, target: target, origin: PlacementCalculator.sampleFrame(screens: screens))
            .frame(height: 200)
            .padding(16)
            .background(PreviewStage())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          ZStack {
            ScreenPreview(screens: screens, dimmed: true)
            PreviewMessage(symbol: "eye.slash", title: "Preview unavailable")
          }
          .frame(height: 200)
          .padding(16)
          .background(PreviewStage())
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
      }
      section("Notices") {
        VStack(spacing: 8) {
          Notice(style: .warning, title: "Duplicate shortcut", message: "Another shortcut uses ✦M.")
          Notice(style: .error, title: "Couldn't register", message: "Another app already uses ✦Space.")
        }
      }
      section("Recorder") {
        HStack(spacing: 12) {
          ShortcutRecorder(combo: .constant(KeyCombo(key: "left", modifiers: .hyper)))
          ShortcutRecorder(combo: .constant(KeyCombo(key: "", modifiers: [])))
          KeyComboView(combo: KeyCombo(key: "mouse4"))
        }
      }
      section("Automation art") {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .bottom, spacing: 26) {
            MouseGlyph(lit: .left, height: 44)
            MouseGlyph(lit: .right, height: 44, held: true)
            MouseGlyph(lit: .middle, height: 44)
            ForEach(AutomationRecipes.all.prefix(6)) { recipe in
              RecipeArt(art: recipe.art, badge: RecipeCard.badge(for: recipe.action), scale: 0.8)
                .frame(width: 70, height: 56)
            }
          }
          HStack(spacing: 18) {
            RateRuler(interval: 0.1).frame(width: 220)
            RateRuler(interval: 0.05, jitter: 0.3).frame(width: 220)
            AutomationIndicatorPreview(stop: KeyCombo(key: "esc", modifiers: .hyper))
          }
          if let macro = AutomationRecipes.recipe("macro"), case .sequence(let steps) = macro.action {
            MacroTimeline(schedule: MacroSchedule(steps: steps.map(\.action))).frame(width: 420)
          }
          HStack(spacing: 8) {
            PresetChip(title: "50 ms", selected: false) {}
            PresetChip(title: "100 ms", selected: true) {}
            ArtBadge(text: "10/s")
            HoldBadge()
            LiveDot()
            Button {
            } label: {
              Label("Stop All", systemImage: "stop.fill")
            }
            .buttonStyle(StopButtonStyle())
          }
        }
      }
      section("Clipboard") {
        HStack(alignment: .top, spacing: 24) {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(PreviewData.clipboard(now: Date()).prefix(6)) { item in
              HStack(spacing: 8) {
                ClipSourceIcon(item: item, size: 20)
                ClipPreviewLine(item: item, fontSize: 12.5)
                Spacer(minLength: 4)
                ClipKindBadge(kind: ClipboardContent.kind(of: item.text))
              }
            }
          }
          .frame(width: 440)
          ClipboardStackArt(items: PreviewData.clipboard(now: Date()))
            .frame(width: 210, height: 100)
        }
      }
    }
    .padding(28)
    .frame(width: 900, alignment: .leading)
    .background(Theme.paneBackground)
    .environment(model)
    .tint(Theme.accent)
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
  }
}
