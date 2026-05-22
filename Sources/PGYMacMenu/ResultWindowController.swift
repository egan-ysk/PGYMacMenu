import AppKit
import CoreImage

final class ResultWindowController: NSWindowController {
    private let response: PgyerResponse
    private let openButton = UI.primaryButton("打开蒲公英", target: nil, action: nil)
    private let copyButton = UI.button("复制短链", target: nil, action: nil)
    private let qrCodeImageView = NSImageView()

    private var appURL: URL? {
        response.data?.appURL
    }

    private var shortLinkText: String {
        appURL?.absoluteString ?? "未返回"
    }

    init(response: PgyerResponse) {
        self.response = response
        super.init(window: UI.makeWindow(title: "上传成功", width: 860, height: 560, minWidth: 780, minHeight: 500))
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func close() {
        qrCodeImageView.image = nil
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
        contentView.addSubview(rootStack)

        let header = makeHeaderView()
        let qrSection = makeQRCodeSection()
        let detailsStack = NSStackView(views: [makeInfoSection(), makeUpdateSection()])
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 14
        detailsStack.translatesAutoresizingMaskIntoConstraints = false

        let bodyStack = NSStackView(views: [qrSection, detailsStack])
        bodyStack.orientation = .horizontal
        bodyStack.alignment = .top
        bodyStack.spacing = 18
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = UI.button("关闭", target: self, action: #selector(closeWindow))
        let footer = NSStackView(views: [flexibleSpace(), closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        [header, bodyStack, footer].forEach(rootStack.addArrangedSubview)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            header.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            qrSection.widthAnchor.constraint(equalToConstant: 270),
            detailsStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 500)
        ])
    }

    private func makeHeaderView() -> NSView {
        let data = response.data
        let icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "成功")
            ?? NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: "成功")
        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        iconView.contentTintColor = .systemGreen
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 42).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let titleLabel = NSTextField(labelWithString: valueOrFallback(data?.buildName, fallback: "上传成功"))
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        var subtitleParts: [String] = []
        if let version = data?.buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            subtitleParts.append("版本 \(version)")
        }
        if let identifier = data?.buildIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
            subtitleParts.append(identifier)
        }
        let fileSize = formatFileSize(data?.buildFileSize)
        if fileSize != "未返回" {
            subtitleParts.append(fileSize)
        }
        let subtitleLabel = NSTextField(labelWithString: subtitleParts.joined(separator: " · "))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let header = NSStackView(views: [iconView, textStack, flexibleSpace(), makeStatusBadge()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    private func makeQRCodeSection() -> NSView {
        qrCodeImageView.image = appURL.flatMap { makeQRCodeImage(for: $0.absoluteString) }
            ?? NSImage(systemSymbolName: "qrcode", accessibilityDescription: "二维码")
        qrCodeImageView.imageScaling = .scaleProportionallyUpOrDown
        qrCodeImageView.translatesAutoresizingMaskIntoConstraints = false
        qrCodeImageView.widthAnchor.constraint(equalToConstant: 210).isActive = true
        qrCodeImageView.heightAnchor.constraint(equalToConstant: 210).isActive = true

        let qrContainer = NSView()
        qrContainer.wantsLayer = true
        qrContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        qrContainer.layer?.cornerRadius = 8
        qrContainer.translatesAutoresizingMaskIntoConstraints = false
        qrContainer.addSubview(qrCodeImageView)
        NSLayoutConstraint.activate([
            qrCodeImageView.centerXAnchor.constraint(equalTo: qrContainer.centerXAnchor),
            qrCodeImageView.centerYAnchor.constraint(equalTo: qrContainer.centerYAnchor),
            qrContainer.widthAnchor.constraint(equalToConstant: 230),
            qrContainer.heightAnchor.constraint(equalToConstant: 230)
        ])

        let titleLabel = NSTextField(labelWithString: "安装短链")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let linkLabel = UI.valueLabel(shortLinkText)
        linkLabel.isSelectable = true
        linkLabel.lineBreakMode = .byTruncatingMiddle

        copyButton.target = self
        copyButton.action = #selector(copyShortLink)
        copyButton.isEnabled = appURL != nil
        openButton.target = self
        openButton.action = #selector(openPgyer)
        openButton.isEnabled = appURL != nil
        let buttonStack = NSStackView(views: [copyButton, openButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        let contentStack = NSStackView(views: [qrContainer, titleLabel, linkLabel, buttonStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 12
        return makeSection(title: "扫码安装", content: contentStack)
    }

    private func makeInfoSection() -> NSView {
        let data = response.data
        let grid = UI.gridStack()
        [
            ("应用名称", valueOrFallback(data?.buildName)),
            ("包名", valueOrFallback(data?.buildIdentifier)),
            ("版本号", valueOrFallback(data?.buildVersion)),
            ("App Build", valueOrFallback(data?.buildVersionNo)),
            ("蒲公英 Build", valueOrFallback(data?.buildBuildVersion)),
            ("文件名", valueOrFallback(data?.buildFileName)),
            ("文件大小", formatFileSize(data?.buildFileSize)),
            ("上传时间", valueOrFallback(data?.buildCreated)),
            ("更新时间", valueOrFallback(data?.buildUpdated))
        ].forEach { title, value in
            let label = UI.valueLabel(value)
            label.isSelectable = true
            UI.addRow(grid, title: title, view: label)
        }
        return makeSection(title: "发布信息", content: grid)
    }

    private func makeUpdateSection() -> NSView {
        let updateText = valueOrFallback(response.data?.buildUpdateDescription)
        let scrollView = UI.textView(initialText: updateText, minHeight: 110, minWidth: 500)
        let textView = UI.documentTextView(from: scrollView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = updateText == "未返回" ? .secondaryLabelColor : .labelColor
        return makeSection(title: "更新说明", content: scrollView)
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
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        return box
    }

    private func makeStatusBadge() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let label = NSTextField(labelWithString: "上传成功")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .systemGreen

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.13).cgColor
        stack.layer?.cornerRadius = 12
        stack.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
        stack.layer?.borderWidth = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return stack
    }

    private func makeQRCodeImage(for text: String) -> NSImage? {
        guard let messageData = text.data(using: .utf8),
              let qrFilter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        qrFilter.setValue(messageData, forKey: "inputMessage")
        qrFilter.setValue("M", forKey: "inputCorrectionLevel")
        guard var outputImage = qrFilter.outputImage else {
            return nil
        }
        if let colorFilter = CIFilter(name: "CIFalseColor") {
            colorFilter.setValue(outputImage, forKey: kCIInputImageKey)
            colorFilter.setValue(CIColor(color: .black), forKey: "inputColor0")
            colorFilter.setValue(CIColor(color: .white), forKey: "inputColor1")
            outputImage = colorFilter.outputImage ?? outputImage
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private func formatFileSize(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "未返回"
        }
        guard let size = Int64(value) else {
            return value
        }
        return readableFileSize(size)
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func copyShortLink() {
        guard let appURL else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appURL.absoluteString, forType: .string)
        copyButton.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "复制短链"
        }
    }

    @objc private func openPgyer() {
        guard let appURL else {
            return
        }
        NSWorkspace.shared.open(appURL)
    }

    @objc private func closeWindow() {
        close()
    }
}
