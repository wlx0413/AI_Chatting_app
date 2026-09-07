import SwiftUI

/// Settings window (macOS 14+): manages API relay profiles + user profile
/// (learned personalization preferences).
struct SettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var userProfileStore: UserProfileStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var editingConfig: APIServerConfig?
    @State private var isAddingNew = false
    @State private var showStatusAlert = false

    var body: some View {
        Group {
            if let config = editingConfig {
                ProfileEditView(
                    config: config,
                    isNew: isAddingNew,
                    onSave: { updated in
                        if isAddingNew {
                            appSettingViewModel.add(updated)
                        } else {
                            appSettingViewModel.update(updated)
                        }
                        editingConfig = nil
                    },
                    onCancel: { editingConfig = nil }
                )
            } else {
                ProfileListView(
                    onAdd: {
                        isAddingNew = true
                        editingConfig = APIServerConfig(name: "New Profile")
                    },
                    onEdit: { editingConfig = $0 }
                )
            }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 520)
        .alert(
            appSettingViewModel.statusIsError ? L("operation.failed") : L("success"),
            isPresented: $showStatusAlert
        ) {
            Button("OK", role: .cancel) { appSettingViewModel.clearStatus() }
        } message: {
            Text(appSettingViewModel.statusMessage ?? "")
        }
        .onChange(of: appSettingViewModel.statusMessage) { _, message in
            if message != nil { showStatusAlert = true }
        }
    }
}

// MARK: - Profile list

private struct ProfileListView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var userProfileStore: UserProfileStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var sessionStore: SessionStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    let onAdd: () -> Void
    let onEdit: (APIServerConfig) -> Void

    var body: some View {
        // 外层 ScrollView：保证所有分区（外观/备份/语言）在窗口缩小时仍可滚动到。
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text(L("api.relay.profiles")).font(.title2.bold())
                    Spacer()
                    Button(action: onAdd) { Label(L("add.profile"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .tint(appearanceStore.prominentButtonColor)
                }
                .padding(16)

                Divider()

                if configStore.configs.isEmpty {
                    ContentUnavailableView {
                        Label(L("no.profiles"), systemImage: "network.slash")
                    } description: {
                        Text(L("no.profiles.description"))
                    } actions: {
                        Button(L("add.profile"), action: onAdd)
                            .buttonStyle(.borderedProminent)
                            .tint(appearanceStore.prominentButtonColor)
                    }
                    .frame(height: 220)
                } else {
                    // 配置列表：多条时限制高度（外层 ScrollView 可继续滚动下面的分区）。
                    List(configStore.configs) { config in
                        ProfileRow(
                            config: config,
                            isActive: configStore.activeConfigID == config.id,
                            isTesting: appSettingViewModel.isTestingConnection
                                && configStore.activeConfigID == config.id,
                            onActivate: { configStore.activeConfigID = config.id },
                            onEdit: { onEdit(config) },
                            onDelete: { appSettingViewModel.delete(config) },
                            onFetchModels: {
                                Task { await appSettingViewModel.fetchModels(for: config.id) }
                            },
                            onTest: {
                                Task { await appSettingViewModel.testConnection(for: config) }
                            }
                        )
                    }
                    .frame(height: CGFloat(min(configStore.configs.count, 4)) * 100 + 16)
                }

                Divider()

                // User Profile section: learned personalization preferences.
                UserProfileSection()
                    .environmentObject(userProfileStore)

                Divider()

                // Interface appearance: font preset + size.
                AppearancePickerView()
                    .environmentObject(appearanceStore)

                Divider()

                // PDF 文档发送：最多渲染页数（0 = 全部页）。
                PDFSettingsSection()

                Divider()

                // Backup & Restore: export/import all user data as ZIP.
                BackupRestoreView()
                    .environmentObject(configStore)
                    .environmentObject(sessionStore)
                    .environmentObject(userProfileStore)
                    .environmentObject(appearanceStore)
                    .environmentObject(LocalizationManager.shared)

                Divider()

                // Interface language picker (UN official languages).
                LanguagePickerView()
                    .environmentObject(LocalizationManager.shared)
            }
        }
    }
}

// MARK: - PDF settings section

/// PDF 文档发送设置：视觉模型渲染 PNG 的页数上限（0 = 全部页）。
///
/// 该参数全局生效（`PDFProcessor.maxRenderPages`），作用于「转成 PNG 发送」
/// 与「图片 + 文字都发送」两种模式；渲染结果缓存按 `(attachment, maxPages)`
/// 区分，改参数不会复用旧缓存。
private struct PDFSettingsSection: View {
    @AppStorage(PDFProcessor.maxRenderPagesKey) private var maxPages = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("pdf.settings.title"), systemImage: "doc.richtext")
                .font(.headline)

            HStack(spacing: 8) {
                Text(L("pdf.settings.maxPages"))
                Stepper(value: $maxPages, in: 0...100, step: 1) {
                    Text(maxPages == 0
                         ? L("pdf.settings.all")
                         : L("pdf.settings.count", maxPages))
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 90, alignment: .leading)
                }
                .frame(maxWidth: 240)
            }

            Text(L("pdf.settings.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - User profile section

/// Editable list of learned personalization preferences.
private struct UserProfileSection: View {
    @EnvironmentObject private var userProfileStore: UserProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("user.profile"), systemImage: "person")
                .font(.headline)

            Text(L("user.profile.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if userProfileStore.preferences.isEmpty {
                Text(L("no.preferences.learned"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                List {
                    ForEach($userProfileStore.preferences) { $pref in
                        HStack(spacing: 8) {
                            TextField("category", text: $pref.category)
                                .font(.caption)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)

                            TextField("value", text: $pref.value)
                                .font(.body)
                                .textFieldStyle(.roundedBorder)

                            Spacer()

                            Button(role: .destructive) {
                                userProfileStore.remove(pref)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(height: CGFloat(min(userProfileStore.preferences.count, 6)) * 30 + 14)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let config: APIServerConfig
    let isActive: Bool
    let isTesting: Bool

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onFetchModels: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(config.displayName).font(.headline)
                if isActive {
                    Text(L("active")).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(config.baseURL.isEmpty ? L("no.base.url") : config.baseURL)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(config.apiKey.isEmpty ? L("no.api.key") : "API key: ••••••••")
                    .font(.caption).foregroundStyle(.secondary)
                Text(config.selectedModel.isEmpty
                     ? L("no.model.selected")
                     : "Model: \(config.selectedModel)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(config.availableModels.isEmpty
                       ? L("fetch.models")
                       : L("models.count", config.availableModels.count),
                       action: onFetchModels)
                    .buttonStyle(.bordered)
                Button(L("test"), action: onTest).buttonStyle(.bordered)
                Button(L("edit"), action: onEdit).buttonStyle(.bordered)
                Spacer()
                Button(L("delete"), role: .destructive, action: onDelete).buttonStyle(.bordered)
            }
            .font(.callout)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Profile editor

private struct ProfileEditView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var appearanceStore: AppearanceStore

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var draft: APIServerConfig
    let isNew: Bool
    let onSave: (APIServerConfig) -> Void
    let onCancel: () -> Void

    init(
        config: APIServerConfig,
        isNew: Bool,
        onSave: @escaping (APIServerConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // MARK: - Custom price bindings

    /// Enables/disables the user-defined price (creates the struct on demand).
    private var customPriceEnabled: Binding<Bool> {
        Binding(
            get: { draft.customPrice != nil },
            set: { enabled in
                if enabled {
                    if draft.customPrice == nil {
                        draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                    }
                } else {
                    draft.customPrice = nil
                }
            }
        )
    }

    private var customPriceInput: Binding<Double> {
        Binding(
            get: { draft.customPrice?.input ?? 0 },
            set: { value in
                if draft.customPrice == nil {
                    draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                }
                draft.customPrice?.input = value
            }
        )
    }

    private var customPriceOutput: Binding<Double> {
        Binding(
            get: { draft.customPrice?.output ?? 0 },
            set: { value in
                if draft.customPrice == nil {
                    draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                }
                draft.customPrice?.output = value
            }
        )
    }

    private var customPriceCached: Binding<Double> {
        Binding(
            get: { draft.customPrice?.cachedInput ?? 0 },
            set: { value in
                if draft.customPrice == nil {
                    draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                }
                draft.customPrice?.cachedInput = value > 0 ? value : nil
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? L("add.profile.title") : L("edit.profile.title")).font(.title2.bold())

            Form {
                TextField(L("profile.name"), text: $draft.name)
                TextField(L("base.url"), text: $draft.baseURL)
                SecureField(L("api.key"), text: $draft.apiKey)

                Section {
                    Toggle(L("streaming.on"), isOn: $draft.streamEnabled)

                    Toggle(L("timestamp.on"), isOn: $draft.includeTimestamp)
                        .help(L("timestamp.warning"))

                    Toggle(L("agent.mode"), isOn: $draft.toolsEnabled)

                    Toggle(L("latex.on"), isOn: $draft.latexEnabled)
                        .disabled(!LaTeXService.isAvailable)
                        .help(
                            LaTeXService.isAvailable
                                ? L("latex.help", LaTeXService.installedEngineList)
                                : L("latex.not.installed")
                        )
                } header: {
                    Text(L("generation"))
                } footer: {
                    Text(L("generation.footer"))
                }

                Section {
                    Toggle(L("custom.price.enable"), isOn: customPriceEnabled)
                    if customPriceEnabled.wrappedValue {
                        TextField(L("custom.price.input"), value: customPriceInput, format: .number)
                        TextField(L("custom.price.output"), value: customPriceOutput, format: .number)
                        TextField(L("custom.price.cached"), value: customPriceCached, format: .number)
                            .help(L("custom.price.cached.help"))
                    }
                } header: {
                    Text(L("custom.price"))
                } footer: {
                    Text(L("custom.price.footer"))
                }

                Section {
                    TextEditor(text: $draft.systemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Label(L("system.prompt.hint"),
                          systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L("system.prompt"))
                } footer: {
                    Text(L("system.prompt.footer"))
                }

                if !isNew {
                    Section(L("models")) {
                        Picker(L("selected.model"), selection: $draft.selectedModel) {
                            if draft.availableModels.isEmpty {
                                Text(L("no.models.yet")).tag("")
                            }
                            ForEach(draft.availableModels, id: \.self) { model in
                                HStack(spacing: 4) {
                                    Text(model)
                                    if MultimodalSupport.isMultimodal(model) {
                                        Image(systemName: "photo")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(model)
                            }
                        }
                        .tint(appearanceStore.accentColor)
                        .disabled(draft.availableModels.isEmpty)

                        Label(L("multimodal.hint"),
                              systemImage: "photo.on.rectangle")
                            .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Button {
                                Task {
                                    await appSettingViewModel.fetchModels(for: draft.id)
                                    if let updated = configStore.configs.first(where: { $0.id == draft.id }) {
                                        draft = updated
                                    }
                                }
                            } label: {
                                Label(L("fetch.models.button"), systemImage: "arrow.clockwise")
                            }
                            .disabled(appSettingViewModel.isLoadingModels)

                            if appSettingViewModel.isLoadingModels {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(L("cancel"), role: .cancel, action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: save) {
                    Text(isNew ? L("add") : L("save"))
                }
                .buttonStyle(.borderedProminent)
                .tint(appearanceStore.prominentButtonColor)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .onAppear {
            if let existing = configStore.configs.first(where: { $0.id == draft.id }) {
                draft = existing
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
    }
}