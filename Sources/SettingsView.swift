import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Field { case address, token }

    // The model is created by whoever shows the window and handed in; the view owns no logic.
    @Bindable var model: SettingsModel
    @FocusState private var focus: Field?

    var body: some View {
        // Messages have fixed-height areas, so the window never changes size while you use it.
        Form {
            // verbatim: a string literal would be parsed as Markdown and the URL shown as a blue link.
            TextField("Paperless URL", text: $model.address, prompt: Text(verbatim: "https://paperless.example.com"))
                .focused($focus, equals: .address)
            SecureField("API token", text: $model.token,
                        prompt: Text(model.hasToken ? "Stored in Keychain – paste to replace" : "Paste API token"))
                .focused($focus, equals: .token)
            tokenHelp

            HStack(alignment: .top) {
                feedbackView
                    .frame(height: 34, alignment: .topLeading)
                Spacer()
                Button("Save") { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isChecking)
            }
            .padding(.top, 4)

            // Unlike the fields above, this applies at once and has nothing to do with Save.
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text(model.loginNote ?? " ")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(model.loginNote ?? "")
                    .frame(height: 14, alignment: .topLeading)
                    .accessibilityHidden(model.loginNote == nil) // don't read out the blank placeholder
            }
            .padding(.top, 12)

            updateFooter
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 14) // the Form already adds a little space below the last row
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Start where typing is needed: the address if there is none yet, otherwise the token.
            // Set here because `.defaultFocus` does nothing in a window hosted from AppKit.
            focus = model.address.isEmpty ? .address : .token
            await model.refreshTokenState()
        }
        .onChange(of: model.feedback) { _, new in announce(new?.announcement) }
        .onChange(of: model.updateStatus) { _, new in announce(new?.announcement) }
    }

    // MARK: - Token help

    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Find the token in Paperless under My Profile → API Auth Token.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if let site = model.siteURL { Link("Open Paperless", destination: site) }
                if model.hasToken {
                    Button("Remove stored token") { Task { await model.removeToken() } }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption)
    }

    // MARK: - Save and check

    @ViewBuilder private var feedbackView: some View {
        switch model.feedback {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking connection…")
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
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

    /// Two lines at most; the full text is in the tooltip. The symbol only repeats what the
    /// color says, so VoiceOver skips it instead of reading "checkmark circle fill".
    private func message(_ text: String, symbol: String, symbolColor: Color, textColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(textColor)
                .lineLimit(2)
                .help(text)
        }
        .font(.callout)
    }

    private func announce(_ text: String?) {
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    // MARK: - Version and updates

    /// The running version, and a manual check for a newer release. Nothing is installed:
    /// the link opens the release page, where the dmg is.
    private var updateFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.version.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Check for Updates…") { Task { await model.checkForUpdates() } }
                    .disabled(model.isCheckingForUpdates)
            }
            updateStatusView
                .frame(height: 16, alignment: .leading)
        }
    }

    @ViewBuilder private var updateStatusView: some View {
        switch model.updateStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking GitHub…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text("You're up to date.").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .available(let release):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("Version \(release.version) is available.")
                Link("View release", destination: release.url)
            }
            .font(.caption)
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
                Text(message).foregroundStyle(.red).lineLimit(1).help(message)
            }
            .font(.caption)
        case nil:
            Color.clear
        }
    }
}

// MARK: - The real system

extension SettingsModel.Services {
    /// What the app uses: saved preferences, the Keychain, Paperless, GitHub and the login item.
    static var live: SettingsModel.Services {
        SettingsModel.Services(
            storedAddress: { UserDefaults.standard.string(forKey: PaperlessClient.baseURLKey) ?? "" },
            storeAddress: { UserDefaults.standard.set($0, forKey: PaperlessClient.baseURLKey) },
            hasToken: { Keychain.hasToken() },
            saveToken: { Keychain.saveToken($0) },
            deleteToken: { Keychain.deleteToken() },
            checkConnection: { try await PaperlessClient.fromSettings().checkConnection() },
            checkForUpdates: { try await UpdateChecker().check(currentVersion: $0) },
            loginItemStatus: {
                switch SMAppService.mainApp.status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                default: .disabled
                }
            },
            setLaunchAtLogin: { enabled in
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            }
        )
    }
}

/// Hosts SettingsView in a plain window. Accessory apps need to activate
/// themselves, otherwise the window opens behind other apps.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    private func makeContent() -> NSHostingController<SettingsView> {
        NSHostingController(rootView: SettingsView(model: SettingsModel(services: .live, version: .current)))
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: makeContent())
            window.title = "Paperless Drop Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else if window?.isVisible == false {
            // The window is kept for next time; start it with a fresh model, so an old "Connected" or
            // "You're up to date" doesn't linger and the switches show what the system says now.
            window?.contentViewController = makeContent()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Previews

#if DEBUG
extension SettingsModel.Services {
    /// Touches nothing: no Keychain, no preferences, no network, no login item.
    static var preview: SettingsModel.Services {
        SettingsModel.Services(
            storedAddress: { "" },
            storeAddress: { _ in },
            hasToken: { true },
            saveToken: { _ in true },
            deleteToken: { true },
            checkConnection: { (version: "3.4.2", documents: 189) },
            checkForUpdates: { _ in .upToDate },
            loginItemStatus: { .disabled },
            setLaunchAtLogin: { _ in }
        )
    }
}

extension SettingsModel {
    /// A model with made-up data, for previews and the README screenshot.
    static func preview(address: String = "https://paperless.example.com", hasToken: Bool = true,
                        feedback: Feedback? = nil, updateStatus: UpdateStatus? = nil) -> SettingsModel {
        SettingsModel(services: .preview, version: AppVersion(short: "0.1.2", build: "4"), address: address,
                      hasToken: hasToken, feedback: feedback, updateStatus: updateStatus)
    }
}

private let previewRelease = UpdateChecker.Release(
    version: "0.2.0",
    url: URL(string: "https://github.com/jonasgrau/paperless-drop/releases/tag/v0.2.0")!
)

#Preview("Empty, first start") {
    SettingsView(model: .preview(address: "", hasToken: false))
}

#Preview("Connected, update available") {
    SettingsView(model: .preview(
        feedback: .success("Connected – Paperless 3.4.2 · 189 documents"),
        updateStatus: .available(previewRelease)
    ))
}

#Preview("Plain http address") {
    SettingsView(model: .preview(address: "http://paperless.local", feedback: .error(ServerAddress.Problem.insecure.message)))
}

#Preview("Can't reach the servers") {
    SettingsView(model: .preview(
        feedback: .error("Can't reach Paperless: The Internet connection appears to be offline."),
        updateStatus: .failed("Can't reach GitHub: The Internet connection appears to be offline.")
    ))
}

#Preview("Checking") {
    SettingsView(model: .preview(feedback: .checking, updateStatus: .checking))
}
#endif
