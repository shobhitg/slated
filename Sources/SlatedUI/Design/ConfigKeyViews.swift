import SlatedCore
import SwiftUI

// Every setting shows its key in the files under its label (`settings.json › island.enabled`), and a
// right-click on it offers Copy Key, Copy Value as JSON and Open the file. Settings name their key
// (`SettingRow(configKey:)`); an item editor's fields name theirs relative to the item
// (`LabeledField(key: "trigger")`), which `configKeyItem` and `configKeyBase` put in the environment.
// ConfigKeyCoverageTests fails when a control in a settings pane names no key.

/// A key in small monospace secondary text, as shown under a setting's label. A whole key starts with
/// its file's name, which is a link that opens the file (`FileNameLink`); the rest is plain text.
struct ConfigKeyCaption: View {
  let text: String
  /// The file the key is in; nil for a field's key, which is relative to its item (`trigger`).
  var file: ConfigFile?

  /// A field's key, relative to its item.
  init(text: String) {
    self.text = text
  }

  /// A whole key: `settings.json › island.enabled`, its file's name a link.
  init(key: ConfigKey) {
    text = key.display
    file = key.file
  }

  /// The caption's parts: the file its start links to (nil when it names none) and the text after it.
  static func parts(of text: String, file: ConfigFile?) -> (link: FileLink?, rest: String) {
    guard let file, text.hasPrefix(file.rawValue) else { return (nil, text) }
    return (FileLink(file), String(text.dropFirst(file.rawValue.count)))
  }

  var body: some View {
    let parts = Self.parts(of: text, file: file)
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      if let link = parts.link {
        FileNameLink(link: link)
          .fixedSize()
          .layoutPriority(1)
      }
      Text(verbatim: parts.rest)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityLabel("Config key: \(text)")
    }
    .font(.system(size: 10.5, design: .monospaced))
    .foregroundStyle(.secondary)
  }
}

/// Where an item editor's fields are: the item (whose key the editor's header shows) and the key
/// fields are under right now (the item, its action, an operation in a chain).
struct ConfigKeyScope: Equatable {
  var item: ConfigKey
  var base: ConfigKey
}

private struct ConfigKeyScopeKey: EnvironmentKey {
  static let defaultValue: ConfigKeyScope? = nil
}

extension EnvironmentValues {
  var configKeyScope: ConfigKeyScope? {
    get { self[ConfigKeyScopeKey.self] }
    set { self[ConfigKeyScopeKey.self] = newValue }
  }
}

extension View {
  /// Fields inside are keyed under `item` (a shortcut, a hotstring, a layout); nil when it isn't in the
  /// file (a recipe not added yet), which leaves them without keys.
  func configKeyItem(_ item: ConfigKey?) -> some View {
    environment(\.configKeyScope, item.map { ConfigKeyScope(item: $0, base: $0) })
  }

  /// Fields inside are keyed under `path` from the current base (`"action"`, `"landscape"`), then the
  /// item at `index` of that list when there is one (`"operations"`, index 1).
  func configKeyBase(_ path: String, index: Int? = nil) -> some View {
    transformEnvironment(\.configKeyScope) { scope in
      guard var updated = scope else { return }
      updated.base = updated.base.appending(path)
      if let index { updated.base = updated.base.item(index) }
      scope = updated
    }
  }

  /// Fields inside are keyed under what `transform` makes of the current base, for paths that go on
  /// after an index (`steps[2].action`).
  func configKeyBase(_ transform: @escaping (ConfigKey) -> ConfigKey) -> some View {
    transformEnvironment(\.configKeyScope) { scope in
      guard var updated = scope else { return }
      updated.base = transform(updated.base)
      scope = updated
    }
  }

  /// Right-click: Copy Key, Copy Value as JSON, Open the file. Nothing when `key` is nil.
  func configKeyMenu(_ key: ConfigKey?) -> some View {
    modifier(ConfigKeyMenu(key: key))
  }

  /// A field of the item being edited, at `path` under the current base: its key under it and the
  /// key's menu. Nothing when `path` is nil or the editor's item isn't in the file.
  func configField(_ path: String?) -> some View {
    modifier(ConfigField(path: path))
  }
}

private struct ConfigKeyMenu: ViewModifier {
  let key: ConfigKey?
  @Environment(AppModel.self) private var model: AppModel?

  func body(content: Content) -> some View {
    if let key, let model {
      content
        .contentShape(Rectangle())
        .contextMenu {
          Button("Copy Key") { model.copyConfigKey(key) }
          Button("Copy Value as JSON") { model.copyConfigValue(key) }
          Divider()
          Button("Open \(key.file.rawValue)") { model.openConfigFile(key.file) }
        }
    } else {
      content
    }
  }
}

private struct ConfigField: ViewModifier {
  let path: String?

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      content
      ConfigFieldCaption(path: path)
    }
    .configFieldMenu(path)
  }
}

/// The key of the field at `path` under the current base, relative to the item, when keys are shown.
struct ConfigFieldCaption: View {
  let path: String?
  @Environment(\.configKeyScope) private var scope
  @Environment(AppModel.self) private var model: AppModel?

  var body: some View {
    if let path, let scope, model?.showsConfigKeys == true {
      ConfigKeyCaption(text: scope.base.appending(path).relative(to: scope.item))
    }
  }
}

private struct ConfigFieldMenu: ViewModifier {
  let path: String?
  @Environment(\.configKeyScope) private var scope

  func body(content: Content) -> some View {
    content.configKeyMenu(path.flatMap { path in scope.map { $0.base.appending(path) } })
  }
}

extension View {
  /// The menu of the field at `path` under the current base, for fields that place their caption
  /// themselves (`ConfigFieldCaption`).
  func configFieldMenu(_ path: String?) -> some View {
    modifier(ConfigFieldMenu(path: path))
  }
}

/// An item's location, for its editor's header: `config.json › hotstrings › ";sig"`, with the menu.
struct ConfigItemCaption: View {
  let key: ConfigKey?
  @Environment(AppModel.self) private var model: AppModel?

  var body: some View {
    if let key, model?.showsConfigKeys == true {
      ConfigKeyCaption(key: key)
        .configKeyMenu(key)
    }
  }
}
