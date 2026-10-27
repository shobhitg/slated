import SlatedCore
import SwiftUI

// Drawings for automation: a mouse with a lit button, click ripples, held and repeated keys, a macro
// timeline and a rate ruler. All vector (Canvas and shapes), so they stay sharp at any size and in
// both appearances.

/// A mouse seen from above with one button lit in the accent gradient.
struct MouseGlyph: View {
  var lit: MouseButton?
  /// Height in points; the width follows a mouse's proportions.
  var height: CGFloat = 32
  /// Shows the lit button pressed down (held), with a soft inner glow.
  var held = false

  var body: some View {
    Canvas { context, size in
      let w = size.width
      let h = size.height
      let line = max(1, h / 30)
      let shell = Path(
        roundedRect: CGRect(x: line / 2, y: line / 2, width: w - line, height: h - line), cornerRadius: w * 0.47,
        style: .continuous)
      context.fill(
        shell,
        with: .linearGradient(
          Gradient(colors: [Theme.keycapTop, Theme.keycapBottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
      let split = h * 0.43
      let gradient = Gradient(colors: Theme.accentStops)
      if let lit, lit != .middle {
        let region =
          lit == .left
          ? CGRect(x: 0, y: 0, width: w / 2, height: split) : CGRect(x: w / 2, y: 0, width: w / 2, height: split)
        context.drawLayer { layer in
          layer.clip(to: shell)
          layer.fill(
            Path(region),
            with: .linearGradient(
              gradient, startPoint: region.origin, endPoint: CGPoint(x: region.maxX, y: region.maxY)))
          if held {
            // A darker band along the seam: the button is down.
            layer.fill(
              Path(CGRect(x: region.minX, y: split - h * 0.06, width: region.width, height: h * 0.06)),
              with: .color(.black.opacity(0.18)))
          }
        }
      }
      var seams = Path()
      seams.move(to: CGPoint(x: w / 2, y: line))
      seams.addLine(to: CGPoint(x: w / 2, y: split))
      seams.move(to: CGPoint(x: line, y: split))
      seams.addLine(to: CGPoint(x: w - line, y: split))
      context.stroke(seams, with: .color(Theme.keycapStroke), lineWidth: line)
      let wheelRect = CGRect(x: w / 2 - w * 0.085, y: h * 0.12, width: w * 0.17, height: h * 0.2)
      let wheel = Path(roundedRect: wheelRect, cornerRadius: w * 0.085, style: .continuous)
      context.fill(wheel, with: .color(Theme.keycapTop))
      if lit == .middle {
        context.fill(
          wheel,
          with: .linearGradient(gradient, startPoint: wheelRect.origin, endPoint: CGPoint(x: 0, y: wheelRect.maxY)))
      } else {
        context.fill(wheel, with: .color(Theme.keycapText.opacity(0.35)))
      }
      context.stroke(shell, with: .color(Theme.keycapStroke), lineWidth: line)
    }
    .frame(width: height * 0.64, height: height)
    .shadow(color: Theme.keycapEdge, radius: 0, y: max(1, height / 22))
    .accessibilityHidden(true)
  }
}

/// Arcs fanning out from a corner: "click, click, click".
struct ClickRipples: View {
  /// Which way the arcs open: towards the left (left button) or the right.
  var towardsLeft = true
  var rings = 3
  var size: CGFloat = 26

  var body: some View {
    Canvas { context, canvas in
      let center = CGPoint(x: towardsLeft ? canvas.width : 0, y: canvas.height)
      for ring in 0..<rings {
        let radius = canvas.width * (0.42 + 0.29 * Double(ring))
        var arc = Path()
        let start: Angle = towardsLeft ? .degrees(195) : .degrees(-15)
        let end: Angle = towardsLeft ? .degrees(255) : .degrees(-75)
        arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: !towardsLeft)
        context.stroke(
          arc,
          with: .linearGradient(
            Gradient(colors: Theme.accentStops), startPoint: .zero, endPoint: CGPoint(x: canvas.width, y: canvas.height)
          ),
          style: StrokeStyle(lineWidth: max(1.4, size / 14), lineCap: .round))
        context.opacity *= 0.62
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A small accent capsule with a short label ("10/s", "×50"), pinned to art.
struct ArtBadge: View {
  let text: String
  var size: CGFloat = 10

  var body: some View {
    Text(text)
      .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
      .foregroundStyle(.white)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, size * 0.55)
      .padding(.vertical, size * 0.18)
      .background(Theme.accentGradientHorizontal, in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
      .shadow(color: Theme.accent.opacity(0.35), radius: 3, y: 1)
  }
}

/// The illustration on a recipe card.
struct RecipeArt: View {
  let art: AutomationRecipe.Art
  var badge: String?
  /// Scales every part of the drawing.
  var scale: CGFloat = 1

  var body: some View {
    ZStack {
      content
    }
    .overlay(alignment: .bottomTrailing) {
      if let badge {
        ArtBadge(text: badge, size: 9.5 * scale).offset(x: 12 * scale, y: 2 * scale)
      }
    }
    .accessibilityHidden(true)
  }

  /// Keycaps come in fixed sizes (scaling them would misplace their badges).
  private var keycapSize: KeycapSize { scale < 0.7 ? .regular : .large }

  @ViewBuilder private var content: some View {
    switch art {
    case .mouse(let button, let repeating):
      MouseGlyph(lit: button, height: 42 * scale)
        .overlay(alignment: button == .right ? .topTrailing : .topLeading) {
          if repeating {
            ClickRipples(towardsLeft: button != .right, size: 20 * scale)
              .offset(x: (button == .right ? 15 : -15) * scale, y: -11 * scale)
          }
        }
    case .holdMouse(let button):
      MouseGlyph(lit: button, height: 42 * scale, held: true)
        .overlay(alignment: button == .right ? .topTrailing : .topLeading) {
          HoldBadge(size: 15 * scale).offset(x: (button == .right ? 9 : -9) * scale, y: -6 * scale)
        }
    case .holdKey(let key):
      Keycap(label: KeyNames.displayName(for: key), size: keycapSize, isPressed: true)
        .overlay(alignment: .topTrailing) {
          HoldBadge(size: 15 * scale).offset(x: 6 * scale, y: -5 * scale)
        }
    case .spamKey(let key):
      ZStack {
        ForEach(0..<3, id: \.self) { index in
          Keycap(label: KeyNames.displayName(for: key), size: keycapSize, isPressed: index == 0)
            .opacity(index == 0 ? 1 : 0.32 / Double(index))
            .offset(x: CGFloat(index) * 7 * scale, y: CGFloat(index) * -6 * scale)
            .zIndex(Double(-index))
        }
      }
    case .doubleClick:
      MouseGlyph(lit: .left, height: 42 * scale)
        .overlay(alignment: .topLeading) {
          ClickRipples(towardsLeft: true, rings: 2, size: 20 * scale).offset(x: -15 * scale, y: -11 * scale)
        }
    case .clickCount:
      MouseGlyph(lit: .left, height: 42 * scale)
        .overlay(alignment: .topLeading) {
          ClickRipples(towardsLeft: true, rings: 3, size: 20 * scale).offset(x: -15 * scale, y: -11 * scale)
        }
    case .macro:
      if let recipe = AutomationRecipes.recipe("macro"), case .sequence(let steps) = recipe.action {
        MacroTimeline(schedule: MacroSchedule(steps: steps.map(\.action)), compact: true)
          .frame(width: 124 * scale, height: 40 * scale)
      }
    }
  }
}

/// A small padlock-style "held" marker: a ring around a down arrow.
struct HoldBadge: View {
  var size: CGFloat = 15

  var body: some View {
    Image(systemName: "arrow.down.to.line.compact")
      .font(.system(size: size * 0.5, weight: .heavy))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Theme.accentGradient, in: Circle())
      .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.8))
      .shadow(color: Theme.accent.opacity(0.4), radius: 3, y: 1)
  }
}

// MARK: - Macro timeline

/// The steps of a macro on a time axis: held inputs as bars, clicks and key presses as dots.
struct MacroTimeline: View {
  let schedule: MacroSchedule
  /// Leaves out labels and the axis (recipe cards).
  var compact = false

  var body: some View {
    let lanes = schedule.lanes
    let duration = max(schedule.duration, 0.0001)
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
        HStack(spacing: compact ? 6 : 10) {
          laneLabel(lane)
            .frame(width: compact ? 20 : 34, alignment: .center)
          GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
              Capsule().fill(Theme.well).frame(height: compact ? 4 : 5)
              ForEach(Array(schedule.spans.enumerated()).filter { $0.element.input == lane }, id: \.offset) { _, span in
                let start = CGFloat(span.start / duration) * width
                let end = CGFloat((span.end ?? duration) / duration) * width
                SpanBar(open: span.end == nil, compact: compact)
                  .frame(width: max(compact ? 6 : 10, end - start), height: compact ? 10 : 14)
                  .offset(x: start)
              }
              ForEach(Array(schedule.instants.enumerated()).filter { $0.element.input == lane }, id: \.offset) {
                _, instant in
                let x = CGFloat(instant.time / duration) * width
                InstantDot(compact: compact)
                  .offset(x: min(max(x - (compact ? 5 : 7), 0), width - (compact ? 10 : 14)))
              }
            }
            .frame(maxHeight: .infinity)
          }
        }
        .frame(height: compact ? 12 : 18)
      }
      if !compact, schedule.duration > 0 {
        TimeAxis(duration: schedule.duration)
          .padding(.leading, 44)
      }
    }
  }

  @ViewBuilder private func laneLabel(_ lane: SyntheticInput?) -> some View {
    switch lane {
    case .mouse(let button)?:
      MouseGlyph(lit: button, height: compact ? 13 : 18)
    case .key(let combo)?:
      Keycap(label: KeyNames.displayName(for: combo.key), size: .small)
        .scaleEffect(compact ? 0.82 : 1)
    case nil:
      Image(systemName: "bolt.fill").font(.system(size: compact ? 8 : 10, weight: .bold)).foregroundStyle(.secondary)
    }
  }

  private struct SpanBar: View {
    let open: Bool
    let compact: Bool

    var body: some View {
      Capsule()
        .fill(
          open
            ? AnyShapeStyle(
              LinearGradient(
                colors: [Theme.accentStops[0], Theme.accentStops[1].opacity(0.15)], startPoint: .leading,
                endPoint: .trailing))
            : AnyShapeStyle(Theme.accentGradientHorizontal)
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Theme.accent.opacity(0.3), radius: compact ? 2 : 3, y: 1)
    }
  }

  private struct InstantDot: View {
    let compact: Bool

    var body: some View {
      Circle()
        .fill(Theme.accentGradient)
        .frame(width: compact ? 10 : 14, height: compact ? 10 : 14)
        .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: compact ? 1.5 : 2))
        .shadow(color: Theme.accent.opacity(0.35), radius: 2, y: 1)
    }
  }

  private struct TimeAxis: View {
    let duration: Double

    var body: some View {
      let step = duration <= 5 ? 1.0 : (duration / 4).rounded(.up)
      let marks = Array(stride(from: 0, through: duration + 0.0001, by: step))
      GeometryReader { proxy in
        ZStack(alignment: .topLeading) {
          ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
            let x = CGFloat(mark / duration) * proxy.size.width
            Text(ActionDescriber.seconds(mark).replacingOccurrences(of: "0 ms", with: "0"))
              .font(.system(size: 9.5, weight: .medium).monospacedDigit())
              .foregroundStyle(.tertiary)
              .fixedSize()
              .position(x: min(max(x, 8), proxy.size.width - 8), y: 6)
              .id(index)
          }
        }
      }
      .frame(height: 12)
    }
  }
}

// MARK: - Rate ruler

/// One second (or a few, for slow repeats) of an auto-repeat: a tick for every run, the first one
/// right away. Jittered timing shows as irregular ticks.
struct RateRuler: View {
  let interval: Double
  var jitter: Double = 0

  var body: some View {
    let span = interval <= 1 ? 1.0 : interval * 3
    let count = min(Int((span / max(interval, 0.01)).rounded(.down)) + 1, 101)
    VStack(alignment: .leading, spacing: 4) {
      Canvas { context, size in
        let midY = size.height / 2
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(baseline, with: .color(Theme.hairline), lineWidth: 1)
        let gradient = Gradient(colors: Theme.accentStops)
        let tickWidth: CGFloat = count > 40 ? 1 : (count > 15 ? 2 : 3)
        var time = 0.0
        for index in 0..<count {
          if index > 0 {
            // Each interval varies by a fixed pseudo-random amount, so the drawing is stable.
            time += interval * (1 + (Self.noise(index) * 2 - 1) * jitter)
          }
          guard time <= span + 0.0001 else { break }
          let x = CGFloat(time / span) * (size.width - tickWidth)
          let height = size.height * (index == 0 ? 1 : 0.72)
          let rect = CGRect(x: x, y: midY - height / 2, width: tickWidth, height: height)
          context.fill(
            Path(roundedRect: rect, cornerRadius: tickWidth / 2),
            with: .linearGradient(
              gradient, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: size.width, y: rect.maxY)))
        }
      }
      .frame(height: 20)
      HStack {
        Text("0").font(.system(size: 9.5, weight: .medium).monospacedDigit())
        Spacer()
        Text(ActionDescriber.seconds(span)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
      }
      .foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AutomationDescriber.rate(interval))
  }

  private static func noise(_ index: Int) -> Double {
    let x = sin(Double(index) * 12.9898 + 78.233) * 43758.5453
    return x - x.rounded(.down)
  }
}

// MARK: - Indicator preview

/// A miniature of what the app shows while automations run: the notch island, or, with the island
/// off, the "running" pill at the top of the screen.
struct AutomationIndicatorPreview: View {
  /// What "Show an indicator" does. The island is on by default.
  static let settingSubtitle =
    "Shows what's running and how to stop it: in the notch island, or in a small pill at the top of the screen "
    + "when the island is off."

  var title = "Auto-Click Left"
  var stop: KeyCombo?
  var isOn = true
  /// Drawn as the island (black, light text) rather than the pill.
  var inIsland = false
  @Environment(\.colorScheme) private var colorScheme

  /// The island's concave top corners.
  private let flare: CGFloat = 6

  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(Theme.critical).frame(width: 7, height: 7)
        .background(Circle().fill(Theme.critical.opacity(0.3)).frame(width: 12, height: 12))
      Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
      if let stop {
        Text("\(stop.display()) to stop").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.horizontal, inIsland ? 11 + flare : 11)
    .padding(.vertical, 6)
    .background {
      if inIsland {
        IslandShape(topRadius: flare, bottomRadius: 11).fill(Color.black)
      } else {
        Capsule().fill(Theme.cardBackground)
      }
    }
    .overlay {
      if !inIsland { Capsule().strokeBorder(Theme.critical.opacity(0.35)) }
    }
    .environment(\.colorScheme, inIsland ? .dark : colorScheme)
    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    .opacity(isOn ? 1 : 0.35)
    .scaleEffect(isOn ? 1 : 0.94)
    .animation(Theme.spring, value: isOn)
    .accessibilityHidden(true)
  }
}

/// A pulsing "live" dot.
struct LiveDot: View {
  var color: Color = Theme.critical
  var size: CGFloat = 8
  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .background(
        Circle()
          .fill(color.opacity(0.35))
          .frame(width: size * 2.1, height: size * 2.1)
          .scaleEffect(pulse ? 1 : 0.55)
          .opacity(pulse ? 0 : 1)
      )
      .onAppear {
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
      }
      .accessibilityHidden(true)
  }
}
