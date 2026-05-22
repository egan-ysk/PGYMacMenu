import AppKit

final class PreferencesWindowController: NSWindowController {
    private let store: ConfigurationStore
    private let onPreferencesChanged: () -> Void
    private let aaptPathField = UI.textField(placeholder: "/Users/.../Android/sdk/build-tools/35.0.0/aapt")
    private let sdkPathField = UI.textField(placeholder: "/Users/.../Library/Android/sdk")
    private let allowMenuBarRunningCheckbox = NSButton(checkboxWithTitle: "允许关闭窗口后继续运行", target: nil, action: nil)
    private let showMenuBarIconCheckbox = NSButton(checkboxWithTitle: "显示菜单栏 PGY 图标", target: nil, action: nil)
    private let quitAfterUploadCheckbox = NSButton(checkboxWithTitle: "上传成功后自动退出应用", target: nil, action: nil)

    init(store: ConfigurationStore, onPreferencesChanged: @escaping () -> Void = {}) {
        self.store = store
        self.onPreferencesChanged = onPreferencesChanged
        super.init(window: UI.makeWindow(title: "偏好设置", width: 720, height: 360, minWidth: 680, minHeight: 330))
        buildUI()
        loadPreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let grid = UI.gridStack()
        grid.translatesAutoresizingMaskIntoConstraints = false

        let aaptRow = pathRow(field: aaptPathField, browseAction: #selector(chooseAapt))
        UI.addRow(grid, title: "aapt 工具", view: aaptRow)

        let sdkRow = pathRow(field: sdkPathField, browseAction: #selector(chooseSDK))
        UI.addRow(grid, title: "Android SDK", view: sdkRow)
        allowMenuBarRunningCheckbox.target = self
        allowMenuBarRunningCheckbox.action = #selector(menuBarRunningChanged)
        UI.addRow(grid, title: "后台运行", view: allowMenuBarRunningCheckbox)
        UI.addRow(grid, title: "菜单栏图标", view: showMenuBarIconCheckbox)
        UI.addRow(grid, title: "", view: quitAfterUploadCheckbox)

        let hint = UI.valueLabel("默认关闭窗口即退出应用；只有开启“允许关闭窗口后继续运行”后，才允许显示菜单栏 PGY 图标。APK 元信息解析优先使用 aapt 工具路径。")
        hint.textColor = .secondaryLabelColor

        let saveButton = UI.primaryButton("保存", target: self, action: #selector(savePreferences))
        let closeButton = UI.button("关闭", target: self, action: #selector(closeWindow))
        let footer = NSStackView(views: [closeButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(grid)
        contentView.addSubview(hint)
        contentView.addSubview(footer)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
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

    private func loadPreferences() {
        let preferences = store.loadPreferences()
        aaptPathField.stringValue = preferences.aaptPath
        sdkPathField.stringValue = preferences.androidSDKPath
        allowMenuBarRunningCheckbox.state = preferences.allowMenuBarRunning ? .on : .off
        showMenuBarIconCheckbox.state = preferences.showMenuBarIcon ? .on : .off
        quitAfterUploadCheckbox.state = preferences.quitAfterSuccessfulUpload ? .on : .off
        updateMenuBarIconAvailability()
    }

    @objc private func chooseAapt() {
        let panel = NSOpenPanel()
        panel.title = "选择 aapt 可执行文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            aaptPathField.stringValue = url.path
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
        }
    }

    @objc private func savePreferences() {
        let allowMenuBarRunning = allowMenuBarRunningCheckbox.state == .on
        store.savePreferences(AppPreferences(
            aaptPath: aaptPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            androidSDKPath: sdkPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            quitAfterSuccessfulUpload: quitAfterUploadCheckbox.state == .on,
            allowMenuBarRunning: allowMenuBarRunning,
            showMenuBarIcon: allowMenuBarRunning && showMenuBarIconCheckbox.state == .on
        ))
        loadPreferences()
        onPreferencesChanged()
        UI.showAlert(title: "提示", message: "操作成功", window: window)
    }

    @objc private func menuBarRunningChanged() {
        updateMenuBarIconAvailability()
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
