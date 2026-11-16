import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Feedback: Equatable {
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

    private enum UpdateStatus: Equatable {
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

    let version: AppVersion
    @AppStorage("baseURL") private var storedURL = ""
    @State private var url = ""
    @State private var token = ""
    @State private var hasToken = Keychain.hasToken()
    @State private var feedback: Feedback?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    @State private var updateStatus: UpdateStatus?

    init(version: AppVersion = .current) {
        self.version = version
    }

    var body: some View {
        // Messages have fixed-height areas, so the window never changes size while you use it.
        Form {
            // verbatim: a string literal would be parsed as Markdown and the URL shown as a blue link.
            TextField("Paperless URL", text: $url, prompt: Text(verbatim: "https://paperless.example.com"))
            SecureField("API token", text: $token,
                        prompt: Text(hasToken ? "Stored in Keychain – paste to replace" : "Paste API token"))
            tokenHelp

            HStack(alignment: .top) {
                feedbackView
                    .frame(height: 34, alignment: .topLeading)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking)
            }
            .padding(.top, 4)

            Divider().padding(.vertical, 4)

            // Unlike the fields above, this applies at once and has nothing to do with Save.
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text(loginNote ?? " ")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(loginNote ?? "")
                    .frame(height: 16, alignment: .topLeading)
            }

            Divider().padding(.vertical, 4)

            updateFooter
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 14) // the Form already adds a little space below the last row
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { url = storedURL }
        .onChange(of: feedback) { _, new in announce(new?.announcement) }
        .onChange(of: updateStatus) { _, new in announce(new?.announcement) }
    }

    // MARK: - Token help

    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Find the token in Paperless under My Profile → API Auth Token.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if let site = siteURL { Link("Open Paperless", destination: site) }
                if hasToken { Button("Remove stored token", action: removeToken).buttonStyle(.link) }
            }
        }
        .font(.caption)
    }

    /// The address as typed, once it is a usable one.
    private var siteURL: URL? {
        if case .success(let address) = ServerAddress.normalize(url) { URL(string: address) } else { nil }
    }

    private func removeToken() {
        Task {
            let removed = await Task.detached { Keychain.deleteToken() }.value
            if removed {
                hasToken = false
                token = ""
                feedback = .info("Token removed from the Keychain")
            } else {
                feedback = .error("Couldn't remove the token from the Keychain")
            }
        }
    }

    // MARK: - Save and check

    private var isChecking: Bool {
        if case .checking = feedback { true } else { false }
    }

    @ViewBuilder private var feedbackView: some View {
        switch feedback {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking connection…")
            }
            .foregroundStyle(.secondary)
        case .success(let text):
            message(text, symbol: "checkmark.circle.fill", symbolColor: .green, textColor: .secondary)
        case .error(let text):
            message(text, symbol: "exclamationmark.circle.fill", symbolColor: .red, textColor: .red)
        case .info(let text):
            message(text, symbol: "info.circle.fill", symbolColor: .secondary, textColor: .secondary)
        case nil:
            Color.clear // not EmptyView: that collapses to nothing even inside a fixed frame
        }
    }

    /// Two lines at most; the full text is in the tooltip.
    private func message(_ text: String, symbol: String, symbolColor: Color, textColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(symbolColor)
            Text(text)
                .foregroundStyle(textColor)
                .lineLimit(2)
                .help(text)
        }
        .font(.callout)
    }

    /// Saves the address, then the token, then makes one real API call, so a typo or a wrong
    /// token shows up here instead of on the next upload.
    private func save() {
        switch ServerAddress.normalize(url) {
        case .failure(let problem):
            feedback = .error(problem.message)
            return
        case .success(let address):
            url = address
            storedURL = address
        }

        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        feedback = .checking
        Task {
            // The Keychain can block while macOS asks for access, so never on the main thread.
            if !newToken.isEmpty {
                guard await Task.detached(operation: { Keychain.saveToken(newToken) }).value else {
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
                let result = try await PaperlessClient.fromSettings().checkConnection()
                var text = "Connected"
                if let version = result.version { text += " – Paperless \(version)" }
                if let count = result.documents { text += " · \(count) documents" }
                feedback = .success(text)
            } catch {
                feedback = .error(error.localizedDescription)
            }
        }
    }

    private func announce(_ text: String?) {
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    // MARK: - Open at login

    /// Without this the drop target is missing after a restart, and a drop onto nothing fails silently.
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        loginNote = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                loginNote = "Allow Paperless Drop in System Settings → General → Login Items"
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginNote = "Couldn't change the login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Version and updates

    /// The running version, and a manual check for a newer release. Nothing is installed:
    /// the link opens the release page, where the dmg is.
    private var updateFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(version.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Check for Updates…", action: checkForUpdates)
                    .disabled(isCheckingForUpdates)
            }
            updateStatusView
                .frame(height: 16, alignment: .leading)
        }
    }

    @ViewBuilder private var updateStatusView: some View {
        switch updateStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking GitHub…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("You're up to date.").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .available(let release):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text("Version \(release.version) is available.")
                Link("View release", destination: release.url)
            }
            .font(.caption)
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(message).foregroundStyle(.red).lineLimit(1).help(message)
            }
            .font(.caption)
        case nil:
            Color.clear
        }
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = updateStatus { true } else { false }
    }

    private func checkForUpdates() {
        updateStatus = .checking
        let current = version.short
        Task {
            do {
                switch try await UpdateChecker().check(currentVersion: current) {
                case .upToDate: updateStatus = .upToDate
                case .available(let release): updateStatus = .available(release)
                }
            } catch {
                updateStatus = .failed(error.localizedDescription)
            }
        }
    }
}

/// Hosts SettingsView in a plain window. Accessory apps need to activate
/// themselves, otherwise the window opens behind other apps.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Paperless Drop Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else if window?.isVisible == false {
            // The window is kept for next time; start it with fresh state, so an old "Connected" or
            // "You're up to date" doesn't linger and switches show what the system says now.
            window?.contentViewController = NSHostingController(rootView: SettingsView())
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
