import SlatedCore

/// Describes what changed between two configurations, for the event log ("binding added: Left half
/// (hyper+a)"). Settings-window edits show up in the log this way.
enum ConfigDiff {
  static func changes(from old: SlatedConfiguration, to new: SlatedConfiguration) -> [String] {
    var changes: [String] = []
    changes += diff(old.bindings, new.bindings, noun: "binding") {
      "\($0.name ?? SlateSyntax.format($0.action.redactedForLog)) (\($0.keys.string))"
    }
    changes += diff(old.hotstrings, new.hotstrings, noun: "hotstring") { $0.trigger }
    if old.keyboard != new.keyboard {
      let k = new.keyboard
      changes.append(
        "keyboard: capsLock \(k.capsLock.rawValue), alone \(k.capsLockAlone.rawValue), "
          + "modifiers \(k.hyperModifiers.symbols), "
          + "keyRepeat \(k.keyRepeat.map { "\($0.delay)/\($0.interval) ms" } ?? "system")")
    }
    if old.general != new.general {
      let g = new.general
      changes.append(
        "general: launchAtLogin \(g.launchAtLogin), showActionHUD \(g.showActionHUD), "
          + "hotstringsEnabled \(g.hotstringsEnabled), showStatusIcon \(g.showStatusIcon)")
    }
    if old.clipboard != new.clipboard {
      let c = new.clipboard
      changes.append(
        "clipboard: enabled \(c.enabled), shortcut \(c.shortcut?.string ?? "none"), maxItems \(c.maxItems), "
          + "persist \(c.persist), retentionDays \(c.retentionDays), excludedApps \(c.excludedApps.count)")
    }
    if old.automation != new.automation {
      let a = new.automation
      changes.append(
        "automation: stopShortcut \(a.stopShortcut?.string ?? "none"), stopOnAppSwitch \(a.stopOnAppSwitch), "
          + "maxRunMinutes \(a.maxRunMinutes), showIndicator \(a.showIndicator)")
    }
    if old.island != new.island {
      let i = new.island
      changes.append(
        "island: enabled \(i.enabled), cheatSheet \(i.cheatSheet), cheatSheetDelay \(i.cheatSheetDelay), "
          + "showFailures \(i.showFailures)")
    }
    for key in Set(old.windows.values.keys).union(new.windows.values.keys).sorted()
    where old.windows[key] != new.windows[key] {
      changes.append("setting \(key): \(new.windows[key]?.stringValue ?? "removed")")
    }
    if old.layouts != new.layouts { changes.append("layouts: \(new.layouts.map(\.name).joined(separator: ", "))") }
    if old.defaults != new.defaults { changes.append("display defaults: \(new.defaults.count)") }
    return changes
  }

  private static func diff<T: Identifiable & Equatable>(
    _ old: [T], _ new: [T], noun: String, describe: (T) -> String
  ) -> [String] {
    let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var result: [String] = []
    for item in new {
      if let previous = oldByID[item.id] {
        if previous != item { result.append("\(noun) changed: \(describe(item))") }
      } else {
        result.append("\(noun) added: \(describe(item))")
      }
    }
    for item in old where newByID[item.id] == nil { result.append("\(noun) removed: \(describe(item))") }
    return result
  }
}
