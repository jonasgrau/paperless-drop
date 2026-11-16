import Foundation

/// Cleans up and checks the Paperless address typed or pasted in Settings.
enum ServerAddress {
    enum Problem: Error, Equatable {
        case empty
        case notAnAddress
        case insecure

        var message: String {
            switch self {
            case .empty: "Enter the address of your Paperless server"
            case .notAnAddress: "That doesn't look like a web address"
            case .insecure: "Plain http:// isn't supported. Use an https:// address."
            }
        }
    }

    /// Path parts that belong to Paperless' web pages or API, not to where it is installed.
    /// People paste what the browser shows, so everything from the first of these on is dropped.
    private static let siteParts: Set<String> = [
        "api", "dashboard", "documents", "profile", "settings", "tasks", "accounts", "login",
    ]

    /// Returns the address as the app stores it: `https://host[:port][/subpath]`, without a
    /// trailing slash, query, login or page names. A missing `https://` is added.
    static func normalize(_ input: String) -> Result<String, Problem> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") { text = "https://" + text }

        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return .failure(.notAnAddress)
        }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": return .failure(.insecure)
        default: return .failure(.notAnAddress)
        }

        var parts = components.path.split(separator: "/").map(String.init)
        if let cut = parts.firstIndex(where: { siteParts.contains($0.lowercased()) }) {
            parts.removeSubrange(cut...)
        }

        var result = URLComponents()
        result.scheme = "https"
        result.host = host.lowercased()
        result.port = components.port
        result.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        guard let address = result.string else { return .failure(.notAnAddress) }
        return .success(address)
    }
}
