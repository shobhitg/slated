import AppKit
import SlatedCore
@_spi(Snapshots) import SlatedUI
import SwiftUI

/// The notch island in each presentation, over a desktop with a menu bar, on a display with a notch
/// (14-inch MacBook Pro: 185 × 32 pt) and on one without.
@MainActor func islandShots() -> [Shot] {
  let notch = IslandGeometry(notch: CGSize(width: 185, height: 32), menuBarHeight: 32)
  let plain = IslandGeometry(notch: nil, menuBarHeight: 24)
  let leftHalf = IslandFeedback(title: "Left half", app: "Safari", region: CGRect(x: 0, y: 0, width: 0.5, height: 1))
  let throwRight = IslandFeedback(
    title: "Throw to the screen on the right", app: "Xcode", symbol: "rectangle.portrait.and.arrow.right")

  func shot(_ name: String, _ geometry: IslandGeometry, height: CGFloat = 200, _ configure: @escaping @MainActor (IslandModel) -> Void)
    -> Shot
  {
    Shot(name: "island-\(name)", size: CGSize(width: 900, height: height)) {
      let model = IslandModel()
      model.geometry = geometry
      configure(model)
      return AnyView(IslandScene(model: model))
    }
  }

  return [
    shot("banner-notch", notch) { $0.show(.done(leftHalf)) },
    shot("banner-plain", plain) { $0.show(.done(throwRight)) },
    shot("failure-notch", notch) { $0.show(.failed("No focused window to move")) },
    shot("automation-notch", notch) { $0.automations = Array(PreviewServices.sampleAutomations().prefix(1)) },
    shot("automation-plain", plain) { $0.automations = PreviewServices.sampleAutomations() },
    shot("automation-hover-notch", notch, height: 300) { model in
      model.automations = PreviewServices.sampleAutomations()
      model.stopShortcut = KeyCombo(string: "hyper+esc")
      model.isHovering = true
    },
    shot("cheatsheet-notch", notch, height: 460) { model in
      model.cheatSheet = .hyper(sampleShortcuts, hyperModifiers: .hyper)
      model.highlightedItem = "hyper+a"
    },
    shot("cheatsheet-plain", plain, height: 460) { $0.cheatSheet = .hyper(sampleShortcuts, hyperModifiers: .hyper) },
    shot("modal-notch", notch) { $0.modal = modalSheet },
    shot("modal-expanded-notch", notch, height: 260) { model in
      model.modal = modalSheet
      model.modalExpanded = true
    },
  ]
}

/// The starter bindings plus a few of other kinds.
@MainActor private var sampleShortcuts: [CheatSheet.Shortcut] {
  StarterBindings.all.map { CheatSheet.Shortcut(keys: $0.keys, name: $0.name, action: $0.action) } + [
    CheatSheet.Shortcut(keys: KeyCombo(string: "hyper+t")!, action: .focusApp("Terminal")),
    CheatSheet.Shortcut(keys: KeyCombo(string: "hyper+m")!, action: .focusApp("Mail")),
    CheatSheet.Shortcut(
      keys: KeyCombo(string: "hyper+r")!, name: "Auto-click",
      action: .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle)),
    CheatSheet.Shortcut(keys: KeyCombo(string: "hyper+esc")!, name: "Stop automations", action: .stopAutomations),
    CheatSheet.Shortcut(keys: KeyCombo(string: "hyper+shift+s")!, summary: "JavaScript function"),
  ]
}

@MainActor private var modalSheet: CheatSheet {
  let modal = KeyCombo(string: "ctrl+e")!
  let keys: [(String, String)] = [("h", "left-half"), ("l", "right-half"), ("k", "top-half"), ("j", "bottom-half")]
  return .modal(
    modal,
    keys.map { key, name in
      CheatSheet.Shortcut(
        keys: KeyCombo(key: key, modifiers: []), modal: modal, name: name.replacingOccurrences(of: "-", with: " ").capitalized,
        action: .push(direction: key == "h" ? .left : key == "l" ? .right : key == "k" ? .up : .down, style: .barResize("screenSizeX/2"), screen: nil))
    })
}

/// A desktop: wallpaper, a menu bar and, on notch displays, the camera housing the island grows from.
private struct IslandScene: View {
  let model: IslandModel

  var body: some View {
    let band = model.geometry.notch?.height ?? model.geometry.menuBarHeight
    ZStack(alignment: .top) {
      LinearGradient(
        colors: [Color(red: 0.13, green: 0.17, blue: 0.38), Color(red: 0.5, green: 0.33, blue: 0.62), Color(red: 0.96, green: 0.62, blue: 0.46)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      Rectangle().fill(.black.opacity(0.22)).frame(height: band)
      HStack(spacing: 18) {
        Image(systemName: "apple.logo")
        Text("Finder").fontWeight(.bold)
        Text("File")
        Text("Edit")
        Text("View")
        Spacer()
        Image(systemName: "wifi")
        Image(systemName: "battery.75percent")
        Text("Wed Oct 22  9:41")
      }
      .font(.system(size: 13))
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .frame(height: band)
      if let notch = model.geometry.notch {
        UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
          .fill(.black)
          .frame(width: notch.width, height: notch.height)
      }
      SlatedUI.makeIslandView(model: model)
    }
  }
}
