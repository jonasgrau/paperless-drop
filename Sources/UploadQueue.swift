import Foundation
import Observation

/// Uploads dropped files one at a time and tracks each file's status.
@MainActor
@Observable
final class UploadQueue {
    enum Status: Equatable {
        case queued
        case uploading(progress: Double)
        case processing
        case done(documentID: Int?, title: String?)
        case duplicate(of: Int?, title: String?)
        case skipped(String)
        /// `needsSettings`: the fix is a new URL or token, so the UI offers to open Settings.
        case failed(String, needsSettings: Bool = false)

        var isActive: Bool {
            switch self {
            case .queued, .uploading, .processing: true
            default: false
            }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let fileURL: URL
        var status: Status = .queued

        var needsSettings: Bool {
            if case .failed(_, let needs) = status { needs } else { false }
        }

        /// Paperless' title for the document, if it says more than the file name already does.
        var distinctTitle: String? {
            let title: String?
            switch status {
            case .done(_, let value), .duplicate(_, let value): title = value
            default: return nil
            }
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let stem = fileURL.deletingPathExtension().lastPathComponent
            return title.caseInsensitiveCompare(stem) == .orderedSame ? nil : title
        }
    }

    private struct Outcome: Sendable {
        let documentID: Int?
        let title: String?
    }

    var items: [Item] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: (id: UUID, task: Task<Outcome, any Error>)?
    /// Called when an upload fails because URL or token are missing.
    @ObservationIgnored var onNotConfigured: () -> Void = {}
    /// Called with true when a batch starts and false when it is finished.
    @ObservationIgnored var onBusyChanged: (Bool) -> Void = { _ in }
    // Both exist for tests: a stub client, and no real notifications from a test process.
    @ObservationIgnored var makeClient: @Sendable () async throws -> PaperlessClient = { try await PaperlessClient.fromSettings() }
    @ObservationIgnored var notificationsEnabled = true

    /// True while any file is waiting, uploading or processing.
    var isBusy: Bool { items.contains { $0.status.isActive } }

    func clearFinished() {
        items.removeAll { !$0.status.isActive }
    }

    /// Splits dropped files into PDFs (queued) and everything else (shown as skipped).
    func add(_ urls: [URL]) {
        for url in urls {
            if DropTargetView.isPDF(url) {
                items.append(Item(fileURL: url))
            } else {
                log.info("Rejected non-PDF: \(url.lastPathComponent, privacy: .public)")
                items.append(Item(fileURL: url, status: .skipped("Not a PDF – skipped")))
            }
        }
        startIfNeeded()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status.isFailure else { return }
        items[index].status = .queued
        startIfNeeded()
    }

    /// Requeues failed files by location (the notification's Retry action); files not listed any more are added again.
    func retry(fileURLs: [URL]) {
        for url in fileURLs {
            if let index = items.firstIndex(where: { $0.fileURL == url && $0.status.isFailure }) {
                items[index].status = .queued
            } else {
                items.append(Item(fileURL: url))
            }
        }
        startIfNeeded()
    }

    /// Removes a queued file or aborts a running upload. Files already
    /// processing are in Paperless already and can't be taken back.
    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.status {
        case .queued:
            items.removeAll { $0.id == id }
        case .uploading:
            if current?.id == id { current?.task.cancel() }
        default:
            break
        }
    }

    /// URL of the document in the Paperless web UI, if the item has one.
    func documentURL(for item: Item) -> URL? {
        let id: Int?
        switch item.status {
        case .done(let documentID, _): id = documentID
        case .duplicate(let original, _): id = original
        default: return nil
        }
        guard let id, let base = PaperlessClient.storedBaseURL() else { return nil }
        return URL(string: "\(base)/documents/\(id)/details")
    }

    private func startIfNeeded() {
        guard worker == nil, items.contains(where: { $0.status == .queued }) else { return }
        onBusyChanged(true)
        worker = Task { await processQueue() }
    }

    private func processQueue() async {
        var batch: [UUID] = []
        let makeClient = makeClient
        while let index = items.firstIndex(where: { $0.status == .queued }) {
            let id = items[index].id
            let fileURL = items[index].fileURL
            batch.append(id)
            setStatus(.uploading(progress: 0), for: id)

            let task = Task<Outcome, any Error> { [weak self] in
                let client = try await makeClient()
                let taskID = try await client.upload(fileURL) { fraction in
                    Task { @MainActor in self?.setProgress(fraction, for: id) }
                }
                log.info("Uploaded \(fileURL.lastPathComponent, privacy: .public), task \(taskID, privacy: .public)")
                self?.setStatus(.processing, for: id)
                do {
                    let documentID = try await client.waitForTask(taskID)
                    return Outcome(documentID: documentID, title: await client.documentTitle(documentID))
                } catch PaperlessError.duplicate(let original, _) {
                    throw PaperlessError.duplicate(of: original, title: await client.documentTitle(original))
                }
            }
            current = (id, task)
            do {
                let outcome = try await task.value
                setStatus(.done(documentID: outcome.documentID, title: outcome.title), for: id)
            } catch is CancellationError {
                log.info("Cancelled \(fileURL.lastPathComponent, privacy: .public)")
                items.removeAll { $0.id == id }
                batch.removeAll { $0 == id }
            } catch PaperlessError.duplicate(let original, let title) {
                setStatus(.duplicate(of: original, title: title), for: id)
            } catch {
                let needsSettings = (error as? PaperlessError)?.needsSettings ?? false
                setStatus(.failed(error.localizedDescription, needsSettings: needsSettings), for: id)
                if case PaperlessError.notConfigured = error { onNotConfigured() }
            }
            current = nil
        }
        worker = nil
        onBusyChanged(false)
        notify(about: items.filter { batch.contains($0.id) })
    }

    private func setProgress(_ fraction: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .uploading = items[index].status else { return }
        items[index].status = .uploading(progress: fraction)
    }

    private func setStatus(_ status: Status, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        log.info("\(self.items[index].fileURL.lastPathComponent, privacy: .public): \(String(describing: status), privacy: .public)")
    }

    private func notify(about batch: [Item]) {
        guard notificationsEnabled, !batch.isEmpty else { return }
        let name = { (item: Item) in item.fileURL.lastPathComponent }
        let failed = batch.filter { $0.status.isFailure }
        let duplicates = batch.filter { if case .duplicate = $0.status { true } else { false } }
        let added = batch.count - failed.count - duplicates.count

        if !failed.isEmpty {
            let lines = failed.map { item -> String in
                guard case .failed(let message, _) = item.status else { return "" }
                return "\(name(item)): \(message)"
            }
            let title = batch.count == 1 ? "Upload failed" : "\(failed.count) of \(batch.count) uploads failed"
            Notifier.shared.post(title: title, body: lines.joined(separator: "\n"),
                                 retry: failed.map(\.fileURL),
                                 opensSettings: failed.contains(where: \.needsSettings))
        } else if batch.count == 1 {
            let item = batch[0]
            let title = duplicates.isEmpty ? "Added to Paperless" : "Already in Paperless"
            Notifier.shared.post(title: title, body: item.distinctTitle ?? name(item), openURL: documentURL(for: item))
        } else {
            var parts = ["\(added) added"]
            if !duplicates.isEmpty { parts.append("\(duplicates.count) already in Paperless") }
            Notifier.shared.post(title: parts.joined(separator: ", "),
                                 body: batch.map(name).joined(separator: "\n"),
                                 openURL: PaperlessClient.storedBaseURL().flatMap { URL(string: "\($0)/documents") })
        }
    }
}
