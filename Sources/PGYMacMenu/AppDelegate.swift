import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum APKOpenSource {
        case home
        case external
    }

    private let store = ConfigurationStore()
    private var statusItem: NSStatusItem?
    private var homeWindowController: HomeWindowController?
    private var apiKeyWindowController: APIKeySettingsWindowController?
    private var templateWindowController: TemplateSettingsWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var activeUploadWindows: [UploadWindowController] = []
    private var activeResultWindows: [ResultWindowController] = []
    private var pendingOpenURLs: [URL] = []
    private var pendingHomeOpenWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        applyMenuBarPreferences()

        let arguments = CommandLine.arguments.dropFirst().map(URL.init(fileURLWithPath:))
        let apkArguments = arguments.filter(Self.isAPK)
        if !apkArguments.isEmpty {
            pendingOpenURLs.append(contentsOf: apkArguments)
        }
        if pendingOpenURLs.isEmpty {
            scheduleHomeWindowOpen()
        } else {
            openPendingURLsIfNeeded(source: .external)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        cancelScheduledHomeWindowOpen()
        let apkURLs = urls.filter(Self.isAPK)
        guard !apkURLs.isEmpty else {
            UI.showAlert(title: "提示", message: "文件无效，请选择 APK 文件", style: .warning)
            return
        }
        pendingOpenURLs.append(contentsOf: apkURLs)
        openPendingURLsIfNeeded(source: .external)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        cancelScheduledHomeWindowOpen()
        let url = URL(fileURLWithPath: filename)
        guard Self.isAPK(url) else {
            return false
        }
        pendingOpenURLs.append(url)
        openPendingURLsIfNeeded(source: .external)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !store.loadPreferences().allowMenuBarRunning
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag || !activeUploadWindows.isEmpty || !activeResultWindows.isEmpty {
            return true
        }
        openHomeWindow()
        return true
    }

    private func applyMenuBarPreferences() {
        let preferences = store.loadPreferences()
        if preferences.allowMenuBarRunning && preferences.showMenuBarIcon {
            configureStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "PGYMacMenu")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "PGYMacMenu")
        let aboutItem = NSMenuItem(
            title: "关于 PGYMacMenu",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "退出 PGYMacMenu",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        [
            NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem.separator(),
            NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ].forEach { item in
            item.target = nil
            editMenu.addItem(item)
        }
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        if statusItem != nil {
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "PGYMacMenu") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeft
            }
            button.title = "PGY"
            button.toolTip = "PGYMacMenu"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 PGYMacMenu", action: #selector(openHome), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "上传 APK...", action: #selector(selectAPK), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "API Key 配置...", action: #selector(openAPIKeySettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "更新模板配置...", action: #selector(openTemplateSettings), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "偏好设置...", action: #selector(openPreferences), keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 PGYMacMenu", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func openHome() {
        openHomeWindow()
    }

    private func openHomeWindow() {
        cancelScheduledHomeWindowOpen()
        let controller = homeWindowController ?? HomeWindowController(
            onSelectAPK: { [weak self] in self?.selectAPK() },
            onAPIKeySettings: { [weak self] in self?.openAPIKeySettings() },
            onTemplateSettings: { [weak self] in self?.openTemplateSettings() },
            onPreferences: { [weak self] in self?.openPreferences() }
        )
        homeWindowController = controller
        controller.window?.delegate = self
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleHomeWindowOpen() {
        cancelScheduledHomeWindowOpen()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingOpenURLs.isEmpty,
                  self.activeUploadWindows.isEmpty,
                  self.activeResultWindows.isEmpty else {
                return
            }
            self.openHomeWindow()
        }
        pendingHomeOpenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func cancelScheduledHomeWindowOpen() {
        pendingHomeOpenWorkItem?.cancel()
        pendingHomeOpenWorkItem = nil
    }

    private func closeHomeWindowIfNeeded() {
        guard let controller = homeWindowController else {
            return
        }
        controller.close()
        homeWindowController = nil
    }

    @objc private func selectAPK() {
        let panel = NSOpenPanel()
        panel.title = "选择 APK 文件"
        panel.message = "请选择需要上传到蒲公英的 APK 文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            openAPK(url, source: .home)
        }
    }

    @objc private func openAPIKeySettings() {
        let controller = apiKeyWindowController ?? APIKeySettingsWindowController(store: store)
        apiKeyWindowController = controller
        controller.window?.delegate = self
        controller.showWindow(nil)
    }

    @objc private func openTemplateSettings() {
        let controller = templateWindowController ?? TemplateSettingsWindowController(store: store)
        templateWindowController = controller
        controller.window?.delegate = self
        controller.showWindow(nil)
    }

    @objc private func openPreferences() {
        let controller = preferencesWindowController ?? PreferencesWindowController(store: store) { [weak self] in
            self?.applyMenuBarPreferences()
            self?.terminateIfNeededAfterWindowClose()
        }
        preferencesWindowController = controller
        controller.window?.delegate = self
        controller.showWindow(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openPendingURLsIfNeeded(source: APKOpenSource) {
        guard !pendingOpenURLs.isEmpty else {
            return
        }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        urls.forEach { openAPK($0, source: source) }
    }

    private func openAPK(_ url: URL, source: APKOpenSource) {
        cancelScheduledHomeWindowOpen()
        guard Self.isAPK(url) else {
            UI.showAlert(title: "提示", message: "文件无效，请选择 APK 文件", style: .warning)
            return
        }
        let info = ApkMetadataReader.read(fileURL: url, preferences: store.loadPreferences())
        let controller = UploadWindowController(
            store: store,
            apkInfo: info,
            onBackToHome: { [weak self] in self?.openHomeWindow() },
            onComplete: { [weak self] response in self?.showResult(response) }
        )
        controller.window?.delegate = self
        activeUploadWindows.append(controller)
        controller.showWindow(nil)
        if source == .external {
            closeHomeWindowIfNeeded()
        }
    }

    private func showResult(_ response: PgyerResponse) {
        let controller = ResultWindowController(response: response)
        controller.window?.delegate = self
        activeResultWindows.append(controller)
        controller.showWindow(nil)

        if store.loadPreferences().quitAfterSuccessfulUpload {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.terminate(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        activeUploadWindows.removeAll { $0.window === window }
        activeResultWindows.removeAll { $0.window === window }
        if apiKeyWindowController?.window === window {
            apiKeyWindowController = nil
        }
        if homeWindowController?.window === window {
            homeWindowController = nil
        }
        if templateWindowController?.window === window {
            templateWindowController = nil
        }
        if preferencesWindowController?.window === window {
            preferencesWindowController = nil
        }
        terminateIfNeededAfterWindowClose()
    }

    private func terminateIfNeededAfterWindowClose() {
        guard !store.loadPreferences().allowMenuBarRunning else {
            return
        }
        DispatchQueue.main.async {
            let hasVisibleAppWindow = NSApp.windows.contains { window in
                window.isVisible && !(window is NSPanel)
            }
            if !hasVisibleAppWindow {
                NSApp.terminate(nil)
            }
        }
    }

    @objc(uploadAPKService:userData:error:)
    func uploadAPKService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let urls = Self.fileURLs(from: pasteboard)
        let apkURLs = urls.filter(Self.isAPK)
        guard let first = apkURLs.first else {
            error?.pointee = "请选择 APK 文件" as NSString
            return
        }
        DispatchQueue.main.async {
            self.openAPK(first, source: .external)
        }
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var result: [URL] = []

        let nsURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] ?? []
        result.append(contentsOf: nsURLs.map { $0 as URL })

        let fileURLType = NSPasteboard.PasteboardType("public.file-url")
        let legacyURLType = NSPasteboard.PasteboardType("NSURLPboardType")
        for type in [fileURLType, legacyURLType] {
            if let values = pasteboard.propertyList(forType: type) as? [String] {
                result.append(contentsOf: values.compactMap(URL.init(string:)))
            } else if let value = pasteboard.string(forType: type), let url = URL(string: value) {
                result.append(url)
            }
        }

        let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: fileNamesType) as? [String] {
            result.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        } else if let path = pasteboard.string(forType: fileNamesType), !path.isEmpty {
            result.append(URL(fileURLWithPath: path))
        }

        return Array(Set(result))
    }

    private static func isAPK(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("apk") == .orderedSame
    }
}
