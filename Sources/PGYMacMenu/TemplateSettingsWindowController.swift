import AppKit

final class TemplateSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigurationStore
    private var templates: [UpdateTemplate] = []
    private var editingTemplate = UpdateTemplate()
    private var configurationObserver: NSObjectProtocol?
    private var isRefreshingConfiguration = false

    private let tableView = NSTableView()
    private let nameField = UI.textField(placeholder: "例如：日常测试包")
    private let contentScrollView = UI.textView(minHeight: 220)

    init(store: ConfigurationStore) {
        self.store = store
        super.init(window: UI.makeWindow(title: "更新模板配置", width: 760, height: 520, minWidth: 680, minHeight: 460))
        buildUI()
        reloadData(select: nil)
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
        let rightPanel = NSView()
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

        let newButton = UI.button("新建", target: self, action: #selector(newTemplate))
        let deleteButton = UI.button("删除", target: self, action: #selector(deleteTemplate))
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
        UI.addRow(grid, title: "模板名称", view: nameField)
        UI.addRow(grid, title: "模板内容", view: contentScrollView)

        let saveButton = UI.primaryButton("保存", target: self, action: #selector(saveTemplate))
        let closeButton = UI.button("关闭", target: self, action: #selector(closeWindow))
        let footer = NSStackView(views: [closeButton, saveButton])
        footer.orientation = .horizontal
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
        isRefreshingConfiguration = true
        defer { isRefreshingConfiguration = false }

        templates = store.loadUpdateTemplates()
        tableView.reloadData()
        if let id, let index = templates.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            applyTemplateToFields(templates[index])
        } else if !templates.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            applyTemplateToFields(templates[0])
        } else {
            tableView.deselectAll(nil)
            editingTemplate = UpdateTemplate()
            applyTemplateToFields(editingTemplate)
        }
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .configurationStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] notification in
            guard Self.includesTemplateChanges(notification) else {
                return
            }
            self?.configurationDidChange()
        }
    }

    private static func includesTemplateChanges(_ notification: Notification) -> Bool {
        guard let categories = notification.userInfo?["categories"] as? [String] else {
            return true
        }
        return categories.contains(ConfigurationChangeCategory.updateTemplates.rawValue)
    }

    private func configurationDidChange() {
        let selectedID = templates[safe: tableView.selectedRow]?.id
        guard hasUnsavedDraft else {
            reloadData(select: selectedID)
            return
        }

        isRefreshingConfiguration = true
        defer { isRefreshingConfiguration = false }
        templates = store.loadUpdateTemplates()
        tableView.reloadData()
        if let selectedID, let index = templates.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private var hasUnsavedDraft: Bool {
        nameField.stringValue != editingTemplate.name
            || UI.documentTextView(from: contentScrollView).string != editingTemplate.content
    }

    private func applyTemplateToFields(_ template: UpdateTemplate) {
        editingTemplate = template
        nameField.stringValue = template.name
        UI.documentTextView(from: contentScrollView).string = template.content
    }

    @objc private func newTemplate() {
        tableView.deselectAll(nil)
        applyTemplateToFields(UpdateTemplate())
        nameField.becomeFirstResponder()
    }

    @objc private func deleteTemplate() {
        guard let selected = templates[safe: tableView.selectedRow] else {
            return
        }
        do {
            try store.deleteUpdateTemplate(id: selected.id)
            reloadData(select: nil)
        } catch {
            UI.showAlert(title: "删除失败", message: error.localizedDescription, style: .critical, window: window)
        }
    }

    @objc private func saveTemplate() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UI.documentTextView(from: contentScrollView).string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            UI.showAlert(title: "提示", message: "请填写模板名称", style: .warning, window: window)
            return
        }
        guard !content.isEmpty else {
            UI.showAlert(title: "提示", message: "请填写模板内容", style: .warning, window: window)
            return
        }

        var template = editingTemplate
        template.name = name
        template.content = content
        do {
            try store.saveUpdateTemplate(template)
            reloadData(select: template.id)
            UI.showAlert(title: "提示", message: "操作成功", window: window)
        } catch {
            UI.showAlert(title: "保存失败", message: error.localizedDescription, style: .critical, window: window)
        }
    }

    @objc private func closeWindow() {
        close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        templates.count
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
        cell.textField?.stringValue = templates[row].displayName
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshingConfiguration else {
            return
        }
        guard let selected = templates[safe: tableView.selectedRow] else {
            return
        }
        applyTemplateToFields(selected)
    }
}
