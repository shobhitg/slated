import AppKit
import SlatedCore
import SlatedUI
import SwiftUI

/// A small pill at the top of the screen while any automation runs, saying how to stop it.
final class AutomationIndicator {
  private var panel: NSPanel?

  func update(active: [ActiveAutomation], stopShortcut: KeyCombo?, visible: Bool) {
    guard visible, !active.isEmpty else {
      panel?.orderOut(nil)
      return
    }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let title = active.count == 1 ? active[0].title : "\(active.count) automations running"
    let host = NSHostingView(rootView: IndicatorPill(title: title, stop: stopShortcut?.display()))
    host.frame.size = host.fittingSize
    panel.contentView = host
    let size = host.fittingSize
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let visibleFrame = screen.visibleFrame
    panel.setFrame(
      NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.maxY - size.height - 8, width: size.width, height: size.height),
      display: true)
    panel.orderFrontRegardless()
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }
}

private struct IndicatorPill: View {
  let title: String
  let stop: String?
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 9) {
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)
        .opacity(pulse ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
      Text(title)
        .font(.system(size: 12.5, weight: .semibold))
        .lineLimit(1)
      if let stop {
        Text("\(stop) to stop")
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.red.opacity(0.35)))
    .padding(6)
  }
}
