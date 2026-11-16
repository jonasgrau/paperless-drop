import Foundation
import os

/// One canned answer from the stub server.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
        return StubResponse(status: status, headers: headers, body: data)
    }

    static func text(_ text: String, status: Int = 200) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8))
    }
}

/// Answers the requests of one test's URLSession from a closure. Every test gets its own host
/// name and handlers are looked up by host, so tests can run in parallel without sharing state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> StubResponse
    private static let handlers = OSAllocatedUnfairLock(initialState: [String: Handler]())

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                           headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A fake Paperless server for one test, plus a client that talks to it with fast polling.
struct StubServer: Sendable {
    let host = "stub-\(UUID().uuidString.lowercased()).test"

    func respond(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.register(host: host, handler: handler)
    }

    func client(token: String = "secret-token") -> PaperlessClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return PaperlessClient(baseURL: "https://\(host)", token: token,
                               session: URLSession(configuration: configuration),
                               pollInterval: .milliseconds(5), taskTimeout: 5)
    }
}

/// What a request looked like when it reached the stub server.
struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: Data

    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        path = request.url?.requestPath ?? ""
        query = request.url?.query ?? ""
        headers = request.allHTTPHeaderFields ?? [:]
        body = request.bodyData
    }
}

extension URL {
    /// The path as sent on the wire. `URL.path` drops a trailing slash, which Paperless' URLs end in.
    var requestPath: String {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.path ?? path
    }
}

extension URLRequest {
    /// URLSession hands the body of an upload to protocols as a stream.
    var bodyData: Data {
        guard let stream = httpBodyStream else { return httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A thread-safe list of values, so handlers (which run off the main thread) can report to the test.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [Value]())
    func record(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
    var count: Int { values.count }
}

/// One step of a scripted conversation: an answer, or a network failure.
enum Step: Sendable {
    case respond(StubResponse)
    case fail(URLError.Code)

    func resolve() throws -> StubResponse {
        switch self {
        case .respond(let response): response
        case .fail(let code): throw URLError(code)
        }
    }
}

/// Hands out its steps one after the other and then repeats the last one.
final class Script: Sendable {
    private let steps: OSAllocatedUnfairLock<[Step]>

    init(_ steps: [Step]) { self.steps = OSAllocatedUnfairLock(initialState: steps) }

    func next() throws -> StubResponse {
        try steps.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }.resolve()
    }
}

/// Task answers in the two shapes Paperless uses.
enum TaskJSON {
    /// API v10: paginated, lowercase status, `related_document_ids` and `result_data`.
    static func v10(_ status: String, documentIDs: [Int] = [], resultData: [String: Any]? = nil) -> StubResponse {
        var task: [String: Any] = ["task_id": "t", "status": status, "related_document_ids": documentIDs]
        if let resultData { task["result_data"] = resultData }
        return .json(["count": 1, "next": NSNull(), "previous": NSNull(), "results": [task]])
    }

    /// API v9 and older: a plain array, uppercase status, `related_document` and `result` text.
    static func v9(_ status: String, document: Int? = nil, result: String? = nil) -> StubResponse {
        var task: [String: Any] = ["task_id": "t", "status": status]
        if let document { task["related_document"] = document }
        if let result { task["result"] = result }
        return .json([task])
    }

    /// The server hasn't registered the task yet.
    static let none = StubResponse.json(["count": 0, "next": NSNull(), "previous": NSNull(), "results": [Any]()])
}

/// A small file on disk, removed again with `remove()`.
struct TempFile {
    let url: URL

    init(name: String = "Invoice.pdf", contents: Data = Data("%PDF-1.4 test".utf8)) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PaperlessDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: name)
        try contents.write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

extension PaperlessError {
    var isUnreachable: Bool {
        if case .unreachable = self { true } else { false }
    }
}
