import Foundation
import Testing

@MainActor
@Suite("UploadQueue", .timeLimit(.minutes(1)))
struct UploadQueueTests {
    let server = StubServer()
    let queue = UploadQueue()

    init() {
        let stub = server
        queue.makeClient = { stub.client() }
        queue.notificationsEnabled = false // a test process must not post real notifications
    }

    /// A Paperless that accepts everything and finishes processing straight away.
    func respondSuccessfully(documentID: Int = 7, title: String? = "Electricity bill October") {
        let taskID = UUID().uuidString
        let titleAnswer = StubResponse.json(title.map { ["title": $0] } ?? [String: String]())
        server.respond { request in
            switch request.url?.requestPath ?? "" {
            case "/api/documents/post_document/": return .text("\"\(taskID)\"")
            case "/api/tasks/": return TaskJSON.v10("success", documentIDs: [documentID])
            case let path where path.hasPrefix("/api/documents/"): return titleAnswer
            default: return StubResponse(status: 404)
            }
        }
    }

    func waitUntilIdle() async {
        for _ in 0..<1000 {
            if !queue.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The queue was still busy after 10 seconds")
    }

    // MARK: - Outcomes

    @Test("a PDF is uploaded and ends as done, with the title Paperless gave it")
    func uploadsAPDF() async throws {
        let file = try TempFile()
        defer { file.remove() }
        respondSuccessfully(documentID: 7, title: "Electricity bill October")
        let busy = Recorder<Bool>()
        queue.onBusyChanged = { busy.record($0) }

        queue.add([file.url])
        await waitUntilIdle()

        #expect(queue.items.map(\.status) == [.done(documentID: 7, title: "Electricity bill October")])
        #expect(queue.isBusy == false)
        #expect(busy.values == [true, false])
    }

    @Test("a file that isn't a PDF is skipped without any request")
    func skipsOtherFiles() async throws {
        let note = try TempFile(name: "notes.txt", contents: Data("hello".utf8))
        defer { note.remove() }
        let requests = Recorder<RecordedRequest>()
        server.respond { request in
            requests.record(RecordedRequest(request))
            return StubResponse(status: 500)
        }

        queue.add([note.url])

        #expect(queue.items.map(\.status) == [.skipped("Not a PDF – skipped")])
        #expect(queue.isBusy == false)
        #expect(requests.count == 0)
    }

    @Test("a duplicate is reported as one, with the title of the original")
    func reportsDuplicates() async throws {
        let file = try TempFile()
        defer { file.remove() }
        let taskID = UUID().uuidString
        server.respond { request in
            switch request.url?.requestPath ?? "" {
            case "/api/documents/post_document/": return .text("\"\(taskID)\"")
            case "/api/tasks/": return TaskJSON.v10("failure", resultData: ["duplicate_of": 12])
            case "/api/documents/12/": return .json(["title": "Original invoice"])
            default: return StubResponse(status: 404)
            }
        }

        queue.add([file.url])
        await waitUntilIdle()

        #expect(queue.items.map(\.status) == [.duplicate(of: 12, title: "Original invoice")])
    }

    @Test("a rejected token fails the file and points to Settings")
    func rejectedToken() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in .text("", status: 401) }

        queue.add([file.url])
        await waitUntilIdle()

        let message = PaperlessError.unauthorized.errorDescription ?? ""
        #expect(queue.items.map(\.status) == [.failed(message, needsSettings: true)])
        #expect(queue.items.first?.needsSettings == true)
    }

    @Test("a server error is a plain failure that Settings can't fix")
    func serverError() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in .text("", status: 500) }

        queue.add([file.url])
        await waitUntilIdle()

        let message = PaperlessError.http(500).errorDescription ?? ""
        #expect(queue.items.map(\.status) == [.failed(message, needsSettings: false)])
    }

    @Test("without a saved URL and token the file fails and the app is asked to open Settings")
    func notConfigured() async throws {
        let file = try TempFile()
        defer { file.remove() }
        queue.makeClient = { throw PaperlessError.notConfigured }
        let openedSettings = Recorder<Bool>()
        queue.onNotConfigured = { openedSettings.record(true) }

        queue.add([file.url])
        await waitUntilIdle()

        let message = PaperlessError.notConfigured.errorDescription ?? ""
        #expect(queue.items.map(\.status) == [.failed(message, needsSettings: true)])
        #expect(openedSettings.count == 1)
    }

    // MARK: - Retry, cancel, clear

    @Test("retry puts a failed file back in line, and this time it can succeed")
    func retryAFailure() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in .text("", status: 500) }
        queue.add([file.url])
        await waitUntilIdle()
        let id = try #require(queue.items.first?.id)
        #expect(queue.items.first?.status.isFailure == true)

        respondSuccessfully()
        queue.retry(id)
        await waitUntilIdle()

        #expect(queue.items.map(\.status) == [.done(documentID: 7, title: "Electricity bill October")])
    }

    @Test("retry ignores files that did not fail")
    func retryIgnoresOthers() async throws {
        let file = try TempFile()
        defer { file.remove() }
        respondSuccessfully()
        queue.add([file.url])
        await waitUntilIdle()
        let id = try #require(queue.items.first?.id)

        queue.retry(id)

        #expect(queue.isBusy == false)
        #expect(queue.items.count == 1)
    }

    @Test("retry by location requeues the failed file and adds files the list no longer has")
    func retryByLocation() async throws {
        let failed = try TempFile(name: "First.pdf")
        let unknown = try TempFile(name: "Second.pdf")
        defer { failed.remove(); unknown.remove() }
        server.respond { _ in .text("", status: 500) }
        queue.add([failed.url])
        await waitUntilIdle()

        respondSuccessfully()
        queue.retry(fileURLs: [failed.url, unknown.url])
        await waitUntilIdle()

        #expect(queue.items.map(\.fileURL.lastPathComponent) == ["First.pdf", "Second.pdf"])
        #expect(queue.items.allSatisfy { $0.status == .done(documentID: 7, title: "Electricity bill October") })
    }

    @Test("cancel removes a file that is still waiting")
    func cancelWaitingFile() async throws {
        let first = try TempFile(name: "First.pdf")
        let second = try TempFile(name: "Second.pdf")
        defer { first.remove(); second.remove() }
        respondSuccessfully()
        let stub = server
        queue.makeClient = { // slow, so both files are still waiting when we cancel
            try await Task.sleep(for: .milliseconds(100))
            return stub.client()
        }

        queue.add([first.url, second.url])
        let secondID = try #require(queue.items.last?.id)
        queue.cancel(secondID)
        await waitUntilIdle()

        #expect(queue.items.map(\.fileURL.lastPathComponent) == ["First.pdf"])
    }

    @Test("clearFinished removes finished files")
    func clearFinished() async throws {
        let file = try TempFile()
        defer { file.remove() }
        respondSuccessfully()
        queue.add([file.url])
        await waitUntilIdle()
        #expect(queue.items.count == 1)

        queue.clearFinished()

        #expect(queue.items.isEmpty)
    }

    // MARK: - Titles and status helpers

    nonisolated static let titleCases: [(file: String, title: String?, expected: String?)] = [
        ("Invoice October.pdf", "Invoice October", nil),            // same as the file name
        ("Invoice October.pdf", "invoice OCTOBER", nil),            // ... ignoring case
        ("scan0042.pdf", "Rent contract Aachen", "Rent contract Aachen"),
        ("scan0042.pdf", "  Rent contract  ", "Rent contract"),     // trimmed
        ("scan0042.pdf", "   ", nil),                               // blank
        ("scan0042.pdf", nil, nil),                                 // none
    ]

    @Test("a title is only shown when it says more than the file name", arguments: titleCases)
    func distinctTitle(file: String, title: String?, expected: String?) {
        let url = URL(fileURLWithPath: "/tmp/\(file)")
        let done = UploadQueue.Item(fileURL: url, status: .done(documentID: 1, title: title))
        let duplicate = UploadQueue.Item(fileURL: url, status: .duplicate(of: 1, title: title))

        #expect(done.distinctTitle == expected)
        #expect(duplicate.distinctTitle == expected)
    }

    @Test("only finished-with-a-document states have a title")
    func noTitleWhileRunning() {
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let states: [UploadQueue.Status] = [.queued, .uploading(progress: 0.5), .processing, .skipped("x"), .failed("x")]
        for status in states {
            #expect(UploadQueue.Item(fileURL: url, status: status).distinctTitle == nil)
        }
    }

    nonisolated static let statusCases: [(UploadQueue.Status, active: Bool, failure: Bool)] = [
        (.queued, true, false),
        (.uploading(progress: 0.5), true, false),
        (.processing, true, false),
        (.done(documentID: 1, title: nil), false, false),
        (.duplicate(of: 1, title: nil), false, false),
        (.skipped("x"), false, false),
        (.failed("x"), false, true),
        (.failed("x", needsSettings: true), false, true),
    ]

    @Test("statuses know whether they are running or failed", arguments: statusCases)
    func statusFlags(status: UploadQueue.Status, active: Bool, failure: Bool) {
        #expect(status.isActive == active)
        #expect(status.isFailure == failure)
    }
}

@MainActor
@Suite("PDF detection")
struct PDFDetectionTests {
    @Test("PDFs are recognised by their type", arguments: [
        ("a.pdf", true), ("SCAN.PDF", true), ("notes.txt", false), ("image.png", false), ("archive.zip", false),
    ])
    func detects(name: String, expected: Bool) throws {
        let file = try TempFile(name: name)
        defer { file.remove() }

        #expect(DropTargetView.isPDF(file.url) == expected)
    }

    @Test("a file that doesn't exist is not a PDF")
    func missingFile() {
        #expect(DropTargetView.isPDF(URL(fileURLWithPath: "/nonexistent/missing.pdf")) == false)
    }
}
