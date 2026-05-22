import AppKit

enum UI {
    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    static func valueLabel(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func textField(placeholder: String = "") -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        return field
    }

    static func secureField(placeholder: String = "") -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        return field
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    static func primaryButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = button(title, target: target, action: action)
        button.keyEquivalent = "\r"
        button.bezelColor = .controlAccentColor
        return button
    }

    static func textView(initialText: String = "", minHeight: CGFloat = 120, minWidth: CGFloat = 420) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true

        let textView = NSTextView()
        textView.string = initialText
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return scrollView
    }

    static func documentTextView(from scrollView: NSScrollView) -> NSTextView {
        scrollView.documentView as? NSTextView ?? NSTextView()
    }

    static func makeWindow(
        title: String,
        width: CGFloat,
        height: CGFloat,
        minWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        let minimumSize = NSSize(width: minWidth ?? min(width, 520), height: minHeight ?? min(height, 360))
        window.minSize = minimumSize
        window.contentMinSize = minimumSize
        window.isRestorable = false
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        return window
    }

    static func gridStack() -> NSGridView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.yPlacement = .top
        return grid
    }

    static func addRow(_ grid: NSGridView, title: String, view: NSView) {
        let row = grid.addRow(with: [label(title), view])
        row.yPlacement = .top
        if view is NSTextField || view is NSPopUpButton || view is NSScrollView {
            let minWidth = view is NSScrollView ? CGFloat(520) : CGFloat(360)
            let constraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
            constraint.priority = .defaultHigh
            constraint.isActive = true
        }
        if grid.numberOfColumns >= 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .fill
        }
    }

    static func showAlert(title: String, message: String, style: NSAlert.Style = .informational, window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "确定")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

final class BlockTarget: NSObject {
    private let block: () -> Void

    init(_ block: @escaping () -> Void) {
        self.block = block
    }

    @objc func invoke() {
        block()
    }
}
