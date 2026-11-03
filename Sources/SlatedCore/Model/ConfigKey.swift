import Foundation

/// Where a value lives in Slated's files: the file, and the path to the value as the file writes it.
///
/// Slated is driven by its two files, so the settings window shows the key under every setting
/// (`settings.json › island.cheatSheetDelay`) and copies it on request. Keys must be exactly what
/// the encoder writes: tests encode a configuration and look every registered key up in it.
public struct ConfigKey: Hashable, Sendable {
  public enum Component: Hashable, Sendable {
    case key(String)
    /// The item at an index of a list, with its natural key (a hotstring's trigger) when that names
    /// it uniquely. Copied paths always use the index; the name is for reading.
    case item(Int, name: String?)
  }

  public var file: ConfigFile
  public var components: [Component]

  public init(file: ConfigFile, components: [Component]) {
    self.file = file
    self.components = components
  }

  /// `ConfigKey(.settings, "island.cheatSheetDelay")`.
  public init(_ file: ConfigFile, _ dotted: String) {
    self.init(file: file, components: Self.keys(dotted))
  }

  /// This key with more keys after it: `"action.direction"`.
  public func appending(_ dotted: String) -> ConfigKey {
    ConfigKey(file: file, components: components + Self.keys(dotted))
  }

  /// The item at `index` of the list this key names.
  public func item(_ index: Int, name: String? = nil) -> ConfigKey {
    ConfigKey(file: file, components: components + [.item(index, name: name)])
  }

  /// What Copy Key copies, the path inside the file: `island.cheatSheetDelay`,
  /// `hotstrings[2].replacement` (items by index, so it's exact even where names repeat).
  public var path: String {
    components.reduce(into: "") { out, component in
      switch component {
      case .key(let key): out += out.isEmpty ? key : "." + key
      case .item(let index, _): out += "[\(index)]"
      }
    }
  }

  /// What the window shows: `settings.json › island.cheatSheetDelay`,
  /// `config.json › hotstrings › ";sig" › replacement`, or with an item that has no unique name,
  /// `config.json › bindings[3].keys`. secrets.json has one section, so a secret shows its name alone:
  /// `secrets.json › pw`.
  public var display: String {
    let isSecret = file == .secrets && components.count > 1 && components.first == .key("secrets")
    return file.rawValue + " › " + Self.describe(isSecret ? components.dropFirst() : components[...])
  }

  /// The part after `base` (an item), as a field of that item's editor shows it: `replacement`,
  /// `action.direction`, `action.operations[1].x`.
  public func relative(to base: ConfigKey) -> String {
    guard base.file == file, components.starts(with: base.components) else { return display }
    return Self.describe(components[base.components.count...])
  }

  /// The value at this key in `configuration`'s file, as the encoder writes it; nil when the file
  /// doesn't have it (an optional value that's unset, a Slate setting at its default).
  public func value(in configuration: SlatedConfiguration) -> JSONValue? {
    guard let data = try? configuration.encoded(file),
      var node = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    for component in components {
      switch (component, node) {
      case (.key(let key), .object(let members)):
        guard let next = members[key] else { return nil }
        node = next
      case (.item(let index, _), .array(let items)):
        guard items.indices.contains(index) else { return nil }
        node = items[index]
      default:
        return nil
      }
    }
    return node
  }

  /// What Copy Value as JSON copies: the value as the file has it, pretty-printed with sorted keys.
  /// Nothing from secrets.json: a sensitive hotstring's Copy Value copies its reference in config.json,
  /// never its text.
  public func valueText(in configuration: SlatedConfiguration) -> String? {
    guard file != .secrets, let value = value(in: configuration) else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// An item's name when it's not empty and no other item in the list has it, else nil (the item is
  /// then named by its index). `names` are the list's natural keys, in order.
  public static func itemName(_ names: [String], at index: Int) -> String? {
    guard names.indices.contains(index), !names[index].isEmpty else { return nil }
    return names.filter { $0 == names[index] }.count == 1 ? names[index] : nil
  }

  private static func keys(_ dotted: String) -> [Component] {
    dotted.split(separator: ".").map { .key(String($0)) }
  }

  /// Keys join with dots and unnamed items attach as `[3]`; a named item starts a new segment, ` › "name"`,
  /// so a path through a list reads like the list's own headings.
  private static func describe(_ components: ArraySlice<Component>) -> String {
    var out = ""
    var afterName = false
    for component in components {
      switch component {
      case .key(let key):
        out += out.isEmpty ? key : (afterName ? " › " : ".") + key
        afterName = false
      case .item(let index, nil):
        out += "[\(index)]"
        afterName = false
      case .item(_, let name?):
        out += (out.isEmpty ? "" : " › ") + quoted(name)
        afterName = true
      }
    }
    return out
  }

  /// `name` as a JSON string, so what's shown is what the file has.
  static func quoted(_ name: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? encoder.encode(name)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(name)\""
  }
}
