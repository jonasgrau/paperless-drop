import AppKit

/// Owns the menu bar icon, its menu and the drop panel.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings = SettingsWindowController()
    private let queue = UploadQueue()
    /// Shown instead of the button's own image while busy, because only
    /// NSImageView supports symbol effects like the pulse.
    private let busyIcon = NSImageView()
    private let menu = NSMenu()
    private lazy var panel: DropPanelController = DropPanelController(
        queue: queue,
        onDrop: { [weak self] urls in self?.enqueue(urls) },
        onChoose: { [weak self] in self?.choosePDFs() },
        onSettings: { [weak self] in
            self?.panel.hide()
            self?.openSettings()
        }
    )

    var isBusy: Bool { queue.isBusy }

    override init() {
        super.init()
        queue.onNotConfigured = { [weak self] in self?.openSettings() }
        queue.onBusyChanged = { [weak self] busy in self?.setIcon(busy: busy) }
        Notifier.shared.onOpenSettings = { [weak self] in self?.openSettings() }
        Notifier.shared.onRetry = { [weak self] urls in
            self?.queue.retry(fileURLs: urls)
            self?.showPanel(.drag)
        }

        if let button = statusItem.button {
            busyIcon.image = Self.symbol("tray.and.arrow.up.fill", description: "Paperless Drop – uploading")
            busyIcon.frame = button.bounds
            busyIcon.autoresizingMask = [.width, .height]
            busyIcon.isHidden = true
            button.addSubview(busyIcon)

            // Added last so it sits on top and receives the drags.
            let dropView = DropTargetView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onDrop = { [weak self] urls in self?.enqueue(urls) }
            dropView.onDragEntered = { [weak self] in self?.dragEntered() }
            button.addSubview(dropView)
            setIcon(busy: false)

            // No statusItem.menu: that would make every click open the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.addItem(withTitle: "Choose PDFs…", action: #selector(choosePDFs), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Paperless Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Click: the uploads panel. Right-click or ctrl-click: Settings and Quit.
    @objc private func statusItemClicked() {
        guard let button = statusItem.button, let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            panel.hide()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            panel.toggle(below: button)
        }
    }

    private func enqueue(_ urls: [URL]) {
        for url in urls { log.info("Dropped: \(url.path, privacy: .public)") }
        queue.add(urls)
        showPanel(.drag)
    }

    /// A new drag starts with a clean list unless a batch is still running;
    /// otherwise the last batch's results stay visible when the panel is reopened.
    private func dragEntered() {
        if !queue.isBusy { queue.clearFinished() }
        showPanel(.drag)
    }

    private func setIcon(busy: Bool) {
        guard let button = statusItem.button else { return }
        button.image = busy ? nil : Self.symbol("tray.and.arrow.up", description: "Paperless Drop")
        busyIcon.isHidden = !busy
        if busy {
            busyIcon.addSymbolEffect(.pulse, options: .repeating)
        } else {
            busyIcon.removeAllSymbolEffects()
        }
    }

    private static func symbol(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private func showPanel(_ trigger: DropPanelController.Trigger) {
        guard let button = statusItem.button else { return }
        panel.show(below: button, trigger: trigger)
    }

    @objc func openSettings() {
        settings.show()
    }

    /// The keyboard and VoiceOver way in: a file chooser instead of dragging.
    @objc func choosePDFs() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.pdf]
        chooser.allowsMultipleSelection = true
        chooser.canChooseDirectories = false
        chooser.message = "Choose PDFs to upload to Paperless"
        chooser.prompt = "Upload"
        // The drop panel floats above normal windows and would cover the chooser.
        panel.hide()
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard let self else { return }
            if response == .OK {
                for url in chooser.urls { log.info("Chosen: \(url.path, privacy: .public)") }
                self.queue.add(chooser.urls)
            }
            self.showPanel(.menu) // back to the panel, to follow progress or try again
        }
    }
}
