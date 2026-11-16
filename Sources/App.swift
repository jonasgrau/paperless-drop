import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        Notifier.shared.setUp()
        statusItemController = StatusItemController()
    }

    /// Quitting mid-batch would silently drop the remaining files, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard statusItemController?.isBusy == true else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Uploads are still running"
        alert.informativeText = "Files that haven't finished uploading won't reach Paperless."
        alert.addButton(withTitle: "Keep Uploading")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    @objc private func openSettings() { statusItemController?.openSettings() }
    @objc private func choosePDFs() { statusItemController?.choosePDFs() }

    /// Never visible (LSUIElement), but its key equivalents work: text fields only get
    /// ⌘X/⌘C/⌘V/⌘A/⌘Z through the Edit menu, and ⌘, ⌘O ⌘Q should work wherever the panel
    /// or the Settings window has the keyboard.
    private func makeMainMenu() -> NSMenu {
        let app = NSMenu(title: "Paperless Drop")
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Paperless Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Choose PDFs…", action: #selector(choosePDFs), keyEquivalent: "o").target = self

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for submenu in [app, file, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}
