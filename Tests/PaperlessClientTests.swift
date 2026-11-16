import Foundation
import Testing

@Suite("PaperlessClient", .timeLimit(.minutes(1)))
struct PaperlessClientTests {
    let server = StubServer()

    // MARK: - Upload

    @Test("upload sends the file as the multipart field 'document', with the token")
    func uploadRequestShape() async throws {
        let file = try TempFile(name: "Invoice October.pdf", contents: Data("%PDF-1.4 hello".utf8))
        defer { file.remove() }
        let requests = Recorder<RecordedRequest>()
        let taskID = UUID().uuidString
        server.respond { request in
            requests.record(RecordedRequest(request))
            return .text("\"\(taskID)\"")
        }

        let result = try await server.client().upload(file.url)

        #expect(result == taskID)
        let request = try #require(requests.values.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/documents/post_document/")
        #expect(request.headers["Authorization"] == "Token secret-token")
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("name=\"document\"; filename=\"Invoice October.pdf\""))
        #expect(body.contains("Content-Type: application/pdf"))
        #expect(body.contains("%PDF-1.4 hello"))
    }

    @Test("upload accepts the task ID with or without JSON quotes and whitespace",
          arguments: ["\"{id}\"", "\"{id}\"\n", "{id}", "  {id}  "])
    func uploadTaskIDFormats(template: String) async throws {
        let file = try TempFile()
        defer { file.remove() }
        let taskID = UUID().uuidString
        let body = template.replacingOccurrences(of: "{id}", with: taskID)
        server.respond { _ in .text(body) }

        #expect(try await server.client().upload(file.url) == taskID)
    }

    @Test("upload turns HTTP errors into readable ones", arguments: [
        (401, PaperlessError.unauthorized),
        (403, PaperlessError.forbidden),
        (413, PaperlessError.tooLarge),
        (500, PaperlessError.http(500)),
        (503, PaperlessError.http(503)),
    ])
    func uploadHTTPErrors(status: Int, expected: PaperlessError) async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in .text("error page", status: status) }

        await #expect(throws: expected) { try await server.client().upload(file.url) }
    }

    @Test("upload rejects an answer that isn't a task ID, such as a login page")
    func uploadRejectsHTML() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in .text("<html><body>Please sign in</body></html>") }

        await #expect(throws: PaperlessError.badResponse) { try await server.client().upload(file.url) }
    }

    @Test("upload reports an unreachable server")
    func uploadUnreachable() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in throw URLError(.notConnectedToInternet) }

        let error = try #require(await #expect(throws: PaperlessError.self) {
            try await server.client().upload(file.url)
        })
        #expect(error.isUnreachable)
    }

    @Test("a cancelled upload ends as a cancellation, not as an error message")
    func uploadCancelled() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in throw URLError(.cancelled) }

        await #expect(throws: CancellationError.self) { try await server.client().upload(file.url) }
    }

    // MARK: - Waiting for the task

    @Test("waitForTask polls until the task succeeds and returns the document (API v10)")
    func waitV10() async throws {
        let requests = Recorder<RecordedRequest>()
        let script = Script([
            .respond(TaskJSON.v10("pending")),
            .respond(TaskJSON.v10("started")),
            .respond(TaskJSON.v10("success", documentIDs: [42])),
        ])
        server.respond { request in
            requests.record(RecordedRequest(request))
            return try script.next()
        }

        let documentID = try await server.client().waitForTask("abc-123")

        #expect(documentID == 42)
        #expect(requests.count == 3)
        #expect(requests.values.allSatisfy { $0.path == "/api/tasks/" && $0.query == "task_id=abc-123" })
    }

    @Test("waitForTask understands the older API v9: a plain array with uppercase status")
    func waitV9() async throws {
        let script = Script([.respond(TaskJSON.v9("STARTED")), .respond(TaskJSON.v9("SUCCESS", document: 7))])
        server.respond { _ in try script.next() }

        #expect(try await server.client().waitForTask("t") == 7)
    }

    @Test("waitForTask returns nil when a successful task names no document")
    func waitSuccessWithoutDocument() async throws {
        server.respond { _ in TaskJSON.v10("success") }

        #expect(try await server.client().waitForTask("t") == nil)
    }

    @Test("waitForTask keeps polling while the server doesn't know the task yet",
          arguments: [TaskJSON.none, StubResponse.json([Any]())])
    func waitSkipsEmptyAnswers(empty: StubResponse) async throws {
        let script = Script([.respond(empty), .respond(TaskJSON.v10("success", documentIDs: [5]))])
        server.respond { _ in try script.next() }

        #expect(try await server.client().waitForTask("t") == 5)
    }

    @Test("waitForTask reports the server's reason when the task fails", arguments: [
        (TaskJSON.v10("failure", resultData: ["error_message": "File type text/plain not supported"]),
         "File type text/plain not supported"),
        (TaskJSON.v10("failure", resultData: ["reason": "Not consuming: empty file"]),
         "Not consuming: empty file"),
        (TaskJSON.v9("FAILURE", result: "File type text/plain not supported"),
         "File type text/plain not supported"),
        (TaskJSON.v10("revoked"), "Processing failed in Paperless"),
    ])
    func waitFailureMessages(answer: StubResponse, message: String) async throws {
        server.respond { _ in answer }

        await #expect(throws: PaperlessError.taskFailed(message)) { try await server.client().waitForTask("t") }
    }

    @Test("waitForTask recognises a duplicate in both formats", arguments: [
        (TaskJSON.v10("failure", resultData: ["duplicate_of": 12]), 12),
        (TaskJSON.v9("FAILURE", result: "Not consuming scan.pdf: It is a duplicate of other.pdf (#185)"), 185),
    ])
    func waitDuplicates(answer: StubResponse, original: Int) async throws {
        server.respond { _ in answer }

        await #expect(throws: PaperlessError.duplicate(of: original, title: nil)) {
            try await server.client().waitForTask("t")
        }
    }

    @Test("waitForTask gives up when a task never finishes")
    func waitTimesOut() async throws {
        server.respond { _ in TaskJSON.v10("started") }
        var client = server.client()
        client.taskTimeout = 0.05
        let impatient = client

        await #expect(throws: PaperlessError.timedOut) { try await impatient.waitForTask("t") }
    }

    @Test("waitForTask rides out failed polls, and a good answer resets the count")
    func waitToleratesHiccups() async throws {
        let hiccups: [Step] = Array(repeating: .fail(.networkConnectionLost), count: 4)
        let script = Script(hiccups + [.respond(TaskJSON.v10("started"))] + hiccups
                            + [.respond(TaskJSON.v10("success", documentIDs: [3]))])
        server.respond { _ in try script.next() }

        #expect(try await server.client().waitForTask("t") == 3)
    }

    @Test("waitForTask gives up after five failed polls in a row")
    func waitGivesUp() async throws {
        let script = Script([.fail(.notConnectedToInternet)]) // repeats forever
        let requests = Recorder<RecordedRequest>()
        server.respond { request in
            requests.record(RecordedRequest(request))
            return try script.next()
        }

        let error = try #require(await #expect(throws: PaperlessError.self) {
            try await server.client().waitForTask("t")
        })
        #expect(error.isUnreachable)
        #expect(requests.count == 5)
    }

    @Test("waitForTask rejects answers that aren't task lists")
    func waitBadResponse() async throws {
        server.respond { _ in .text("<html>maintenance</html>") }

        await #expect(throws: PaperlessError.badResponse) { try await server.client().waitForTask("t") }
    }

    @Test("waitForTask passes on a rejected token straight away")
    func waitUnauthorized() async throws {
        server.respond { _ in .text("", status: 401) }

        await #expect(throws: PaperlessError.unauthorized) { try await server.client().waitForTask("t") }
    }

    // MARK: - Document title

    @Test("documentTitle asks only for the title and returns it")
    func documentTitle() async throws {
        let requests = Recorder<RecordedRequest>()
        server.respond { request in
            requests.record(RecordedRequest(request))
            return .json(["title": "Electricity bill October"])
        }

        let title = await server.client().documentTitle(4711)

        #expect(title == "Electricity bill October")
        let request = try #require(requests.values.first)
        #expect(request.path == "/api/documents/4711/")
        #expect(request.query == "fields=title")
    }

    @Test("documentTitle is nil when the title can't be had, and never fails")
    func documentTitleFailures() async throws {
        let requests = Recorder<RecordedRequest>()
        server.respond { request in
            requests.record(RecordedRequest(request))
            return .text("not json")
        }
        let client = server.client()

        #expect(await client.documentTitle(nil) == nil)
        #expect(requests.count == 0) // no id, no request
        #expect(await client.documentTitle(1) == nil) // garbage answer

        server.respond { _ in .text("", status: 404) }
        #expect(await client.documentTitle(1) == nil) // unknown document
    }

    // MARK: - Connection check

    @Test("checkConnection reports the server version and the document count")
    func checkConnection() async throws {
        let requests = Recorder<RecordedRequest>()
        server.respond { request in
            requests.record(RecordedRequest(request))
            return .json(["count": 189, "results": [Any]()], headers: ["X-Version": "3.4.2"])
        }

        let result = try await server.client().checkConnection()

        #expect(result.version == "3.4.2")
        #expect(result.documents == 189)
        let request = try #require(requests.values.first)
        #expect(request.path == "/api/documents/")
        #expect(request.query == "page_size=1&fields=id")
        #expect(request.headers["Authorization"] == "Token secret-token")
    }

    @Test("checkConnection gives up after 15 seconds, not the default minute")
    func checkConnectionTimeout() async throws {
        let requests = Recorder<RecordedRequest>()
        server.respond { request in
            requests.record(RecordedRequest(request))
            return .json(["count": 1])
        }

        _ = try await server.client().checkConnection()

        #expect(try #require(requests.values.first).timeout == 15)
    }

    @Test("an http:// address is explained instead of showing the system's security message")
    func insecureAddress() async throws {
        let file = try TempFile()
        defer { file.remove() }
        server.respond { _ in throw URLError(.appTransportSecurityRequiresSecureConnection) }

        await #expect(throws: PaperlessError.insecureAddress) { try await server.client().checkConnection() }
        await #expect(throws: PaperlessError.insecureAddress) { try await server.client().upload(file.url) }
        await #expect(throws: PaperlessError.insecureAddress) { try await server.client().waitForTask("t") }
    }

    @Test("checkConnection explains a wrong token and a wrong address")
    func checkConnectionFailures() async throws {
        server.respond { _ in .text("", status: 401) }
        await #expect(throws: PaperlessError.unauthorized) { try await server.client().checkConnection() }

        server.respond { _ in .text("<html>not paperless</html>") }
        await #expect(throws: PaperlessError.badResponse) { try await server.client().checkConnection() }
    }
}

@Suite("PaperlessError")
struct PaperlessErrorTests {
    static let settingsCases: [(PaperlessError, Bool)] = [
        (.notConfigured, true),
        (.unauthorized, true),
        (.forbidden, false),
        (.unreachable("offline"), false),
        (.tooLarge, false),
        (.http(500), false),
        (.badResponse, false),
        (.timedOut, false),
        (.taskFailed("nope"), false),
        (.duplicate(of: 1, title: nil), false),
        (.insecureAddress, true),
    ]

    @Test("only a missing setup or a rejected token send the user to Settings", arguments: settingsCases)
    func needsSettings(error: PaperlessError, expected: Bool) {
        #expect(error.needsSettings == expected)
    }

    @Test("every error has a message to show", arguments: settingsCases.map(\.0))
    func hasMessage(error: PaperlessError) {
        #expect(error.errorDescription?.isEmpty == false)
    }

    static let duplicateCases: [(Int?, String)] = [(12, "Already in Paperless (#12)"), (nil, "Already in Paperless")]

    @Test("the duplicate message names the original when it is known", arguments: duplicateCases)
    func duplicateMessage(id: Int?, expected: String) {
        #expect(PaperlessError.duplicate(of: id, title: nil).errorDescription == expected)
    }
}
