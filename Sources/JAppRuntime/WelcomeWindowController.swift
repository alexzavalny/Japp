import AppKit
import JAppKit

/// Shown when JApp Runtime itself is opened rather than a `.japp` file.
@MainActor
final class WelcomeWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "JApp Runtime"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: "JApp Runtime")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let version = NSTextField(labelWithString: "Version \(JAppVersion.runtime)")
        version.textColor = .secondaryLabelColor
        let text = NSTextField(wrappingLabelWithString:
            "Double-click a .japp file in Finder to run it. To change an app, right-click it and choose Services › Edit JApp Source (or use File › Edit Source in this app).")
        text.alignment = .center
        text.preferredMaxLayoutWidth = 400

        let open = NSButton(title: "Open App…", target: NSApp.delegate, action: #selector(AppDelegate.openDocument(_:)))
        open.keyEquivalent = "\r"
        let edit = NSButton(title: "Edit Source…", target: NSApp.delegate, action: #selector(AppDelegate.editSource(_:)))
        let example = NSButton(title: "Open Calculator Example", target: NSApp.delegate, action: #selector(AppDelegate.openExample(_:)))
        let buttons = NSStackView(views: [example, edit, open])
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, version, text, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: text)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 30, bottom: 24, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}
