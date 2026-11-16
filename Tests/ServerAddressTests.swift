import Testing

@Suite("ServerAddress")
struct ServerAddressTests {
    nonisolated static let accepted: [(input: String, expected: String)] = [
        ("https://paperless.example.com", "https://paperless.example.com"),
        ("https://paperless.example.com/", "https://paperless.example.com"),
        ("  https://paperless.example.com//  ", "https://paperless.example.com"),   // spaces, slashes
        ("paperless.example.com", "https://paperless.example.com"),                  // https is added
        ("HTTPS://Paperless.Example.COM", "https://paperless.example.com"),          // host is case-insensitive
        ("https://paperless.example.com:8000", "https://paperless.example.com:8000"),
        ("192.168.1.20:8000", "https://192.168.1.20:8000"),
        ("https://example.com/paperless", "https://example.com/paperless"),          // installed under a path
        ("https://example.com/paperless/", "https://example.com/paperless"),
        ("https://paperless.example.com/api", "https://paperless.example.com"),      // pasted from the API
        ("https://paperless.example.com/api/documents/?page=2", "https://paperless.example.com"),
        ("https://paperless.example.com/dashboard", "https://paperless.example.com"), // pasted from the browser
        ("https://paperless.example.com/documents/12/details", "https://paperless.example.com"),
        ("https://example.com/paperless/api/", "https://example.com/paperless"),
        ("https://paperless.example.com/?foo=bar#top", "https://paperless.example.com"),
        ("https://me:secret@paperless.example.com", "https://paperless.example.com"), // no password is kept
    ]

    @Test("an address is cleaned up to scheme, host, port and installation path", arguments: accepted)
    func normalizes(input: String, expected: String) {
        #expect(ServerAddress.normalize(input) == .success(expected))
    }

    nonisolated static let rejected: [(input: String, problem: ServerAddress.Problem)] = [
        ("", .empty),
        ("   \n", .empty),
        ("http://paperless.example.com", .insecure),
        ("HTTP://192.168.1.20:8000", .insecure),
        ("ftp://paperless.example.com", .notAnAddress),
        ("https://", .notAnAddress),
        ("not an address", .notAnAddress),
    ]

    @Test("what can't be an address is rejected with the reason", arguments: rejected)
    func rejects(input: String, problem: ServerAddress.Problem) {
        #expect(ServerAddress.normalize(input) == .failure(problem))
    }

    @Test("every problem has a message that says what to do")
    func messages() {
        #expect(ServerAddress.Problem.insecure.message.contains("https://"))
        for problem in [ServerAddress.Problem.empty, .notAnAddress, .insecure] {
            #expect(problem.message.isEmpty == false)
        }
    }
}
