import SlatedCore
import SwiftUI

/// Edits any `Action`: pick the operation, start from a preset, then fine-tune its parameters.
struct ActionEditor: View {
  @Binding var action: Action
  /// Nesting level (chain and sequence steps edit their operations with a nested editor).
  var depth = 0
  @Environment(AppModel.self) private var model

  var body: some View {
    let kind = ActionKind(action)
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        ActionKindPicker(kind: kind, allowsComposition: depth < 2) { newKind in
          action = converted(to: newKind)
        }
        Text(kind.explanation)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if kind.isWindowGeometry {
        PresetGallery(action: $action)
      }
      ActionParameters(action: $action, depth: depth)
    }
  }

  private func converted(to kind: ActionKind) -> Action {
    let result = ActionForm.convert(action, to: kind)
    if case .layout(let name) = result, name.isEmpty, let first = model.knownLayoutNames.sorted().first {
      return .layout(name: first)
    }
    return result
  }
}

// MARK: - Kind picker

/// A field-like button that opens a categorized palette of every operation.
struct ActionKindPicker: View {
  let kind: ActionKind
  var allowsComposition = true
  let onSelect: (ActionKind) -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 9) {
        IconTile(symbol: kind.symbol, tint: kind.category.tint, size: 24)
        VStack(alignment: .leading, spacing: 0) {
          Text(kind.category.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
          Text(kind.title).font(.system(size: 13, weight: .semibold))
        }
        Spacer(minLength: 16)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 6)
      .padding(.trailing, 10)
      .frame(width: 250, height: 42)
      .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.wellStroke))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Operation: \(kind.title)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      ActionPalette(selected: kind, allowsComposition: allowsComposition) { picked in
        isPresented = false
        if picked != kind { onSelect(picked) }
      }
    }
  }
}

private struct ActionPalette: View {
  let selected: ActionKind
  let allowsComposition: Bool
  let onPick: (ActionKind) -> Void

  var body: some View {
    let columns = [
      GridItem(.fixed(178), alignment: .top), GridItem(.fixed(178), alignment: .top),
      GridItem(.fixed(178), alignment: .top),
    ]
    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
      ForEach(ActionKind.Category.allCases) { category in
        VStack(alignment: .leading, spacing: 3) {
          Text(category.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.bottom, 3)
          ForEach(category.kinds) { kind in
            let disabled = !allowsComposition && (kind == .chain || kind == .sequence)
            Button {
              onPick(kind)
            } label: {
              HStack(spacing: 8) {
                IconTile(symbol: kind.symbol, tint: category.tint, size: 20)
                Text(kind.title).font(.system(size: 12.5))
                Spacer(minLength: 0)
                if kind == selected {
                  Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }
              }
              .padding(.horizontal, 6)
              .padding(.vertical, 4)
              .background(
                kind == selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            .help(kind.explanation)
          }
        }
      }
    }
    .padding(16)
  }
}

extension ActionKind.Category {
  var tint: Color {
    switch self {
    case .window: return SettingsPane.windows.tint
    case .combine: return Color(hex: 0x7A5AF8)
    case .focus: return Color(hex: 0x14A89A)
    case .apps: return Color(hex: 0xE5484D)
    case .snapshots: return Color(hex: 0xD6409F)
    case .automation: return Color(hex: 0xF08A24)
    case .input: return Color(hex: 0x0EA5E9)
    }
  }
}

// MARK: - Presets

/// Window placements as glyphs, grouped by kind. The current placement is highlighted.
struct PresetGallery: View {
  @Binding var action: Action

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Presets").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(WindowPreset.Group.allCases) { group in
          HStack(spacing: 6) {
            Text(group.rawValue)
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
              .frame(width: 84, alignment: .leading)
            ForEach(WindowPresets.all.filter { $0.group == group }) { preset in
              PresetTile(preset: preset, isSelected: preset.matches(action)) {
                withAnimation(Theme.spring) { action = preset.action }
              }
            }
            Spacer(minLength: 0)
          }
        }
      }
      .padding(10)
      .wellStyle()
    }
  }
}

private struct PresetTile: View {
  let preset: WindowPreset
  let isSelected: Bool
  let onTap: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: onTap) {
      Group {
        if let region = preset.region {
          RegionGlyph(region: region, width: 32, height: 21, highlighted: isSelected)
        } else {
          Image(systemName: preset.symbol ?? "display")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accentGradient)
            .frame(width: 32, height: 21)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.primary.opacity(0.28), lineWidth: isSelected ? 1.2 : 1)
            )
        }
      }
      .padding(3)
      .background(
        (isSelected ? Theme.selection : (hovering ? Theme.well : .clear)),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .scaleEffect(hovering && !isSelected ? 1.06 : 1)
      .animation(Theme.snappy, value: hovering)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(preset.title)
    .accessibilityLabel(preset.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
