import AppKit
import JAppKit

/// The "Edit Source" window.
///
/// The app's files are unpacked into a workspace folder that opens in the
/// user's code editor. This small window is the document-like control for that
/// folder: it shows what changed, and **Save** packs the folder back into the
/// `.japp` file (validated, atomically, with a backup). Saving is always an
/// explicit action, because external editors give no reliable "done" signal.
@MainActor
final class EditSessionController: NSWindowController, NSWindowDelegate {
    let workspace: SourceWorkspace
    var archiveURL: URL { workspace.archiveURL }
    var onClose: ((EditSessionController) -> Void)?

    private let editors = EditorLocator.installedEditors()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let editorPopup = NSPopUpButton()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let runButton = NSButton(title: "Save & Run", target: nil, action: nil)
    private let keepInFront = NSButton(checkboxWithTitle: "Keep this window in front", target: nil, action: nil)
    private var refreshTimer: Timer?
    private var lastSaved: Date?

    /// Opens (or resumes) the workspace for `archiveURL`, shows the window and opens the code editor.
    static func open(archiveURL: URL) throws -> EditSessionController? {
        let (workspace, outcome) = try SourceWorkspace.open(archiveURL: archiveURL)
        if outcome == .resumedArchiveChanged {
            if try workspace.changes().isEmpty {
                try workspace.discardChanges()
            } else {
                let alert = NSAlert()
                alert.messageText = "“\(archiveURL.lastPathComponent)” changed since you started editing it."
                alert.informativeText = "The source folder still has your unsaved changes. Keep editing them, or discard them and reload the source from the file?"
                alert.addButton(withTitle: "Keep My Changes")
                alert.addButton(withTitle: "Reload from File")
                if alert.runModal() == .alertSecondButtonReturn { try workspace.discardChanges() }
            }
        }
        let controller = EditSessionController(workspace: workspace)
        controller.bringToFront()
        // Automated runs must not pop editor or Finder windows on the user's screen.
        if !RuntimeSettings.isAutomating { controller.openInEditor(nil) }
        return controller
    }

    private init(workspace: SourceWorkspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildInterface()
        updateHeader()
        refreshStatus()
        window.center()

        let floats = RuntimeSettings.flag("JAppEditWindowInFront", default: true)
        keepInFront.state = floats ? .on : .off
        window.level = floats ? .floating : .normal

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func bringToFront() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Interface

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 52).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 52).isActive = true
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 12)
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [iconView, titles])
        header.spacing = 12

        pathLabel.stringValue = workspace.sourceURL.path
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        pathLabel.toolTip = workspace.sourceURL.path
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealFolder(_:)))
        let folderCaption = NSTextField(labelWithString: "Source folder:")
        let folderRow = NSStackView(views: [folderCaption, pathLabel, reveal])
        folderRow.spacing = 8

        for editor in editors { editorPopup.addItem(withTitle: editor.name) }
        editorPopup.selectItem(withTitle: EditorLocator.preferredEditor(in: editors).name)
        editorPopup.target = self
        editorPopup.action = #selector(editorChanged(_:))
        let openButton = NSButton(title: "Open", target: self, action: #selector(openInEditor(_:)))
        keepInFront.target = self
        keepInFront.action = #selector(toggleKeepInFront(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editorRow = NSStackView(views: [NSTextField(labelWithString: "Open in:"), editorPopup, openButton, spacer, keepInFront])
        editorRow.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 500

        let discard = NSButton(title: "Discard Changes…", target: self, action: #selector(discardChanges(_:)))
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        runButton.target = self
        runButton.action = #selector(saveAndRun(_:))
        runButton.keyEquivalent = "\r"
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [discard, bottomSpacer, saveButton, runButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [header, folderRow, editorRow, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            // Slack below lets the status text wrap onto a second line.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            editorRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: content.frame.width, height: stack.fittingSize.height + 24))
    }

    private func updateHeader() {
        let package = try? JAppPackage.load(from: workspace.sourceURL)
        let name = package?.manifest.name ?? workspace.session.sourceFolderName
        titleLabel.stringValue = name
        subtitleLabel.stringValue = "Editing the source of “\(archiveURL.lastPathComponent)”"
        iconView.image = package.flatMap(IconManager.image(for:)) ?? IconManager.genericIcon
        window?.title = "\(name) — Edit Source"
        window?.representedURL = archiveURL
    }

    private func refreshStatus() {
        guard let changes = try? workspace.changes() else {
            statusLabel.stringValue = "The source folder can’t be read. Was it moved or deleted?"
            return
        }
        let savedNote = lastSaved.map { "Saved at \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)). " } ?? ""
        if changes.isEmpty {
            statusLabel.stringValue = savedNote + "No unsaved changes. Edit the files in the source folder, then click Save."
        } else {
            let listed = changes.prefix(5).map { change -> String in
                switch change.kind {
                case .added: return "\(change.path) (new)"
                case .deleted: return "\(change.path) (deleted)"
                case .modified: return change.path
                }
            }
            let more = changes.count > 5 ? ", …" : ""
            let noun = changes.count == 1 ? "unsaved change" : "unsaved changes"
            statusLabel.stringValue = "\(changes.count) \(noun): " + listed.joined(separator: ", ") + more
        }
        saveButton.isEnabled = !changes.isEmpty
        window?.isDocumentEdited = !changes.isEmpty
        if RuntimeSettings.isAutomating {
            Automation.reportEditSession(workspace, status: statusLabel.stringValue)
            Automation.renderWindow(window, to: "edit-window.png")
        }
    }

    // MARK: Actions

    @objc func openInEditor(_ sender: Any?) {
        let index = max(0, editorPopup.indexOfSelectedItem)
        guard editors.indices.contains(index) else { return }
        EditorLocator.open(workspace.sourceURL, with: editors[index])
    }

    @objc private func editorChanged(_ sender: Any?) {
        let index = editorPopup.indexOfSelectedItem
        guard editors.indices.contains(index) else { return }
        RuntimeSettings.editorBundleID = editors[index].bundleID ?? "finder"
        openInEditor(nil)
    }

    @objc private func revealFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([workspace.sourceURL])
    }

    @objc private func toggleKeepInFront(_ sender: Any?) {
        let floats = keepInFront.state == .on
        window?.level = floats ? .floating : .normal
        UserDefaults.standard.set(floats, forKey: "JAppEditWindowInFront")
    }

    @objc func save(_ sender: Any?) { performSave(run: false) }

    @objc func saveAndRun(_ sender: Any?) { performSave(run: true) }

    @objc private func discardChanges(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Discard all unsaved changes to “\(titleLabel.stringValue)”?"
        alert.informativeText = "The source folder will be reset to the contents of “\(archiveURL.lastPathComponent)”. This can’t be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try workspace.discardChanges()
        } catch {
            presentError("The changes could not be discarded.", error)
        }
        updateHeader()
        refreshStatus()
    }

    @discardableResult
    private func performSave(run: Bool, overwriting: Bool = false) -> Bool {
        do {
            let result = try workspace.save(overwritingExternalChanges: overwriting)
            lastSaved = Date()
            if let package = try? JAppPackage.load(from: archiveURL) { IconManager.applyFinderIcon(for: package) }
            for warning in result.warnings { FileHandle.standardError.write(Data("[\(result.manifest.name)] \(warning)\n".utf8)) }
            updateHeader()
            refreshStatus()
            if run { ApplicationManager.shared.runUpdated(archiveURL) }
            return true
        } catch WorkspaceError.archiveChangedOnDisk {
            let alert = NSAlert()
            alert.messageText = "“\(archiveURL.lastPathComponent)” was changed by another program."
            alert.informativeText = "Saving replaces that version with the source in this editing session. The replaced version is kept in the workspace’s backups folder."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Replace")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            return performSave(run: run, overwriting: true)
        } catch {
            presentError("“\(archiveURL.lastPathComponent)” was not saved.", error)
            return false
        }
    }

    private func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let changes = (try? workspace.changes()) ?? []
        if !changes.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to “\(titleLabel.stringValue)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: if !performSave(run: false) { return false }
            case .alertThirdButtonReturn: break
            default: return false
            }
        }
        // The workspace is temporary: once saved (or discarded) it is removed.
        try? workspace.remove()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose?(self)
    }

    /// On quit, clean workspaces are removed; ones with unsaved edits are kept
    /// so the next "Edit Source" resumes them.
    func cleanUpForTermination() {
        if (try? workspace.changes())?.isEmpty == true { try? workspace.remove() }
    }
}
