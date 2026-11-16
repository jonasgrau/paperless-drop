import Foundation

enum PaperlessError: LocalizedError {
    case notConfigured
    case unauthorized
    case forbidden
    case unreachable(String)
    case tooLarge
    case http(Int)
    case badResponse
    case timedOut
    case taskFailed(String)
    case duplicate(of: Int?, title: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set the Paperless URL and API token in Settings"
        case .unauthorized: "Invalid API token – check Settings"
        case .forbidden: "Your Paperless user may not add documents"
        case .unreachable(let reason): "Can't reach Paperless: \(reason)"
        case .tooLarge: "File too large for the server"
        case .http(let code): "Server error (HTTP \(code))"
        case .badResponse: "Unexpected response – is the URL correct?"
        case .timedOut: "Still processing after 10 minutes – check Paperless"
        case .taskFailed(let message): message
        case .duplicate(let id, _): id.map { "Already in Paperless (#\($0))" } ?? "Already in Paperless"
        }
    }

    /// True when the fix is a new URL or token, so the UI can offer to open Settings.
    var needsSettings: Bool {
        switch self {
        case .notConfigured, .unauthorized: true
        default: false
        }
    }
}

/// Talks to the paperless-ngx REST API (handles both API v9 and v10 task formats).
struct PaperlessClient: Sendable {
    let baseURL: String
    let token: String

    /// The saved base URL without trailing slash, or nil if none is set.
    static func storedBaseURL() -> String? {
        var base = UserDefaults.standard.string(forKey: "baseURL")?
            .trimmingCharacters(in: .whitespaces) ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        return base.isEmpty ? nil : base
    }

    /// Reads the base URL from UserDefaults and the token from the Keychain.
    /// Reading the token can block for as long as macOS shows its access question (a rebuilt
    /// app is a new program to it), so `@concurrent` keeps it off the main thread and the
    /// panel stays responsive meanwhile.
    @concurrent
    static func fromSettings() async throws -> PaperlessClient {
        guard let base = storedBaseURL(), let token = Keychain.readToken(), !token.isEmpty else {
            throw PaperlessError.notConfigured
        }
        return PaperlessClient(baseURL: base, token: token)
    }

    /// Makes one authenticated request and reports the server version and
    /// document count, so Settings can confirm URL and token actually work.
    func checkConnection() async throws -> (version: String?, documents: Int?) {
        var request = try makeRequest("/api/documents/")
        request.url = request.url.flatMap { URL(string: $0.absoluteString + "?page_size=1&fields=id") }
        let (data, response) = try await perform { try await URLSession.shared.data(for: request) }
        struct Page: Decodable { let count: Int? }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw PaperlessError.badResponse }
        return ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Version"), page.count)
    }

    /// The document's title, or nil if it can't be fetched. Only used to make
    /// the UI friendlier, so every failure is swallowed. `fields=title` keeps the
    /// response small: a document's OCR text can be megabytes.
    func documentTitle(_ id: Int?) async -> String? {
        guard let id, var request = try? makeRequest("/api/documents/\(id)/?fields=title") else { return nil }
        request.timeoutInterval = 10
        guard let (data, _) = try? await perform({ try await URLSession.shared.data(for: request) }) else { return nil }
        struct Document: Decodable { let title: String? }
        return (try? JSONDecoder().decode(Document.self, from: data))?.title
    }

    /// Uploads a file and returns the consumption task UUID.
    /// `onProgress` receives the sent fraction (0…1) from a background queue.
    func upload(_ fileURL: URL, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile = try Self.writeMultipartBody(for: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var request = try makeRequest("/api/documents/post_document/")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgress(onProgress: onProgress)
        let (data, _) = try await perform {
            try await URLSession.shared.upload(for: request, fromFile: bodyFile, delegate: delegate)
        }
        // The body is the UUID as a JSON string, e.g. "\"3f2c…\"". Anything else
        // (e.g. an HTML login page from a proxy) means we're not talking to the API.
        let taskID = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        guard UUID(uuidString: taskID) != nil else { throw PaperlessError.badResponse }
        return taskID
    }

    /// Polls the task until it finishes. Returns the new document ID if the server reports one.
    func waitForTask(_ taskID: String) async throws -> Int? {
        let deadline = Date.now.addingTimeInterval(10 * 60)
        var networkErrors = 0
        while Date.now < deadline {
            do {
                if let task = try await fetchTask(taskID) {
                    switch task.status.lowercased() {
                    case "success":
                        return task.related_document_ids?.first ?? task.related_document
                    case "failure", "revoked":
                        if let original = task.duplicateOf { throw PaperlessError.duplicate(of: original, title: nil) }
                        throw PaperlessError.taskFailed(task.failureMessage)
                    default:
                        break // pending / started
                    }
                }
                networkErrors = 0
            } catch PaperlessError.unreachable(let reason) {
                // The upload already succeeded, so tolerate short hiccups while polling.
                networkErrors += 1
                if networkErrors >= 5 { throw PaperlessError.unreachable(reason) }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw PaperlessError.timedOut
    }

    private func fetchTask(_ taskID: String) async throws -> TaskInfo? {
        var request = try makeRequest("/api/tasks/")
        request.url = request.url.flatMap {
            var components = URLComponents(url: $0, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "task_id", value: taskID)]
            return components?.url
        }
        let (data, _) = try await perform { try await URLSession.shared.data(for: request) }

        // API v10 returns a paginated object, v9 and older a plain array.
        let decoder = JSONDecoder()
        if let page = try? decoder.decode(TaskPage.self, from: data) { return page.results.first }
        if let list = try? decoder.decode([TaskInfo].self, from: data) { return list.first }
        throw PaperlessError.badResponse
    }

    /// Runs a request and turns transport and HTTP failures into PaperlessError.
    private func perform(_ request: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await request()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw PaperlessError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw PaperlessError.badResponse }
        switch http.statusCode {
        case 200..<300: return (data, response)
        case 401: throw PaperlessError.unauthorized
        case 403: throw PaperlessError.forbidden
        case 413: throw PaperlessError.tooLarge
        default:
            log.error("HTTP \(http.statusCode): \(String(decoding: data.prefix(500), as: UTF8.self), privacy: .public)")
            throw PaperlessError.http(http.statusCode)
        }
    }

    /// Writes the multipart body to a temp file in 1 MB chunks, so large PDFs
    /// never sit in memory. Reading also downloads cloud placeholder files (iCloud, Nextcloud, …).
    private static func writeMultipartBody(for fileURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appending(path: "paperless-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        let filename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        try output.write(contentsOf: Data("""
            --\(boundary)\r
            Content-Disposition: form-data; name="document"; filename="\(filename)"\r
            Content-Type: application/pdf\r
            \r\n
            """.utf8))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    private func makeRequest(_ path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw PaperlessError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

// Field names match the JSON, covering both API v9 and v10.
private struct TaskInfo: Decodable {
    struct ResultData: Decodable {        // v10
        let error_message: String?
        let reason: String?
        let duplicate_of: Int?
    }

    let status: String
    let result: String?                 // v9
    let related_document: Int?          // v9
    let related_document_ids: [Int]?    // v10
    let result_data: ResultData?        // v10

    /// v10 reports the original directly; v9 only says so in the result text.
    var duplicateOf: Int? {
        if let id = result_data?.duplicate_of { return id }
        guard let text = result, text.localizedCaseInsensitiveContains("duplicate") else { return nil }
        return text.firstMatch(of: /#(\d+)/).flatMap { Int($0.1) }
    }

    var failureMessage: String {
        return result_data?.error_message ?? result_data?.reason ?? result ?? "Processing failed in Paperless"
    }
}

private struct TaskPage: Decodable {
    let results: [TaskInfo]
}

/// Forwards upload progress from URLSession to a closure.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
