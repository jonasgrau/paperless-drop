import Foundation

/// The version of the running app, as shown in Settings.
struct AppVersion: Sendable {
    let short: String
    let build: String

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(short: info["CFBundleShortVersionString"] as? String ?? "?",
                          build: info["CFBundleVersion"] as? String ?? "?")
    }

    var description: String { "Paperless Drop \(short) (\(build))" }
}

/// Asks GitHub whether a newer release exists. It only runs when the user asks for it:
/// the app never contacts GitHub by itself. Nothing is installed; the user downloads the dmg.
struct UpdateChecker: Sendable {
    struct Release: Equatable, Sendable {
        /// Without the leading "v", for example "0.1.2".
        let version: String
        /// The release page on github.com.
        let url: URL
    }

    enum Outcome: Equatable, Sendable {
        case upToDate
        case available(Release)
    }

    enum CheckError: LocalizedError, Equatable {
        case unreachable(String)
        case rateLimited
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let reason): "Can't reach GitHub: \(reason)"
            case .rateLimited: "GitHub is limiting requests right now. Try again later."
            case .badResponse: "Unexpected answer from GitHub"
            }
        }
    }

    var session: URLSession = .shared
    /// The release list, not `/releases/latest`: that one skips pre-releases.
    var releasesURL = URL(string: "https://api.github.com/repos/jonasgrau/paperless-drop/releases?per_page=30")!

    func check(currentVersion: String) async throws -> Outcome {
        var request = URLRequest(url: releasesURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PaperlessDrop/\(currentVersion)", forHTTPHeaderField: "User-Agent") // GitHub requires one

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw CheckError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse }
        switch http.statusCode {
        case 200: break
        case 403, 429: throw CheckError.rateLimited
        default: throw CheckError.badResponse
        }

        struct Item: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
        }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { throw CheckError.badResponse }

        let releases = items.compactMap { item -> Release? in
            // The link is opened in the browser, so only trust release pages on github.com.
            guard item.draft != true, Self.parse(item.tag_name) != nil,
                  item.html_url.scheme == "https", item.html_url.host == "github.com" else { return nil }
            return Release(version: item.tag_name.hasPrefix("v") ? String(item.tag_name.dropFirst()) : item.tag_name,
                           url: item.html_url)
        }
        guard let newest = releases.max(by: { Self.isNewer($1.version, than: $0.version) }),
              Self.isNewer(newest.version, than: currentVersion) else { return .upToDate }
        return .available(newest)
    }

    /// True when `candidate` is a higher version than `current`. Compares dotted numbers
    /// (0.10.0 is newer than 0.9.0). A leading "v" and anything after "-" or "+" are ignored.
    /// If either side can't be read as a version, nothing counts as newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = parse(candidate), var b = parse(current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    private static func parse(_ version: String) -> [Int]? {
        var text = Substring(version)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
        if let end = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = text[..<end] }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
