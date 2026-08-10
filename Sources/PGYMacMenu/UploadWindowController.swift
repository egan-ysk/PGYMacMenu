import AppKit

final class UploadWindowController: NSWindowController {
    private let store: ConfigurationStore
    private let apkInfo: ApkFileInfo
    private let onBackToHome: () -> Void
    private let onComplete: (PgyerResponse) -> Void

    private var profiles: [APIKeyProfile] = []
    private var templates: [UpdateTemplate] = []
    private var client: PgyerClient?
    private var uploadTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    private let apiKeyPopup = NSPopUpButton()
    private let templatePopup = NSPopUpButton()
    private let updateInfoScrollView = UI.textView(minHeight: 200, minWidth: 500)
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = UI.valueLabel("等待上传")
    private let uploadButton = UI.primaryButton("上传", target: nil, action: nil)
    private let cancelButton = UI.button("取消", target: nil, action: nil)
    private let backHomeButton = UI.button("返回 Home", target: nil, action: nil)
    private weak var confirmationSheet: NSWindow?

    init(
        store: ConfigurationStore,
        apkInfo: ApkFileInfo,
        onBackToHome: @escaping () -> Void,
        onComplete: @escaping (PgyerResponse) -> Void
    ) {
        self.store = store
        self.apkInfo = apkInfo
        self.onBackToHome = onBackToHome
        self.onComplete = onComplete
        super.init(window: UI.makeWindow(title: "APK 发布", width: 1040, height: 520, minWidth: 960, minHeight: 500))
        window?.styleMask.remove(.resizable)
        buildUI()
        reloadConfiguration()
        observeConfigurationChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        [0.0, 0.1, 0.35].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restorePreferredWindowSize()
            }
        }
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func close() {
        uploadTask?.cancel()
        client?.cancel()
        super.close()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerView = makeHeaderView()

        let infoGrid = UI.gridStack()
        [
            ("名称", apkInfo.nameDisplay),
            ("版本", apkInfo.versionDisplay),
            ("调试状态", apkInfo.buildConfig),
            ("minSdk", apkInfo.sdkVersionDisplay),
            ("targetSdk", apkInfo.targetSdkVersionDisplay),
            ("ABI", apkInfo.abi.isEmpty ? "未识别" : apkInfo.abi),
            ("包名", apkInfo.packageName.isEmpty ? "未识别" : apkInfo.packageName),
            ("文件名", apkInfo.fileName),
            ("大小", apkInfo.fileSize),
            ("文件更新时间", apkInfo.fileModifiedTime),
            ("路径", apkInfo.filePath)
        ].forEach { title, value in
            UI.addRow(infoGrid, title: title, view: UI.valueLabel(value))
        }
        let infoSection = makeSection(title: "上传文件信息", content: infoGrid)
        infoSection.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true

        let configGrid = UI.gridStack()
        apiKeyPopup.target = self
        apiKeyPopup.action = #selector(apiKeyChanged)
        templatePopup.target = self
        templatePopup.action = #selector(templateChanged)
        UI.addRow(configGrid, title: "API Key", view: apiKeyPopup)
        UI.addRow(configGrid, title: "更新模板", view: templatePopup)

        let updateTitleLabel = sectionSubtitle("更新说明")
        let restoreButton = UI.button("恢复 API 默认", target: self, action: #selector(restoreSelectedProfileTemplate))
        restoreButton.controlSize = .small
        let updateHeader = NSStackView(views: [updateTitleLabel, flexibleSpace(), restoreButton])
        updateHeader.orientation = .horizontal
        updateHeader.alignment = .centerY
        updateHeader.spacing = 8

        let configStack = NSStackView(views: [configGrid, updateHeader, updateInfoScrollView])
        configStack.orientation = .vertical
        configStack.alignment = .leading
        configStack.spacing = 12
        configStack.translatesAutoresizingMaskIntoConstraints = false
        configStack.setCustomSpacing(16, after: configGrid)
        let configSection = makeSection(title: "发布配置", content: configStack)
        configSection.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        let bodyStack = NSStackView(views: [infoSection, configSection])
        bodyStack.orientation = .horizontal
        bodyStack.alignment = .top
        bodyStack.distribution = .fill
        bodyStack.spacing = 16
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isIndeterminate = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        statusLabel.textColor = .secondaryLabelColor

        uploadButton.target = self
        uploadButton.action = #selector(startUpload)
        cancelButton.target = self
        cancelButton.action = #selector(cancelOrClose)
        backHomeButton.target = self
        backHomeButton.action = #selector(backToHome)

        let progressStack = NSStackView(views: [progressIndicator, statusLabel])
        progressStack.orientation = .vertical
        progressStack.alignment = .leading
        progressStack.spacing = 6
        progressStack.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [backHomeButton, cancelButton, uploadButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let bottomStack = NSStackView(views: [progressStack, flexibleSpace(), footer])
        bottomStack.orientation = .horizontal
        bottomStack.alignment = .bottom
        bottomStack.spacing = 16
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        [headerView, bodyStack, bottomStack].forEach(rootStack.addArrangedSubview)
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            headerView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bottomStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    private func restorePreferredWindowSize() {
        guard let window else {
            return
        }
        window.minSize = NSSize(width: 960, height: 500)
        window.contentMinSize = NSSize(width: 960, height: 500)
        let contentRect = NSRect(x: 0, y: 0, width: 1040, height: 520)
        var frame = window.frameRect(forContentRect: contentRect)
        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = visibleFrame.midX - frame.width / 2
            frame.origin.y = visibleFrame.midY - frame.height / 2
        }
        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeHeaderView() -> NSView {
        let iconImage = NSImage(systemSymbolName: "shippingbox.and.arrow.up", accessibilityDescription: "APK")
            ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: "APK")
        let iconView = NSImageView(image: iconImage ?? NSImage())
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let titleLabel = NSTextField(labelWithString: apkInfo.nameDisplay)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        let subtitleParts = [
            apkInfo.versionDisplay == "未识别" ? nil : "版本 \(apkInfo.versionDisplay)",
            apkInfo.packageName.isEmpty ? nil : apkInfo.packageName,
            apkInfo.fileSize.isEmpty ? nil : apkInfo.fileSize
        ].compactMap { $0 }
        let subtitleLabel = NSTextField(labelWithString: subtitleParts.joined(separator: " · "))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let badgeView = makeBuildConfigBadge(apkInfo.buildConfig)
        let header = NSStackView(views: [iconView, textStack, flexibleSpace(), badgeView])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private func makeSection(title: String, content: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = box.contentView else {
            return box
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
        return box
    }

    private func sectionSubtitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeBuildConfigBadge(_ buildConfig: String) -> NSView {
        let normalized = buildConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = normalized.isEmpty ? "未识别" : normalized
        let lowercased = displayText.lowercased()
        let color: NSColor
        let backgroundColor: NSColor
        if lowercased.contains("debug") {
            color = NSColor.systemOrange
            backgroundColor = NSColor.systemOrange.withAlphaComponent(0.13)
        } else if displayText.contains("非") {
            color = NSColor.systemGreen
            backgroundColor = NSColor.systemGreen.withAlphaComponent(0.13)
        } else {
            color = NSColor.secondaryLabelColor
            backgroundColor = NSColor.controlBackgroundColor
        }

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let label = NSTextField(labelWithString: displayText)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = backgroundColor.cgColor
        stack.layer?.cornerRadius = 12
        stack.layer?.borderColor = color.withAlphaComponent(0.35).cgColor
        stack.layer?.borderWidth = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        return stack
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .configurationStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] notification in
            guard Self.includesUploadConfigurationChanges(notification), self?.uploadTask == nil else {
                return
            }
            self?.reloadConfiguration(preservingSelection: true)
        }
    }

    private static func includesUploadConfigurationChanges(_ notification: Notification) -> Bool {
        guard let categories = notification.userInfo?["categories"] as? [String] else {
            return true
        }
        return categories.contains(ConfigurationChangeCategory.apiKeyProfiles.rawValue)
            || categories.contains(ConfigurationChangeCategory.updateTemplates.rawValue)
    }

    private func reloadConfiguration(preservingSelection: Bool = false) {
        let previousProfiles = profiles
        let selectedProfileID = profiles[safe: apiKeyPopup.indexOfSelectedItem]?.id
        let selectedTemplateID = templates[safe: templatePopup.indexOfSelectedItem - 1]?.id
        let currentUpdateInfo = UI.documentTextView(from: updateInfoScrollView).string

        profiles = store.loadAPIKeyProfiles()
        templates = store.loadUpdateTemplates()

        apiKeyPopup.removeAllItems()
        if profiles.isEmpty {
            apiKeyPopup.addItem(withTitle: "未配置 API Key")
        } else {
            profiles.forEach { apiKeyPopup.addItem(withTitle: $0.displayName) }
        }

        templatePopup.removeAllItems()
        templatePopup.addItem(withTitle: "不使用模板")
        templates.forEach { template in
            templatePopup.addItem(withTitle: template.displayName)
        }

        let selectedProfileIndex = selectedProfileID.flatMap { id in
            profiles.firstIndex(where: { $0.id == id })
        }
        let selectedProfileWasDeleted = preservingSelection
            && selectedProfileID != nil
            && selectedProfileIndex == nil

        if let selectedProfileIndex {
            apiKeyPopup.selectItem(at: selectedProfileIndex)
        } else if preservingSelection && !previousProfiles.isEmpty {
            apiKeyPopup.select(nil)
        } else if !profiles.isEmpty {
            apiKeyPopup.selectItem(at: 0)
        }

        let selectedTemplateIndex = selectedTemplateID.flatMap { id in
            templates.firstIndex(where: { $0.id == id })
        }
        let selectedTemplateWasDeleted = preservingSelection
            && selectedTemplateID != nil
            && selectedTemplateIndex == nil
        if let selectedTemplateIndex {
            templatePopup.selectItem(at: selectedTemplateIndex + 1)
        } else {
            templatePopup.selectItem(at: 0)
        }

        let updateInfo: String
        if selectedProfileWasDeleted || selectedTemplateWasDeleted {
            updateInfo = ""
        } else if preservingSelection {
            updateInfo = currentUpdateInfo
        } else {
            updateInfo = profiles.first?.updateTemplate ?? ""
        }
        UI.documentTextView(from: updateInfoScrollView).string = updateInfo
        uploadButton.isEnabled = profiles[safe: apiKeyPopup.indexOfSelectedItem] != nil
    }

    @objc private func apiKeyChanged() {
        guard let profile = profiles[safe: apiKeyPopup.indexOfSelectedItem] else {
            return
        }
        UI.documentTextView(from: updateInfoScrollView).string = profile.updateTemplate
        templatePopup.selectItem(at: 0)
    }

    @objc private func templateChanged() {
        let index = templatePopup.indexOfSelectedItem - 1
        guard let template = templates[safe: index] else {
            return
        }
        UI.documentTextView(from: updateInfoScrollView).string = template.content
    }

    @objc private func restoreSelectedProfileTemplate() {
        guard let profile = profiles[safe: apiKeyPopup.indexOfSelectedItem] else {
            return
        }
        UI.documentTextView(from: updateInfoScrollView).string = profile.updateTemplate
        templatePopup.selectItem(at: 0)
    }

    @objc private func startUpload() {
        guard let profile = profiles[safe: apiKeyPopup.indexOfSelectedItem] else {
            UI.showAlert(title: "提示", message: "请先配置 API Key", style: .warning, window: window)
            return
        }
        let updateInfo = UI.documentTextView(from: updateInfoScrollView).string.trimmingCharacters(in: .whitespacesAndNewlines)
        showUploadConfirmation(profile: profile, updateInfo: updateInfo)
    }

    private func performUpload(profile: APIKeyProfile, updateInfo: String) {
        setUploading(true)
        let client = PgyerClient()
        self.client = client
        uploadTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let response = try await client.upload(
                    fileURL: apkInfo.fileURL,
                    profile: profile,
                    updateInfo: updateInfo
                ) { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.applyProgress(progress)
                    }
                }
                DispatchQueue.main.async {
                    self.uploadTask = nil
                    self.client = nil
                    self.setUploading(false)
                    self.close()
                    self.onComplete(response)
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    self.uploadTask = nil
                    self.client = nil
                    self.setUploading(false)
                    self.statusLabel.stringValue = "已取消上传"
                }
            } catch {
                DispatchQueue.main.async {
                    self.uploadTask = nil
                    self.client = nil
                    self.setUploading(false)
                    UI.showAlert(title: "上传失败", message: error.localizedDescription, style: .critical, window: self.window)
                }
            }
        }
    }

    private func showUploadConfirmation(profile: APIKeyProfile, updateInfo: String) {
        guard let window else {
            performUpload(profile: profile, updateInfo: updateInfo)
            return
        }

        let sheet = makeConfirmationSheet(profile: profile, updateInfo: updateInfo)
        confirmationSheet = sheet
        window.beginSheet(sheet) { [weak self] response in
            self?.confirmationSheet = nil
            guard response == .OK else {
                return
            }
            guard let self else { return }
            guard let currentProfile = store.loadAPIKeyProfiles().first(where: { $0.id == profile.id }) else {
                UI.showAlert(
                    title: "配置已变更",
                    message: "所选 API Key 配置已被删除或暂时无法读取，请重新选择后再上传。",
                    style: .warning,
                    window: window
                )
                return
            }
            performUpload(profile: currentProfile, updateInfo: updateInfo)
        }
    }

    private func makeConfirmationSheet(profile: APIKeyProfile, updateInfo: String) -> NSWindow {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "确认上传"
        sheet.isReleasedWhenClosed = false
        sheet.tabbingMode = .disallowed

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sheet.contentView = contentView

        let icon = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "上传")
            ?? NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "上传")
        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let titleLabel = NSTextField(labelWithString: "确认上传到蒲公英")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitleLabel = NSTextField(labelWithString: "请确认目标配置和发布信息，确认后将开始上传。")
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 12)
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let header = NSStackView(views: [iconView, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let grid = UI.gridStack()
        [
            ("APK", apkInfo.fileName),
            ("应用", apkInfo.nameDisplay),
            ("包名", apkInfo.packageName.isEmpty ? "未识别" : apkInfo.packageName),
            ("版本", apkInfo.versionDisplay),
            ("文件大小", apkInfo.fileSize),
            ("API Key", profile.displayName),
            ("安装密码", profile.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未设置" : "已设置")
        ].forEach { title, value in
            UI.addRow(grid, title: title, view: UI.valueLabel(value))
        }

        let updateTitle = sectionSubtitle("更新说明")
        let preview = UI.textView(
            initialText: updateInfo.isEmpty ? "未设置" : updateInfo,
            minHeight: 96,
            minWidth: 500
        )
        let previewTextView = UI.documentTextView(from: preview)
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.textColor = updateInfo.isEmpty ? .secondaryLabelColor : .labelColor
        let updateStack = NSStackView(views: [updateTitle, preview])
        updateStack.orientation = .vertical
        updateStack.alignment = .leading
        updateStack.spacing = 8

        let cancelButton = UI.button("取消", target: self, action: #selector(cancelUploadSheet))
        let confirmButton = UI.primaryButton("确认上传", target: self, action: #selector(confirmUploadSheet))
        let footer = NSStackView(views: [flexibleSpace(), cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let rootStack = NSStackView(views: [header, grid, updateStack, footer])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            header.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            updateStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: updateStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])

        return sheet
    }

    @objc private func confirmUploadSheet() {
        guard let sheet = confirmationSheet else {
            return
        }
        window?.endSheet(sheet, returnCode: .OK)
    }

    @objc private func cancelUploadSheet() {
        guard let sheet = confirmationSheet else {
            return
        }
        window?.endSheet(sheet, returnCode: .cancel)
    }

    private func setUploading(_ uploading: Bool) {
        uploadButton.isEnabled = !uploading
        apiKeyPopup.isEnabled = !uploading
        templatePopup.isEnabled = !uploading
        backHomeButton.isEnabled = !uploading
        cancelButton.title = uploading ? "取消上传" : "关闭"
        if uploading {
            progressIndicator.doubleValue = 0
            statusLabel.stringValue = "正在准备上传..."
        }
    }

    private func applyProgress(_ progress: UploadProgress) {
        switch progress {
        case .status(let text):
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = text
        case .fileUpload(let fraction, let text):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = fraction
            statusLabel.stringValue = "上传进度 \(text)"
        case .polling(let index, let total):
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = "正在发布应用... \(index)/\(total)"
        }
    }

    @objc private func cancelOrClose() {
        if uploadTask != nil {
            uploadTask?.cancel()
            client?.cancel()
            uploadTask = nil
            setUploading(false)
            statusLabel.stringValue = "已取消上传"
        } else {
            close()
        }
    }

    @objc private func backToHome() {
        guard uploadTask == nil else {
            return
        }
        close()
        onBackToHome()
    }
}
