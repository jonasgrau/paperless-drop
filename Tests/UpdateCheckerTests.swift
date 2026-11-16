import Foundation
import Testing

@Suite("UpdateChecker", .timeLimit(.minutes(1)))
struct UpdateCheckerTests {
    let server = StubServer()

    func checker() -> UpdateChecker {
        UpdateChecker(session: server.session, releasesURL: URL(string: "https://\(server.host)/releases")!)
    }

    /// One entry of GitHub's release list.
    static func release(_ tag: String, draft: Bool = false, page: String? = nil) -> [String: Any] {
        ["tag_name": tag,
         "html_url": page ?? "https://github.com/jonasgrau/paperless-drop/releases/tag/\(tag)",
         "draft": draft]
    }

    static func page(_ tag: String) -> URL {
        URL(string: "https://github.com/jonasgrau/paperless-drop/releases/tag/\(tag)")!
    }

    // MARK: - Comparing versions

    nonisolated static let comparisons: [(String, String, Bool)] = [
        ("0.1.2", "0.1.1", true),
        ("0.1.1", "0.1.1", false),
        ("0.1.0", "0.1.1", false),
        ("0.10.0", "0.9.0", true),        // numbers, not text
        ("0.2", "0.1.9", true),
        ("1.0", "0.9.9", true),
        ("0.1.1", "0.1.1.0", false),      // a missing part counts as zero
        ("0.1.1.1", "0.1.1", true),
        ("v0.1.2", "0.1.1", true),        // a leading v is ignored
        ("v0.1.1", "0.1.1", false),
        ("0.2.0-beta.1", "0.1.1", true),  // so is a suffix
        ("nightly", "0.1.1", false),      // unreadable: never newer
        ("0.1.2", "dev", false),
        ("", "0.1.1", false),
        ("0.1.x", "0.1.1", false),
    ]

    @Test("versions are compared as numbers", arguments: comparisons)
    func isNewer(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == expected)
    }

    @Test("the version line names the app, version and build")
    func versionDescription() {
        #expect(AppVersion(short: "0.1.1", build: "3").description == "Paperless Drop 0.1.1 (3)")
    }

    // MARK: - Asking GitHub

    @Test("the newest release is offered, whichever order GitHub lists them in")
    func offersTheNewest() async throws {
        let requests = Recorder<RecordedRequest>()
        let answer = StubResponse.json([Self.release("v0.1.1"), Self.release("v0.2.0"), Self.release("v0.1.0")])
        server.respond { request in
            requests.record(RecordedRequest(request))
            return answer
        }

        let outcome = try await checker().check(currentVersion: "0.1.1")

        #expect(outcome == .available(.init(version: "0.2.0", url: Self.page("v0.2.0"))))
        let request = try #require(requests.values.first)
        #expect(request.path == "/releases")
        #expect(request.headers["Accept"] == "application/vnd.github+json")
        #expect(request.headers["User-Agent"] == "PaperlessDrop/0.1.1")
    }

    @Test("nothing is offered when the app is at or beyond the newest release", arguments: ["0.2.0", "0.9.0"])
    func upToDate(current: String) async throws {
        let answer = StubResponse.json([Self.release("v0.2.0"), Self.release("v0.1.0")])
        server.respond { _ in answer }

        #expect(try await checker().check(currentVersion: current) == .upToDate)
    }

    @Test("drafts and tags that aren't versions are ignored")
    func ignoresDraftsAndOddTags() async throws {
        let answer = StubResponse.json([
            Self.release("v9.9.9", draft: true),
            Self.release("nightly"),
            Self.release("v0.1.2"),
        ])
        server.respond { _ in answer }

        #expect(try await checker().check(currentVersion: "0.1.1")
                == .available(.init(version: "0.1.2", url: Self.page("v0.1.2"))))
    }

    @Test("a release page that isn't on github.com over https is never offered", arguments: [
        "https://evil.example/releases/tag/v9.0.0",
        "http://github.com/jonasgrau/paperless-drop/releases/tag/v9.0.0",
        "https://github.com.evil.example/releases/tag/v9.0.0",
    ])
    func ignoresForeignLinks(page: String) async throws {
        let answer = StubResponse.json([Self.release("v9.0.0", page: page)])
        server.respond { _ in answer }

        #expect(try await checker().check(currentVersion: "0.1.1") == .upToDate)
    }

    @Test("an empty release list means up to date")
    func noReleases() async throws {
        server.respond { _ in .json([Any]()) }

        #expect(try await checker().check(currentVersion: "0.1.1") == .upToDate)
    }

    // MARK: - Failures

    @Test("GitHub's rate limit and other errors get their own messages", arguments: [
        (403, UpdateChecker.CheckError.rateLimited),
        (429, UpdateChecker.CheckError.rateLimited),
        (404, UpdateChecker.CheckError.badResponse),
        (500, UpdateChecker.CheckError.badResponse),
    ])
    func httpErrors(status: Int, expected: UpdateChecker.CheckError) async throws {
        server.respond { _ in .text("{}", status: status) }

        await #expect(throws: expected) { try await checker().check(currentVersion: "0.1.1") }
    }

    @Test("an answer that isn't a release list is rejected", arguments: ["<html>nope</html>", "{\"message\": \"hi\"}"])
    func badBody(body: String) async throws {
        server.respond { _ in .text(body) }

        await #expect(throws: UpdateChecker.CheckError.badResponse) { try await checker().check(currentVersion: "0.1.1") }
    }

    @Test("a missing connection is reported, not swallowed")
    func unreachable() async throws {
        server.respond { _ in throw URLError(.notConnectedToInternet) }

        let error = try #require(await #expect(throws: UpdateChecker.CheckError.self) {
            try await checker().check(currentVersion: "0.1.1")
        })
        guard case .unreachable = error else {
            Issue.record("Expected .unreachable but got \(error)")
            return
        }
    }
}
