import AppKit

final class APIKeySettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigurationStore
    private var profiles: [APIKeyProfile] = []
    private var editingProfile = APIKeyProfile()

    private let tableView = NSTableView()
    private let nameField = UI.textField(placeholder: "例如：测试环境")
    private let apiKeyField = UI.secureField(placeholder: "蒲公英 API Key")
    private let passwordField = UI.secureField(placeholder: "不填写则不设置安装密码")
    private let templateScrollView = UI.textView(minHeight: 150)

    init(store: ConfigurationStore) {
        self.store = store
        super.init(window: UI.makeWindow(title: "API Key 配置", width: 760, height: 520, minWidth: 680, minHeight: 460))
        buildUI()
        reloadData(select: nil)
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

        let root = NSSplitView()
        root.isVertical = true
        root.dividerStyle = .thin
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let leftPanel = NSView()
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        let rightPanel = NSView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(leftPanel)
        root.addArrangedSubview(rightPanel)
        leftPanel.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = false
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        scrollView.documentView = tableView

        let newButton = UI.button("新建", target: self, action: #selector(newProfile))
        let deleteButton = UI.button("删除", target: self, action: #selector(deleteProfile))
        let buttons = NSStackView(views: [newButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        leftPanel.addSubview(scrollView)
        leftPanel.addSubview(buttons)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: leftPanel.topAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor, constant: -16)
        ])

        let grid = UI.gridStack()
        UI.addRow(grid, title: "名称", view: nameField)
        UI.addRow(grid, title: "API Key", view: apiKeyField)
        UI.addRow(grid, title: "安装密码", view: passwordField)
        UI.addRow(grid, title: "更新模板", view: templateScrollView)

        let saveButton = UI.primaryButton("保存", target: self, action: #selector(saveProfile))
        let closeButton = UI.button("关闭", target: self, action: #selector(closeWindow))
        let footer = NSStackView(views: [closeButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .gravityAreas
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        rightPanel.addSubview(grid)
        rightPanel.addSubview(footer)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            footer.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor, constant: -20)
        ])
    }

    private func reloadData(select id: UUID?) {
        profiles = store.loadAPIKeyProfiles()
        tableView.reloadData()
        if let id, let index = profiles.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !profiles.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            editingProfile = APIKeyProfile()
            applyProfileToFields(editingProfile)
        }
    }

    private func applyProfileToFields(_ profile: APIKeyProfile) {
        editingProfile = profile
        nameField.stringValue = profile.name
        apiKeyField.stringValue = profile.apiKey
        passwordField.stringValue = profile.password
        UI.documentTextView(from: templateScrollView).string = profile.updateTemplate
    }

    @objc private func newProfile() {
        tableView.deselectAll(nil)
        applyProfileToFields(APIKeyProfile())
        nameField.becomeFirstResponder()
    }

    @objc private func deleteProfile() {
        guard let selected = profiles[safe: tableView.selectedRow] else {
            return
        }
        store.deleteAPIKeyProfile(id: selected.id)
        reloadData(select: nil)
    }

    @objc private func saveProfile() {
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            UI.showAlert(title: "提示", message: "请填写 API Key", style: .warning, window: window)
            return
        }

        var profile = editingProfile
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = name.isEmpty ? apiKey : name
        profile.apiKey = apiKey
        profile.password = passwordField.stringValue
        profile.updateTemplate = UI.documentTextView(from: templateScrollView).string
        store.saveAPIKeyProfile(profile)
        reloadData(select: profile.id)
        UI.showAlert(title: "提示", message: "操作成功", window: window)
    }

    @objc private func closeWindow() {
        close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        profiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = profiles[row].displayName
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selected = profiles[safe: tableView.selectedRow] else {
            return
        }
        applyProfileToFields(selected)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
