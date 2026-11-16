import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Feedback {
        case checking
        case success(String)
        case error(String)
    }

    private enum UpdateStatus {
        case checking
        case upToDate
        case available(UpdateChecker.Release)
        case failed(String)
    }

    let version: AppVersion
    @AppStorage("baseURL") private var storedURL = ""
    @State private var url = ""
    @State private var token = ""
    @State private var hasToken = Keychain.hasToken()
    @State private var feedback: Feedback?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var updateStatus: UpdateStatus?

    init(version: AppVersion = .current) {
        self.version = version
    }

    var body: some View {
        Form {
            // verbatim: a string literal would be parsed as Markdown and the URL shown as a blue link.
            TextField("Paperless URL", text: $url, prompt: Text(verbatim: "https://paperless.example.com"))
            SecureField("API token", text: $token,
                        prompt: Text(hasToken ? "Stored in Keychain – paste to replace" : "Paste API token"))
            Text("Find the token in Paperless under My Profile → API Auth Token.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                .padding(.top, 6)

            HStack(alignment: .firstTextBaseline) {
                feedbackView
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking)
            }
            .padding(.top, 8)

            Divider().padding(.top, 10)
            updateFooter
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 14) // the Form already adds a little space below the last row
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { url = storedURL }
    }

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
            Label("You're up to date.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        case .available(let release):
            HStack(spacing: 6) {
                Label("Version \(release.version) is available.", systemImage: "arrow.down.circle.fill")
                Link("View release", destination: release.url)
            }
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case nil:
            EmptyView()
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

    private var isChecking: Bool {
        if case .checking = feedback { true } else { false }
    }

    @ViewBuilder private var feedbackView: some View {
        switch feedback {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking connection…").foregroundStyle(.secondary)
            }
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    /// Without this the drop target is missing after a restart, and a drop onto nothing fails silently.
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                feedback = .error("Allow Paperless Drop in System Settings → General → Login Items")
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            feedback = .error("Couldn't change the login item: \(error.localizedDescription)")
        }
    }

    /// Saves both values, then makes one real API call so a typo or a wrong
    /// token shows up here instead of on the next upload.
    private func save() {
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        guard let parsed = URL(string: cleaned), ["https", "http"].contains(parsed.scheme), parsed.host() != nil else {
            feedback = .error("Enter a full URL starting with https://")
            return
        }
        url = cleaned
        storedURL = cleaned

        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newToken.isEmpty {
            guard Keychain.saveToken(newToken) else {
                feedback = .error("Couldn't save the token to the Keychain")
                return
            }
            token = ""
            hasToken = true
        }
        guard hasToken else {
            feedback = .error("URL saved – the API token is still missing")
            return
        }

        feedback = .checking
        Task {
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
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
