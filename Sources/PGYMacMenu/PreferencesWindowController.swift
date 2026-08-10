import AppKit

final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private let store: ConfigurationStore
    private let syncCoordinator: SyncCoordinator
    private let onPreferencesChanged: () -> Void

    private let aaptPathField = UI.textField(placeholder: "/Users/.../Android/sdk/build-tools/35.0.0/aapt")
    private let sdkPathField = UI.textField(placeholder: "/Users/.../Library/Android/sdk")
    private let allowMenuBarRunningCheckbox = NSButton(checkboxWithTitle: "允许关闭窗口后继续运行", target: nil, action: nil)
    private let showMenuBarIconCheckbox = NSButton(checkboxWithTitle: "显示菜单栏 PGY 图标", target: nil, action: nil)
    private let quitAfterUploadCheckbox = NSButton(checkboxWithTitle: "上传成功后自动退出应用", target: nil, action: nil)

    private let rootURLField = UI.textField(placeholder: "https://dav.example.com/remote.php/dav/files/user/")
    private let relativePathField = UI.textField(placeholder: "PGYMacMenu.sync")
    private let usernameField = UI.textField(placeholder: "WebDAV 用户名")
    private let webDAVPasswordField = UI.secureField(placeholder: "WebDAV 密码或应用专用密码")
    private let passphraseField = UI.secureField(placeholder: "至少 12 个字符")
    private let passphraseConfirmationField = UI.secureField(placeholder: "再次输入同步口令")
    private let statusLabel = UI.valueLabel("未配置")
    private let statusProgressIndicator = NSProgressIndicator()
    private let generalRemoteUpdateLabel = UI.valueLabel("云端偏好已更新；当前未保存内容已保留。保存会以当前表单为准。")

    private lazy var testConnectionButton = UI.button("测试连接", target: self, action: #selector(testConnection))
    private lazy var saveSyncButton = UI.button("保存设置", target: self, action: #selector(saveSyncSettings))
    private lazy var syncNowButton = UI.button("立即同步", target: self, action: #selector(syncNow))
    private lazy var removeSyncButton = UI.button("移除配置", target: self, action: #selector(removeSyncSettings))

    private var statusObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var syncStatus: SyncCoordinatorStatus = .notConfigured
    private var loadedGeneralPreferences = AppPreferences()
    private var hasDeferredRemotePreferences = false
    private var hasSavedSyncSettings = false
    private var isPerformingSyncAction = false
    private var isApplyingSavedSettings = false
    private var hasSyncDraft = false

    private lazy var statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    init(
        store: ConfigurationStore,
        syncCoordinator: SyncCoordinator,
        onPreferencesChanged: @escaping () -> Void = {}
    ) {
        self.store = store
        self.syncCoordinator = syncCoordinator
        self.onPreferencesChanged = onPreferencesChanged
        super.init(window: UI.makeWindow(
            title: "偏好设置",
            width: 760,
            height: 560,
            minWidth: 720,
            minHeight: 520
        ))
        buildUI()
        configureSyncFields()
        observeSyncStatus()
        observeConfigurationChanges()
        loadPreferences()
        refreshSyncSettings(force: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    override func showWindow(_ sender: Any?) {
        if !hasGeneralDraft {
            loadPreferences()
        }
        if !hasSyncDraft {
            refreshSyncSettings(force: false)
        } else {
            refreshSyncStatus()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "通用"
        generalItem.view = makeGeneralView()
        tabView.addTabViewItem(generalItem)

        let syncItem = NSTabViewItem(identifier: "sync")
        syncItem.label = "同步"
        syncItem.view = makeSyncView()
        tabView.addTabViewItem(syncItem)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    private func makeGeneralView() -> NSView {
        let container = NSView()
        let grid = UI.gridStack()
        aaptPathField.delegate = self
        sdkPathField.delegate = self

        UI.addRow(grid, title: "aapt 工具", view: pathRow(field: aaptPathField, browseAction: #selector(chooseAapt)))
        UI.addRow(grid, title: "Android SDK", view: pathRow(field: sdkPathField, browseAction: #selector(chooseSDK)))
        allowMenuBarRunningCheckbox.target = self
        allowMenuBarRunningCheckbox.action = #selector(menuBarRunningChanged)
        showMenuBarIconCheckbox.target = self
        showMenuBarIconCheckbox.action = #selector(generalPreferencesChanged)
        quitAfterUploadCheckbox.target = self
        quitAfterUploadCheckbox.action = #selector(generalPreferencesChanged)
        UI.addRow(grid, title: "后台运行", view: allowMenuBarRunningCheckbox)
        UI.addRow(grid, title: "菜单栏图标", view: showMenuBarIconCheckbox)
        UI.addRow(grid, title: "", view: quitAfterUploadCheckbox)

        let hint = UI.valueLabel("默认关闭窗口即退出应用；只有开启“允许关闭窗口后继续运行”后，才允许显示菜单栏 PGY 图标。APK 元信息解析优先使用 aapt 工具路径。")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        generalRemoteUpdateLabel.translatesAutoresizingMaskIntoConstraints = false
        generalRemoteUpdateLabel.textColor = .systemOrange
        generalRemoteUpdateLabel.maximumNumberOfLines = 2
        generalRemoteUpdateLabel.isHidden = true
        let notes = NSStackView(views: [hint, generalRemoteUpdateLabel])
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = 8
        notes.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = UI.primaryButton("保存", target: self, action: #selector(savePreferences))
        let closeButton = UI.button("关闭", target: self, action: #selector(closeWindow))
        let footer = NSStackView(views: [closeButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(grid)
        container.addSubview(notes)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            notes.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            notes.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            notes.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            notes.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])
        return container
    }

    private func makeSyncView() -> NSView {
        let container = NSView()
        let grid = UI.gridStack()
        UI.addRow(grid, title: "HTTPS 根 URL", view: rootURLField)
        UI.addRow(grid, title: "相对文件路径", view: relativePathField)
        UI.addRow(grid, title: "用户名", view: usernameField)
        UI.addRow(grid, title: "WebDAV 密码", view: webDAVPasswordField)
        UI.addRow(grid, title: "同步口令", view: passphraseField)
        UI.addRow(grid, title: "确认同步口令", view: passphraseConfirmationField)

        statusProgressIndicator.style = .spinning
        statusProgressIndicator.controlSize = .small
        statusProgressIndicator.isDisplayedWhenStopped = false
        statusProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusProgressIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        statusProgressIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusLabel.maximumNumberOfLines = 2
        let statusStack = NSStackView(views: [statusProgressIndicator, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8
        UI.addRow(grid, title: "同步状态", view: statusStack)

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [removeSyncButton, buttonSpacer, testConnectionButton, saveSyncButton, syncNowButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(grid)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])
        return container
    }

    private func pathRow(field: NSTextField, browseAction: Selector) -> NSView {
        let button = UI.button("选择...", target: self, action: browseAction)
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return stack
    }

    private func configureSyncFields() {
        relativePathField.stringValue = "PGYMacMenu.sync"
        [
            rootURLField,
            relativePathField,
            usernameField,
            webDAVPasswordField,
            passphraseField,
            passphraseConfirmationField
        ].forEach { $0.delegate = self }
        updateSyncControls()
    }

    private func observeSyncStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .syncCoordinatorStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let status = notification.userInfo?["status"] as? SyncCoordinatorStatus else {
                return
            }
            self?.applySyncStatus(status)
        }
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .configurationStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?["source"] as? String == ConfigurationChangeSource.remote.rawValue else {
                return
            }
            if let categories = notification.userInfo?["categories"] as? [String],
               !categories.contains(ConfigurationChangeCategory.preferences.rawValue) {
                return
            }
            self?.remotePreferencesDidChange()
        }
    }

    private func remotePreferencesDidChange() {
        guard hasGeneralDraft else {
            loadPreferences()
            return
        }
        hasDeferredRemotePreferences = true
        generalRemoteUpdateLabel.isHidden = false
    }

    private func loadPreferences() {
        let preferences = store.loadPreferences()
        loadedGeneralPreferences = preferences
        aaptPathField.stringValue = preferences.aaptPath
        sdkPathField.stringValue = preferences.androidSDKPath
        allowMenuBarRunningCheckbox.state = preferences.allowMenuBarRunning ? .on : .off
        showMenuBarIconCheckbox.state = preferences.showMenuBarIcon ? .on : .off
        quitAfterUploadCheckbox.state = preferences.quitAfterSuccessfulUpload ? .on : .off
        hasDeferredRemotePreferences = false
        generalRemoteUpdateLabel.isHidden = true
        updateMenuBarIconAvailability()
    }

    private var hasGeneralDraft: Bool {
        aaptPathField.stringValue != loadedGeneralPreferences.aaptPath
            || sdkPathField.stringValue != loadedGeneralPreferences.androidSDKPath
            || (quitAfterUploadCheckbox.state == .on) != loadedGeneralPreferences.quitAfterSuccessfulUpload
            || (allowMenuBarRunningCheckbox.state == .on) != loadedGeneralPreferences.allowMenuBarRunning
            || (showMenuBarIconCheckbox.state == .on) != loadedGeneralPreferences.showMenuBarIcon
    }

    private func generalFormDidChange() {
        guard hasDeferredRemotePreferences, !hasGeneralDraft else { return }
        loadPreferences()
    }

    private func refreshSyncSettings(force: Bool) {
        guard force || !hasSyncDraft else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let settings = try await syncCoordinator.savedSettings()
                guard !hasSyncDraft else { return }
                applySavedSettings(settings)
                applySyncStatus(await syncCoordinator.currentStatus())
            } catch {
                applySyncStatus(.failed(errorMessage(for: error)))
            }
        }
    }

    private func refreshSyncStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            applySyncStatus(await syncCoordinator.currentStatus())
        }
    }

    private func applySavedSettings(_ settings: WebDAVSyncSettings?) {
        isApplyingSavedSettings = true
        defer { isApplyingSavedSettings = false }
        hasSavedSyncSettings = settings != nil
        rootURLField.stringValue = settings?.rootURL ?? ""
        relativePathField.stringValue = settings?.relativePath ?? "PGYMacMenu.sync"
        usernameField.stringValue = settings?.username ?? ""
        webDAVPasswordField.stringValue = settings?.webDAVPassword ?? ""
        passphraseField.stringValue = settings?.encryptionPassphrase ?? ""
        passphraseConfirmationField.stringValue = settings?.encryptionPassphrase ?? ""
        hasSyncDraft = false
        updateSyncControls()
    }

    private func applySyncStatus(_ status: SyncCoordinatorStatus) {
        syncStatus = status
        switch status {
        case .notConfigured:
            statusLabel.stringValue = "未配置"
            statusLabel.textColor = .secondaryLabelColor
        case .pending:
            statusLabel.stringValue = "等待上传"
            statusLabel.textColor = .systemOrange
        case .syncing:
            statusLabel.stringValue = "同步中..."
            statusLabel.textColor = .controlAccentColor
        case .lastSuccess(let date):
            statusLabel.stringValue = "最后成功：\(statusDateFormatter.string(from: date))"
            statusLabel.textColor = .secondaryLabelColor
        case .failed(let message):
            statusLabel.stringValue = "同步失败：\(message)"
            statusLabel.textColor = .systemRed
        }

        if status == .syncing {
            statusProgressIndicator.startAnimation(nil)
        } else {
            statusProgressIndicator.stopAnimation(nil)
        }
        updateSyncControls()
    }

    private func updateSyncControls() {
        let isBusy = isPerformingSyncAction || syncStatus == .syncing
        testConnectionButton.isEnabled = !isBusy
        saveSyncButton.isEnabled = !isBusy
        syncNowButton.isEnabled = hasSavedSyncSettings && !isBusy
        removeSyncButton.isEnabled = hasSavedSyncSettings && !isBusy
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isApplyingSavedSettings else { return }
        if let field = notification.object as? NSTextField,
           field === aaptPathField || field === sdkPathField {
            generalFormDidChange()
        } else {
            hasSyncDraft = true
        }
    }

    private func settingsFromFields() -> WebDAVSyncSettings? {
        guard passphraseField.stringValue == passphraseConfirmationField.stringValue else {
            UI.showAlert(
                title: "同步口令不一致",
                message: "请重新输入两次相同的同步口令。",
                style: .warning,
                window: window
            )
            return nil
        }
        return WebDAVSyncSettings(
            rootURL: rootURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            relativePath: relativePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            webDAVPassword: webDAVPasswordField.stringValue,
            encryptionPassphrase: passphraseField.stringValue
        )
    }

    private func beginSyncAction() {
        isPerformingSyncAction = true
        updateSyncControls()
    }

    private func finishSyncAction(successMessage: String?, error: Error? = nil) {
        isPerformingSyncAction = false
        updateSyncControls()
        if let error {
            UI.showAlert(
                title: "操作失败",
                message: errorMessage(for: error),
                style: .warning,
                window: window
            )
        } else if let successMessage {
            UI.showAlert(title: "操作成功", message: successMessage, window: window)
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let message = (error as? LocalizedError)?.errorDescription, !message.isEmpty {
            return message
        }
        return "操作未完成，请检查设置后重试。"
    }

    @objc private func chooseAapt() {
        let panel = NSOpenPanel()
        panel.title = "选择 aapt 可执行文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            aaptPathField.stringValue = url.path
            generalFormDidChange()
        }
    }

    @objc private func chooseSDK() {
        let panel = NSOpenPanel()
        panel.title = "选择 Android SDK 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sdkPathField.stringValue = url.path
            generalFormDidChange()
        }
    }

    @objc private func savePreferences() {
        let allowMenuBarRunning = allowMenuBarRunningCheckbox.state == .on
        do {
            try store.savePreferences(AppPreferences(
                aaptPath: aaptPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                androidSDKPath: sdkPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                quitAfterSuccessfulUpload: quitAfterUploadCheckbox.state == .on,
                allowMenuBarRunning: allowMenuBarRunning,
                showMenuBarIcon: allowMenuBarRunning && showMenuBarIconCheckbox.state == .on
            ))
            loadPreferences()
            onPreferencesChanged()
            UI.showAlert(title: "提示", message: "操作成功", window: window)
        } catch {
            UI.showAlert(
                title: "保存失败",
                message: errorMessage(for: error),
                style: .warning,
                window: window
            )
        }
    }

    @objc private func testConnection() {
        guard let settings = settingsFromFields() else { return }
        beginSyncAction()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await syncCoordinator.testConnection(settings)
                finishSyncAction(successMessage: "连接测试通过，服务器支持安全并发同步。")
            } catch {
                finishSyncAction(successMessage: nil, error: error)
            }
        }
    }

    @objc private func saveSyncSettings() {
        guard let settings = settingsFromFields() else { return }
        beginSyncAction()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await syncCoordinator.saveSettings(settings)
                hasSavedSyncSettings = true
                hasSyncDraft = false
                applySavedSettings(try await syncCoordinator.savedSettings())
                applySyncStatus(await syncCoordinator.currentStatus())
                finishSyncAction(successMessage: "同步设置已保存，并已完成一次安全双向同步。")
            } catch {
                hasSavedSyncSettings = (try? await syncCoordinator.savedSettings()) != nil
                applySyncStatus(await syncCoordinator.currentStatus())
                finishSyncAction(successMessage: nil, error: error)
            }
        }
    }

    @objc private func syncNow() {
        beginSyncAction()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await syncCoordinator.synchronizeNow()
                applySyncStatus(await syncCoordinator.currentStatus())
                finishSyncAction(successMessage: "同步已完成。")
            } catch {
                applySyncStatus(await syncCoordinator.currentStatus())
                finishSyncAction(successMessage: nil, error: error)
            }
        }
    }

    @objc private func removeSyncSettings() {
        let alert = NSAlert()
        alert.messageText = "移除 WebDAV 配置？"
        alert.informativeText = "本机连接凭据将被删除，远端加密备份不会被删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beginSyncAction()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await syncCoordinator.removeSettings()
                applySavedSettings(nil)
                applySyncStatus(.notConfigured)
                finishSyncAction(successMessage: "本机同步配置已移除，远端备份保持不变。")
            } catch {
                finishSyncAction(successMessage: nil, error: error)
            }
        }
    }

    @objc private func menuBarRunningChanged() {
        updateMenuBarIconAvailability()
        generalFormDidChange()
    }

    @objc private func generalPreferencesChanged() {
        generalFormDidChange()
    }

    private func updateMenuBarIconAvailability() {
        let allowMenuBarRunning = allowMenuBarRunningCheckbox.state == .on
        showMenuBarIconCheckbox.isEnabled = allowMenuBarRunning
        if !allowMenuBarRunning {
            showMenuBarIconCheckbox.state = .off
        }
    }

    @objc private func closeWindow() {
        close()
    }
}
