import AppKit
import OSLog
import UniformTypeIdentifiers

let log = Logger(subsystem: "de.jonas.PaperlessDrop", category: "app")

/// Transparent view laid over the status bar button that accepts dragged files.
/// Non-PDFs are accepted too, so the queue can show them as skipped.
/// It doesn't override any mouse handling, so clicks travel up the responder
/// chain to the button and the menu still opens.
@MainActor
final class DropTargetView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onDragEntered: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let count = fileURLs(in: sender).count
        log.debug("Drag entered, \(count) file(s)")
        onDragEntered()
        return count == 0 ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func fileURLs(in info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    static func isPDF(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .pdf) ?? false
    }
}
