import AppKit
import SlatedCore
import SlatedSystem

/// Performs actions: window geometry, focus, app visibility, shell commands, text, layouts,
/// snapshots and undo. Geometry is computed by `FrameCalculator` (pure, tested) and applied here.
final class ActionRunner {
  var settings = SlateSettings()
  var layouts: [String: Layout] = [:]
  /// Something happened worth showing ("Left half · Safari").
  var onPerformed: ((String) -> Void)?
  var onError: ((String) -> Void)?
  /// Slate's `relaunch`: reload all configuration.
  var onRelaunch: (() -> Void)?
  /// Shows window hints or the grid (implemented by the overlay controller).
  var overlays: OverlayPresenting?

  private var undoStack: [(window: AXWindow, frame: CGRect)] = []
  private var chains: [String: (next: Int, window: AXWindow?)] = [:]
  private let snapshots = SnapshotStore()

  /// Runs `action`. Window actions target `window`, or the focused window when nil.
  /// `chainKey` identifies a binding so each `chain` cycles independently.
  @discardableResult
  func perform(_ action: Action, on window: AXWindow? = nil, label: String? = nil, chainKey: String? = nil) -> Bool {
    switch action {
    case .move, .resize, .push, .nudge, .throwWindow, .corner:
      return applyGeometry(action, to: window ?? Accessibility.focusedWindow(), label: label)

    case .chain(let actions):
      guard !actions.isEmpty else { return false }
      let key = chainKey ?? String(action.hashValue)
      let target = window ?? Accessibility.focusedWindow()
      var state = chains[key] ?? (0, nil)
      // Start over when the chain is used on a different window.
      if let last = state.window, let target, !last.isSame(as: target) { state.next = 0 }
      let index = state.next % actions.count
      chains[key] = (index + 1, target)
      return perform(actions[index], on: target, label: label, chainKey: "\(key)/\(index)")

    case .sequence(let steps):
      // `|` steps act on whatever is focused when they run; `>` steps (keepWindow) act on the window
      // that was focused when their run began.
      var anchor = window ?? Accessibility.focusedWindow()
      var ok = true
      for (i, step) in steps.enumerated() {
        if i > 0 && !step.keepWindow { anchor = Accessibility.focusedWindow() }
        ok = perform(step.action, on: anchor, chainKey: chainKey.map { "\($0)/\(i)" }) && ok
      }
      return ok

    case .layout(let name):
      guard let layout = layouts[name] else { return fail("No layout named \"\(name)\"") }
      applyLayout(layout)
      report("Layout \(name)")
      return true

    case .focus(let direction):
      guard let current = window ?? Accessibility.focusedWindow() else { return fail("No focused window") }
      guard let next = direction == .behind ? windowBehind(current) : nearestWindow(direction, of: current) else {
        return false
      }
      next.focus()
      report(label ?? "Focus \(direction.rawValue)", next)
      return true

    case .focusApp(let name):
      guard let app = runningApp(named: name) else { return fail("\(name) isn't running") }
      app.unhide()
      app.activate()
      report(label ?? "Focus \(name)")
      return true

    case .hide(let selector):
      apps(selector).forEach { $0.hide() }
      return true
    case .show(let selector):
      apps(selector).forEach { $0.unhide() }
      return true
    case .toggle(let selector):
      for app in apps(selector) { _ = app.isHidden ? app.unhide() : app.hide() }
      return true

    case .shell(let command, let wait, let path):
      return runShell(command, wait: wait, path: path)

    case .undo:
      guard let last = undoStack.popLast() else { return false }
      last.window.setFrame(last.frame)
      report("Undo", last.window)
      return true

    case .relaunch:
      onRelaunch?()
      return true

    case .snapshot(let name, let save, let stack):
      snapshots.take(name, save: save, stack: stack)
      report("Snapshot \(name)")
      return true
    case .activateSnapshot(let name, let delete):
      guard snapshots.activate(name, delete: delete) else { return fail("No snapshot named \"\(name)\"") }
      report("Snapshot \(name)")
      return true
    case .deleteSnapshot(let name, let all):
      snapshots.delete(name, all: all)
      return true

    case .hint(let characters):
      guard let overlays else { return fail("Window hints aren't available yet") }
      overlays.showHints(characters: characters ?? settings.windowHintsCharacters)
      return true
    case .grid(let padding, let grids):
      guard let overlays else { return fail("The grid isn't available yet") }
      overlays.showGrid(padding: padding ?? 2, grids: grids, window: window ?? Accessibility.focusedWindow())
      return true

    case .switchApp:
      return fail("Slate's app switcher (switch) isn't supported yet")

    case .insertText(let text, let method):
      TextInjector.shared.insert(text: text, method: method)
      return true
    case .openURL(let string):
      guard let url = URL(string: string) ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
        return fail("Invalid URL \(string)")
      }
      NSWorkspace.shared.open(url)
      return true
    case .keystroke(let combo):
      guard let code = KeyCodes.code(for: combo.key) else { return fail("Unknown key \(combo.key)") }
      TextInjector.shared.press(keyCode: code, modifiers: combo.modifiers)
      return true
    }
  }

  // MARK: Geometry

  private func applyGeometry(_ action: Action, to window: AXWindow?, label: String?, record: Bool = true) -> Bool {
    guard let window else { return fail("No focused window to move") }
    guard let frame = window.frame else { return fail("Couldn't read the window's position") }
    do {
      let context = WindowContext(frame: frame, screens: Screens.current(), settings: settings)
      let target = try FrameCalculator.targetFrame(for: action, in: context).integral
      if record { pushUndo(window, frame) }
      guard window.setFrame(target) else { return fail("\(window.app?.localizedName ?? "The app") didn't allow moving that window") }
      report(label ?? SlateSyntax.format(action), window)
      return true
    } catch {
      return fail("\(error)")
    }
  }

  private func pushUndo(_ window: AXWindow, _ frame: CGRect) {
    undoStack.append((window, frame))
    let limit = max(settings.undoMaxStackSize, 1)
    if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
  }

  // MARK: Layouts (Slate's `layout`)

  private func applyLayout(_ layout: Layout) {
    for action in layout.before { perform(action) }
    for entry in layout.apps {
      guard let app = runningApp(named: entry.app), !entry.operations.isEmpty else { continue }
      let windows = ordered(Accessibility.windows(of: app.processIdentifier).filter { $0.isStandard && !$0.isMinimized }, entry.options)
      for (i, window) in windows.enumerated() {
        let index: Int
        if i < entry.operations.count {
          index = i
        } else if entry.options.repeat {
          index = i % entry.operations.count
        } else if entry.options.repeatLast {
          index = entry.operations.count - 1
        } else {
          break
        }
        let action = entry.operations[index]
        let ok = action.isWindowGeometry ? applyGeometry(action, to: window, label: nil, record: false) : perform(action, on: window)
        if !ok && !entry.options.ignoreFail { break }
      }
    }
    for action in layout.after { perform(action) }
    if settings.bool("layoutFocusOnActivate", default: false), let first = layout.apps.first {
      runningApp(named: first.app)?.activate()
    }
  }

  private func ordered(_ windows: [AXWindow], _ options: LayoutAppOptions) -> [AXWindow] {
    var result = windows
    if options.sortTitle { result.sort { ($0.title ?? "") < ($1.title ?? "") } }
    if let titles = options.titleOrder {
      let rank = { (w: AXWindow) in titles.firstIndex(of: w.title ?? "") ?? Int.max }
      result = result.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
    if let patterns = options.titleOrderRegex {
      let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
      var remaining = result
      var picked: [AXWindow] = []
      for regex in regexes {
        if let i = remaining.firstIndex(where: { w in
          let title = w.title ?? ""
          return regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
        }) {
          picked.append(remaining.remove(at: i))
        }
      }
      result = picked + remaining
    }
    if options.mainFirst, let i = result.firstIndex(where: \.isMain) { result.insert(result.remove(at: i), at: 0) }
    if options.mainLast, let i = result.firstIndex(where: \.isMain) { result.append(result.remove(at: i)) }
    return result
  }

  // MARK: Focus

  /// The nearest window whose center lies in `direction`, preferring windows that overlap the
  /// current one along the other axis (Slate's focusCheckWidth idea).
  private func nearestWindow(_ direction: FocusDirection, of current: AXWindow) -> AXWindow? {
    guard let from = current.frame else { return nil }
    var best: (window: AXWindow, score: CGFloat)?
    for candidate in Accessibility.allWindows() where !candidate.isSame(as: current) {
      guard let to = candidate.frame else { continue }
      let dx = to.midX - from.midX
      let dy = to.midY - from.midY
      let (along, across, overlaps): (CGFloat, CGFloat, Bool)
      switch direction {
      case .right: (along, across, overlaps) = (dx, abs(dy), to.minY < from.maxY && to.maxY > from.minY)
      case .left: (along, across, overlaps) = (-dx, abs(dy), to.minY < from.maxY && to.maxY > from.minY)
      case .down: (along, across, overlaps) = (dy, abs(dx), to.minX < from.maxX && to.maxX > from.minX)
      case .up: (along, across, overlaps) = (-dy, abs(dx), to.minX < from.maxX && to.maxX > from.minX)
      case .behind: continue
      }
      guard along > 1 else { continue }
      var score = along + across * 2
      if !overlaps { score += 10_000 }
      if settings.focusPreferSameApp && candidate.pid == current.pid { score -= 1 }
      if score < (best?.score ?? .infinity) { best = (candidate, score) }
    }
    return best?.window
  }

  /// The next window down in the global stacking order.
  private func windowBehind(_ current: AXWindow) -> AXWindow? {
    guard let frame = current.frame,
      let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let stack: [(pid: pid_t, bounds: CGRect)] = info.compactMap { entry in
      guard (entry[kCGWindowLayer as String] as? Int) == 0,
        let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
        let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { return nil }
      return (pid, bounds)
    }
    guard let index = stack.firstIndex(where: { $0.pid == current.pid && $0.bounds.equalTo(frame) }) else { return nil }
    for entry in stack.dropFirst(index + 1) {
      if let match = Accessibility.windows(of: entry.pid).first(where: { $0.frame?.equalTo(entry.bounds) == true && $0.isStandard }) {
        return match
      }
    }
    return nil
  }

  // MARK: Apps, shell

  private func runningApp(named name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.localizedName == name || $0.bundleIdentifier == name }
  }

  private func apps(_ selector: AppSelector) -> [NSRunningApplication] {
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    switch selector {
    case .current: return NSWorkspace.shared.frontmostApplication.map { [$0] } ?? []
    case .all: return regular
    case .allBut(let name): return regular.filter { $0.localizedName != name }
    case .apps(let names): return regular.filter { names.contains($0.localizedName ?? "") }
    }
  }

  private func runShell(_ command: String, wait: Bool, path: String?) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: path ?? "~").expandingTildeInPath)
    do {
      try process.run()
      if wait { process.waitUntilExit() }
      return true
    } catch {
      return fail("Couldn't run \(command): \(error.localizedDescription)")
    }
  }

  // MARK: Reporting

  private func report(_ what: String, _ window: AXWindow? = nil) {
    let app = window?.app?.localizedName
    onPerformed?(app.map { "\(what) · \($0)" } ?? what)
  }

  @discardableResult
  private func fail(_ message: String) -> Bool {
    log.error("\(message, privacy: .public)")
    onError?(message)
    return false
  }
}

/// Window hints and the grid overlay.
protocol OverlayPresenting: AnyObject {
  func showHints(characters: String)
  func showGrid(padding: Int, grids: [GridScreen], window: AXWindow?)
}
