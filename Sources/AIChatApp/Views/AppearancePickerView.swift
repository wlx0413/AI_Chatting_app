import SwiftUI
import UniformTypeIdentifiers

/// 界面外观设置：主题（跟随系统 / Claude 米白橙）、字体预设（serif/sans/mono）、
/// 字号分级（小/中/大/特大）。
///
/// 字体预设已开放：serif 默认为系统衬线（中文自动宋体 Songti SC），可导入
/// 自定义衬线字体（如 Newsreader SC 合并字体）覆盖；选择即时生效并持久化。
struct AppearancePickerView: View {

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    /// 字体导入文件选择器。
    @State private var showFontImporter = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("appearance.font"), systemImage: "textformat")
                .font(.headline)

            // 主题：跟随系统 / Claude 米白橙。
            Picker(L("appearance.theme"), selection: $appearance.theme) {
                ForEach(ChatTheme.allCases) { theme in
                    Text(theme.displayName)
                        .tag(theme)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            .tint(appearance.accentColor)

            // 字体预设选择（serif/sans/mono）。
            if appearance.isFontPresetSelectionEnabled {
                Picker(L("appearance.font"), selection: $appearance.fontPreset) {
                    ForEach(FontPreset.allCases) { preset in
                        Text(preset.displayName)
                            .tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                .tint(appearance.accentColor)
            }

            // 导入衬线字体：覆盖系统 serif（New York + 宋体级联），
            // 例如导入 Newsreader SC 合并字体（Newsreader 拉丁 + 宋体中文字形）。
            HStack(spacing: 8) {
                Button(L("appearance.font.import"), systemImage: "plus.circle") {
                    showFontImporter = true
                }
                .buttonStyle(.bordered)
                .tint(appearance.accentColor)

                if let family = ImportedFontManager.shared.familyName {
                    Text("✓ \(family)")
                        .font(.caption)
                        .foregroundStyle(appearance.accentColor)
                    Button(L("appearance.font.remove"), role: .destructive) {
                        ImportedFontManager.shared.removeImportedFont()
                        appearance.objectWillChange.send()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                } else {
                    Text(L("appearance.font.none"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(L("appearance.fontsize"), selection: $appearance.fontSizeLevel) {
                ForEach(FontSizeLevel.allCases) { level in
                    Text(level.localizedName)
                        .tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            .tint(appearance.accentColor)

            // 字号预览（跟随当前预设，默认 sans）。
            Text(L("appearance.sample"))
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(L("appearance.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(
            isPresented: $showFontImporter,
            allowedContentTypes: [.font],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            if ImportedFontManager.shared.install(urls: urls) {
                appearance.objectWillChange.send()
            }
        }
    }
}

// MARK: - 本地化显示名

extension FontPreset {
    /// 界面显示名称（本地化）。
    var displayName: String {
        switch self {
        case .serif: return L("appearance.serif")
        case .sans:  return L("appearance.sans")
        case .mono:  return L("appearance.mono")
        }
    }
}

extension FontSizeLevel {
    /// 本地化字号名称。
    var localizedName: String {
        switch self {
        case .small:      return L("appearance.size.small")
        case .medium:     return L("appearance.size.medium")
        case .large:      return L("appearance.size.large")
        case .extraLarge: return L("appearance.size.xlarge")
        }
    }
}