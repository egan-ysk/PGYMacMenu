import AppKit

final class HomeWindowController: NSWindowController {
    private let onSelectAPK: () -> Void
    private let onAPIKeySettings: () -> Void
    private let onTemplateSettings: () -> Void
    private let onPreferences: () -> Void

    init(
        onSelectAPK: @escaping () -> Void,
        onAPIKeySettings: @escaping () -> Void,
        onTemplateSettings: @escaping () -> Void,
        onPreferences: @escaping () -> Void
    ) {
        self.onSelectAPK = onSelectAPK
        self.onAPIKeySettings = onAPIKeySettings
        self.onTemplateSettings = onTemplateSettings
        self.onPreferences = onPreferences
        super.init(window: UI.makeWindow(title: "PGYMacMenu", width: 520, height: 300, minWidth: 500, minHeight: 260))
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let titleLabel = NSTextField(labelWithString: "PGYMacMenu 已启动")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(wrappingLabelWithString: "可通过菜单栏 PGY 入口、选择 APK 文件或 Finder 右键服务上传到蒲公英。")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        let uploadButton = UI.primaryButton("上传 APK...", target: self, action: #selector(selectAPK))
        let apiKeyButton = UI.button("API Key 配置...", target: self, action: #selector(openAPIKeySettings))
        let templateButton = UI.button("更新模板配置...", target: self, action: #selector(openTemplateSettings))
        let preferencesButton = UI.button("偏好设置...", target: self, action: #selector(openPreferences))

        let buttonGrid = NSGridView(views: [
            [uploadButton, apiKeyButton],
            [templateButton, preferencesButton]
        ])
        buttonGrid.rowSpacing = 10
        buttonGrid.columnSpacing = 10
        buttonGrid.translatesAutoresizingMaskIntoConstraints = false
        buttonGrid.column(at: 0).xPlacement = .fill
        buttonGrid.column(at: 1).xPlacement = .fill
        uploadButton.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let hintLabel = NSTextField(wrappingLabelWithString: "默认关闭最后一个窗口会退出；可在偏好设置中开启后台运行与菜单栏图标。")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, subtitleLabel, buttonGrid, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    @objc private func selectAPK() {
        onSelectAPK()
    }

    @objc private func openAPIKeySettings() {
        onAPIKeySettings()
    }

    @objc private func openTemplateSettings() {
        onTemplateSettings()
    }

    @objc private func openPreferences() {
        onPreferences()
    }
}
