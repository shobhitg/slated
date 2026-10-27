import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI
import SwiftUI

/// Puts the notch island on screen: a transparent panel pinned to the top center of the display
/// you're working on, fed by the engine. Owns the island's timers: banner expiry, the cheat-sheet
/// delay and pointer tracking while automations run.
///
/// The panel is ordered out whenever the island has nothing to show, and parked (drawn collapsed)
/// for one run-loop turn when it comes back, so every appearance grows out of the notch.
final class IslandPresenter {
  let model = IslandModel()
  private(set) var settings = IslandSettings()
  /// Builds the Hyper cheat sheet when it's about to appear (bindings can change at any time).
  var hyperSheet: (() -> CheatSheet?)?
  /// The running automations, polled for live counts while the island shows them.
  var currentAutomations: (() -> [ActiveAutomation])?

  private var panel: NSPanel?
  private var screenNumber: UInt32?
  private var parked = false
  private var orderOutWork: DispatchWorkItem?
  private var cheatSheetWork: DispatchWorkItem?
  private var modalWork: DispatchWorkItem?
  private var highlightWork: DispatchWorkItem?
  private var trackingTimer: Timer?
  private var trackingTicks = 0

  private static let panelSize = CGSize(width: 900, height: 620)

  /// How long Caps Lock must be held (or a modal key stay active) before its shortcuts appear.
  var cheatSheetDelay: TimeInterval { min(max(settings.cheatSheetDelay, 0.15), 3) }

  func apply(_ settings: IslandSettings) {
    self.settings = settings
    if !settings.enabled {
      cheatSheetWork?.cancel()
      modalWork?.cancel()
      model.cheatSheet = nil
      model.modal = nil
      model.automations = []
    } else if !settings.cheatSheet {
      model.cheatSheet = nil
      model.modalExpanded = false
    }
    refresh()
  }

  // MARK: Banners

  /// Briefly shows what a shortcut did, on the display of `frame` (top-left global coordinates).
  func flash(_ feedback: IslandFeedback, near frame: CGRect?) {
    guard settings.enabled else { return }
    showBanner(.done(feedback), for: 1.3, near: frame)
  }

  /// Briefly shows why a shortcut didn't work.
  func flashFailure(_ message: String) {
    guard settings.enabled, settings.showFailures else { return }
    showBanner(.failed(message), for: 2.4, near: nil)
  }

  private func showBanner(_ banner: IslandModel.Banner, for seconds: TimeInterval, near frame: CGRect?) {
    let id = model.show(banner)
    refresh(near: frame)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self else { return }
      model.clearBanner(id: id)
      refresh()
    }
  }

  // MARK: Automations

  func automationsChanged(_ active: [ActiveAutomation], stopShortcut: KeyCombo?) {
    model.stopShortcut = stopShortcut
    model.automations = settings.enabled ? active : []
    if model.automations.isEmpty { model.isHovering = false }
    refresh()
  }

  // MARK: Cheat sheet

  func hyperEvent(_ event: KeyboardTap.HyperEvent) {
    switch event {
    case .pressed:
      guard settings.enabled, settings.cheatSheet else { return }
      cheatSheetWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.showCheatSheet() }
      cheatSheetWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + cheatSheetDelay, execute: work)
    case .used:
      // A quick Hyper combo: no cheat sheet. Once it's up, it stays while you try shortcuts.
      if model.cheatSheet == nil { cheatSheetWork?.cancel() }
    case .released:
      cheatSheetWork?.cancel()
      if model.cheatSheet != nil {
        model.cheatSheet = nil
        refresh()
      }
    }
  }

  private func showCheatSheet() {
    guard let sheet = hyperSheet?(), !sheet.isEmpty else {
      Log.record("island.cheat_sheet", level: .debug, ["items": 0])
      return
    }
    model.cheatSheet = sheet
    refresh(near: Accessibility.focusedWindow()?.frame)
    Log.record("island.cheat_sheet", level: .debug, ["items": sheet.items.count])
  }

  /// The Hyper key stopped working (tap stopped, Hyper turned off): don't leave the sheet up.
  func hyperUnavailable() {
    cheatSheetWork?.cancel()
    guard model.cheatSheet != nil else { return }
    model.cheatSheet = nil
    refresh()
  }

  /// A modal key was pressed (its shortcuts) or modal mode ended (nil).
  func modalChanged(_ sheet: CheatSheet?) {
    modalWork?.cancel()
    model.modalExpanded = false
    model.modal = settings.enabled ? sheet : nil
    if let sheet, settings.enabled, settings.cheatSheet, !sheet.isEmpty {
      let work = DispatchWorkItem { [weak self] in
        guard let self, model.modal != nil else { return }
        model.modalExpanded = true
        refresh()
      }
      modalWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + cheatSheetDelay, execute: work)
    }
    refresh(near: sheet == nil ? nil : Accessibility.focusedWindow()?.frame)
  }

  /// A shortcut fired: if the cheat sheet lists it, light it up for a moment.
  func shortcutFired(id: String) {
    let visible = model.cheatSheet ?? (model.modalExpanded ? model.modal : nil)
    guard let visible, visible.items.contains(where: { $0.id == id }) else { return }
    model.highlightedItem = id
    highlightWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.model.highlightedItem = nil }
    highlightWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
  }

  // MARK: Showing and hiding

  /// Brings the panel in line with the model: ordered out when there's nothing to show, otherwise on
  /// the display of `frame` (or the focused window, or the pointer), growing out of the notch.
  private func refresh(near frame: CGRect? = nil) {
    let wanted = model.presentation
    if wanted == .hidden && !parked {
      stopTracking()
      guard panel?.isVisible == true, orderOutWork == nil else { return }
      // Let the island shrink back into the notch first.
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        orderOutWork = nil
        if model.presentation == .hidden { panel?.orderOut(nil) }
      }
      orderOutWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
      return
    }
    orderOutWork?.cancel()
    orderOutWork = nil
    let visible = panel?.isVisible == true
    let screen = (visible && frame == nil ? currentScreen() : nil) ?? targetScreen(near: frame)
    if !visible || Self.number(of: screen) != screenNumber {
      reveal(on: screen)
    }
    updateTracking()
  }

  /// Positions the panel on `screen` and lets the island grow from the notch on the next turn.
  private func reveal(on screen: NSScreen) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    screenNumber = Self.number(of: screen)
    model.geometry = Self.geometry(of: screen)
    let size = CGSize(
      width: min(Self.panelSize.width, screen.frame.width), height: min(Self.panelSize.height, screen.frame.height))
    let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
    panel.setFrame(NSRect(origin: origin, size: size), display: false)
    // Draw collapsed for a moment, so the change animates from the notch.
    parked = true
    model.isParked = true
    panel.ignoresMouseEvents = true
    panel.orderFrontRegardless()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      parked = false
      model.isParked = false
      refresh()
    }
  }

  private func makePanel() -> NSPanel {
    let panel = IslandPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    let host = IslandHostingView(rootView: AnyView(SlatedUI.makeIslandView(model: model)))
    // The panel keeps its size; the island draws itself inside it.
    host.sizingOptions = []
    panel.contentView = host
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // Above the menu bar and its status items, below menus.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isMovable = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    return panel
  }

  // MARK: Pointer tracking

  /// While automations show, follow the pointer: hovering expands the island and lets it take
  /// clicks (the Stop button); elsewhere the panel stays click-through. Live counts refresh too.
  private func updateTracking() {
    guard model.isInteractive else {
      stopTracking()
      return
    }
    guard trackingTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.trackPointer() }
    }
    RunLoop.main.add(timer, forMode: .common)
    trackingTimer = timer
  }

  private func stopTracking() {
    trackingTimer?.invalidate()
    trackingTimer = nil
    panel?.ignoresMouseEvents = true
    if model.isHovering { model.isHovering = false }
  }

  private func trackPointer() {
    guard let screen = currentScreen(), model.isInteractive else {
      stopTracking()
      return
    }
    let size = model.size
    let island = NSRect(
      x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    let inside = island.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    if inside != model.isHovering {
      model.isHovering = inside
      panel?.ignoresMouseEvents = !inside
    }
    trackingTicks += 1
    if trackingTicks % 8 == 0, let current = currentAutomations?() {
      model.automations = current
    }
  }

  // MARK: Displays

  private func currentScreen() -> NSScreen? {
    NSScreen.screens.first { Self.number(of: $0) == screenNumber }
  }

  /// The display holding `frame` (top-left global coordinates), else the focused window's, else the
  /// pointer's.
  private func targetScreen(near frame: CGRect?) -> NSScreen {
    if let rect = frame ?? Accessibility.focusedWindow()?.frame {
      let appKit = Screens.appKitRect(fromTopLeft: rect)
      let best = NSScreen.screens.max { a, b in
        a.frame.intersection(appKit).area < b.frame.intersection(appKit).area
      }
      if let best, best.frame.intersects(appKit) { return best }
    }
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
  }

  static func geometry(of screen: NSScreen) -> IslandGeometry {
    let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
    var notch: CGSize?
    if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
    return IslandGeometry(notch: notch, menuBarHeight: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
  }

  private static func number(of screen: NSScreen?) -> UInt32? {
    (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

/// Never takes keyboard focus from the app you're in, even when its Stop button is clicked.
private final class IslandPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Clicks work on the first try, without activating Slated first. Not generic: a private generic
/// NSHostingView subclass crashes the Swift 6.2 optimizer in release builds.
private final class IslandHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
}
