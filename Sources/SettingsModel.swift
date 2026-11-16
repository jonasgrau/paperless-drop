import Foundation
import Observation

/// What the Settings window shows and does, without any UI. Everything that touches the system
/// goes through `Services`, so the model also runs in tests and previews without a Keychain,
/// saved preferences, a network or login items.
@MainActor
@Observable
final class SettingsModel {
    enum Feedback: Equatable {
        case checking
        case success(String)
        case error(String)
        case info(String)

        /// What VoiceOver says when this appears. Changing a label on screen is silent otherwise.
        var announcement: String? {
            switch self {
            case .checking: nil
            case .success(let text), .error(let text), .info(let text): text
            }
        }
    }

    enum UpdateStatus: Equatable {
        case checking
        case upToDate
        case available(UpdateChecker.Release)
        case failed(String)

        var announcement: String? {
            switch self {
            case .checking: nil
            case .upToDate: "You're up to date."
            case .available(let release): "Version \(release.version) is available."
            case .failed(let message): message
            }
        }
    }

    enum LoginItemStatus: Sendable, Equatable {
        case enabled
        case disabled
        case requiresApproval
    }

    /// The system, as the model sees it. The app uses `Services.live` (in SettingsView.swift).
    struct Services: Sendable {
        var storedAddress: @Sendable () -> String
        var storeAddress: @Sendable (String) -> Void
        var hasToken: @Sendable () -> Bool
        var saveToken: @Sendable (String) -> Bool
        var deleteToken: @Sendable () -> Bool
        var checkConnection: @Sendable () async throws -> (version: String?, documents: Int?)
        var checkForUpdates: @Sendable (_ currentVersion: String) async throws -> UpdateChecker.Outcome
        var loginItemStatus: @Sendable () -> LoginItemStatus
        var setLaunchAtLogin: @Sendable (Bool) throws -> Void
    }

    let version: AppVersion
    var address: String
    var token = ""
    private(set) var hasToken: Bool
    private(set) var feedback: Feedback?
    private(set) var launchAtLogin: Bool
    private(set) var loginNote: String?
    private(set) var updateStatus: UpdateStatus?

    @ObservationIgnored private let services: Services

    /// Cheap on purpose: it only reads saved preferences. Whether a token exists is asked
    /// separately by `refreshTokenState()`, because the Keychain must not block the main thread.
    /// The last three parameters are starting values for previews and tests.
    init(services: Services, version: AppVersion, address: String? = nil, hasToken: Bool = false,
         feedback: Feedback? = nil, updateStatus: UpdateStatus? = nil) {
        self.services = services
        self.version = version
        self.address = address ?? services.storedAddress()
        self.hasToken = hasToken
        self.feedback = feedback
        self.updateStatus = updateStatus
        self.launchAtLogin = services.loginItemStatus() == .enabled
    }

    var isChecking: Bool { feedback == .checking }
    var isCheckingForUpdates: Bool { updateStatus == .checking }

    /// The address as typed, once it is a usable one.
    var siteURL: URL? {
        if case .success(let normalized) = ServerAddress.normalize(address) { URL(string: normalized) } else { nil }
    }

    func refreshTokenState() async {
        let hasToken = services.hasToken
        self.hasToken = await Task.detached { hasToken() }.value
    }

    // MARK: - Save and check

    /// Saves the address, then the token, then makes one real API call, so a typo or a wrong
    /// token shows up here instead of on the next upload.
    func save() async {
        switch ServerAddress.normalize(address) {
        case .failure(let problem):
            feedback = .error(problem.message)
            return
        case .success(let normalized):
            address = normalized
            services.storeAddress(normalized)
        }

        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        feedback = .checking
        if !newToken.isEmpty {
            // The Keychain can block while macOS asks for access, so never on the main thread.
            let saveToken = services.saveToken
            guard await Task.detached(operation: { saveToken(newToken) }).value else {
                feedback = .error("Couldn't save the token to the Keychain")
                return
            }
            token = ""
            hasToken = true
        }
        guard hasToken else {
            feedback = .error("Address saved – the API token is still missing")
            return
        }
        do {
            let result = try await services.checkConnection()
            var text = "Connected"
            if let version = result.version { text += " – Paperless \(version)" }
            if let count = result.documents { text += " · \(count) documents" }
            feedback = .success(text)
        } catch {
            feedback = .error(error.localizedDescription)
        }
    }

    func removeToken() async {
        let deleteToken = services.deleteToken
        if await Task.detached(operation: { deleteToken() }).value {
            hasToken = false
            token = ""
            feedback = .info("Token removed from the Keychain")
        } else {
            feedback = .error("Couldn't remove the token from the Keychain")
        }
    }

    // MARK: - Open at login

    /// Without this the drop target is missing after a restart, and a drop onto nothing fails silently.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin else { return }
        loginNote = nil
        do {
            try services.setLaunchAtLogin(enabled)
            launchAtLogin = enabled
            if services.loginItemStatus() == .requiresApproval {
                loginNote = "Allow Paperless Drop in System Settings → General → Login Items"
            }
        } catch {
            launchAtLogin = services.loginItemStatus() == .enabled
            loginNote = "Couldn't change the login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Updates

    func checkForUpdates() async {
        updateStatus = .checking
        do {
            switch try await services.checkForUpdates(version.short) {
            case .upToDate: updateStatus = .upToDate
            case .available(let release): updateStatus = .available(release)
            }
        } catch {
            updateStatus = .failed(error.localizedDescription)
        }
    }
}
